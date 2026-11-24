//! ferry: command-line front end.
//!
//! Talks to a running ferryd when there is one (so jobs show up in the GUI
//! too), otherwise runs the same core.Service in-process. Either way every
//! command goes through the one typed dispatch table (`Service.call`), so the
//! CLI cannot drift from the GUI or the daemon.
const std = @import("std");
const clap = @import("clap");
const core = @import("core");
const client = @import("client");
const protocol = @import("protocol");
const i18n = @import("i18n");
const migrate = @import("migrate");
const tr = i18n.tr;

const Io = std.Io;
const ArgIter = std.process.Args.Iterator;

var g_io: Io = undefined;
var stdout_buf: [16 * 1024]u8 = undefined;
var stdout_fw: Io.File.Writer = undefined;
var stderr_buf: [4096]u8 = undefined;
var stderr_fw: Io.File.Writer = undefined;

const Allocator = std.mem.Allocator;

const Command = enum { devices, info, apps, install, uninstall, sign, inspect, identities, identity, import, provider, jobs, watch, daemon, schema, help };

const main_params = clap.parseParamsComptime(
    \\-h, --help     Show help (also: ferry <command> --help).
    \\    --json     Print results as JSON.
    \\    --local    Run in-process even if ferryd is running.
    \\    --remote   Require ferryd (start it if needed).
    \\<command>
    \\
);

const main_parsers = .{ .command = clap.parsers.enumeration(Command) };

const UsageLine = struct { []const u8, []const u8 };
const usage_sections = [_]struct { []const u8, []const UsageLine }{
    .{ i18n.N_("Devices:"), &.{
        .{ "devices", i18n.N_("list connected devices (USB and Wi-Fi)") },
        .{ "info [device]", i18n.N_("lockdown values") },
        .{ "apps [device]", i18n.N_("user-installed apps") },
        .{ "install [device] <ipa>", i18n.N_("sign with an identity and install") },
        .{ "uninstall [device] <bundle>", i18n.N_("remove an app") },
    } },
    .{ i18n.N_("Signing:"), &.{
        .{ "sign <ipa> -o <out>", i18n.N_("sign without installing") },
        .{ "inspect <ipa>", i18n.N_("bundle id, version, minimum iOS") },
        .{ "identities", i18n.N_("list signing identities") },
        .{ "identity add <name> --p12 F --profile F... [--password P]", "" },
        .{ "import jimpactor [DIR]", i18n.N_("import Jimpactor's pairing records and certificates") },
    } },
    .{ i18n.N_("Daemon:"), &.{
        .{ "jobs", i18n.N_("jobs known to the daemon") },
        .{ "watch", i18n.N_("stream device and job events") },
        .{ "daemon start|stop|status", "" },
        .{ "schema", i18n.N_("print the protocol's JSON Schema") },
    } },
};

fn printUsage() !void {
    const w = out();
    try w.print("{s}: ferry [--json] [--local|--remote] <command> [args]\n", .{tr("usage")});
    for (usage_sections) |sec| {
        try w.print("\n{s}\n", .{tr(sec[0])});
        for (sec[1]) |l| {
            if (l[1].len == 0) {
                try w.print("  {s}\n", .{l[0]});
            } else {
                try w.print("  {s:<29}{s}\n", .{ l[0], tr(l[1]) });
            }
        }
    }
    try w.print("\n{s}\n\n{s}\n\n", .{ tr("[device] is a UDID, UDID prefix or name; omit it when one device is connected."), tr("Global options:") });
}

var json_out = false;

// ---- errors ----------------------------------------------------------------

var fail_buf: [2048]u8 = undefined;
var fail_msg: []const u8 = "";

fn fail(comptime fmt: []const u8, args: anytype) error{Failed} {
    fail_msg = std.fmt.bufPrint(&fail_buf, fmt, args) catch fmt;
    return error.Failed;
}

/// Translated failure: `msgid` with {0}.. placeholders.
fn failT(msgid: []const u8, args: []const []const u8) error{Failed} {
    fail_msg = i18n.trfBuf(&fail_buf, msgid, args);
    return error.Failed;
}

var num_bufs: [4][24]u8 = undefined;
var num_next: usize = 0;

