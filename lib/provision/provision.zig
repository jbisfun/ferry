//! Where signing material comes from.
//!
//! An *identity* is a directory under `<data>/identities/<name>/` backed by a
//! provider:
//!
//!   files  a certificate (`*.p12`, optional `password` file) plus one or more
//!          `*.mobileprovision` profiles. Works for paid teams, certificates
//!          exported from Xcode, Jimpactor (`account export-p12`) or AltServer.
//!   exec   `provider.json` = {"exec": ["cmd", "arg", ...]}. The command is
//!          run with one more argument, the request as JSON:
//!          {"bundle_id": "...", "udid": "..."|null, "ipa": path|null}
//!          and prints {"p12": path, "password": "...", "profile": path,
//!          "bundle_id": "..."} on stdout.
//!          This is the plugin seam for Apple-account provisioning (e.g. a
//!          helper built on xkit + omnisette) without linking it in here.
//!
//! The provider only answers "which cert + profile + final bundle id"; it
//! never signs. That keeps profile selection in exactly one place.
const std = @import("std");
const diag = @import("diag");
const plist = @import("plist");

const Io = std.Io;
const Dir = std.Io.Dir;

pub const Profile = struct {
    path: []const u8,
    name: []const u8,
    team_id: []const u8,
    /// Entitlements application-identifier, e.g. "ABCDE12345.com.foo.*".
    app_id: []const u8,
    devices: []const []const u8,
    all_devices: bool,
    /// Unix seconds; 0 when the profile has no ExpirationDate.
    expires: i64,

    /// The bundle-id part of app_id ("com.foo.*").
    pub fn bundlePattern(self: Profile) []const u8 {
        const prefix_len = self.team_id.len + 1;
        if (self.app_id.len > prefix_len and std.mem.startsWith(u8, self.app_id, self.team_id) and self.app_id[self.team_id.len] == '.')
            return self.app_id[prefix_len..];
        return self.app_id;
    }

    pub fn coversDevice(self: Profile, udid: ?[]const u8) bool {
        const u = udid orelse return true;
        if (self.all_devices) return true;
        for (self.devices) |dev| if (std.ascii.eqlIgnoreCase(dev, u)) return true;
        return false;
    }
};

/// Does a bundle pattern ("com.foo.*", "*", "com.foo.app") cover `bundle_id`?
pub fn patternMatches(pattern: []const u8, bundle_id: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.endsWith(u8, pattern, ".*")) {
        const stem = pattern[0 .. pattern.len - 1]; // keep the dot
        return std.mem.startsWith(u8, bundle_id, stem);
    }
    return std.mem.eql(u8, pattern, bundle_id);
}

/// Parse a .mobileprovision already in memory. `path` is only recorded.
pub fn parseProfile(alloc: std.mem.Allocator, blob: []const u8, path: []const u8, d: ?*diag.Diag) !Profile {
    const xml = plist.embeddedXml(blob) orelse return diag.fail(d, error.BadProfile, "{s} has no embedded plist", .{path});
    const p = try plist.parse(xml, d);
    defer p.deinit();
    const r = p.root;

    const team = if (r.get("TeamIdentifier")) |t| (if (t.at(0)) |first| first.str() else null) else null;
    const app_id = r.path(&.{ "Entitlements", "application-identifier" });
    var devices: std.ArrayList([]const u8) = .empty;
    if (r.get("ProvisionedDevices")) |devs| {
        for (0..devs.len()) |i| if (devs.at(i).?.str()) |s| try devices.append(alloc, try alloc.dupe(u8, s));
    }
    return .{
        .path = try alloc.dupe(u8, path),
        .name = try alloc.dupe(u8, r.getStr("Name") orelse ""),
        .team_id = try alloc.dupe(u8, team orelse ""),
        .app_id = try alloc.dupe(u8, if (app_id) |a| a.str() orelse "" else ""),
        .devices = try devices.toOwnedSlice(alloc),
        .all_devices = if (r.get("ProvisionsAllDevices")) |n| n.boolean() orelse false else false,
        .expires = if (r.get("ExpirationDate")) |n| n.date() orelse 0 else 0,
    };
}

pub fn readProfile(alloc: std.mem.Allocator, io: Io, path: []const u8, d: ?*diag.Diag) !Profile {
    const blob = Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 * 1024 * 1024)) catch |e|
        return diag.fail(d, e, "cannot read profile {s}: {s}", .{ path, @errorName(e) });
    defer alloc.free(blob);
    return parseProfile(alloc, blob, path, d);
}

pub const Request = struct {
    bundle_id: []const u8,
    udid: ?[]const u8 = null,
    /// The IPA being signed, for providers that need it.
    ipa: ?[]const u8 = null,
    /// Unix seconds, for expiry checks.
    now: i64,
};

