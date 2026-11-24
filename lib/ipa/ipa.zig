//! Read metadata out of an .ipa without extracting it (libzip).
const std = @import("std");
const diag = @import("diag");
const plist = @import("plist");

pub const c = @import("c");

pub const Info = struct {
    bundle_id: []const u8,
    name: []const u8,
    version: []const u8,
    build: []const u8,
    min_os: []const u8,
    executable: []const u8,
    /// e.g. "Payload/Foo.app"
    app_dir: []const u8,
};

/// True for "Payload/<name>.app/Info.plist" (the main bundle, not nested ones).
fn isMainInfoPlist(name: []const u8) bool {
    const prefix = "Payload/";
    const suffix = ".app/Info.plist";
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, suffix)) return false;
    const middle = name[prefix.len .. name.len - suffix.len];
    return middle.len > 0 and std.mem.indexOfScalar(u8, middle, '/') == null;
}

pub fn inspect(alloc: std.mem.Allocator, path: []const u8, d: ?*diag.Diag) !Info {
    const pathz = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(pathz);

    var zerr: c_int = 0;
    const za = c.zip_open(pathz.ptr, c.ZIP_RDONLY, &zerr) orelse
        return diag.fail(d, error.BadIpa, "cannot open {s} as a zip archive (libzip error {d})", .{ path, zerr });
    defer _ = c.zip_close(za);

    const n = c.zip_get_num_entries(za, 0);
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        const raw = c.zip_get_name(za, @intCast(i), 0) orelse continue;
        const name = std.mem.span(raw);
        if (!isMainInfoPlist(name)) continue;

        var st: c.zip_stat_t = undefined;
        c.zip_stat_init(&st);
        if (c.zip_stat_index(za, @intCast(i), 0, &st) != 0) break;
        const size: usize = @intCast(st.size);
        if (size > 16 * 1024 * 1024) return diag.fail(d, error.BadIpa, "Info.plist is implausibly large", .{});

        const buf = try alloc.alloc(u8, size);
        defer alloc.free(buf);
        const zf = c.zip_fopen_index(za, @intCast(i), 0) orelse
            return diag.fail(d, error.BadIpa, "cannot read {s}", .{name});
        defer _ = c.zip_fclose(zf);
        if (c.zip_fread(zf, buf.ptr, size) != @as(i64, @intCast(size)))
            return diag.fail(d, error.BadIpa, "short read on {s}", .{name});

        const p = try plist.parse(buf, d);
        defer p.deinit();
        const r = p.root;
        const bundle_id = r.getStr("CFBundleIdentifier") orelse
            return diag.fail(d, error.BadIpa, "{s} has no CFBundleIdentifier", .{name});
        const display = r.getStr("CFBundleDisplayName") orelse r.getStr("CFBundleName") orelse "";
        return .{
            .bundle_id = try alloc.dupe(u8, bundle_id),
            .name = try alloc.dupe(u8, display),
            .version = try alloc.dupe(u8, r.getStr("CFBundleShortVersionString") orelse ""),
            .build = try alloc.dupe(u8, r.getStr("CFBundleVersion") orelse ""),
            .min_os = try alloc.dupe(u8, r.getStr("MinimumOSVersion") orelse ""),
            .executable = try alloc.dupe(u8, r.getStr("CFBundleExecutable") orelse ""),
            .app_dir = try alloc.dupe(u8, name[0 .. name.len - "/Info.plist".len]),
        };
    }
    return diag.fail(d, error.BadIpa, "{s} has no Payload/*.app/Info.plist", .{path});
}

/// Read `name` (e.g. "embedded.mobileprovision") from the main app bundle.
pub fn readMainBundleFile(alloc: std.mem.Allocator, path: []const u8, name: []const u8, d: ?*diag.Diag) ![]u8 {
    const pathz = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(pathz);
    var zerr: c_int = 0;
    const za = c.zip_open(pathz.ptr, c.ZIP_RDONLY, &zerr) orelse
        return diag.fail(d, error.BadIpa, "cannot open {s} as a zip archive (libzip error {d})", .{ path, zerr });
    defer _ = c.zip_close(za);

    const n = c.zip_get_num_entries(za, 0);
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        const raw = c.zip_get_name(za, @intCast(i), 0) orelse continue;
        const entry = std.mem.span(raw);
        const prefix = "Payload/";
        if (!std.mem.startsWith(u8, entry, prefix)) continue;
        const rest = entry[prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        if (!std.mem.endsWith(u8, rest[0..slash], ".app") or !std.mem.eql(u8, rest[slash + 1 ..], name)) continue;

        var st: c.zip_stat_t = undefined;
        c.zip_stat_init(&st);
        if (c.zip_stat_index(za, @intCast(i), 0, &st) != 0) break;
        const size: usize = @intCast(st.size);
        const buf = try alloc.alloc(u8, size);
        errdefer alloc.free(buf);
        const zf = c.zip_fopen_index(za, @intCast(i), 0) orelse return diag.fail(d, error.BadIpa, "cannot read {s}", .{entry});
        defer _ = c.zip_fclose(zf);
        if (c.zip_fread(zf, buf.ptr, size) != @as(i64, @intCast(size))) return diag.fail(d, error.BadIpa, "short read on {s}", .{entry});
        return buf;
    }
    return diag.fail(d, error.FileNotFound, "{s} has no {s} in its app bundle", .{ path, name });
}

test "main info plist matcher" {
    try std.testing.expect(isMainInfoPlist("Payload/Foo.app/Info.plist"));
    try std.testing.expect(!isMainInfoPlist("Payload/Foo.app/PlugIns/W.appex/Info.plist"));
    try std.testing.expect(!isMainInfoPlist("Payload/.app/Info.plist"));
    try std.testing.expect(!isMainInfoPlist("Foo.app/Info.plist"));
}