/// Integer as text for placeholders (small rotating buffer pool).
fn num(n: anytype) []const u8 {
    const b = &num_bufs[num_next % num_bufs.len];
    num_next += 1;
    return std.fmt.bufPrint(b, "{d}", .{n}) catch "?";
}

/// Print a translated line to stdout.
fn say(msgid: []const u8, args: []const []const u8) !void {
    var buf: [4096]u8 = undefined;
    try out().print("{s}\n", .{i18n.trfBuf(&buf, msgid, args)});
}

// ---- backend -----------------------------------------------------------------

const Backend = union(enum) {
    remote: *client.Conn,
    local: *core.Service,

    fn call(self: Backend, arena: Allocator, comptime m: protocol.Method, params: protocol.Params(m)) !protocol.Result(m) {
        switch (self) {
            .remote => |c| return c.call(arena, m, params) catch |e| switch (e) {
                error.Remote => fail("{s}", .{c.last_error.items}),
                else => failT("daemon connection: {0}", &.{@errorName(e)}),
            },
            .local => |s| {
                var d: core.Diag = .{};
                return s.call(arena, m, params, &d) catch |e| fail("{s}", .{if (d.len > 0) d.message() else @errorName(e)});
            },
        }
    }
};

const Mode = enum { auto, local, remote };

/// Event sink for in-process mode: print job progress like the remote path does.
fn localSink(_: ?*anyopaque, ev: protocol.Event) void {
    printEvent(ev);
}

fn open(gpa: Allocator, arena: Allocator, mode: Mode) !Backend {
    if (mode != .local) {
        if (client.Conn.connect(gpa, g_io)) |c| return .{ .remote = c } else |e| {
            if (mode == .remote) {
                const c = client.connectOrSpawn(gpa, g_io) catch return failT("cannot reach or start ferryd: {0}", &.{@errorName(e)});
                return .{ .remote = c };
            }
        }
    }
    const paths = try core.Paths.default(arena);
    const svc = try core.Service.create(gpa, g_io, paths, .{ .func = localSink });
    svc.ferry_exe = selfExe(arena);
    return .{ .local = svc };
}

fn closeBackend(b: Backend) void {
    switch (b) {
        .remote => |c| c.close(),
        .local => |s| s.destroy(),
    }
}

// ---- output ------------------------------------------------------------------

fn out() *Io.Writer {
    return &stdout_fw.interface;
}

/// Unbuffered-ish stderr; flushes stdout first so output stays ordered.
fn errw() *Io.Writer {
    out().flush() catch {};
    return &stderr_fw.interface;
}

fn selfExe(a: Allocator) []const u8 {
    return std.process.executablePathAlloc(g_io, a) catch "ferry";
}

fn absPath(a: Allocator, p: []const u8) ![]const u8 {
    return Io.Dir.cwd().realPathFileAlloc(g_io, p, a);
}

fn printJson(v: anytype) !void {
    try std.json.Stringify.value(v, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, out());
    try out().writeByte('\n');
}

var last_step: [32]u8 = undefined;
var last_step_len: usize = 0;
var last_pct: u8 = 255;

fn printEvent(ev: protocol.Event) void {
    const w = errw();
    defer w.flush() catch {};
    switch (ev) {
        .@"device.attached" => |d| w.print("+ {s} ({s})\n", .{ d.udid, @tagName(d.connection) }) catch {},
        .@"device.detached" => |d| w.print("- {s} ({s})\n", .{ d.udid, @tagName(d.connection) }) catch {},
        .@"job.updated" => |j| {
            if (j.state != .running or j.step.len == 0) return; // final state is printed by the caller
            const step_changed = !std.mem.eql(u8, last_step[0..last_step_len], j.step);
            if (!step_changed and j.percent / 10 == last_pct / 10) return;
            const n = @min(j.step.len, last_step.len);
            @memcpy(last_step[0..n], j.step[0..n]);
            last_step_len = n;
            last_pct = j.percent;
            const step = tr(j.step);
            w.print("  [{d:>3}%] {s}", .{ j.percent, step }) catch {};
            w.splatByteAll(' ', 11 -| displayWidth(step)) catch {};
            w.print("{s}\n", .{j.message}) catch {};
        },
    }
}

