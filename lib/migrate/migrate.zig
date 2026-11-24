//! Importers for data from other sideloading tools. Each importer only
//! translates files into Ferry's own layout; nothing here talks to Apple.
//!
//! Jimpactor (~/.config/Jimpactor):
//!   pairings/<UDID>.plist   lockdown pairing records -> <data>/pairings/, and
//!                           handed to usbmuxd when it is running (the daemon
//!                           retries when the device next appears)
//!   xkit/data/<TEAM>        signing certificate + private key -> a p12 in
//!                           identities/jimpactor-<TEAM>/
//!   accounts.json           which Apple ID/team the identity belongs to
//! Provisioning profiles are not stored by Jimpactor (it fetches them per
//! install), so the identity gets an exec provider that asks jimpactor-cli for
//! one and caches it; see `jimpactorProvide`.
const std = @import("std");
const diag = @import("diag");
const plist = @import("plist");
const provision = @import("provision");
const signing = @import("signing");
const device = @import("device");
const ipa = @import("ipa");

const Io = std.Io;
const Dir = std.Io.Dir;

pub const Target = struct {
    /// Ferry data dir; pairings go to <data>/pairings.
    data: []const u8,
    identities: []const u8,
    tmp: []const u8,
    /// Absolute path of the `ferry` CLI, used in provider.json.
    ferry_exe: []const u8,
};

pub const Report = struct {
    imported: std.ArrayList([]const u8) = .empty,
    skipped: std.ArrayList([]const u8) = .empty,

    fn add(list: *std.ArrayList([]const u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        try list.append(alloc, try std.fmt.allocPrint(alloc, fmt, args));
    }
};

pub fn defaultJimpactorDir(alloc: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |x| return std.fs.path.join(alloc, &.{ std.mem.span(x), "Jimpactor" });
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";
    return std.fs.path.join(alloc, &.{ home, ".config", "Jimpactor" });
}

/// Where jimpactor-cli lives: $JIMPACTOR_CLI, PATH, then the usual dev build.
pub fn findJimpactorCli(alloc: std.mem.Allocator, io: Io) ?[]const u8 {
    if (std.c.getenv("JIMPACTOR_CLI")) |p| return alloc.dupe(u8, std.mem.span(p)) catch null;
    if (std.c.getenv("PATH")) |path| {
        var it = std.mem.tokenizeScalar(u8, std.mem.span(path), ':');
        while (it.next()) |dir| {
            const full = std.fs.path.join(alloc, &.{ dir, "jimpactor-cli" }) catch continue;
            if (Dir.cwd().access(io, full, .{ .execute = true })) |_| return full else |_| {}
        }
    }
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return null;
    for ([_][]const u8{ "projs/jimpactor/target/release/jimpactor-cli", "projs/jimpactor/target/debug/jimpactor-cli" }) |rel| {
        const full = std.fs.path.join(alloc, &.{ home, rel }) catch continue;
        if (Dir.cwd().access(io, full, .{ .execute = true })) |_| return full else |_| {}
    }
    return null;
}

fn isUdid(s: []const u8) bool {
    if (s.len == 25 and s[8] == '-') {
        for (s, 0..) |ch, i| if (i != 8 and !std.ascii.isHex(ch)) return false;
        return true;
    }
    if (s.len == 40) {
        for (s) |ch| if (!std.ascii.isHex(ch)) return false;
        return true;
    }
    return false;
}

pub fn importJimpactor(alloc: std.mem.Allocator, io: Io, src: []const u8, t: Target, d: ?*diag.Diag) !Report {
    var report: Report = .{};
    var root = Dir.cwd().openDir(io, src, .{}) catch |e|
        return diag.fail(d, e, "no Jimpactor data at {s} ({s})", .{ src, @errorName(e) });
    defer root.close(io);

    try importPairings(alloc, io, root, t, &report);
    try importIdentities(alloc, io, root, src, t, &report);

    for ([_][]const u8{ "wifi_devices.plist", "tailscale_keys.json", "anisette.json" }) |name| {
        if (root.access(io, name, .{})) |_| {
            try Report.add(&report.skipped, alloc, "{s}: not used by Ferry (Wi-Fi devices are reached through usbmuxd; no Tailscale or anisette yet)", .{name});
        } else |_| {}
    }
    return report;
}

fn importPairings(alloc: std.mem.Allocator, io: Io, root: Dir, t: Target, report: *Report) !void {
    var dir = root.openDir(io, "pairings", .{ .iterate = true }) catch return;
    defer dir.close(io);
    const dest_path = try std.fs.path.join(alloc, &.{ t.data, "pairings" });
    var dest = try Dir.cwd().createDirPathOpen(io, dest_path, .{});
    defer dest.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".plist")) continue;
        const udid = e.name[0 .. e.name.len - ".plist".len];
        if (!isUdid(udid)) {
            try Report.add(&report.skipped, alloc, "pairings/{s}: file name is not a UDID", .{e.name});
            continue;
        }
        const bytes = try dir.readFileAlloc(io, e.name, alloc, .limited(1 << 20));
        const p = plist.parse(bytes, null) catch {
            try Report.add(&report.skipped, alloc, "pairings/{s}: not a property list", .{e.name});
            continue;
        };
        defer p.deinit();
        if (p.root.get("HostCertificate") == null or p.root.get("HostPrivateKey") == null) {
            try Report.add(&report.skipped, alloc, "pairings/{s}: not a lockdown pairing record", .{e.name});
            continue;
        }
        try provision.writeSecret(io, dest, e.name, bytes);
        const status = pushPairRecord(udid, bytes);
        try Report.add(&report.imported, alloc, "pairing record for {s} -> {s}/{s} ({s})", .{ udid, dest_path, e.name, status });
    }
}

