//! Device access through libimobiledevice (usbmuxd for USB and Wi-Fi).
//!
//! Every call opens its own idevice/lockdown/service handles and closes them
//! on every path (defer), so there is no long-lived per-device worker whose
//! state can wedge. This module knows nothing about signing or the protocol.
const std = @import("std");
const diag = @import("diag");
const plist = @import("plist");

pub const c = @import("c");

const label = "ferry";

pub const Connection = enum { usb, network };

pub const Summary = struct {
    udid: []const u8,
    connection: Connection,
    name: []const u8 = "",
    product_type: []const u8 = "",
    os_version: []const u8 = "",
    paired: bool = false,
};

pub const KeyValue = struct { key: []const u8, value: []const u8 };

pub const App = struct {
    bundle_id: []const u8,
    name: []const u8,
    version: []const u8,
};

fn connOf(t: c_uint) Connection {
    return if (t == c.CONNECTION_NETWORK) .network else .usb;
}

// ---- handles -------------------------------------------------------------

const Handle = struct {
    dev: c.idevice_t,

    fn open(udid: []const u8, d: ?*diag.Diag) !Handle {
        var buf: [128]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{udid}, 0) catch return diag.fail(d, error.BadUdid, "UDID too long", .{});
        var dev: c.idevice_t = null;
        const rc = c.idevice_new_with_options(&dev, z.ptr, c.IDEVICE_LOOKUP_USBMUX | c.IDEVICE_LOOKUP_NETWORK);
        if (rc != c.IDEVICE_E_SUCCESS) return diag.fail(d, error.DeviceNotFound, "device {s} is not connected (usbmuxd error {d})", .{ udid, rc });
        return .{ .dev = dev };
    }

    fn close(self: Handle) void {
        _ = c.idevice_free(self.dev);
    }

    fn lockdown(self: Handle, udid: []const u8, d: ?*diag.Diag) !c.lockdownd_client_t {
        var ld: c.lockdownd_client_t = null;
        const rc = c.lockdownd_client_new_with_handshake(self.dev, &ld, label);
        if (rc != c.LOCKDOWN_E_SUCCESS) return diag.fail(d, error.Lockdown, "lockdown session with {s} failed ({s}); is the device unlocked and trusted?", .{ udid, lockdownError(rc) });
        return ld;
    }
};

fn lockdownError(rc: c.lockdownd_error_t) []const u8 {
    return switch (rc) {
        c.LOCKDOWN_E_PASSWORD_PROTECTED => "device is locked",
        c.LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING => "trust dialog pending on device",
        c.LOCKDOWN_E_USER_DENIED_PAIRING => "user denied pairing",
        c.LOCKDOWN_E_INVALID_HOST_ID => "not paired with this computer",
        c.LOCKDOWN_E_SSL_ERROR => "TLS error",
        c.LOCKDOWN_E_MUX_ERROR => "usbmux error",
        else => "lockdown error",
    };
}

// ---- queries ---------------------------------------------------------------

/// Devices known to usbmuxd, one entry per UDID (USB preferred over Wi-Fi).
/// Each is probed over lockdown for name/model/version; unpaired devices are
/// still listed with `paired = false`.
pub fn list(alloc: std.mem.Allocator) ![]Summary {
    var infos: [*c]c.idevice_info_t = null;
    var count: c_int = 0;
    if (c.idevice_get_device_list_extended(&infos, &count) != c.IDEVICE_E_SUCCESS) return &.{};
    defer _ = c.idevice_device_list_extended_free(infos);

    var out: std.ArrayList(Summary) = .empty;
    var i: usize = 0;
    while (i < @as(usize, @intCast(count))) : (i += 1) {
        const entry = infos[i];
        const udid = std.mem.span(entry.*.udid);
        const conn = connOf(entry.*.conn_type);
        var dup = false;
        for (out.items) |*s| if (std.mem.eql(u8, s.udid, udid)) {
            dup = true;
            if (conn == .usb) s.connection = .usb;
        };
        if (dup) continue;
        try out.append(alloc, try probe(alloc, udid, conn));
    }
    return out.toOwnedSlice(alloc);
}