/// Terminal columns taken by `s` (East Asian wide characters count as 2).
fn displayWidth(s: []const u8) usize {
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(s) catch return s.len).iterator();
    while (it.nextCodepoint()) |cp| n += if (cp >= 0x1100 and (cp <= 0x115f or (cp >= 0x2e80 and cp <= 0xa4cf) or (cp >= 0xac00 and cp <= 0xd7a3) or (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0xfe30 and cp <= 0xfe4f) or (cp >= 0xff00 and cp <= 0xff60) or (cp >= 0xffe0 and cp <= 0xffe6))) 2 else 1;
    return n;
}

// ---- main ------------------------------------------------------------------

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const a = init.arena.allocator();
    g_io = init.io;
    stdout_fw = Io.File.stdout().writer(g_io, &stdout_buf);
    stderr_fw = Io.File.stderr().writer(g_io, &stderr_buf);
    defer out().flush() catch {};
    defer stderr_fw.interface.flush() catch {};

    i18n.initFromEnv();
    var iter = try init.minimal.args.iterateAllocator(a);
    _ = iter.next();
    var parse_diag: clap.Diagnostic = .{};
    const res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &parse_diag,
        .allocator = a,
        .terminating_positional = 0,
    }) catch |err| {
        parse_diag.report(errw(), err) catch {};
        return 2;
    };
    const command = res.positionals[0] orelse .help;
    if (res.args.help != 0 or command == .help) {
        try printUsage();
        try clap.help(out(), clap.Help, &main_params, .{});
        return if (res.args.help != 0 or command == .help) 0 else 2;
    }
    json_out = res.args.json != 0;
    const mode: Mode = if (res.args.local != 0) .local else if (res.args.remote != 0) .remote else .auto;

    dispatch(gpa, a, command, &iter, mode) catch |err| switch (err) {
        error.Failed => {
            errw().print("{s}: {s}\n", .{ tr("error"), fail_msg }) catch {};
            return 1;
        },
        error.Usage => return 2,
        error.HelpShown => return 0,
        else => return err,
    };
    return 0;
}

fn dispatch(gpa: Allocator, a: Allocator, command: Command, iter: *ArgIter, mode: Mode) !void {
    switch (command) {
        .schema => {
            try protocol.writeSchema(out());
            return;
        },
        .identity => return cmdIdentity(a, iter),
        .provider => return cmdProvider(a, iter),
        .daemon => return cmdDaemon(gpa, a, iter),
        else => {},
    }
    const backend = try open(gpa, a, if (command == .watch or command == .jobs) (if (mode == .auto) .remote else mode) else mode);
    defer closeBackend(backend);
    switch (command) {
        .devices => try cmdDevices(a, iter, backend),
        .info => try cmdInfo(a, iter, backend),
        .apps => try cmdApps(a, iter, backend),
        .install => try cmdInstall(gpa, a, iter, backend),
        .uninstall => try cmdUninstall(a, iter, backend),
        .sign => try cmdSign(gpa, a, iter, backend),
        .inspect => try cmdInspect(a, iter, backend),
        .identities => try cmdIdentities(a, iter, backend),
        .import => try cmdImport(a, iter, backend),
        .jobs => try cmdJobs(a, iter, backend),
        .watch => try cmdWatch(gpa, a, iter, backend),
        .schema, .identity, .provider, .daemon, .help => unreachable,
    }
}

const parsers = .{
    .str = clap.parsers.string,
    .path = clap.parsers.string,
    .device = clap.parsers.string,
    .ipa = clap.parsers.string,
    .bundle = clap.parsers.string,
    .name = clap.parsers.string,
    .action = clap.parsers.string,
};

fn parseSub(a: Allocator, comptime name: []const u8, comptime params: anytype, iter: *ArgIter) !clap.ResultEx(clap.Help, params, parsers) {
    var d: clap.Diagnostic = .{};
    const res = clap.parseEx(clap.Help, params, parsers, iter, .{ .diagnostic = &d, .allocator = a }) catch |err| {
        d.report(errw(), err) catch {};
        errw().print("{s}\n", .{i18n.trfBuf(&fail_buf, "see: ferry {0} --help", &.{name})}) catch {};
        return error.Usage;
    };
    if (res.args.help != 0) {
        try out().print("{s}: ferry {s} ", .{ tr("usage"), name });
        try clap.usage(out(), clap.Help, params);
        try out().writeAll("\n\n");
        try clap.help(out(), clap.Help, params, .{});
        return error.HelpShown;
    }
    return res;
}

