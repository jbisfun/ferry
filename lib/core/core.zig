//! The application service: everything Ferry can do, behind one typed
//! entry point (`Service.call`). Hosts decide only how it is reached:
//! ferryd serves it over the socket, `ferry --local` calls it in-process.
//! Front ends never import device/signing/provision themselves.
const std = @import("std");
const diag = @import("diag");
const protocol = @import("protocol");
const ipa = @import("ipa");
const device = @import("device");
const provision = @import("provision");
const signing = @import("signing");
const i18n = @import("i18n");
const migrate = @import("migrate");

pub const pipeline = @import("pipeline.zig");
pub const Diag = diag.Diag;
pub const Provision = provision;

const log = std.log.scoped(.core);

pub const Sink = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, ev: protocol.Event) void,

    pub fn emit(self: Sink, ev: protocol.Event) void {
        self.func(self.ctx, ev);
    }

    pub const none: Sink = .{ .func = struct {
        fn f(_: ?*anyopaque, _: protocol.Event) void {}
    }.f };
};

pub const Paths = struct {
    data: []const u8,
    identities: []const u8,
    tmp: []const u8,
    config: []const u8,

    /// `$FERRY_HOME`, else `$XDG_CONFIG_HOME/ferry`, else `~/.config/ferry`.
    pub fn default(alloc: std.mem.Allocator) !Paths {
        const data = if (getenv("FERRY_HOME")) |h|
            try alloc.dupe(u8, h)
        else if (getenv("XDG_CONFIG_HOME")) |x|
            try std.fs.path.join(alloc, &.{ x, "ferry" })
        else
            try std.fs.path.join(alloc, &.{ getenv("HOME") orelse "/tmp", ".config", "ferry" });
        return fromRoot(alloc, data);
    }

    pub fn fromRoot(alloc: std.mem.Allocator, data: []const u8) !Paths {
        return .{
            .data = data,
            .identities = try std.fs.path.join(alloc, &.{ data, "identities" }),
            .tmp = try std.fs.path.join(alloc, &.{ data, "tmp" }),
            .config = try std.fs.path.join(alloc, &.{ data, "config.json" }),
        };
    }

    pub fn ensure(self: Paths, io: std.Io) !void {
        try std.Io.Dir.cwd().createDirPath(io, self.identities);
        try std.Io.Dir.cwd().createDirPath(io, self.tmp);
    }
};