fn probe(alloc: std.mem.Allocator, udid: []const u8, conn: Connection) !Summary {
    var s: Summary = .{ .udid = try alloc.dupe(u8, udid), .connection = conn };
    const h = Handle.open(udid, null) catch return s;
    defer h.close();

    var ld: c.lockdownd_client_t = null;
    if (c.lockdownd_client_new_with_handshake(h.dev, &ld, label) != c.LOCKDOWN_E_SUCCESS) {
        // Unpaired: the name is still readable without a session.
        if (c.lockdownd_client_new(h.dev, &ld, label) == c.LOCKDOWN_E_SUCCESS) {
            defer _ = c.lockdownd_client_free(ld);
            var name: [*c]u8 = null;
            if (c.lockdownd_get_device_name(ld, &name) == c.LOCKDOWN_E_SUCCESS and name != null) {
                defer c.plist_mem_free(name);
                s.name = try alloc.dupe(u8, std.mem.span(name));
            }
        }
        return s;
    }
    defer _ = c.lockdownd_client_free(ld);
    s.paired = true;
    s.name = try getString(alloc, ld, "DeviceName");
    s.product_type = try getString(alloc, ld, "ProductType");
    s.os_version = try getString(alloc, ld, "ProductVersion");
    return s;
}

fn getString(alloc: std.mem.Allocator, ld: c.lockdownd_client_t, key: [:0]const u8) ![]const u8 {
    var v: c.plist_t = null;
    if (c.lockdownd_get_value(ld, null, key.ptr, &v) != c.LOCKDOWN_E_SUCCESS or v == null) return "";
    const owned = plist.adopt(v);
    defer owned.deinit();
    return alloc.dupe(u8, owned.root.str() orelse "");
}