/// UDID, unique UDID prefix or name (case-insensitive); null = the only device.
fn resolveDevice(a: Allocator, b: Backend, query: ?[]const u8) ![]const u8 {
    const devices = try b.call(a, .@"devices.list", .{});
    if (query) |q| {
        for (devices) |d| if (std.mem.eql(u8, d.udid, q)) return d.udid;
        var found: ?[]const u8 = null;
        for (devices) |d| {
            if (std.mem.startsWith(u8, d.udid, q) or std.ascii.eqlIgnoreCase(d.name, q)) {
                if (found != null) return failT("'{0}' matches more than one device", &.{q});
                found = d.udid;
            }
        }
        return found orelse failT("no connected device matches '{0}' (see `ferry devices`)", &.{q});
    }
    return switch (devices.len) {
        0 => failT("no devices connected (is usbmuxd running? Wi-Fi devices must be paired)", &.{}),
        1 => devices[0].udid,
        else => failT("{0} devices connected; name one (see `ferry devices`)", &.{num(devices.len)}),
    };
}

// ---- commands --------------------------------------------------------------

fn cmdDevices(a: Allocator, iter: *ArgIter, b: Backend) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Show this help.
        \\
    );
    _ = try parseSub(a, "devices", &params, iter);
    const devices = try b.call(a, .@"devices.list", .{});
    if (json_out) return printJson(devices);
    if (devices.len == 0) return say("no devices", &.{});
    // Column headers stay ASCII so the table aligns in any language.
    try out().print("{s:<26} {s:<8} {s:<7} {s:<12} {s:<8} {s}\n", .{ "UDID", "VIA", "PAIRED", "MODEL", "IOS", "NAME" });
    for (devices) |d| try out().print("{s:<26} {s:<8} {s:<7} {s:<12} {s:<8} {s}\n", .{
        d.udid, @tagName(d.connection), if (d.paired) "yes" else "no", d.product_type, d.os_version, d.name,
    });
}

fn cmdInfo(a: Allocator, iter: *ArgIter, b: Backend) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Show this help.
        \\<device>
        \\
    );
    const res = try parseSub(a, "info", &params, iter);
    const udid = try resolveDevice(a, b, res.positionals[0]);
    const kv = try b.call(a, .@"device.info", .{ .udid = udid });
    if (json_out) return printJson(kv);
    for (kv) |e| try out().print("{s:<32} {s}\n", .{ e.key, e.value });
}

fn cmdApps(a: Allocator, iter: *ArgIter, b: Backend) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Show this help.
        \\<device>
        \\
    );
    const res = try parseSub(a, "apps", &params, iter);
    const udid = try resolveDevice(a, b, res.positionals[0]);
    const apps = try b.call(a, .@"device.apps", .{ .udid = udid });
    if (json_out) return printJson(apps);
    for (apps) |app| try out().print("{s:<44} {s:<12} {s}\n", .{ app.bundle_id, app.version, app.name });
}

/// Run a job to completion and print its progress.
fn runJob(gpa: Allocator, a: Allocator, b: Backend, comptime m: protocol.Method, params: protocol.Params(m)) !void {
    var events: ?*client.Conn = null;
    defer if (events) |e| e.close();
    if (b == .remote) {
        // Subscribe before starting so no update is missed.
        const e = try client.Conn.connect(gpa, g_io);
        events = e;
        e.subscribe(a) catch return failT("subscribe: {0}", &.{@errorName(error.Remote)});
    }
    const ref = try b.call(a, m, params);

    const final: protocol.Job = switch (b) {
        .local => try b.call(a, .@"job.wait", .{ .job = ref.job }),
        .remote => blk: {
            while (true) {
                const ev = events.?.nextEvent(a) catch |e| return failT("lost the daemon: {0}", &.{@errorName(e)});
                if (ev == .@"job.updated" and ev.@"job.updated".id != ref.job) continue;
                printEvent(ev);
                if (ev == .@"job.updated" and ev.@"job.updated".state != .running) break :blk ev.@"job.updated";
            }
        },
    };
    if (json_out) try printJson(final);
    if (final.state == .failed) return fail("{s}", .{final.message});
    if (!json_out) try out().print("{s}\n", .{final.message});
}

