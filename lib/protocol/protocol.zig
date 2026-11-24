//! Ferry wire protocol: newline-delimited JSON over a Unix socket.
//!
//!   request  {"id":1,"method":"devices.list","params":{}}
//!   response {"id":1,"result":[...]}            or {"id":1,"error":"text"}
//!   event    {"event":"job.updated","data":{...}}  (only after "subscribe")
//!
//! Every method's parameter and result type is declared once, below, as a Zig
//! type. The daemon, the in-process CLI path and every client encode and decode
//! through these same types, and `writeSchema` derives the JSON Schema from
//! them at comptime, so a hand-maintained schema can never drift from the code.
//! This module has no dependencies so any client (GUI, CLI, idl, scripts
//! generated from the schema) can use it.
const std = @import("std");

pub const version: u32 = 1;

// ---- data types ----------------------------------------------------------

pub const Connection = enum { usb, network };

pub const Device = struct {
    udid: []const u8,
    name: []const u8 = "",
    connection: Connection,
    product_type: []const u8 = "",
    os_version: []const u8 = "",
    /// False when lockdown refused a session (not paired / not trusted yet).
    paired: bool = true,
};

pub const DeviceRef = struct {
    udid: []const u8,
    connection: Connection,
};

pub const KeyValue = struct { key: []const u8, value: []const u8 };

pub const App = struct {
    bundle_id: []const u8,
    name: []const u8 = "",
    version: []const u8 = "",
};

pub const IpaInfo = struct {
    bundle_id: []const u8,
    name: []const u8 = "",
    version: []const u8 = "",
    min_os: []const u8 = "",
    executable: []const u8 = "",
};

pub const Identity = struct {
    name: []const u8,
    /// Which provider backs it: "files" or "exec".
    provider: []const u8,
    detail: []const u8 = "",
};

pub const JobState = enum { running, succeeded, failed };

pub const Job = struct {
    id: u32,
    kind: []const u8,
    title: []const u8,
    state: JobState,
    step: []const u8 = "",
    percent: u8 = 0,
    message: []const u8 = "",
};

pub const Hello = struct {
    protocol: u32 = version,
    server: []const u8,
    pid: i64,
};

// ---- methods -------------------------------------------------------------

pub const Method = enum {
    hello,
    @"devices.list",
    @"device.info",
    @"device.apps",
    @"device.uninstall",
    @"ipa.inspect",
    @"identities.list",
    sign,
    install,
    @"jobs.list",
    @"job.wait",
    @"import.jimpactor",
    subscribe,
    shutdown,
};

pub const Empty = struct {};
pub const Udid = struct { udid: []const u8 };
pub const UninstallParams = struct { udid: []const u8, bundle_id: []const u8 };
pub const PathParams = struct { path: []const u8 };
pub const JobRef = struct { job: u32 };

pub const ImportParams = struct {
    /// Jimpactor's data dir; null = ~/.config/Jimpactor.
    path: ?[]const u8 = null,
};

pub const ImportReport = struct {
    imported: []const []const u8,
    skipped: []const []const u8,
};

pub const SignParams = struct {
    ipa: []const u8,
    output: []const u8,
    identity: ?[]const u8 = null,
    bundle_id: ?[]const u8 = null,
    /// Device the profile must include; null skips the device check.
    udid: ?[]const u8 = null,
};

pub const InstallParams = struct {
    udid: []const u8,
    ipa: []const u8,
    /// Re-sign before installing (default). False installs the IPA as is.
    sign: bool = true,
    identity: ?[]const u8 = null,
    bundle_id: ?[]const u8 = null,
};

pub fn Params(comptime m: Method) type {
    return switch (m) {
        .hello, .@"devices.list", .@"identities.list", .@"jobs.list", .subscribe, .shutdown => Empty,
        .@"device.info", .@"device.apps" => Udid,
        .@"device.uninstall" => UninstallParams,
        .@"ipa.inspect" => PathParams,
        .sign => SignParams,
        .install => InstallParams,
        .@"job.wait" => JobRef,
        .@"import.jimpactor" => ImportParams,
    };
}

pub fn Result(comptime m: Method) type {
    return switch (m) {
        .hello => Hello,
        .@"devices.list" => []const Device,
        .@"device.info" => []const KeyValue,
        .@"device.apps" => []const App,
        .@"device.uninstall", .subscribe, .shutdown => Empty,
        .@"ipa.inspect" => IpaInfo,
        .@"identities.list" => []const Identity,
        .sign, .install => JobRef,
        .@"jobs.list" => []const Job,
        .@"job.wait" => Job,
        .@"import.jimpactor" => ImportReport,
    };
}