/// `<data>/config.json`. Unknown keys are ignored so newer files load in older builds.
pub const Config = struct {
    default_identity: ?[]const u8 = null,

    pub fn load(alloc: std.mem.Allocator, io: std.Io, path: []const u8) Config {
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return .{};
        return std.json.parseFromSliceLeaky(Config, alloc, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e| {
            log.warn("ignoring {s}: {s}", .{ path, @errorName(e) });
            return .{};
        };
    }
};

const JobRec = struct {
    id: u32,
    kind: []const u8,
    title: []u8,
    state: protocol.JobState = .running,
    step_buf: [32]u8 = undefined,
    step_len: usize = 0,
    percent: u8 = 0,
    msg_buf: [1024]u8 = undefined,
    msg_len: usize = 0,

    fn snapshot(self: *const JobRec, arena: std.mem.Allocator) !protocol.Job {
        return .{
            .id = self.id,
            .kind = self.kind,
            .title = try arena.dupe(u8, self.title),
            .state = self.state,
            .step = try arena.dupe(u8, self.step_buf[0..self.step_len]),
            .percent = self.percent,
            .message = try arena.dupe(u8, self.msg_buf[0..self.msg_len]),
        };
    }
};

pub const Service = struct {
    gpa: std.mem.Allocator,
    paths: Paths,
    sink: Sink,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    job_changed: std.Io.Condition = .init,
    jobs: std.ArrayList(*JobRec) = .empty,
    next_job: u32 = 1,
    running: std.atomic.Value(u32) = .init(0),
    monitor: ?device.Monitor = null,
    /// The `ferry` CLI, written into provider.json by importers.
    ferry_exe: []const u8 = "ferry",

    pub fn create(gpa: std.mem.Allocator, io: std.Io, paths: Paths, sink: Sink) !*Service {
        try paths.ensure(io);
        const s = try gpa.create(Service);
        s.* = .{ .gpa = gpa, .io = io, .paths = paths, .sink = sink };
        return s;
    }

    pub fn destroy(self: *Service) void {
        if (self.monitor) |*m| m.stop();
        // Let job threads finish before freeing their records.
        while (self.running.load(.acquire) > 0) self.io.sleep(.fromMilliseconds(50), .awake) catch break;
        for (self.jobs.items) |j| {
            self.gpa.free(j.title);
            self.gpa.destroy(j);
        }
        self.jobs.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Forward usbmuxd hotplug events to the sink.
    pub fn startMonitor(self: *Service) !void {
        self.syncPairRecords(null);
        self.monitor = .{ .sink = onDevice, .user = self };
        try self.monitor.?.start();
    }

    /// Hand staged pairing records (<data>/pairings, e.g. imported from
    /// Jimpactor) to usbmuxd for devices it has no record for. `only` limits
    /// it to one UDID.
    pub fn syncPairRecords(self: *Service, only: ?[]const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const dir_path = std.fs.path.join(a, &.{ self.paths.data, "pairings" }) catch return;
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".plist")) continue;
            const udid = e.name[0 .. e.name.len - ".plist".len];
            if (only) |u| if (!std.mem.eql(u8, u, udid)) continue;
            if (device.hasPairRecord(udid)) continue;
            const bytes = dir.readFileAlloc(self.io, e.name, a, .limited(1 << 20)) catch continue;
            device.savePairRecord(udid, bytes, null) catch continue;
            log.info("gave usbmuxd the staged pairing record for {s}", .{udid});
        }
    }

    fn onDevice(user: ?*anyopaque, ev: device.Event) void {
        const self: *Service = @ptrCast(@alignCast(user.?));
        const ref: protocol.DeviceRef = .{ .udid = ev.udid, .connection = mapConn(ev.connection) };
        switch (ev.kind) {
            .attached, .paired => {
                self.syncPairRecords(ev.udid);
                self.sink.emit(.{ .@"device.attached" = ref });
            },
            .detached => self.sink.emit(.{ .@"device.detached" = ref }),
        }
    }

    /// The single dispatch table. Results are allocated in `arena`.
    pub fn call(self: *Service, arena: std.mem.Allocator, comptime m: protocol.Method, p: protocol.Params(m), d: *diag.Diag) !protocol.Result(m) {
        return switch (m) {
            .hello => .{ .server = "ferry", .pid = std.c.getpid() },
            .subscribe, .shutdown => .{},
            .@"devices.list" => blk: {
                const list = try device.list(arena);
                const out = try arena.alloc(protocol.Device, list.len);
                for (list, 0..) |s, i| out[i] = .{
                    .udid = s.udid,
                    .name = s.name,
                    .connection = mapConn(s.connection),
                    .product_type = s.product_type,
                    .os_version = s.os_version,
                    .paired = s.paired,
                };
                break :blk out;
            },
            .@"device.info" => blk: {
                const kv = try device.info(arena, p.udid, d);
                const out = try arena.alloc(protocol.KeyValue, kv.len);
                for (kv, 0..) |e, i| out[i] = .{ .key = e.key, .value = e.value };
                break :blk out;
            },
            .@"device.apps" => blk: {
                const apps = try device.apps(arena, p.udid, d);
                const out = try arena.alloc(protocol.App, apps.len);
                for (apps, 0..) |e, i| out[i] = .{ .bundle_id = e.bundle_id, .name = e.name, .version = e.version };
                break :blk out;
            },
            .@"device.uninstall" => blk: {
                try device.uninstall(p.udid, p.bundle_id, d);
                break :blk .{};
            },
            .@"ipa.inspect" => blk: {
                const i = try ipa.inspect(arena, p.path, d);
                break :blk .{ .bundle_id = i.bundle_id, .name = i.name, .version = i.version, .min_os = i.min_os, .executable = i.executable };
            },
            .@"identities.list" => blk: {
                const store = self.identityStore();
                const entries = try store.list(arena);
                const out = try arena.alloc(protocol.Identity, entries.len);
                for (entries, 0..) |e, i| out[i] = .{
                    .name = e.name,
                    .provider = @tagName(e.provider),
                    .detail = try self.identityDetail(arena, e),
                };
                break :blk out;
            },
            .@"jobs.list" => blk: {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                const out = try arena.alloc(protocol.Job, self.jobs.items.len);
                for (self.jobs.items, 0..) |j, i| out[i] = try j.snapshot(arena);
                break :blk out;
            },
            .@"job.wait" => try self.waitJob(arena, p.job, d),
            .@"import.jimpactor" => blk: {
                const src = p.path orelse try migrate.defaultJimpactorDir(arena);
                const r = try migrate.importJimpactor(arena, self.io, src, .{
                    .data = self.paths.data,
                    .identities = self.paths.identities,
                    .tmp = self.paths.tmp,
                    .ferry_exe = self.ferry_exe,
                }, d);
                break :blk .{ .imported = r.imported.items, .skipped = r.skipped.items };
            },
            .sign => .{ .job = try self.startJob(.sign, p, d) },
            .install => .{ .job = try self.startJob(.install, p, d) },
        };
    }

    // ---- jobs ------------------------------------------------------------

    fn startJob(self: *Service, comptime kind: pipeline.Kind, params: pipeline.ParamsOf(kind), d: *diag.Diag) !u32 {
        if (std.Io.Dir.cwd().access(self.io, params.ipa, .{})) |_| {} else |_| {
            var b: [512]u8 = undefined;
            return diag.fail(d, error.FileNotFound, "{s}", .{i18n.trfBuf(&b, "{0} does not exist", &.{params.ipa})});
        }

        const rec = try self.gpa.create(JobRec);
        errdefer self.gpa.destroy(rec);
        const title = switch (kind) {
            .install => try i18n.trf(self.gpa, "Install {0} on {1}", &.{ std.fs.path.basename(params.ipa), params.udid }),
            .sign => try i18n.trf(self.gpa, "Sign {0}", &.{std.fs.path.basename(params.ipa)}),
        };
        self.mutex.lockUncancelable(self.io);
        rec.* = .{ .id = self.next_job, .kind = @tagName(kind), .title = title };
        self.next_job += 1;
        self.jobs.append(self.gpa, rec) catch |e| {
            self.mutex.unlock(self.io);
            self.gpa.free(title);
            return e;
        };
        self.mutex.unlock(self.io);

        const job = try pipeline.Job(kind).create(self.gpa, self, rec.id, params);
        _ = self.running.fetchAdd(1, .acq_rel);
        const t = std.Thread.spawn(.{}, pipeline.Job(kind).run, .{job}) catch |e| {
            _ = self.running.fetchSub(1, .acq_rel);
            job.destroy();
            self.finish(rec.id, false, "could not start job thread");
            return e;
        };
        t.detach();
        self.publish(rec.id);
        return rec.id;
    }

    fn find(self: *Service, id: u32) ?*JobRec {
        for (self.jobs.items) |j| if (j.id == id) return j;
        return null;
    }

    /// Emit the current state of job `id`.
    fn publish(self: *Service, id: u32) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const snap = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const j = self.find(id) orelse return;
            break :blk j.snapshot(arena.allocator()) catch return;
        };
        self.sink.emit(.{ .@"job.updated" = snap });
    }

    pub fn progress(self: *Service, id: u32, step: []const u8, percent: u8, message: []const u8) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const j = self.find(id) orelse return;
            const changed = j.percent != percent or !std.mem.eql(u8, j.step_buf[0..j.step_len], step) or !std.mem.eql(u8, j.msg_buf[0..j.msg_len], message);
            if (!changed) return;
            j.step_len = copyInto(&j.step_buf, step);
            j.msg_len = copyInto(&j.msg_buf, message);
            j.percent = percent;
        }
        self.publish(id);
    }

    pub fn finish(self: *Service, id: u32, ok: bool, message: []const u8) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const j = self.find(id) orelse return;
            j.state = if (ok) .succeeded else .failed;
            j.msg_len = copyInto(&j.msg_buf, message);
            if (ok) j.percent = 100;
            self.job_changed.broadcast(self.io);
        }
        self.publish(id);
    }

    pub fn jobDone(self: *Service) void {
        _ = self.running.fetchSub(1, .acq_rel);
    }

    fn waitJob(self: *Service, arena: std.mem.Allocator, id: u32, d: *diag.Diag) !protocol.Job {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            const j = self.find(id) orelse return diag.fail(d, error.NoSuchJob, "no job {d}", .{id});
            if (j.state != .running) return j.snapshot(arena);
            try self.job_changed.wait(self.io, &self.mutex);
        }
    }

    // ---- identities ------------------------------------------------------

    /// One-line description; identities created by an importer carry an
    /// account.json naming the Apple ID and team.
    fn identityDetail(self: *Service, arena: std.mem.Allocator, e: provision.Store.Entry) ![]const u8 {
        const path = try std.fs.path.join(arena, &.{ self.paths.identities, e.name, "account.json" });
        if (std.Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(64 * 1024))) |raw| {
            const Meta = struct { source: []const u8 = "", team_id: []const u8 = "", apple_id: []const u8 = "" };
            if (std.json.parseFromSliceLeaky(Meta, arena, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })) |m| {
                return i18n.trf(arena, "Apple ID {0}, team {1} (via {2})", &.{ m.apple_id, m.team_id, m.source });
            } else |_| {}
        } else |_| {}
        return e.provider.describe(arena);
    }

    pub fn identityStore(self: *Service) provision.Store {
        return .{ .io = self.io, .root = self.paths.identities };
    }

    /// Named identity, else config `default_identity`, else the only one.
    pub fn pickIdentity(self: *Service, arena: std.mem.Allocator, name: ?[]const u8, d: *diag.Diag) !provision.Provider {
        const store = self.identityStore();
        if (name) |n| return store.open(arena, n, d);
        const cfg = Config.load(arena, self.io, self.paths.config);
        if (cfg.default_identity) |n| return store.open(arena, n, d);
        const all = try store.list(arena);
        if (all.len == 1) return all[0].provider;
        var b: [1024]u8 = undefined;
        if (all.len == 0) return diag.fail(d, error.NoIdentity, "{s}", .{i18n.trfBuf(&b, "no signing identities in {0}; add one with `ferry identity add`", &.{store.root})});
        var nb: [16]u8 = undefined;
        const n = std.fmt.bufPrint(&nb, "{d}", .{all.len}) catch "?";
        return diag.fail(d, error.AmbiguousIdentity, "{s}", .{i18n.trfBuf(&b, "{0} identities exist; pick one with --identity or set default_identity in {1}", &.{ n, self.paths.config })});
    }
};

fn getenv(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |v| std.mem.span(v) else null;
}

fn copyInto(buf: []u8, s: []const u8) usize {
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
    return n;
}

fn mapConn(c: device.Connection) protocol.Connection {
    return switch (c) {
        .usb => .usb,
        .network => .network,
    };
}

test {
    _ = pipeline;
}

test "service lists identities and rejects missing IPA" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const svc = try Service.create(std.testing.allocator, io, try Paths.fromRoot(a, root), Sink.none);
    defer svc.destroy();

    var d: diag.Diag = .{};
    const ids = try svc.call(a, .@"identities.list", .{}, &d);
    try std.testing.expectEqual(@as(usize, 0), ids.len);

    try std.testing.expectError(error.FileNotFound, svc.call(a, .install, .{ .udid = "x", .ipa = "/nope.ipa" }, &d));
    try std.testing.expectError(error.NoIdentity, svc.pickIdentity(a, null, &d));
}