fn cmdInstall(gpa: Allocator, a: Allocator, iter: *ArgIter, b: Backend) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help              Show this help.
        \\-i, --identity <name>   Signing identity (default: config default_identity, or the only one).
        \\-b, --bundle-id <bundle> Sign with this bundle id.
        \\    --no-sign           Install the IPA as is.
        \\<str>...
        \\
    );
    const res = try parseSub(a, "install", &params, iter);
    const pos = res.positionals[0];
    const dev_q: ?[]const u8, const ipa_arg: []const u8 = switch (pos.len) {
        1 => .{ null, pos[0] },
        2 => .{ pos[0], pos[1] },
        else => return failT("usage: ferry install [device] <ipa>", &.{}),
    };
    const udid = try resolveDevice(a, b, dev_q);
    const ipa = absPath(a, ipa_arg) catch return failT("{0} does not exist", &.{ipa_arg});
    try runJob(gpa, a, b, .install, .{
        .udid = udid,
        .ipa = ipa,
        .sign = res.args.@"no-sign" == 0,
        .identity = res.args.identity,
        .bundle_id = res.args.@"bundle-id",
    });
}

fn cmdUninstall(a: Allocator, iter: *ArgIter, b: Backend) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Show this help.
        \\<str>...
        \\
    );
    const res = try parseSub(a, "uninstall", &params, iter);
    const pos = res.positionals[0];
    const dev_q: ?[]const u8, const bundle: []const u8 = switch (pos.len) {
        1 => .{ null, pos[0] },
        2 => .{ pos[0], pos[1] },
        else => return failT("usage: ferry uninstall [device] <bundle-id>", &.{}),
    };
    const udid = try resolveDevice(a, b, dev_q);
    _ = try b.call(a, .@"device.uninstall", .{ .udid = udid, .bundle_id = bundle });
    if (!json_out) try say("Removed {0}", &.{bundle});
}

fn cmdSign(gpa: Allocator, a: Allocator, iter: *ArgIter, b: Backend) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help               Show this help.
        \\-o, --output <path>      Signed IPA to write (required).
        \\-i, --identity <name>    Signing identity.
        \\-b, --bundle-id <bundle> Sign with this bundle id.
        \\-d, --device <device>    Require the profile to include this device.
        \\<ipa>
        \\
    );
    const res = try parseSub(a, "sign", &params, iter);
    const ipa_arg = res.positionals[0] orelse return failT("usage: ferry sign <ipa> -o <out>", &.{});
    const output_arg = res.args.output orelse return failT("sign: --output is required", &.{});
    const ipa = absPath(a, ipa_arg) catch return failT("{0} does not exist", &.{ipa_arg});
    const output = try std.fs.path.resolveAlloc(a, &.{ try std.process.currentPathAlloc(g_io, a), output_arg });
    const udid: ?[]const u8 = if (res.args.device) |q| try resolveDevice(a, b, q) else null;
    try runJob(gpa, a, b, .sign, .{ .ipa = ipa, .output = output, .identity = res.args.identity, .bundle_id = res.args.@"bundle-id", .udid = udid });
}

fn cmdInspect(a: Allocator, iter: *ArgIter, b: Backend) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Show this help.
        \\<ipa>
        \\
    );
    const res = try parseSub(a, "inspect", &params, iter);
    const ipa_arg = res.positionals[0] orelse return failT("usage: ferry inspect <ipa>", &.{});
    const ipa = absPath(a, ipa_arg) catch return failT("{0} does not exist", &.{ipa_arg});
    const info = try b.call(a, .@"ipa.inspect", .{ .path = ipa });
    if (json_out) return printJson(info);
    const rows = [_][2][]const u8{
        .{ tr("Name"), info.name },
        .{ tr("Bundle ID"), info.bundle_id },
        .{ tr("Version"), info.version },
        .{ tr("Minimum iOS"), info.min_os },
        .{ tr("Executable"), info.executable },
    };
    for (rows) |r| try out().print("{s}\t{s}\n", .{ r[0], r[1] });
}

