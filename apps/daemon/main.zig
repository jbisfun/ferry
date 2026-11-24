//! ferryd: the one process that owns devices and jobs.
//!
//! Serves `core.Service` on a Unix socket (see protocol.socketPath). The GUI
//! and CLI are equal clients; closing the GUI does not stop installs, and the
//! CLI never needs the GUI to be open.
const std = @import("std");
const core = @import("core");
const protocol = @import("protocol");
const i18n = @import("i18n");

const Io = std.Io;
const net = std.Io.net;
const log = std.log.scoped(.daemon);

var log_file: ?Io.File = null;
var log_io: ?Io = null;
var log_lock: Io.Mutex = .init;

pub const std_options: std.Options = .{ .logFn = logFn, .log_level = .info };

fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    const io = log_io orelse return std.log.defaultLog(level, scope, fmt, args);
    log_lock.lockUncancelable(io);
    defer log_lock.unlock(io);
    var buf: [2048]u8 = undefined;
    const f = log_file orelse Io.File.stderr();
    var w = f.writerStreaming(io, &buf);
    const ts = Io.Clock.real.now(io).toSeconds();
    w.interface.print("{d} {s}({s}): " ++ fmt ++ "\n", .{ ts, level.asText(), @tagName(scope) } ++ args) catch {};
    w.interface.flush() catch {};
}

const Peer = struct {
    io: Io,
    stream: net.Stream,
    write_lock: Io.Mutex = .init,
    subscribed: bool = false,

    fn send(self: *Peer, bytes: []const u8) !void {
        self.write_lock.lockUncancelable(self.io);
        defer self.write_lock.unlock(self.io);
        var w = self.stream.writer(self.io, &.{});
        try w.interface.writeAll(bytes);
    }
};

const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    svc: *core.Service = undefined,
    lock: Io.Mutex = .init,
    subscribers: std.ArrayList(*Peer) = .empty,
    listener: net.Server = undefined,
    stopping: std.atomic.Value(bool) = .init(false),

    fn sink(ctx: ?*anyopaque, ev: protocol.Event) void {
        const self: *Server = @ptrCast(@alignCast(ctx.?));
        var buf: Io.Writer.Allocating = .init(self.gpa);
        defer buf.deinit();
        protocol.writeEvent(&buf.writer, ev) catch return;
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.subscribers.items) |p| p.send(buf.written()) catch {};
    }

    fn removeSubscriber(self: *Server, peer: *Peer) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.subscribers.items, 0..) |p, i| if (p == peer) {
            _ = self.subscribers.swapRemove(i);
            return;
        };
    }

    fn serve(self: *Server, stream: net.Stream) void {
        var peer: Peer = .{ .io = self.io, .stream = stream };
        defer {
            if (peer.subscribed) self.removeSubscriber(&peer);
            stream.close(self.io);
        }
        var read_buf: [64 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        var out: Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();

        while (true) {
            const line = (reader.interface.takeDelimiter('\n') catch return) orelse return;
            if (line.len == 0) continue;

            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            out.clearRetainingCapacity();
            // `line` points into the reader buffer; handlers may block, so copy.
            const owned = arena.allocator().dupe(u8, line) catch return;
            self.handle(arena.allocator(), &peer, owned, &out.writer) catch |e| {
                log.warn("bad request: {s}", .{@errorName(e)});
                protocol.writeError(&out.writer, 0, @errorName(e)) catch return;
            };
            peer.send(out.written()) catch return;
            if (self.stopping.load(.acquire)) {
                // Reply sent; wake accept() so main can clean up.
                _ = std.c.shutdown(self.listener.socket.handle, 2);
                return;
            }
        }
    }

    fn handle(self: *Server, arena: std.mem.Allocator, peer: *Peer, line: []const u8, w: *Io.Writer) !void {
        const req = switch (try protocol.parseLine(arena, line)) {
            .request => |r| r,
            else => return error.ExpectedRequest,
        };
        switch (req.method) {
            inline else => |m| {
                const params = protocol.decodeParams(m, arena, req.params) catch |e| {
                    return protocol.writeError(w, req.id, @errorName(e));
                };
                var d: core.Diag = .{};
                const result = self.svc.call(arena, m, params, &d) catch |e| {
                    return protocol.writeError(w, req.id, if (d.len > 0) d.message() else @errorName(e));
                };
                if (m == .subscribe and !peer.subscribed) {
                    peer.subscribed = true;
                    self.lock.lockUncancelable(self.io);
                    defer self.lock.unlock(self.io);
                    try self.subscribers.append(self.gpa, peer);
                }
                if (m == .shutdown) self.stopping.store(true, .release);
                try protocol.writeResult(w, req.id, m, result);
            },
        }
    }
};

fn alreadyRunning(io: Io, path: []const u8) bool {
    const addr = net.UnixAddress.init(path) catch return false;
    const s = addr.connect(io) catch return false;
    s.close(io);
    return true;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    log_io = io;

    // Job titles and messages follow the daemon's locale (it inherits the
    // environment of the GUI/CLI that started it).
    i18n.initFromEnv();
    const paths = try core.Paths.default(arena);
    try paths.ensure(io);
    if (std.c.isatty(2) == 0) {
        const lp = try std.fs.path.join(arena, &.{ paths.data, "ferryd.log" });
        if (Io.Dir.cwd().createFile(io, lp, .{ .truncate = false })) |f| {
            log_file = f;
            // Append: position the streaming writer at the end.
            const len = f.length(io) catch 0;
            _ = std.c.lseek(f.handle, @intCast(len), std.c.SEEK.SET);
        } else |_| {}
    }

    const sock_path = try protocol.socketPath(arena);
    if (alreadyRunning(io, sock_path)) {
        log.err("another ferryd is serving {s}", .{sock_path});
        std.process.exit(1);
    }
    Io.Dir.cwd().deleteFile(io, sock_path) catch {};

    var server: Server = .{ .gpa = gpa, .io = io };
    defer server.subscribers.deinit(gpa);
    server.svc = try core.Service.create(gpa, io, paths, .{ .ctx = &server, .func = Server.sink });
    defer server.svc.destroy();
    {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.process.executableDirPath(io, &buf) catch 0;
        if (n > 0) server.svc.ferry_exe = try std.fs.path.join(arena, &.{ buf[0..n], "ferry" });
    }
    server.svc.startMonitor() catch |e| log.warn("device hotplug unavailable ({s}); is usbmuxd running?", .{@errorName(e)});

    const addr = try net.UnixAddress.init(sock_path);
    server.listener = try addr.listen(io, .{});
    defer Io.Dir.cwd().deleteFile(io, sock_path) catch {};
    const sock_z = try arena.dupeSentinel(u8, sock_path, 0);
    _ = std.c.chmod(sock_z.ptr, 0o600);
    log.info("listening on {s} (data {s})", .{ sock_path, paths.data });

    while (!server.stopping.load(.acquire)) {
        const stream = server.listener.accept(io) catch |e| {
            if (server.stopping.load(.acquire)) break;
            log.warn("accept: {s}", .{@errorName(e)});
            io.sleep(.fromMilliseconds(100), .awake) catch {};
            continue;
        };
        const t = std.Thread.spawn(.{}, Server.serve, .{ &server, stream }) catch {
            stream.close(io);
            continue;
        };
        t.detach();
    }
    log.info("shutting down", .{});
}