// ---- events --------------------------------------------------------------

pub const Event = union(enum) {
    @"device.attached": DeviceRef,
    @"device.detached": DeviceRef,
    @"job.updated": Job,
};

// ---- encoding ------------------------------------------------------------

const json_opts: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
const Writer = std.Io.Writer;

pub fn writeRequest(w: *Writer, id: u64, comptime m: Method, params: Params(m)) Writer.Error!void {
    try w.print("{{\"id\":{d},\"method\":\"{s}\",\"params\":", .{ id, @tagName(m) });
    try std.json.Stringify.value(params, json_opts, w);
    try w.writeAll("}\n");
}

pub fn writeResult(w: *Writer, id: u64, comptime m: Method, result: Result(m)) Writer.Error!void {
    try w.print("{{\"id\":{d},\"result\":", .{id});
    try std.json.Stringify.value(result, json_opts, w);
    try w.writeAll("}\n");
}

pub fn writeError(w: *Writer, id: u64, message: []const u8) Writer.Error!void {
    try w.print("{{\"id\":{d},\"error\":", .{id});
    try std.json.Stringify.value(message, .{}, w);
    try w.writeAll("}\n");
}

pub fn writeEvent(w: *Writer, ev: Event) Writer.Error!void {
    switch (ev) {
        inline else => |data, tag| {
            try w.print("{{\"event\":\"{s}\",\"data\":", .{@tagName(tag)});
            try std.json.Stringify.value(data, json_opts, w);
            try w.writeAll("}\n");
        },
    }
}

const parse_opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

/// One decoded line. Allocations live in the caller's arena.
pub const Message = union(enum) {
    request: struct { id: u64, method: Method, params: std.json.Value },
    response: struct { id: u64, result: ?std.json.Value, err: ?[]const u8 },
    event: Event,
};

pub fn parseLine(arena: std.mem.Allocator, line: []const u8) !Message {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, parse_opts);
    if (root != .object) return error.BadMessage;
    const obj = root.object;

    if (obj.get("event")) |ev| {
        if (ev != .string) return error.BadMessage;
        const data = obj.get("data") orelse return error.BadMessage;
        const info = @typeInfo(Event).@"union";
        inline for (info.field_names, info.field_types) |name, T| {
            if (std.mem.eql(u8, ev.string, name)) {
                const payload = try std.json.parseFromValueLeaky(T, arena, data, parse_opts);
                return .{ .event = @unionInit(Event, name, payload) };
            }
        }
        return error.UnknownEvent;
    }

    const id_v = obj.get("id") orelse return error.BadMessage;
    if (id_v != .integer or id_v.integer < 0) return error.BadMessage;
    const id: u64 = @intCast(id_v.integer);

    if (obj.get("method")) |mv| {
        if (mv != .string) return error.BadMessage;
        const method = std.meta.stringToEnum(Method, mv.string) orelse return error.UnknownMethod;
        return .{ .request = .{
            .id = id,
            .method = method,
            .params = obj.get("params") orelse .{ .object = .empty },
        } };
    }

    const err: ?[]const u8 = if (obj.get("error")) |e| switch (e) {
        .string => |s| s,
        else => "malformed error",
    } else null;
    return .{ .response = .{ .id = id, .result = obj.get("result"), .err = err } };
}

pub fn decodeParams(comptime m: Method, arena: std.mem.Allocator, v: std.json.Value) !Params(m) {
    return std.json.parseFromValueLeaky(Params(m), arena, v, parse_opts);
}

pub fn decodeResult(comptime m: Method, arena: std.mem.Allocator, v: std.json.Value) !Result(m) {
    return std.json.parseFromValueLeaky(Result(m), arena, v, parse_opts);
}

// ---- endpoint ------------------------------------------------------------

/// `$FERRY_SOCKET`, else `$XDG_RUNTIME_DIR/ferry.sock`, else
/// `/tmp/ferry-<uid>.sock`. The runtime dir is 0700, so file permissions
/// are the access control; no token file is needed.
pub fn socketPath(alloc: std.mem.Allocator) ![]u8 {
    if (getenv("FERRY_SOCKET")) |p| return alloc.dupe(u8, p);
    if (getenv("XDG_RUNTIME_DIR")) |d| return std.fs.path.join(alloc, &.{ d, "ferry.sock" });
    return std.fmt.allocPrint(alloc, "/tmp/ferry-{d}.sock", .{std.c.getuid()});
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |v| std.mem.span(v) else null;
}

// ---- schema --------------------------------------------------------------