fn cmdIdentities(a: Allocator, iter: *ArgIter, b: Backend) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Show this help.
        \\
    );
    _ = try parseSub(a, "identities", &params, iter);
    const ids = try b.call(a, .@"identities.list", .{});
    if (json_out) return printJson(ids);
    if (ids.len == 0) return say("no identities (add one with `ferry identity add`)", &.{});
    for (ids) |i| try out().print("{s:<20} {s:<6} {s}\n", .{ i.name, i.provider, i.detail });
}

fn cmdIdentity(a: Allocator, iter: *ArgIter) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help              Show this help.
        \\    --p12 <path>        Certificate + private key (.p12).
        \\    --password <str>    Password for the .p12.
        \\    --profile <path>... Provisioning profile(s) (.mobileprovision).
        \\<action>
        \\<name>
        \\
    );
    const res = try parseSub(a, "identity", &params, iter);
    const action = res.positionals[0] orelse return failT("usage: ferry identity add|path <name> ...", &.{});
    const paths = try core.Paths.default(a);
    try paths.ensure(g_io);
    const store = core.Provision.Store{ .io = g_io, .root = paths.identities };
    if (std.mem.eql(u8, action, "path")) {
        const name = res.positionals[1] orelse return try out().print("{s}\n", .{paths.identities});
        return out().print("{s}/{s}\n", .{ paths.identities, name });
    }
    if (!std.mem.eql(u8, action, "add")) return failT("unknown identity action '{0}' (add, path)", &.{action});
    const name = res.positionals[1] orelse return failT("identity add: missing <name>", &.{});
    const p12 = res.args.p12 orelse return failT("identity add: --p12 is required", &.{});
    if (res.args.profile.len == 0) return failT("identity add: at least one --profile is required", &.{});
    var d: core.Diag = .{};
    store.addFiles(a, name, p12, res.args.password, res.args.profile, &d) catch |e| return fail("{s}", .{if (d.len > 0) d.message() else @errorName(e)});
    try say("Added identity '{0}' in {1}", &.{ name, try std.fs.path.join(a, &.{ paths.identities, name }) });
}

fn cmdImport(a: Allocator, iter: *ArgIter, b: Backend) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Show this help.
        \\<action>
        \\<path>
        \\
    );
    const res = try parseSub(a, "import", &params, iter);
    const what = res.positionals[0] orelse return failT("usage: ferry import jimpactor [DIR]", &.{});
    if (!std.mem.eql(u8, what, "jimpactor")) return failT("usage: ferry import jimpactor [DIR]", &.{});
    const dir: ?[]const u8 = if (res.positionals[1]) |p| try absPath(a, p) else null;
    const r = try b.call(a, .@"import.jimpactor", .{ .path = dir });
    if (json_out) return printJson(r);
    for (r.imported) |l| try out().print("+ {s}\n", .{l});
    for (r.skipped) |l| try out().print("- {s}\n", .{l});
    if (r.imported.len == 0) try say("nothing imported", &.{});
}

/// `ferry provider jimpactor ...`: the exec provider written into imported
/// Jimpactor identities. Not meant to be run by hand.
fn cmdProvider(a: Allocator, iter: *ArgIter) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help           Show this help.
        \\    --team <str>     Team id.
        \\    --cli <path>     jimpactor-cli to provision with.
        \\    --identity <path> Identity directory (identity.p12, profiles/).
        \\<action>
        \\<str>
        \\
    );
    const res = try parseSub(a, "provider", &params, iter);
    const kind = res.positionals[0] orelse return failT("usage: ferry provider jimpactor --team T --cli PATH --identity DIR REQUEST", &.{});
    if (!std.mem.eql(u8, kind, "jimpactor")) return failT("usage: ferry provider jimpactor --team T --cli PATH --identity DIR REQUEST", &.{});
    const request = res.positionals[1] orelse return failT("usage: ferry provider jimpactor --team T --cli PATH --identity DIR REQUEST", &.{});
    const Req = struct { bundle_id: []const u8, udid: ?[]const u8 = null, ipa: ?[]const u8 = null };
    const req = std.json.parseFromSliceLeaky(Req, a, request, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return failT("provider: request is not JSON", &.{});
    const paths = try core.Paths.default(a);
    try paths.ensure(g_io);
    var d: core.Diag = .{};
    const reply = migrate.jimpactorProvide(a, g_io, .{
        .team = res.args.team orelse return failT("provider: --team is required", &.{}),
        .cli = res.args.cli orelse return failT("provider: --cli is required", &.{}),
        .identity_dir = res.args.identity orelse return failT("provider: --identity is required", &.{}),
        .tmp = paths.tmp,
    }, .{ .bundle_id = req.bundle_id, .udid = req.udid, .ipa = req.ipa, .now = Io.Clock.real.now(g_io).toSeconds() }, &d) catch |e|
        return fail("{s}", .{if (d.len > 0) d.message() else @errorName(e)});
    try std.json.Stringify.value(reply, .{}, out());
    try out().writeByte('\n');
}