/// Give a staged record to usbmuxd unless it already has one.
pub fn pushPairRecord(udid: []const u8, bytes: []const u8) []const u8 {
    if (device.hasPairRecord(udid)) return "usbmuxd already has a record";
    device.savePairRecord(udid, bytes, null) catch return "usbmuxd not running; handed over when the device appears";
    return "saved to usbmuxd";
}

fn importIdentities(alloc: std.mem.Allocator, io: Io, root: Dir, src: []const u8, t: Target, report: *Report) !void {
    // accounts.json: { accounts: { email: { email, team_id, ... } }, selected_account }
    const Account = struct { email: []const u8 = "", first_name: []const u8 = "", team_id: []const u8 = "" };
    var accounts: []const Account = &.{};
    if (root.readFileAlloc(io, "accounts.json", alloc, .limited(1 << 20))) |raw| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch null;
        if (parsed) |v| if (v == .object) if (v.object.get("accounts")) |acc| if (acc == .object) {
            var list: std.ArrayList(Account) = .empty;
            var ait = acc.object.iterator();
            while (ait.next()) |kv| {
                const a = std.json.parseFromValueLeaky(Account, alloc, kv.value_ptr.*, .{ .ignore_unknown_fields = true }) catch continue;
                try list.append(alloc, a);
            }
            accounts = list.items;
        };
    } else |_| {}

    var dir = root.openDir(io, "xkit/data", .{ .iterate = true }) catch {
        try Report.add(&report.skipped, alloc, "no signing certificates in {s}/xkit/data (sign in with Jimpactor once to create one)", .{src});
        return;
    };
    defer dir.close(io);
    const cli = findJimpactorCli(alloc, io);

    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        const team = e.name;
        const bytes = try dir.readFileAlloc(io, team, alloc, .limited(1 << 20));
        const p = plist.parse(bytes, null) catch {
            try Report.add(&report.skipped, alloc, "xkit/data/{s}: not a property list", .{team});
            continue;
        };
        defer p.deinit();
        const cert = if (p.root.get("certificate")) |n| n.data() else null;
        const key = if (p.root.path(&.{ "privateKey", "data" })) |n| n.data() else null;
        if (cert == null or key == null) {
            try Report.add(&report.skipped, alloc, "xkit/data/{s}: no certificate/private key", .{team});
            continue;
        }

        var pw_raw: [12]u8 = undefined;
        io.random(&pw_raw);
        var pw_hex: [24]u8 = undefined;
        const pw = std.fmt.bufPrint(&pw_hex, "{x}", .{&pw_raw}) catch unreachable;
        const pwz = try alloc.dupeSentinel(u8, pw, 0);
        const label = try std.fmt.allocPrintSentinel(alloc, "Jimpactor {s}", .{team}, 0);
        var d: diag.Diag = .{};
        const p12 = signing.makeP12(alloc, cert.?, key.?, pwz, label, &d) catch {
            try Report.add(&report.skipped, alloc, "xkit/data/{s}: {s}", .{ team, d.message() });
            continue;
        };

        const name = try std.fmt.allocPrint(alloc, "jimpactor-{s}", .{team});
        const store: provision.Store = .{ .io = io, .root = t.identities };
        var idir = try store.create(name, null);
        defer idir.close(io);
        try provision.writeSecret(io, idir, "identity.p12", p12);
        try provision.writeSecret(io, idir, "password", pw);
        try idir.createDirPath(io, "profiles");

        var email: []const u8 = "";
        for (accounts) |a| if (std.mem.eql(u8, a.team_id, team)) {
            email = a.email;
        };
        const id_dir = try std.fs.path.join(alloc, &.{ t.identities, name });
        const meta = try std.json.Stringify.valueAlloc(alloc, .{ .source = "jimpactor", .team_id = team, .apple_id = email }, .{ .whitespace = .indent_2 });
        try idir.writeFile(io, .{ .sub_path = "account.json", .data = meta });

        if (cli) |cli_path| {
            const cfg = try std.json.Stringify.valueAlloc(alloc, .{ .exec = &[_][]const u8{ t.ferry_exe, "provider", "jimpactor", "--team", team, "--cli", cli_path, "--identity", id_dir } }, .{ .whitespace = .indent_2 });
            try idir.writeFile(io, .{ .sub_path = "provider.json", .data = cfg });
            try Report.add(&report.imported, alloc, "certificate for team {s}{s}{s} -> identity '{s}' (profiles fetched through {s})", .{ team, if (email.len > 0) " / " else "", email, name, cli_path });
        } else {
            try Report.add(&report.imported, alloc, "certificate for team {s} -> identity '{s}'; jimpactor-cli not found, so add .mobileprovision files to {s} yourself", .{ team, name, id_dir });
        }
    }
}