/// All top-level lockdown values, sorted by key.
pub fn info(alloc: std.mem.Allocator, udid: []const u8, d: ?*diag.Diag) ![]KeyValue {
    const h = try Handle.open(udid, d);
    defer h.close();
    const ld = try h.lockdown(udid, d);
    defer _ = c.lockdownd_client_free(ld);

    var v: c.plist_t = null;
    if (c.lockdownd_get_value(ld, null, null, &v) != c.LOCKDOWN_E_SUCCESS or v == null)
        return diag.fail(d, error.Lockdown, "could not read device values", .{});
    const owned = plist.adopt(v);
    defer owned.deinit();

    const entries = try owned.root.entries(alloc);
    const out = try alloc.alloc(KeyValue, entries.len);
    for (entries, 0..) |e, i| out[i] = .{ .key = e.key, .value = try e.value.render(alloc) };
    std.mem.sort(KeyValue, out, {}, struct {
        fn lt(_: void, a: KeyValue, b: KeyValue) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lt);
    return out;
}

fn instproxy(h: Handle, udid: []const u8, d: ?*diag.Diag) !c.instproxy_client_t {
    var ip: c.instproxy_client_t = null;
    const rc = c.instproxy_client_start_service(h.dev, &ip, label);
    if (rc != c.INSTPROXY_E_SUCCESS) return diag.fail(d, error.Service, "cannot start installation_proxy on {s} (error {d}); is the device unlocked?", .{ udid, rc });
    return ip;
}

/// User-installed apps, sorted by name.
pub fn apps(alloc: std.mem.Allocator, udid: []const u8, d: ?*diag.Diag) ![]App {
    const h = try Handle.open(udid, d);
    defer h.close();
    const ip = try instproxy(h, udid, d);
    defer _ = c.instproxy_client_free(ip);

    const opts = c.instproxy_client_options_new();
    defer c.instproxy_client_options_free(opts);
    c.instproxy_client_options_add(opts, "ApplicationType", "User", @as(?*anyopaque, null));
    c.instproxy_client_options_set_return_attributes(opts, "CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString", @as(?*anyopaque, null));

    var result: c.plist_t = null;
    const rc = c.instproxy_browse(ip, opts, &result);
    if (rc != c.INSTPROXY_E_SUCCESS or result == null) return diag.fail(d, error.Service, "listing apps failed (error {d})", .{rc});
    const owned = plist.adopt(result);
    defer owned.deinit();

    var out: std.ArrayList(App) = .empty;
    for (0..owned.root.len()) |i| {
        const a = owned.root.at(i).?;
        const id = a.getStr("CFBundleIdentifier") orelse continue;
        try out.append(alloc, .{
            .bundle_id = try alloc.dupe(u8, id),
            .name = try alloc.dupe(u8, a.getStr("CFBundleDisplayName") orelse a.getStr("CFBundleName") orelse id),
            .version = try alloc.dupe(u8, a.getStr("CFBundleShortVersionString") orelse ""),
        });
    }
    std.mem.sort(App, out.items, {}, struct {
        fn lt(_: void, x: App, y: App) bool {
            return std.ascii.lessThanIgnoreCase(x.name, y.name);
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

pub fn uninstall(udid: []const u8, bundle_id: []const u8, d: ?*diag.Diag) !void {
    const h = try Handle.open(udid, d);
    defer h.close();
    const ip = try instproxy(h, udid, d);
    defer _ = c.instproxy_client_free(ip);
    var buf: [512]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{bundle_id}, 0) catch return diag.fail(d, error.BadBundleId, "bundle id too long", .{});
    // NULL callback = synchronous.
    const rc = c.instproxy_uninstall(ip, z.ptr, null, null, null);
    if (rc != c.INSTPROXY_E_SUCCESS) return diag.fail(d, error.UninstallFailed, "uninstalling {s} failed (error {d})", .{ bundle_id, rc });
}

// ---- install ---------------------------------------------------------------

pub const Phase = enum { upload, install };

/// Progress callback: phase, percent 0-100, optional status text.
pub const Progress = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, phase: Phase, percent: u8, status: []const u8) void,

    fn report(self: Progress, phase: Phase, percent: u8, status: []const u8) void {
        self.func(self.ctx, phase, percent, status);
    }
};

const InstallState = struct {
    io: std.Io,
    progress: Progress,
    done: std.Io.Event = .unset,
    failed: bool = false,
    err_buf: [512]u8 = undefined,
    err_len: usize = 0,
};

fn installCallback(command: c.plist_t, status: c.plist_t, user: ?*anyopaque) callconv(.c) void {
    _ = command;
    const st: *InstallState = @ptrCast(@alignCast(user.?));
    var name: [*c]u8 = null;
    var desc: [*c]u8 = null;
    var code: u64 = 0;
    if (c.instproxy_status_get_error(status, &name, &desc, &code) != c.INSTPROXY_E_SUCCESS) {
        defer if (name != null) c.plist_mem_free(name);
        defer if (desc != null) c.plist_mem_free(desc);
        const n = if (name != null) std.mem.span(name) else "error";
        const ds = if (desc != null) std.mem.span(desc) else "";
        const msg = std.fmt.bufPrint(&st.err_buf, "{s}: {s} (0x{x})", .{ n, ds, code }) catch st.err_buf[0..];
        st.err_len = msg.len;
        st.failed = true;
        st.done.set(st.io);
        return;
    }
    const node = plist.Node{ .h = status };
    const s = node.getStr("Status") orelse "";
    var pct: c_int = -1;
    c.instproxy_status_get_percent_complete(status, &pct);
    if (pct >= 0) st.progress.report(.install, @intCast(@min(pct, 100)), s);
    if (std.mem.eql(u8, s, "Complete")) {
        st.progress.report(.install, 100, s);
        st.done.set(st.io);
    }
}

/// Upload `ipa_path` to PublicStaging over AFC and install it.
pub fn install(alloc: std.mem.Allocator, io: std.Io, udid: []const u8, ipa_path: []const u8, progress: Progress, d: ?*diag.Diag) !void {
    const h = try Handle.open(udid, d);
    defer h.close();

    // Upload.
    var afc: c.afc_client_t = null;
    if (c.afc_client_start_service(h.dev, &afc, label) != c.AFC_E_SUCCESS)
        return diag.fail(d, error.Service, "cannot start AFC on {s}; is the device unlocked?", .{udid});
    defer _ = c.afc_client_free(afc);

    _ = c.afc_make_directory(afc, "PublicStaging");
    var name_buf: [96]u8 = undefined;
    const remote = try std.fmt.bufPrintSentinel(&name_buf, "PublicStaging/ferry-{d}.ipa", .{std.Io.Clock.real.now(io).toMilliseconds()}, 0);

    var file = std.Io.Dir.cwd().openFile(io, ipa_path, .{}) catch |e| return diag.fail(d, e, "cannot open {s}: {s}", .{ ipa_path, @errorName(e) });
    defer file.close(io);
    const total = (try file.stat(io)).size;

    var handle: u64 = 0;
    if (c.afc_file_open(afc, remote.ptr, c.AFC_FOPEN_WRONLY, &handle) != c.AFC_E_SUCCESS)
        return diag.fail(d, error.UploadFailed, "cannot create {s} on device", .{remote});
    const upload_ok = blk: {
        const chunk = try alloc.alloc(u8, 1 << 20);
        defer alloc.free(chunk);
        var sent: u64 = 0;
        while (true) {
            const n = try file.readStreaming(io, &.{chunk});
            if (n == 0) break;
            var off: usize = 0;
            while (off < n) {
                var written: u32 = 0;
                if (c.afc_file_write(afc, handle, chunk[off..].ptr, @intCast(n - off), &written) != c.AFC_E_SUCCESS or written == 0)
                    break :blk false;
                off += written;
            }
            sent += n;
            progress.report(.upload, if (total == 0) 100 else @intCast(sent * 100 / total), "");
        }
        break :blk true;
    };
    _ = c.afc_file_close(afc, handle);
    if (!upload_ok) return diag.fail(d, error.UploadFailed, "upload to {s} failed", .{udid});

    // Install.
    const ip = try instproxy(h, udid, d);
    defer _ = c.instproxy_client_free(ip);
    var st: InstallState = .{ .io = io, .progress = progress };
    const rc = c.instproxy_install(ip, remote.ptr, null, installCallback, &st);
    if (rc != c.INSTPROXY_E_SUCCESS) return diag.fail(d, error.InstallFailed, "install request rejected (error {d})", .{rc});
    st.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(15 * 60), .clock = .awake } }) catch return diag.fail(d, error.Timeout, "install timed out", .{});
    _ = c.afc_remove_path(afc, remote.ptr);
    if (st.failed) return diag.fail(d, error.InstallFailed, "{s}", .{st.err_buf[0..st.err_len]});
}

