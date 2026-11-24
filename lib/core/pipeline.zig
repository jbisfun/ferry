//! Long-running operations as explicit, ordered steps. Each step reports
//! through the service (step name + percent), so every front end shows the
//! same progress and the same failure point without its own copy of the flow.
//!
//!   install: inspect -> provision -> sign -> upload -> install
//!   sign:    inspect -> provision -> sign
const std = @import("std");
const diag = @import("diag");
const protocol = @import("protocol");
const ipa = @import("ipa");
const device = @import("device");
const provision = @import("provision");
const signing = @import("signing");
const core = @import("core.zig");
const i18n = @import("i18n");

/// Step and state names travel as English keys; front ends show tr(name).
/// Listed here so the catalog extractor sees them.
pub const step_names = [_][]const u8{
    i18n.N_("inspect"), i18n.N_("provision"), i18n.N_("sign"),      i18n.N_("upload"),
    i18n.N_("install"), i18n.N_("running"),   i18n.N_("succeeded"), i18n.N_("failed"),
};

pub const Kind = enum { install, sign };

pub fn ParamsOf(comptime k: Kind) type {
    return switch (k) {
        .install => protocol.InstallParams,
        .sign => protocol.SignParams,
    };
}

/// Deep-copy a params struct (strings and optional strings) into `a`.
fn dupeParams(comptime T: type, a: std.mem.Allocator, p: T) !T {
    var out = p;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, FT| {
        if (FT == []const u8) {
            @field(out, name) = try a.dupe(u8, @field(p, name));
        } else if (FT == ?[]const u8) {
            if (@field(p, name)) |s| @field(out, name) = try a.dupe(u8, s);
        }
    }
    return out;
}

pub fn Job(comptime kind: Kind) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        svc: *core.Service,
        id: u32,
        params: ParamsOf(kind),

        pub fn create(gpa: std.mem.Allocator, svc: *core.Service, id: u32, params: ParamsOf(kind)) !*Self {
            const self = try gpa.create(Self);
            self.* = .{ .gpa = gpa, .arena = .init(gpa), .svc = svc, .id = id, .params = undefined };
            self.params = dupeParams(ParamsOf(kind), self.arena.allocator(), params) catch |e| {
                self.destroy();
                return e;
            };
            return self;
        }

        pub fn destroy(self: *Self) void {
            self.arena.deinit();
            self.gpa.destroy(self);
        }

        pub fn run(self: *Self) void {
            const svc = self.svc;
            defer svc.jobDone();
            defer self.destroy();
            var d: diag.Diag = .{};
            const msg = switch (kind) {
                .install => self.install(&d),
                .sign => self.sign(&d),
            } catch |e| {
                std.log.scoped(.job).warn("job {d} failed: {s}", .{ self.id, diag.describe(&d, e) });
                svc.finish(self.id, false, diag.describe(&d, e));
                return;
            };
            svc.finish(self.id, true, msg);
        }

        fn step(self: *Self, name: []const u8, percent: u8, message: []const u8) void {
            self.svc.progress(self.id, name, percent, message);
        }

        /// inspect + provision + sign into `output`. Returns the bundle id used.
        fn signTo(self: *Self, src: []const u8, output: []const u8, identity: ?[]const u8, bundle_override: ?[]const u8, udid: ?[]const u8, d: *diag.Diag) !struct { info: ipa.Info, bundle_id: []const u8 } {
            const a = self.arena.allocator();
            self.step("inspect", 0, std.fs.path.basename(src));
            const info = try ipa.inspect(a, src, d);

            self.step("provision", 0, info.bundle_id);
            const provider = try self.svc.pickIdentity(a, identity, d);
            const material = try provider.resolve(a, .{
                .bundle_id = bundle_override orelse info.bundle_id,
                .udid = udid,
                .ipa = src,
                .now = std.Io.Clock.real.now(self.svc.io).toSeconds(),
            }, d);

            self.step("sign", 0, material.bundle_id);
            try signing.signIpa(a, self.svc.io, .{
                .input = src,
                .output = output,
                .p12 = material.p12_path,
                .password = material.password,
                .profile = material.profile_path,
                .bundle_id = if (std.mem.eql(u8, material.bundle_id, info.bundle_id)) null else material.bundle_id,
                .tmp_dir = self.svc.paths.tmp,
            }, d);
            self.step("sign", 100, material.bundle_id);
            return .{ .info = info, .bundle_id = material.bundle_id };
        }

        fn sign(self: *Self, d: *diag.Diag) ![]const u8 {
            const p = self.params;
            const r = try self.signTo(p.ipa, p.output, p.identity, p.bundle_id, p.udid, d);
            return i18n.trf(self.arena.allocator(), "Signed {0} as {1} -> {2}", &.{ r.info.name, r.bundle_id, p.output });
        }

        fn install(self: *Self, d: *diag.Diag) ![]const u8 {
            const p = self.params;
            const a = self.arena.allocator();

            var path = p.ipa;
            var name: []const u8 = std.fs.path.basename(p.ipa);
            var bundle_id: []const u8 = "";
            var signed_tmp: ?[]const u8 = null;
            defer if (signed_tmp) |t| std.Io.Dir.cwd().deleteFile(self.svc.io, t) catch {};

            if (p.sign) {
                const out = try std.fmt.allocPrint(a, "{s}/job-{d}.ipa", .{ self.svc.paths.tmp, self.id });
                signed_tmp = out;
                const r = try self.signTo(p.ipa, out, p.identity, p.bundle_id, p.udid, d);
                path = out;
                name = r.info.name;
                bundle_id = r.bundle_id;
            } else {
                self.step("inspect", 0, name);
                const info = try ipa.inspect(a, p.ipa, d);
                name = info.name;
                bundle_id = info.bundle_id;
            }

            const Ctx = struct {
                job: *Self,
                fn report(ctx: *anyopaque, phase: device.Phase, percent: u8, status: []const u8) void {
                    const s: *@This() = @ptrCast(@alignCast(ctx));
                    s.job.step(@tagName(phase), percent, status);
                }
            };
            var ctx: Ctx = .{ .job = self };
            self.step("upload", 0, "");
            try device.install(a, self.svc.io, p.udid, path, .{ .ctx = &ctx, .func = Ctx.report }, d);
            return i18n.trf(a, "Installed {0} ({1}) on {2}", &.{ name, bundle_id, p.udid });
        }
    };
}

test "dupeParams copies strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf = "abc".*;
    const p: protocol.InstallParams = .{ .udid = &buf, .ipa = "x", .bundle_id = "y" };
    const q = try dupeParams(protocol.InstallParams, arena.allocator(), p);
    buf[0] = 'z';
    try std.testing.expectEqualStrings("abc", q.udid);
    try std.testing.expectEqualStrings("y", q.bundle_id.?);
}
