//! Code signing. One backend today (zsign, compiled in); the interface is just
//! "IPA + certificate + profile in, signed IPA out" so another backend
//! (apple-codesign via its C API, ldid) can slot in behind `signIpa`.
const std = @import("std");
const diag = @import("diag");

extern fn ferry_zsign_ipa(
    input: [*:0]const u8,
    output: [*:0]const u8,
    p12: [*:0]const u8,
    password: [*:0]const u8,
    profile: [*:0]const u8,
    bundle_id: ?[*:0]const u8,
    display_name: ?[*:0]const u8,
    dylibs: ?[*]const [*:0]const u8,
    ndylibs: usize,
    tmp_dir: [*:0]const u8,
    verbose: c_int,
) c_int;

extern fn ferry_make_p12(
    cert_der: [*]const u8,
    cert_len: usize,
    key_der: [*]const u8,
    key_len: usize,
    password: [*:0]const u8,
    name: [*:0]const u8,
    out: *?[*]u8,
    out_len: *usize,
) c_int;

/// Build a .p12 from a certificate and private key (DER or PEM, PKCS#1 or #8).
/// Caller frees the result with `alloc`.
pub fn makeP12(alloc: std.mem.Allocator, cert_der: []const u8, key_der: []const u8, password: [:0]const u8, name: [:0]const u8, d: ?*diag.Diag) ![]u8 {
    var out: ?[*]u8 = null;
    var len: usize = 0;
    const rc = ferry_make_p12(cert_der.ptr, cert_der.len, key_der.ptr, key_der.len, password.ptr, name.ptr, &out, &len);
    if (rc != 0) return diag.fail(d, error.BadIdentity, "{s}", .{switch (rc) {
        1 => "certificate is neither DER nor PEM",
        2 => "private key is neither DER nor PEM",
        3 => "private key does not belong to the certificate",
        else => "OpenSSL could not build the .p12",
    }});
    defer std.c.free(out);
    return alloc.dupe(u8, out.?[0..len]);
}

pub const Options = struct {
    input: []const u8,
    output: []const u8,
    p12: []const u8,
    password: []const u8 = "",
    profile: []const u8,
    /// New main bundle id; nested bundles are re-prefixed to match.
    bundle_id: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    /// Dylibs/frameworks to inject into the main executable.
    inject: []const []const u8 = &.{},
    tmp_dir: []const u8 = "/tmp",
    verbose: bool = false,
};

/// zsign keeps process-global state (log level, OpenSSL init); serialize.
var lock: std.Io.Mutex = .init;

pub fn signIpa(alloc: std.mem.Allocator, io: std.Io, o: Options, d: ?*diag.Diag) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const dylibs = try a.alloc([*:0]const u8, o.inject.len);
    for (o.inject, 0..) |p, i| dylibs[i] = try a.dupeSentinel(u8, p, 0);

    try lock.lock(io);
    defer lock.unlock(io);
    const rc = ferry_zsign_ipa(
        try a.dupeSentinel(u8, o.input, 0),
        try a.dupeSentinel(u8, o.output, 0),
        try a.dupeSentinel(u8, o.p12, 0),
        try a.dupeSentinel(u8, o.password, 0),
        try a.dupeSentinel(u8, o.profile, 0),
        if (o.bundle_id) |b| try a.dupeSentinel(u8, b, 0) else null,
        if (o.display_name) |n| try a.dupeSentinel(u8, n, 0) else null,
        if (dylibs.len > 0) dylibs.ptr else null,
        dylibs.len,
        try a.dupeSentinel(u8, o.tmp_dir, 0),
        @intFromBool(o.verbose),
    );
    return switch (rc) {
        0 => {},
        1 => diag.fail(d, error.BadIdentity, "zsign rejected the certificate/profile (wrong p12 password, or the profile does not match the certificate)", .{}),
        2 => diag.fail(d, error.BadIpa, "zsign could not extract {s}", .{o.input}),
        3 => diag.fail(d, error.SignFailed, "zsign failed while signing the bundle", .{}),
        4 => diag.fail(d, error.BadIpa, "{s} has no Payload directory", .{o.input}),
        5 => diag.fail(d, error.WriteFailed, "zsign could not write {s}", .{o.output}),
        else => diag.fail(d, error.SignFailed, "zsign returned {d}", .{rc}),
    };
}

test "missing input fails cleanly" {
    var d: diag.Diag = .{};
    const r = signIpa(std.testing.allocator, std.testing.io, .{ .input = "/nonexistent.ipa", .output = "/tmp/x.ipa", .p12 = "/nonexistent.p12", .profile = "/nonexistent.mobileprovision" }, &d);
    try std.testing.expectError(error.BadIdentity, r);
}