/// JSON Schema (draft 2020-12 subset) for every method and event, generated
/// from the types above.
pub fn writeSchema(w: *Writer) Writer.Error!void {
    try w.print("{{\"protocol\":{d},\"methods\":{{", .{version});
    inline for (@typeInfo(Method).@"enum".field_names, 0..) |name, i| {
        if (i > 0) try w.writeByte(',');
        const m: Method = @field(Method, name);
        try w.print("\"{s}\":{{\"params\":", .{name});
        try schemaOf(Params(m), w);
        try w.writeAll(",\"result\":");
        try schemaOf(Result(m), w);
        try w.writeByte('}');
    }
    try w.writeAll("},\"events\":{");
    const ev_info = @typeInfo(Event).@"union";
    inline for (ev_info.field_names, ev_info.field_types, 0..) |name, T, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"{s}\":", .{name});
        try schemaOf(T, w);
    }
    try w.writeAll("}}\n");
}

fn schemaOf(comptime T: type, w: *Writer) Writer.Error!void {
    switch (@typeInfo(T)) {
        .bool => try w.writeAll("{\"type\":\"boolean\"}"),
        .int => try w.writeAll("{\"type\":\"integer\"}"),
        .float => try w.writeAll("{\"type\":\"number\"}"),
        .optional => |o| {
            try w.writeAll("{\"anyOf\":[");
            try schemaOf(o.child, w);
            try w.writeAll(",{\"type\":\"null\"}]}");
        },
        .@"enum" => |e| {
            try w.writeAll("{\"enum\":[");
            inline for (e.field_names, 0..) |name, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("\"{s}\"", .{name});
            }
            try w.writeAll("]}");
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                try w.writeAll("{\"type\":\"string\"}");
            } else if (p.size == .slice) {
                try w.writeAll("{\"type\":\"array\",\"items\":");
                try schemaOf(p.child, w);
                try w.writeByte('}');
            } else @compileError("unsupported pointer in protocol: " ++ @typeName(T));
        },
        .@"struct" => |s| {
            try w.writeAll("{\"type\":\"object\",\"properties\":{");
            inline for (s.field_names, s.field_types, 0..) |name, FT, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("\"{s}\":", .{name});
                try schemaOf(FT, w);
            }
            try w.writeAll("},\"required\":[");
            var first = true;
            inline for (s.field_names, s.field_attrs) |name, attrs| {
                if (attrs.default_value_ptr == null) {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.print("\"{s}\"", .{name});
                }
            }
            try w.writeAll("]}");
        },
        else => @compileError("unsupported type in protocol: " ++ @typeName(T)),
    }
}

// ---- tests ---------------------------------------------------------------

test "request round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.Io.Writer.Allocating = .init(a);
    try writeRequest(&buf.writer, 7, .install, .{ .udid = "abc", .ipa = "/x.ipa", .bundle_id = "a.b" });
    const msg = try parseLine(a, std.mem.trimEnd(u8, buf.written(), "\n"));
    try std.testing.expectEqual(Method.install, msg.request.method);
    const p = try decodeParams(.install, a, msg.request.params);
    try std.testing.expectEqualStrings("abc", p.udid);
    try std.testing.expect(p.sign);
    try std.testing.expectEqualStrings("a.b", p.bundle_id.?);
    try std.testing.expect(p.identity == null);
}

test "event round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.Io.Writer.Allocating = .init(a);
    try writeEvent(&buf.writer, .{ .@"job.updated" = .{ .id = 3, .kind = "install", .title = "t", .state = .running, .percent = 40 } });
    const msg = try parseLine(a, std.mem.trimEnd(u8, buf.written(), "\n"));
    try std.testing.expectEqual(@as(u8, 40), msg.event.@"job.updated".percent);
}

test "response and error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.Io.Writer.Allocating = .init(a);
    try writeResult(&buf.writer, 2, .@"devices.list", &.{.{ .udid = "u", .connection = .network }});
    const ok = try parseLine(a, std.mem.trimEnd(u8, buf.written(), "\n"));
    const devs = try decodeResult(.@"devices.list", a, ok.response.result.?);
    try std.testing.expectEqual(Connection.network, devs[0].connection);

    buf.clearRetainingCapacity();
    try writeError(&buf.writer, 3, "no \"device\"");
    const bad = try parseLine(a, std.mem.trimEnd(u8, buf.written(), "\n"));
    try std.testing.expectEqualStrings("no \"device\"", bad.response.err.?);
}

test "schema covers every method" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try writeSchema(&buf.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.written(), .{});
    defer parsed.deinit();
    const methods = parsed.value.object.get("methods").?.object;
    try std.testing.expectEqual(@typeInfo(Method).@"enum".field_names.len, methods.count());
}