// ---- pairing records ---------------------------------------------------------

/// Whether usbmuxd already holds a pairing record for `udid`.
pub fn hasPairRecord(udid: []const u8) bool {
    var buf: [128]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{udid}, 0) catch return false;
    var data: [*c]u8 = null;
    var len: u32 = 0;
    if (c.usbmuxd_read_pair_record(z.ptr, &data, &len) != 0 or data == null) return false;
    std.c.free(data);
    return true;
}

/// Hand a lockdown pairing record (plist bytes) to usbmuxd, which stores it
/// with its own records so USB and Wi-Fi connections can use it.
pub fn savePairRecord(udid: []const u8, record: []const u8, d: ?*diag.Diag) !void {
    var buf: [128]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{udid}, 0) catch return diag.fail(d, error.BadUdid, "UDID too long", .{});
    const rc = c.usbmuxd_save_pair_record(z.ptr, record.ptr, @intCast(record.len));
    if (rc != 0) return diag.fail(d, error.PairRecord, "usbmuxd refused the pairing record for {s} (error {d}); is usbmuxd running?", .{ udid, rc });
}

// ---- hotplug ----------------------------------------------------------------

pub const Event = struct {
    kind: enum { attached, detached, paired },
    udid: []const u8,
    connection: Connection,
};

pub const Monitor = struct {
    ctx: c.idevice_subscription_context_t = null,
    sink: *const fn (user: ?*anyopaque, ev: Event) void,
    user: ?*anyopaque,

    /// `self` must stay at a stable address until `stop`.
    pub fn start(self: *Monitor) !void {
        if (c.idevice_events_subscribe(&self.ctx, callback, self) != c.IDEVICE_E_SUCCESS) return error.SubscribeFailed;
    }

    pub fn stop(self: *Monitor) void {
        if (self.ctx != null) _ = c.idevice_events_unsubscribe(self.ctx);
        self.ctx = null;
    }

    fn callback(ev: [*c]const c.idevice_event_t, user: ?*anyopaque) callconv(.c) void {
        const self: *Monitor = @ptrCast(@alignCast(user.?));
        const e = ev.*;
        self.sink(self.user, .{
            .kind = switch (e.event) {
                c.IDEVICE_DEVICE_ADD => .attached,
                c.IDEVICE_DEVICE_REMOVE => .detached,
                else => .paired,
            },
            .udid = std.mem.span(e.udid),
            .connection = connOf(e.conn_type),
        });
    }
};

test "list does not crash without usbmuxd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try list(arena.allocator());
}