pub const Material = struct {
    p12_path: []const u8,
    password: []const u8,
    profile_path: []const u8,
    /// Bundle id to sign with; may differ from the request (see `choose`).
    bundle_id: []const u8,
    team_id: []const u8 = "",
};

pub const Choice = struct { profile: Profile, bundle_id: []const u8 };

/// Pick a profile for `req` from `profiles`. Order of preference:
///   1. explicit profile for the bundle id itself
///   2. explicit profile for "<bundle id>.<TEAMID>" (free-account convention
///      used by AltStore/SideStore/Jimpactor); the app is re-identified to it
///   3. wildcard profile covering the bundle id
/// Expired profiles and profiles missing the target device are skipped.
pub fn choose(alloc: std.mem.Allocator, profiles: []const Profile, req: Request, d: ?*diag.Diag) !Choice {
    var usable: std.ArrayList(Profile) = .empty;
    defer usable.deinit(alloc);
    for (profiles) |p| {
        if (p.expires != 0 and p.expires < req.now) continue;
        if (!p.coversDevice(req.udid)) continue;
        try usable.append(alloc, p);
    }
    for (usable.items) |p| if (std.mem.eql(u8, p.bundlePattern(), req.bundle_id)) return .{ .profile = p, .bundle_id = req.bundle_id };
    for (usable.items) |p| {
        const pat = p.bundlePattern();
        if (p.team_id.len > 0 and pat.len == req.bundle_id.len + 1 + p.team_id.len and
            std.mem.startsWith(u8, pat, req.bundle_id) and pat[req.bundle_id.len] == '.' and
            std.mem.endsWith(u8, pat, p.team_id))
            return .{ .profile = p, .bundle_id = try alloc.dupe(u8, pat) };
    }
    for (usable.items) |p| if (patternMatches(p.bundlePattern(), req.bundle_id)) return .{ .profile = p, .bundle_id = req.bundle_id };

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);
    for (profiles, 0..) |p, i| {
        if (i > 0) try list.appendSlice(alloc, ", ");
        try list.appendSlice(alloc, p.app_id);
        if (p.expires != 0 and p.expires < req.now) try list.appendSlice(alloc, " (expired)") else if (!p.coversDevice(req.udid)) try list.appendSlice(alloc, " (device not included)");
    }
    return diag.fail(d, error.NoProfile, "no usable profile for {s}; available: {s}", .{ req.bundle_id, if (list.items.len > 0) list.items else "none" });
}

// ---- providers -----------------------------------------------------------

pub const FilesProvider = struct {
    io: Io,
    dir: []const u8,

    fn scan(self: FilesProvider, alloc: std.mem.Allocator, d: ?*diag.Diag) !struct { p12: ?[]const u8, profiles: []Profile } {
        var dir = Dir.cwd().openDir(self.io, self.dir, .{ .iterate = true }) catch |e|
            return diag.fail(d, e, "cannot open identity {s}: {s}", .{ self.dir, @errorName(e) });
        defer dir.close(self.io);
        var p12: ?[]const u8 = null;
        var profiles: std.ArrayList(Profile) = .empty;
        var it = dir.iterate();
        while (try it.next(self.io)) |e| {
            if (e.kind != .file) continue;
            const full = try std.fs.path.join(alloc, &.{ self.dir, e.name });
            if (std.mem.endsWith(u8, e.name, ".p12")) {
                p12 = full;
            } else if (std.mem.endsWith(u8, e.name, ".mobileprovision")) {
                try profiles.append(alloc, try readProfile(alloc, self.io, full, d));
            }
        }
        return .{ .p12 = p12, .profiles = try profiles.toOwnedSlice(alloc) };
    }

    pub fn resolve(self: FilesProvider, alloc: std.mem.Allocator, req: Request, d: ?*diag.Diag) !Material {
        const s = try self.scan(alloc, d);
        const p12 = s.p12 orelse return diag.fail(d, error.NoCertificate, "{s} has no .p12 certificate", .{self.dir});
        const choice = try choose(alloc, s.profiles, req, d);
        return .{
            .p12_path = p12,
            .password = try readPassword(alloc, self.io, self.dir),
            .profile_path = choice.profile.path,
            .bundle_id = choice.bundle_id,
            .team_id = choice.profile.team_id,
        };
    }

    pub fn describe(self: FilesProvider, alloc: std.mem.Allocator) ![]const u8 {
        var d: diag.Diag = .{};
        const s = self.scan(alloc, &d) catch return alloc.dupe(u8, d.message());
        var teams: std.ArrayList(u8) = .empty;
        for (s.profiles) |p| {
            if (std.mem.indexOf(u8, teams.items, p.team_id) != null) continue;
            if (teams.items.len > 0) try teams.appendSlice(alloc, ",");
            try teams.appendSlice(alloc, p.team_id);
        }
        return std.fmt.allocPrint(alloc, "{s}, {d} profile(s), team {s}", .{
            if (s.p12 != null) "certificate" else "NO certificate", s.profiles.len, if (teams.items.len > 0) teams.items else "?",
        });
    }
};

