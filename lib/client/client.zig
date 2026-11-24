//! Client side of the Ferry socket protocol.
//!
//! `Conn` is one connection: typed `call`s, or, after `subscribe`, a stream of
//! events via `nextEvent`. Use separate connections for the two so replies and
//! events never interleave.
const std = @import("std");
const protocol = @import("protocol");

const Io = std.Io;
const net = std.Io.net;

pub const Conn = struct {
    gpa: std.mem.Allocator,
    io: Io,
    stream: net.Stream,
    read_buf: [64 * 1024]u8 = undefined,
    reader: net.Stream.Reader = undefined,
    next_id: u64 = 1,
    /// Text of the last `error.Remote`, valid until the next call.
    last_error: std.ArrayList(u8) = .empty,

    pub fn connect(gpa: std.mem.Allocator, io: Io) !*Conn {
        const path = try protocol.socketPath(gpa);
        defer gpa.free(path);
        return connectTo(gpa, io, path);
    }

    pub fn connectTo(gpa: std.mem.Allocator, io: Io, path: []const u8) !*Conn {
        const addr = try net.UnixAddress.init(path);
        const stream = try addr.connect(io);
        errdefer stream.close(io);
        const self = try gpa.create(Conn);
        self.* = .{ .gpa = gpa, .io = io, .stream = stream };
        self.reader = self.stream.reader(io, &self.read_buf);
        return self;
    }

    pub fn close(self: *Conn) void {
        self.stream.close(self.io);
        self.last_error.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Interrupt a blocked `nextEvent` from another thread.
    pub fn shutdown(self: *Conn) void {
        self.stream.shutdown(self.io, .both) catch {};
    }

    /// Next newline-terminated message (without the newline). Valid until the
    /// next read.
    fn readLine(self: *Conn) ![]const u8 {
        const r = &self.reader.interface;
        const line = r.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => return error.MessageTooLong,
            error.ReadFailed => return error.Disconnected,
        };
        return line orelse error.Disconnected;
    }

    fn send(self: *Conn, bytes: []const u8) !void {
        var w = self.stream.writer(self.io, &.{});
        w.interface.writeAll(bytes) catch return error.Disconnected;
    }

    /// Send a request and wait for its reply. Result memory is in `arena`.
    /// Remote failures return `error.Remote` with the text in `last_error`.
    pub fn call(self: *Conn, arena: std.mem.Allocator, comptime m: protocol.Method, params: protocol.Params(m)) !protocol.Result(m) {
        const id = self.next_id;
        self.next_id += 1;
        var buf: Io.Writer.Allocating = .init(self.gpa);
        defer buf.deinit();
        try protocol.writeRequest(&buf.writer, id, m, params);
        try self.send(buf.written());

        while (true) {
            const line = try self.readLine();
            const msg = try protocol.parseLine(arena, line);
            switch (msg) {
                .response => |r| {
                    if (r.id != id) continue;
                    if (r.err) |e| {
                        self.last_error.clearRetainingCapacity();
                        try self.last_error.appendSlice(self.gpa, e);
                        return error.Remote;
                    }
                    return protocol.decodeResult(m, arena, r.result orelse return error.BadMessage);
                },
                .event => continue,
                .request => return error.BadMessage,
            }
        }
    }

    pub fn subscribe(self: *Conn, arena: std.mem.Allocator) !void {
        _ = try self.call(arena, .subscribe, .{});
    }

    /// Block until the next event (call `subscribe` first).
    pub fn nextEvent(self: *Conn, arena: std.mem.Allocator) !protocol.Event {
        while (true) {
            const line = try self.readLine();
            switch (try protocol.parseLine(arena, line)) {
                .event => |e| return e,
                else => continue,
            }
        }
    }
};

extern "c" fn fork() c_int;
extern "c" var environ: [*:null]?[*:0]u8;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

fn canConnect(io: Io, path: []const u8) bool {
    const addr = net.UnixAddress.init(path) catch return false;
    const s = addr.connect(io) catch return false;
    s.close(io);
    return true;
}

/// Start `ferryd` (looked up next to the running executable, then PATH),
/// fully detached, and wait up to ~3 s for its socket to accept connections.
pub fn spawnDaemon(gpa: std.mem.Allocator, io: Io) !void {
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executableDirPath(io, &exe_dir_buf) catch 0;
    const sibling = try std.fs.path.joinZ(gpa, &.{ if (n > 0) exe_dir_buf[0..n] else ".", "ferryd" });
    defer gpa.free(sibling);
    const prog: [:0]const u8 = if (std.Io.Dir.cwd().access(io, sibling, .{})) |_| sibling else |_| "ferryd";

    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Child of a possibly multi-threaded process: only async-signal-safe
        // calls until exec, and _exit (never exit(), whose atexit handlers can
        // deadlock). New session, then fork again so init adopts the daemon.
        _ = std.c.setsid();
        const pid2 = fork();
        if (pid2 != 0) std.c._exit(if (pid2 < 0) 1 else 0);
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 0);
            _ = std.c.dup2(devnull, 1);
            _ = std.c.dup2(devnull, 2);
        }
        const argv = [_:null]?[*:0]const u8{ prog.ptr, null };
        if (std.mem.indexOfScalar(u8, prog, '/') != null) {
            _ = std.c.execve(prog.ptr, &argv, @ptrCast(environ));
        } else {
            _ = execvp(prog.ptr, &argv);
        }
        std.c._exit(127);
    }
    _ = std.c.waitpid(pid, null, 0);

    const path = try protocol.socketPath(gpa);
    defer gpa.free(path);
    var tries: usize = 0;
    while (tries < 60) : (tries += 1) {
        if (canConnect(io, path)) return;
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return error.DaemonDidNotStart;
}

var spawn_lock: Io.Mutex = .init;

/// Connect, starting the daemon first if nothing is listening.
pub fn connectOrSpawn(gpa: std.mem.Allocator, io: Io) !*Conn {
    return Conn.connect(gpa, io) catch |e| switch (e) {
        error.FileNotFound, error.ConnectionRefused => {
            // Several threads may race here at startup; only one spawns.
            spawn_lock.lockUncancelable(io);
            defer spawn_lock.unlock(io);
            if (Conn.connect(gpa, io)) |c| return c else |_| {}
            try spawnDaemon(gpa, io);
            return Conn.connect(gpa, io);
        },
        else => return e,
    };
}