// ---- exec provider bridge -------------------------------------------------

pub const BridgeArgs = struct {
    team: []const u8,
    cli: []const u8,
    identity_dir: []const u8,
    tmp: []const u8,
};

pub const Reply = struct {
    p12: []const u8,
    password: []const u8,
    profile: []const u8,
    bundle_id: []const u8,
    team_id: []const u8,
};

/// Answer an exec-provider request for an imported Jimpactor identity:
/// reuse a cached profile from <identity>/profiles when one still fits (more
/// than a day left), otherwise run `jimpactor-cli sign --apple-id` on the IPA
/// (which registers the app and fetches its profile with the Apple ID
/// Jimpactor is signed in to) and keep the profile it embedded.
pub fn jimpactorProvide(alloc: std.mem.Allocator, io: Io, args: BridgeArgs, req: provision.Request, d: ?*diag.Diag) !Reply {
    const profiles_dir = try std.fs.path.join(alloc, &.{ args.identity_dir, "profiles" });
    const p12 = try std.fs.path.join(alloc, &.{ args.identity_dir, "identity.p12" });
    const password = try provision.readPassword(alloc, io, args.identity_dir);

    // Cached profiles, minus those expiring within a day.
    var cached: std.ArrayList(provision.Profile) = .empty;
    if (Dir.cwd().openDir(io, profiles_dir, .{ .iterate = true })) |pd_const| {
        var pd = pd_const;
        defer pd.close(io);
        var it = pd.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".mobileprovision")) continue;
            const full = try std.fs.path.join(alloc, &.{ profiles_dir, e.name });
            const prof = provision.readProfile(alloc, io, full, null) catch continue;
            if (prof.expires != 0 and prof.expires < req.now + 86400) continue;
            try cached.append(alloc, prof);
        }
    } else |_| {}
    if (provision.choose(alloc, cached.items, req, null)) |choice| {
        return .{ .p12 = p12, .password = password, .profile = choice.profile.path, .bundle_id = choice.bundle_id, .team_id = choice.profile.team_id };
    } else |_| {}

    const src = req.ipa orelse return diag.fail(d, error.NoIpa, "no cached profile for {s}, and no IPA to provision it with", .{req.bundle_id});
    const info = try ipa.inspect(alloc, src, d);
    const out = try std.fmt.allocPrint(alloc, "{s}/jimpactor-{d}.ipa", .{ args.tmp, Io.Clock.real.now(io).toMilliseconds() });
    defer Dir.cwd().deleteFile(io, out) catch {};

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ args.cli, "sign", "--apple-id", "--team-id", args.team, "--package", src, "--output", out, "--tweak-loader", "none" });
    if (!std.mem.eql(u8, req.bundle_id, info.bundle_id)) try argv.appendSlice(alloc, &.{ "--custom-identifier", req.bundle_id });
    const res = std.process.run(alloc, io, .{ .argv = argv.items, .stdout_limit = .limited(8 << 20), .stderr_limit = .limited(8 << 20) }) catch |e|
        return diag.fail(d, e, "cannot run {s}: {s}", .{ args.cli, @errorName(e) });
    if (res.term != .exited or res.term.exited != 0) {
        const tail = lastLine(res.stderr) orelse lastLine(res.stdout) orelse "no output";
        return diag.fail(d, error.ProviderFailed, "jimpactor-cli could not provision {s}: {s}", .{ req.bundle_id, tail });
    }

    const blob = try ipa.readMainBundleFile(alloc, out, "embedded.mobileprovision", d);
    const prof_tmp = try provision.parseProfile(alloc, blob, "embedded.mobileprovision", d);
    const file_name = try std.fmt.allocPrint(alloc, "{s}.mobileprovision", .{prof_tmp.bundlePattern()});
    var pd = try Dir.cwd().createDirPathOpen(io, profiles_dir, .{});
    defer pd.close(io);
    try pd.writeFile(io, .{ .sub_path = file_name, .data = blob });
    const path = try std.fs.path.join(alloc, &.{ profiles_dir, file_name });
    const prof = try provision.readProfile(alloc, io, path, d);
    const choice = try provision.choose(alloc, &.{prof}, req, d);
    return .{ .p12 = p12, .password = password, .profile = path, .bundle_id = choice.bundle_id, .team_id = prof.team_id };
}

fn lastLine(s: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, s, " \r\n");
    if (t.len == 0) return null;
    const i = std.mem.lastIndexOfScalar(u8, t, '\n') orelse return t;
    return t[i + 1 ..];
}

test "udid shapes" {
    try std.testing.expect(isUdid("00008130-000A7D6901E0001C"));
    try std.testing.expect(isUdid("0123456789abcdef0123456789abcdef01234567"));
    try std.testing.expect(!isUdid("plume_00008130"));
}