pub fn readPassword(alloc: std.mem.Allocator, io: Io, dir: []const u8) ![]const u8 {
    const path = try std.fs.path.join(alloc, &.{ dir, "password" });
    const raw = Dir.cwd().readFileAlloc(io, path, alloc, .limited(4096)) catch return "";
    return std.mem.trimEnd(u8, raw, "\r\n");
}

pub const ExecProvider = struct {
    io: Io,
    argv: []const []const u8,

    pub fn resolve(self: ExecProvider, alloc: std.mem.Allocator, req: Request, d: ?*diag.Diag) !Material {
        const request = try std.json.Stringify.valueAlloc(alloc, .{ .bundle_id = req.bundle_id, .udid = req.udid, .ipa = req.ipa }, .{});
        const argv = try std.mem.concat(alloc, []const u8, &.{ self.argv, &.{request} });
        const res = std.process.run(alloc, self.io, .{ .argv = argv, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) }) catch |e|
            return diag.fail(d, e, "cannot run provider {s}: {s}", .{ self.argv[0], @errorName(e) });
        if (res.term != .exited or res.term.exited != 0)
            return diag.fail(d, error.ProviderFailed, "provider {s} failed: {s}", .{ self.argv[0], std.mem.trim(u8, res.stderr, " \r\n") });

        const Reply = struct { p12: []const u8, password: []const u8 = "", profile: []const u8, bundle_id: ?[]const u8 = null, team_id: []const u8 = "" };
        const r = std.json.parseFromSliceLeaky(Reply, alloc, res.stdout, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
            return diag.fail(d, error.ProviderFailed, "provider {s} printed invalid JSON", .{self.argv[0]});
        return .{ .p12_path = r.p12, .password = r.password, .profile_path = r.profile, .bundle_id = r.bundle_id orelse req.bundle_id, .team_id = r.team_id };
    }

    pub fn describe(self: ExecProvider, alloc: std.mem.Allocator) ![]const u8 {
        return std.mem.join(alloc, " ", self.argv);
    }
};

pub const Provider = union(enum) {
    files: FilesProvider,
    exec: ExecProvider,

    pub fn resolve(self: Provider, alloc: std.mem.Allocator, req: Request, d: ?*diag.Diag) !Material {
        return switch (self) {
            inline else => |p| p.resolve(alloc, req, d),
        };
    }

    pub fn describe(self: Provider, alloc: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            inline else => |p| p.describe(alloc),
        };
    }
};

fn validName(name: []const u8) bool {
    return name.len > 0 and std.mem.indexOfAny(u8, name, "/\\") == null and !std.mem.eql(u8, name, "..") and !std.mem.eql(u8, name, ".");
}