fn cmdJobs(a: Allocator, iter: *ArgIter, b: Backend) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Show this help.
        \\
    );
    _ = try parseSub(a, "jobs", &params, iter);
    const jobs = try b.call(a, .@"jobs.list", .{});
    if (json_out) return printJson(jobs);
    if (jobs.len == 0) return say("no jobs", &.{});
    for (jobs) |j| try out().print("{d:>4} {s:<10} {s:<10} {d:>3}% {s}  {s}\n", .{ j.id, tr(@tagName(j.state)), tr(j.step), j.percent, j.title, j.message });
}

fn cmdWatch(gpa: Allocator, a: Allocator, iter: *ArgIter, b: Backend) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Show this help.
        \\
    );
    _ = try parseSub(a, "watch", &params, iter);
    switch (b) {
        .local => |s| {
            s.startMonitor() catch return failT("cannot watch usbmuxd hotplug events", &.{});
            while (true) g_io.sleep(.fromSeconds(3600), .awake) catch break;
        },
        .remote => {
            const e = try client.Conn.connect(gpa, g_io);
            defer e.close();
            try e.subscribe(a);
            while (true) {
                var ev_arena = std.heap.ArenaAllocator.init(gpa);
                defer ev_arena.deinit();
                const ev = e.nextEvent(ev_arena.allocator()) catch |err| return failT("lost the daemon: {0}", &.{@errorName(err)});
                if (json_out) {
                    try protocol.writeEvent(out(), ev);
                } else switch (ev) {
                    .@"job.updated" => |j| try out().print("job {d} {s} {s} {d}% {s}\n", .{ j.id, tr(@tagName(j.state)), tr(j.step), j.percent, j.message }),
                    else => printEvent(ev),
                }
            }
        },
    }
}

fn cmdDaemon(gpa: Allocator, a: Allocator, iter: *ArgIter) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Show this help.
        \\<action>
        \\
    );
    const res = try parseSub(a, "daemon", &params, iter);
    const action = res.positionals[0] orelse "status";
    if (std.mem.eql(u8, action, "start")) {
        const c = client.connectOrSpawn(gpa, g_io) catch |e| return failT("could not start ferryd: {0}", &.{@errorName(e)});
        defer c.close();
        const h = try c.call(a, .hello, .{});
        return say("ferryd running (pid {0}, protocol {1})", &.{ num(h.pid), num(h.protocol) });
    }
    const c = client.Conn.connect(gpa, g_io) catch {
        if (std.mem.eql(u8, action, "stop")) return say("ferryd is not running", &.{});
        return say("ferryd is not running (socket {0})", &.{try protocol.socketPath(a)});
    };
    defer c.close();
    if (std.mem.eql(u8, action, "stop")) {
        _ = c.call(a, .shutdown, .{}) catch {};
        return say("ferryd stopped", &.{});
    }
    if (!std.mem.eql(u8, action, "status")) return failT("unknown daemon action '{0}' (start, stop, status)", &.{action});
    const h = try c.call(a, .hello, .{});
    try say("ferryd running (pid {0}, protocol {1}, socket {2})", &.{ num(h.pid), num(h.protocol), try protocol.socketPath(a) });
}