/// The identities directory.
pub const Store = struct {
    io: Io,
    root: []const u8,

    pub const Entry = struct { name: []const u8, provider: Provider };

    pub fn open(self: Store, alloc: std.mem.Allocator, name: []const u8, d: ?*diag.Diag) !Provider {
        if (!validName(name)) return diag.fail(d, error.BadName, "invalid identity name '{s}'", .{name});
        const dir = try std.fs.path.join(alloc, &.{ self.root, name });
        Dir.cwd().access(self.io, dir, .{}) catch return diag.fail(d, error.NoIdentity, "no identity named '{s}' in {s}", .{ name, self.root });
        const cfg_path = try std.fs.path.join(alloc, &.{ dir, "provider.json" });
        if (Dir.cwd().readFileAlloc(self.io, cfg_path, alloc, .limited(64 * 1024))) |raw| {
            const Cfg = struct { exec: []const []const u8 };
            const cfg = std.json.parseFromSliceLeaky(Cfg, alloc, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
                return diag.fail(d, error.BadIdentity, "{s} is not {{\"exec\": [...]}}", .{cfg_path});
            if (cfg.exec.len == 0) return diag.fail(d, error.BadIdentity, "{s}: exec is empty", .{cfg_path});
            return .{ .exec = .{ .io = self.io, .argv = cfg.exec } };
        } else |_| {}
        return .{ .files = .{ .io = self.io, .dir = dir } };
    }

    pub fn list(self: Store, alloc: std.mem.Allocator) ![]Entry {
        var out: std.ArrayList(Entry) = .empty;
        var dir = Dir.cwd().openDir(self.io, self.root, .{ .iterate = true }) catch return out.toOwnedSlice(alloc);
        defer dir.close(self.io);
        var it = dir.iterate();
        while (try it.next(self.io)) |e| {
            if (e.kind != .directory) continue;
            const name = try alloc.dupe(u8, e.name);
            const p = self.open(alloc, name, null) catch continue;
            try out.append(alloc, .{ .name = name, .provider = p });
        }
        std.mem.sort(Entry, out.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
        return out.toOwnedSlice(alloc);
    }

    /// Open (creating) the directory for identity `name`.
    pub fn create(self: Store, name: []const u8, d: ?*diag.Diag) !Dir {
        if (!validName(name)) return diag.fail(d, error.BadName, "invalid identity name '{s}'", .{name});
        var root = try Dir.cwd().createDirPathOpen(self.io, self.root, .{});
        defer root.close(self.io);
        return root.createDirPathOpen(self.io, name, .{});
    }

    /// Create a files identity by copying a certificate and profiles in.
    pub fn addFiles(self: Store, alloc: std.mem.Allocator, name: []const u8, p12: []const u8, password: ?[]const u8, profiles: []const []const u8, d: ?*diag.Diag) !void {
        var dir = try self.create(name, d);
        defer dir.close(self.io);
        Dir.cwd().copyFile(p12, dir, "identity.p12", self.io, .{}) catch |e|
            return diag.fail(d, e, "cannot copy {s}: {s}", .{ p12, @errorName(e) });
        for (profiles) |src| {
            _ = try readProfile(alloc, self.io, src, d); // validate before copying
            Dir.cwd().copyFile(src, dir, std.fs.path.basename(src), self.io, .{}) catch |e|
                return diag.fail(d, e, "cannot copy {s}: {s}", .{ src, @errorName(e) });
        }
        if (password) |pw| try writeSecret(self.io, dir, "password", pw);
    }
};

/// Write a file readable only by the owner.
pub fn writeSecret(io: Io, dir: Dir, name: []const u8, data: []const u8) !void {
    var f = try dir.createFile(io, name, .{ .permissions = .fromMode(0o600) });
    defer f.close(io);
    try f.writeStreamingAll(io, data);
}

// ---- tests ---------------------------------------------------------------

test "pattern matching" {
    try std.testing.expect(patternMatches("*", "a.b"));
    try std.testing.expect(patternMatches("com.foo.*", "com.foo.bar"));
    try std.testing.expect(!patternMatches("com.foo.*", "com.foobar"));
    try std.testing.expect(patternMatches("com.foo", "com.foo"));
}

fn testProfile(app_id: []const u8, devices: []const []const u8, expires: i64) Profile {
    return .{ .path = app_id, .name = "", .team_id = "TEAM123456", .app_id = app_id, .devices = devices, .all_devices = false, .expires = expires };
}

test "choose prefers exact, then free-account suffix, then wildcard" {
    const a = std.testing.allocator;
    const devs: []const []const u8 = &.{"UDID1"};
    const profiles = [_]Profile{
        testProfile("TEAM123456.*", devs, 0),
        testProfile("TEAM123456.com.x.app.TEAM123456", devs, 0),
        testProfile("TEAM123456.com.y", devs, 0),
    };
    const exact = try choose(a, &profiles, .{ .bundle_id = "com.y", .udid = "udid1", .now = 1 }, null);
    try std.testing.expectEqualStrings("com.y", exact.bundle_id);

    const suffixed = try choose(a, &profiles, .{ .bundle_id = "com.x.app", .udid = "UDID1", .now = 1 }, null);
    defer a.free(suffixed.bundle_id);
    try std.testing.expectEqualStrings("com.x.app.TEAM123456", suffixed.bundle_id);

    const wild = try choose(a, &profiles, .{ .bundle_id = "org.other", .udid = null, .now = 1 }, null);
    try std.testing.expectEqualStrings("TEAM123456.*", wild.profile.app_id);
}

test "choose skips expired and wrong device" {
    const a = std.testing.allocator;
    const profiles = [_]Profile{
        testProfile("TEAM123456.com.y", &.{"OTHER"}, 0),
        testProfile("TEAM123456.*", &.{"UDID1"}, 10),
    };
    var d: diag.Diag = .{};
    try std.testing.expectError(error.NoProfile, choose(a, &profiles, .{ .bundle_id = "com.y", .udid = "UDID1", .now = 100 }, &d));
    try std.testing.expect(std.mem.indexOf(u8, d.message(), "(expired)") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.message(), "(device not included)") != null);
}
