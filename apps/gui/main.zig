//! ferry-gui: a pure client of ferryd. Every action is a protocol call on a
//! short-lived connection, and one long-lived subscribed connection keeps
//! devices and jobs live. Quitting the GUI never interrupts a job.
const std = @import("std");
const dvui = @import("dvui");
const client = @import("client");
const protocol = @import("protocol");
const i18n = @import("i18n");
const tr = i18n.tr;
const icons = dvui.entypo;

const app_id = "io.github.jbisfun.Ferry";

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = start },
    .frameFn = frame,
    .initFn = init,
    .deinitFn = deinit,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

fn start() dvui.App.StartOptions {
    // Wayland app_id / X11 class, so the desktop file's icon is used.
    _ = dvui.backend.c.SDL_SetAppMetadata("Ferry", "0.1", app_id);
    return .{
        .size = .{ .w = 1080, .h = 720 },
        .min_size = .{ .w = 760, .h = 500 },
        .title = "Ferry",
        .org = app_id,
        .app = "ferry",
        .icon = @embedFile("icon_png"),
    };
}

const gpa = std.heap.smp_allocator;

fn io() std.Io {
    return dvui.io;
}

/// Scratch memory for one frame (translated + formatted labels).
var frame_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);

fn fa() std.mem.Allocator {
    return frame_arena_state.allocator();
}

/// Translate `msgid` and fill {0}.. from `args`; valid for this frame.
fn trl(msgid: []const u8, args: []const []const u8) []const u8 {
    return i18n.trf(fa(), msgid, args) catch msgid;
}

fn num(n: usize) []const u8 {
    return std.fmt.allocPrint(fa(), "{d}", .{n}) catch "?";
}

// ---- shared state (guarded by `state.lock`) ------------------------------

/// A slice of results plus the arena that owns them.
fn Slot(comptime T: type) type {
    return struct {
        arena: ?std.heap.ArenaAllocator = null,
        items: []const T = &.{},
        loading: bool = false,
        /// Key the items belong to (UDID, path).
        owner: [1024]u8 = undefined,
        owner_len: usize = 0,

        fn replace(self: *@This(), arena: std.heap.ArenaAllocator, items: []const T, owner: []const u8) void {
            if (self.arena) |*a| a.deinit();
            self.arena = arena;
            self.items = items;
            self.loading = false;
            self.owner_len = @min(owner.len, self.owner.len);
            @memcpy(self.owner[0..self.owner_len], owner[0..self.owner_len]);
        }

        fn ownedBy(self: *const @This(), key: []const u8) bool {
            return std.mem.eql(u8, self.owner[0..self.owner_len], key);
        }
    };
}

const JobEntry = struct {
    arena: std.heap.ArenaAllocator,
    job: protocol.Job,
};

const State = struct {
    lock: std.Io.Mutex = .init,
    connected: bool = false,
    status_buf: [1024]u8 = undefined,
    status_len: usize = 0,
    status_is_error: bool = false,

    devices: Slot(protocol.Device) = .{},
    apps: Slot(protocol.App) = .{},
    info: Slot(protocol.KeyValue) = .{},
    identities: Slot(protocol.Identity) = .{},
    ipa: Slot(protocol.IpaInfo) = .{},
    jobs: std.ArrayList(JobEntry) = .empty,

    fn setStatus(self: *State, is_error: bool, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.status_buf, fmt, args) catch self.status_buf[0..];
        self.status_len = s.len;
        self.status_is_error = is_error;
    }

    fn upsertJob(self: *State, job: protocol.Job) void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        const copy = dupeJob(arena.allocator(), job) catch {
            arena.deinit();
            return;
        };
        for (self.jobs.items) |*e| if (e.job.id == job.id) {
            e.arena.deinit();
            e.* = .{ .arena = arena, .job = copy };
            return;
        };
        self.jobs.append(gpa, .{ .arena = arena, .job = copy }) catch arena.deinit();
    }
};

fn dupeJob(a: std.mem.Allocator, j: protocol.Job) !protocol.Job {
    var c = j;
    c.kind = try a.dupe(u8, j.kind);
    c.title = try a.dupe(u8, j.title);
    c.step = try a.dupe(u8, j.step);
    c.message = try a.dupe(u8, j.message);
    return c;
}

var state: State = .{};
var window: ?*dvui.Window = null;

fn lock() void {
    state.lock.lockUncancelable(io());
}

fn unlock() void {
    state.lock.unlock(io());
}

fn wake() void {
    if (window) |w| dvui.refresh(w, @src(), null);
}

// ---- background requests -------------------------------------------------

/// Run one protocol call on its own thread and connection, then hand the
/// result (owned by a fresh arena) to `apply` under the state lock.
fn request(
    comptime m: protocol.Method,
    params: protocol.Params(m),
    comptime apply: fn (arena: std.heap.ArenaAllocator, result: protocol.Result(m), owner: []const u8) void,
    owner: []const u8,
) void {
    const Task = struct {
        arena: std.heap.ArenaAllocator,
        params: protocol.Params(m),
        owner: []const u8,
        msg_buf: [512]u8 = undefined,

        fn run(task: *@This()) void {
            defer gpa.destroy(task);
            const a = task.arena.allocator();
            const conn = client.connectOrSpawn(gpa, io()) catch |e| {
                fail(task, i18n.trfBuf(&task.msg_buf, "Cannot reach ferryd: {0}", &.{@errorName(e)}));
                return;
            };
            defer conn.close();
            const result = conn.call(a, m, task.params) catch |e| {
                if (e == error.Remote) fail(task, conn.last_error.items) else fail(task, @errorName(e));
                return;
            };
            lock();
            apply(task.arena, result, task.owner);
            unlock();
            wake();
        }

        fn fail(task: *@This(), msg: []const u8) void {
            lock();
            state.setStatus(true, "{s}", .{msg});
            state.apps.loading = false;
            state.info.loading = false;
            unlock();
            task.arena.deinit();
            wake();
        }
    };

    const task = gpa.create(Task) catch return;
    task.* = .{ .arena = .init(gpa), .params = undefined, .owner = "" };
    const a = task.arena.allocator();
    task.params = dupeStrings(protocol.Params(m), a, params) catch {
        task.arena.deinit();
        gpa.destroy(task);
        return;
    };
    task.owner = a.dupe(u8, owner) catch "";
    const t = std.Thread.spawn(.{}, Task.run, .{task}) catch {
        task.arena.deinit();
        gpa.destroy(task);
        return;
    };
    t.detach();
}

fn dupeStrings(comptime T: type, a: std.mem.Allocator, p: T) !T {
    var out = p;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, FT| {
        if (FT == []const u8) @field(out, name) = try a.dupe(u8, @field(p, name));
        if (FT == ?[]const u8) if (@field(p, name)) |s| {
            @field(out, name) = try a.dupe(u8, s);
        };
    }
    return out;
}

fn applyDevices(arena: std.heap.ArenaAllocator, r: []const protocol.Device, _: []const u8) void {
    state.devices.replace(arena, r, "");
}
fn applyApps(arena: std.heap.ArenaAllocator, r: []const protocol.App, owner: []const u8) void {
    state.apps.replace(arena, r, owner);
}
fn applyInfo(arena: std.heap.ArenaAllocator, r: []const protocol.KeyValue, owner: []const u8) void {
    state.info.replace(arena, r, owner);
}
fn applyIdentities(arena: std.heap.ArenaAllocator, r: []const protocol.Identity, _: []const u8) void {
    state.identities.replace(arena, r, "");
}
fn applyIpa(arena: std.heap.ArenaAllocator, r: protocol.IpaInfo, owner: []const u8) void {
    var a = arena;
    const one = a.allocator().alloc(protocol.IpaInfo, 1) catch return;
    one[0] = r;
    state.ipa.replace(a, one, owner);
}
fn applyJobs(arena: std.heap.ArenaAllocator, r: []const protocol.Job, _: []const u8) void {
    for (r) |j| state.upsertJob(j);
    var a = arena;
    a.deinit();
}
fn applyStarted(arena: std.heap.ArenaAllocator, r: protocol.JobRef, _: []const u8) void {
    var b: [16]u8 = undefined;
    var mb: [128]u8 = undefined;
    state.setStatus(false, "{s}", .{i18n.trfBuf(&mb, "Started job {0}", &.{std.fmt.bufPrint(&b, "{d}", .{r.job}) catch "?"})});
    var a = arena;
    a.deinit();
}
fn applyUninstalled(arena: std.heap.ArenaAllocator, _: protocol.Empty, owner: []const u8) void {
    state.setStatus(false, "{s}", .{tr("App removed")});
    request(.@"device.apps", .{ .udid = owner }, applyApps, owner);
    var a = arena;
    a.deinit();
}
fn applyImport(arena: std.heap.ArenaAllocator, r: protocol.ImportReport, _: []const u8) void {
    var b: [16]u8 = undefined;
    var mb: [256]u8 = undefined;
    if (r.imported.len == 0) {
        state.setStatus(true, "{s}", .{tr("Nothing to import from Jimpactor")});
    } else {
        state.setStatus(false, "{s}", .{i18n.trfBuf(&mb, "Imported {0} item(s) from Jimpactor", &.{std.fmt.bufPrint(&b, "{d}", .{r.imported.len}) catch "?"})});
    }
    request(.@"identities.list", .{}, applyIdentities, "");
    var a = arena;
    a.deinit();
}

fn refreshAll() void {
    request(.@"devices.list", .{}, applyDevices, "");
    request(.@"identities.list", .{}, applyIdentities, "");
    request(.@"jobs.list", .{}, applyJobs, "");
}

/// Long-lived subscription: keeps devices and jobs current, reconnects
/// (starting the daemon if needed) when the connection drops.
fn eventLoop() void {
    while (true) {
        const conn = client.connectOrSpawn(gpa, io()) catch {
            io().sleep(.fromSeconds(2), .awake) catch {};
            continue;
        };
        defer conn.close();
        var sub_arena = std.heap.ArenaAllocator.init(gpa);
        defer sub_arena.deinit();
        conn.subscribe(sub_arena.allocator()) catch continue;

        lock();
        state.connected = true;
        unlock();
        refreshAll();
        wake();

        while (true) {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const ev = conn.nextEvent(arena.allocator()) catch break;
            switch (ev) {
                .@"device.attached", .@"device.detached" => request(.@"devices.list", .{}, applyDevices, ""),
                .@"job.updated" => |j| {
                    lock();
                    state.upsertJob(j);
                    if (j.state == .failed) state.setStatus(true, "{s}", .{j.message});
                    if (j.state == .succeeded) state.setStatus(false, "{s}", .{j.message});
                    unlock();
                },
            }
            wake();
        }
        lock();
        state.connected = false;
        unlock();
        wake();
        io().sleep(.fromSeconds(1), .awake) catch {};
    }
}

// ---- UI state (GUI thread only) --------------------------------------------

const Tab = enum { install, apps, info };

var ui: struct {
    selected: [80]u8 = undefined,
    selected_len: usize = 0,
    tab: Tab = .install,
    ipa_path: [1024]u8 = @splat(0),
    bundle_id: [256]u8 = @splat(0),
    identity_choice: usize = 0,
    resign: bool = true,
} = .{};

fn selectedUdid() []const u8 {
    return ui.selected[0..ui.selected_len];
}

fn select(udid: []const u8) void {
    ui.selected_len = @min(udid.len, ui.selected.len);
    @memcpy(ui.selected[0..ui.selected_len], udid[0..ui.selected_len]);
}

fn bufText(buf: []const u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

fn setBuf(buf: []u8, s: []const u8) void {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    @memset(buf[n..], 0);
}

// ---- theme and fonts ---------------------------------------------------------

var base_theme: dvui.Theme = undefined;
var loaded_family: ?[]const u8 = null;

/// UI font family and fontconfig patterns for the current language. English
/// follows the desktop's interface font (GNOME `font-name`); Traditional
/// Chinese needs a CJK font because dvui has no per-glyph fallback.
fn wantedFont() struct { family: []const u8, regular: []const u8, bold: []const u8 } {
    if (i18n.language() == .zh_TW) return .{ .family = "Ferry CJK", .regular = "sans-serif:lang=zh-tw", .bold = "sans-serif:lang=zh-tw:weight=bold" };
    return .{ .family = "Ferry UI", .regular = ui_font_pattern, .bold = ui_font_bold_pattern };
}

var ui_font_pattern_buf: [128]u8 = undefined;
var ui_font_bold_buf: [140]u8 = undefined;
var ui_font_pattern: []const u8 = "sans-serif";
var ui_font_bold_pattern: []const u8 = "sans-serif:weight=bold";

/// "'Adwaita Sans 11'" -> "Adwaita Sans".
fn detectDesktopFont() void {
    const res = std.process.run(gpa, io(), .{ .argv = &.{ "gsettings", "get", "org.gnome.desktop.interface", "font-name" } }) catch return;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    var name = std.mem.trim(u8, res.stdout, " \r\n'\"");
    if (std.mem.lastIndexOfScalar(u8, name, ' ')) |sp| {
        if (std.fmt.parseFloat(f32, name[sp + 1 ..])) |_| name = name[0..sp] else |_| {}
    }
    if (name.len == 0) return;
    ui_font_pattern = std.fmt.bufPrint(&ui_font_pattern_buf, "{s}", .{name}) catch return;
    ui_font_bold_pattern = std.fmt.bufPrint(&ui_font_bold_buf, "{s}:weight=bold", .{name}) catch return;
}

fn applyLanguage(win: *dvui.Window) void {
    var theme = base_theme;
    const want = wantedFont();
    const ok = (loaded_family != null and std.mem.eql(u8, loaded_family.?, want.family)) or blk: {
        const r = loadFont(win, want.family, want.regular, .normal);
        const b = loadFont(win, want.family, want.bold, .bold);
        if (r) loaded_family = want.family;
        break :blk r and b or r;
    };
    if (ok) {
        theme.font_body = theme.font_body.withFamily(want.family);
        theme.font_heading = theme.font_heading.withFamily(want.family);
        theme.font_title = theme.font_title.withFamily(want.family);
    } else if (i18n.language() == .zh_TW) {
        std.log.warn("no Traditional Chinese font found (install fonts-noto-cjk); CJK text will not render", .{});
    }
    win.themeSet(theme);
}

/// Load the font fontconfig picks for `pattern` into dvui's font database.
/// dvui opens face 0 of a font file, so for face N of a .ttc the header's
/// offset table is rotated to put face N first (table offsets are absolute,
/// nothing else changes).
fn loadFont(win: *dvui.Window, family: []const u8, pattern: []const u8, weight: dvui.Font.Weight) bool {
    for (win.fonts.database.items) |s| {
        if (std.mem.eql(u8, s.familyName(), family) and s.weight == weight) return true;
    }
    const res = std.process.run(gpa, io(), .{ .argv = &.{ "fc-match", "-f", "%{file}\n%{index}", pattern } }) catch return false;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    const path = lines.next() orelse return false;
    const index = std.fmt.parseInt(u32, lines.next() orelse "0", 10) catch 0;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io(), path, gpa, .limited(64 * 1024 * 1024)) catch return false;
    if (index > 0 and bytes.len > 12 and std.mem.eql(u8, bytes[0..4], "ttcf")) {
        const n = std.mem.readInt(u32, bytes[8..12], .big);
        if (index < n and 12 + n * 4 <= bytes.len) {
            var tmp: [4]u8 = undefined;
            @memcpy(&tmp, bytes[12..16]);
            @memcpy(bytes[12..16], bytes[12 + index * 4 ..][0..4]);
            @memcpy(bytes[12 + index * 4 ..][0..4], &tmp);
        }
    }
    win.fonts.database.append(win.gpa, .{
        .family = dvui.Font.array(family),
        .weight = weight,
        .bytes = bytes,
        .allocator = gpa,
    }) catch {
        gpa.free(bytes);
        return false;
    };
    return true;
}

// ---- app lifecycle -----------------------------------------------------------

fn init(win: *dvui.Window) !void {
    window = win;
    base_theme = switch (win.backend.preferredColorScheme() orelse .dark) {
        .light => dvui.Theme.builtin.adwaita_light,
        .dark => dvui.Theme.builtin.adwaita_dark,
    };
    i18n.initFromEnv();
    detectDesktopFont();
    applyLanguage(win);
    const t = try std.Thread.spawn(.{}, eventLoop, .{});
    t.detach();
}

fn deinit(_: *dvui.Window) void {}

/// FERRY_GUI_SCREENSHOT=out.png: after ~2s of frames, render one frame into
/// a PNG and quit. For docs and checking the UI without a compositor's
/// screenshot permission.
var shot_frames: u32 = 0;

fn frame() !dvui.App.Result {
    if (std.c.getenv("FERRY_GUI_SCREENSHOT")) |path| {
        shot_frames += 1;
        dvui.refresh(null, @src(), null);
        if (shot_frames >= 120) {
            var picture = dvui.Picture.start(dvui.windowRectPixels()) orelse return error.Unsupported;
            _ = try frameInner();
            _ = dvui.currentWindow().endRendering(.{});
            picture.stop();
            var file = try std.Io.Dir.cwd().createFile(io(), std.mem.span(path), .{});
            defer file.close(io());
            var buf: [64 * 1024]u8 = undefined;
            var w = file.writer(io(), &buf);
            try picture.png(&w.interface);
            try w.interface.flush();
            picture.deinit();
            return .close;
        }
    }
    return frameInner();
}

fn frameInner() !dvui.App.Result {
    _ = frame_arena_state.reset(.retain_capacity);
    lock();
    defer unlock();

    var root = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .style = .window });
    defer root.deinit();

    header();
    {
        var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer body.deinit();
        sidebar();
        mainPane();
    }
    jobsPanel();
    statusBar();
    return .ok;
}

// ---- widgets -------------------------------------------------------------------

const green: dvui.Color = .{ .r = 0x2e, .g = 0xc2, .b = 0x7e };
const red: dvui.Color = .{ .r = 0xe0, .g = 0x1b, .b = 0x24 };

/// Button with a leading icon, a gap, and the label beside it (dvui's
/// buttonLabelAndIcon puts them flush together).
fn iconButton(src: std.builtin.SourceLocation, label_text: []const u8, tvg: []const u8, opts: dvui.Options) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{}, opts);
    bw.processEvents();
    bw.drawBackground();
    const o = opts.strip().override(bw.style()).override(.{ .gravity_y = 0.5 });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
        defer row.deinit();
        dvui.icon(@src(), label_text, tvg, .{}, o.strip().override(.{ .gravity_y = 0.5, .min_size_content = .{ .h = 16 }, .margin = .{ .w = 6 }, .color_text = opts.color_text }));
        dvui.labelNoFmt(@src(), label_text, .{}, o.strip().override(.{ .gravity_y = 0.5 }));
    }
    const click = bw.clicked();
    bw.drawFocus();
    bw.deinit();
    return click;
}

fn header() void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 12, .w = 8, .y = 6, .h = 6 }, .background = true, .style = .control });
    defer bar.deinit();
    dvui.icon(@src(), "ferry", icons.water, .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .h = 22 }, .color_text = .{ .color = .{ .r = 0x35, .g = 0x84, .b = 0xe4 } } });
    dvui.labelNoFmt(@src(), "Ferry", .{}, .{ .font = .theme(.title), .gravity_y = 0.5, .margin = .{ .x = 6 } });
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    dvui.icon(@src(), "status", icons.dot_single, .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .h = 26 }, .color_text = .{ .color = if (state.connected) green else red } });
    dvui.labelNoFmt(@src(), if (state.connected) tr("daemon connected") else tr("connecting to ferryd..."), .{}, .{ .gravity_y = 0.5, .margin = .{ .w = 10 } });
    {
        const langs = comptime std.enums.values(i18n.Language);
        var names: [langs.len][]const u8 = undefined;
        for (langs, 0..) |l, k| names[k] = l.displayName();
        var choice: usize = @intFromEnum(i18n.language());
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 110 } })) {
            i18n.set(langs[choice]);
            applyLanguage(dvui.currentWindow());
        }
    }
    if (iconButton(@src(), tr("Refresh"), icons.cycle, .{ .gravity_y = 0.5 })) {
        refreshAll();
        if (ui.selected_len > 0) refreshDevice(selectedUdid());
    }
}

fn refreshDevice(udid: []const u8) void {
    state.apps.loading = true;
    state.info.loading = true;
    request(.@"device.apps", .{ .udid = udid }, applyApps, udid);
    request(.@"device.info", .{ .udid = udid }, applyInfo, udid);
}

fn sidebar() void {
    var side = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = 280 }, .max_size_content = .width(280), .expand = .vertical, .background = true, .style = .content, .padding = .all(8) });
    defer side.deinit();
    dvui.labelNoFmt(@src(), tr("Devices"), .{}, .{ .font = .theme(.heading), .padding = .all(4) });

    {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        if (state.devices.items.len == 0) {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
            tl.addText(tr("No devices.\n\nConnect over USB and trust this computer, or keep a paired device on the same Wi-Fi."), .{});
            tl.deinit();
        }
        for (state.devices.items, 0..) |d, i| deviceRow(d, i);
    }

    // Identities summary + import, at the bottom of the sidebar.
    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .y = 6, .h = 6 } });
    dvui.labelNoFmt(@src(), tr("Signing identities"), .{}, .{ .font = .theme(.heading), .padding = .all(4) });
    if (state.identities.items.len == 0) {
        dvui.labelNoFmt(@src(), tr("None yet"), .{}, .{ .padding = .all(4) });
    }
    for (state.identities.items, 0..) |id, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i, .padding = .{ .x = 4, .y = 2, .h = 2 } });
        defer row.deinit();
        dvui.icon(@src(), "key", icons.key, .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .h = 14 } });
        dvui.labelNoFmt(@src(), id.name, .{}, .{ .gravity_y = 0.5, .margin = .{ .x = 6 } });
    }
    if (iconButton(@src(), tr("Import from Jimpactor"), icons.download, .{ .expand = .horizontal, .margin = .{ .y = 6 } })) {
        request(.@"import.jimpactor", .{}, applyImport, "");
    }
}

fn deviceRow(d: protocol.Device, i: usize) void {
    const is_sel = std.mem.eql(u8, d.udid, selectedUdid());
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = i,
        .expand = .horizontal,
        .background = true,
        .style = if (is_sel) .highlight else .content,
        .corners = .all(8),
        .margin = .{ .y = 2, .h = 2 },
        .padding = .all(8),
    });
    bw.processEvents();
    bw.drawBackground();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.icon(@src(), "device", if (std.mem.startsWith(u8, d.product_type, "iPad")) icons.tablet else icons.mobile, .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .h = 26 }, .margin = .{ .w = 8 } });
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        defer col.deinit();
        dvui.labelNoFmt(@src(), if (d.name.len > 0) d.name else d.udid, .{}, .{ .font = .theme(.heading) });
        const line = trl("{0} · iOS {1} · {2}", &.{
            if (d.product_type.len > 0) d.product_type else tr("unknown"),
            if (d.os_version.len > 0) d.os_version else "?",
            if (d.connection == .usb) "USB" else "Wi-Fi",
        });
        const full = if (d.paired) line else std.mem.concat(fa(), u8, &.{ line, " · ", tr("not paired") }) catch line;
        dvui.labelNoFmt(@src(), full, .{}, .{});
    }
    if (bw.clicked()) {
        select(d.udid);
        refreshDevice(d.udid);
    }
    bw.deinit();
}

fn currentDevice() ?protocol.Device {
    for (state.devices.items) |d| if (std.mem.eql(u8, d.udid, selectedUdid())) return d;
    return null;
}

fn mainPane() void {
    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(16) });
    defer pane.deinit();

    const dev = currentDevice() orelse {
        var c = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_x = 0.5, .gravity_y = 0.4 });
        defer c.deinit();
        dvui.icon(@src(), "empty", icons.mobile, .{}, .{ .gravity_x = 0.5, .min_size_content = .{ .h = 64 } });
        dvui.labelNoFmt(@src(), tr("Select a device"), .{}, .{ .font = .theme(.title), .gravity_x = 0.5, .margin = .{ .y = 8 } });
        return;
    };
    dvui.labelNoFmt(@src(), if (dev.name.len > 0) dev.name else dev.udid, .{}, .{ .font = dvui.Font.theme(.title).larger(4) });
    dvui.labelNoFmt(@src(), dev.udid, .{}, .{});

    {
        var tabs: dvui.TabsWidget = undefined;
        tabs.init(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 10 } });
        defer tabs.deinit();
        inline for (.{ .{ Tab.install, i18n.N_("Install") }, .{ Tab.apps, i18n.N_("Apps") }, .{ Tab.info, i18n.N_("Info") } }) |t| {
            if (tabs.addTabLabel(ui.tab == t[0], tr(t[1]), .{})) ui.tab = t[0];
        }
    }
    switch (ui.tab) {
        .install => installTab(dev),
        .apps => appsTab(dev),
        .info => infoTab(dev),
    }
}

fn formRow(src: std.builtin.SourceLocation, label_text: []const u8) *dvui.BoxWidget {
    const row = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 5 } });
    dvui.labelNoFmt(@src(), label_text, .{}, .{ .min_size_content = .{ .w = 140 }, .gravity_y = 0.5 });
    return row;
}

fn installTab(dev: protocol.Device) void {
    var form = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .all(4) });
    defer form.deinit();

    {
        var row = formRow(@src(), tr("IPA"));
        defer row.deinit();
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = ui.ipa_path[0 .. ui.ipa_path.len - 1] }, .placeholder = tr("/path/to/App.ipa") }, .{ .expand = .horizontal });
        const changed = te.enter_pressed;
        te.deinit();
        if (changed) inspectIpa();
        if (iconButton(@src(), tr("Browse..."), icons.folder, .{})) {
            if (dvui.dialogNativeFileOpen(gpa, .{ .title = tr("Choose an IPA"), .filters = &.{"*.ipa"}, .filter_description = tr("iOS apps") }) catch null) |path| {
                defer gpa.free(path);
                setBuf(&ui.ipa_path, path);
                inspectIpa();
            }
        }
    }

    // What the IPA is, once inspected.
    if (state.ipa.items.len == 1 and state.ipa.ownedBy(bufText(&ui.ipa_path))) {
        const info = state.ipa.items[0];
        var row = formRow(@src(), "");
        defer row.deinit();
        dvui.labelNoFmt(@src(), trl("{0} {1} · {2} · iOS {3}+", &.{ info.name, info.version, info.bundle_id, info.min_os }), .{}, .{ .gravity_y = 0.5 });
    }

    {
        var row = formRow(@src(), tr("Re-sign"));
        defer row.deinit();
        _ = dvui.checkbox(@src(), &ui.resign, tr("Sign with an identity before installing"), .{});
    }

    if (ui.resign) {
        {
            var row = formRow(@src(), tr("Identity"));
            defer row.deinit();
            var names: [32][]const u8 = undefined;
            names[0] = tr("Default");
            var n: usize = 1;
            for (state.identities.items) |id| {
                if (n == names.len) break;
                names[n] = id.name;
                n += 1;
            }
            if (ui.identity_choice >= n) ui.identity_choice = 0;
            _ = dvui.dropdown(@src(), names[0..n], .{ .choice = &ui.identity_choice }, .{}, .{ .min_size_content = .{ .w = 240 } });
            if (ui.identity_choice > 0) {
                const id = state.identities.items[ui.identity_choice - 1];
                dvui.labelNoFmt(@src(), id.detail, .{}, .{ .gravity_y = 0.5, .margin = .{ .x = 8 } });
            } else if (state.identities.items.len == 0) {
                dvui.labelNoFmt(@src(), tr("No identities yet: ferry identity add <name> --p12 ... --profile ..."), .{}, .{ .gravity_y = 0.5, .margin = .{ .x = 8 } });
            }
        }
        {
            var row = formRow(@src(), tr("Bundle ID"));
            defer row.deinit();
            var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = ui.bundle_id[0 .. ui.bundle_id.len - 1] }, .placeholder = tr("keep (or pick from the profile)") }, .{ .expand = .horizontal });
            te.deinit();
        }
    }

    {
        var row = formRow(@src(), "");
        defer row.deinit();
        const path = bufText(&ui.ipa_path);
        const can = path.len > 0 and dev.paired;
        if (iconButton(@src(), tr("Install"), icons.install, .{ .style = if (can) .highlight else .control, .min_size_content = .{ .w = 120 } }) and can) {
            const bundle = bufText(&ui.bundle_id);
            request(.install, .{
                .udid = dev.udid,
                .ipa = path,
                .sign = ui.resign,
                .identity = if (ui.identity_choice > 0) state.identities.items[ui.identity_choice - 1].name else null,
                .bundle_id = if (bundle.len > 0) bundle else null,
            }, applyStarted, "");
        }
        if (!dev.paired) dvui.labelNoFmt(@src(), tr("Unlock the device and trust this computer first."), .{}, .{ .gravity_y = 0.5, .margin = .{ .x = 8 } });
    }
}

fn inspectIpa() void {
    const path = bufText(&ui.ipa_path);
    if (path.len == 0) return;
    request(.@"ipa.inspect", .{ .path = path }, applyIpa, path);
}

fn appsTab(dev: protocol.Device) void {
    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .h = 6 } });
        defer bar.deinit();
        const count = if (state.apps.ownedBy(dev.udid)) state.apps.items.len else 0;
        const label = trl("{0} user apps", &.{num(count)});
        dvui.labelNoFmt(@src(), if (state.apps.loading) std.mem.concat(fa(), u8, &.{ label, " ", tr("(loading...)") }) catch label else label, .{}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (iconButton(@src(), tr("Reload"), icons.cycle, .{})) refreshDevice(dev.udid);
    }
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .style = .content, .corners = .all(8) });
    defer scroll.deinit();
    if (!state.apps.ownedBy(dev.udid)) return;
    for (state.apps.items, 0..) |app, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i, .padding = .all(8) });
        defer row.deinit();
        dvui.icon(@src(), "app", icons.box, .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .h = 22 }, .margin = .{ .w = 10 } });
        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
            defer col.deinit();
            dvui.labelNoFmt(@src(), std.mem.concat(fa(), u8, &.{ app.name, "  ", app.version }) catch app.name, .{}, .{ .font = .theme(.heading) });
            dvui.labelNoFmt(@src(), app.bundle_id, .{}, .{});
        }
        if (iconButton(@src(), tr("Remove"), icons.trash, .{ .gravity_y = 0.5, .style = .err })) {
            request(.@"device.uninstall", .{ .udid = dev.udid, .bundle_id = app.bundle_id }, applyUninstalled, dev.udid);
        }
    }
}

fn infoTab(dev: protocol.Device) void {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .style = .content, .corners = .all(8) });
    defer scroll.deinit();
    if (!state.info.ownedBy(dev.udid)) {
        dvui.labelNoFmt(@src(), if (state.info.loading) tr("Loading...") else tr("No data"), .{}, .{ .padding = .all(8) });
        return;
    }
    for (state.info.items, 0..) |kv, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i, .padding = .{ .x = 10, .w = 10, .y = 3, .h = 3 } });
        defer row.deinit();
        dvui.labelNoFmt(@src(), kv.key, .{}, .{ .min_size_content = .{ .w = 280 }, .font = .theme(.heading) });
        dvui.labelNoFmt(@src(), kv.value, .{}, .{});
    }
}

fn jobsPanel() void {
    if (state.jobs.items.len == 0) return;
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = true, .style = .control, .padding = .{ .x = 12, .w = 12, .y = 8, .h = 8 } });
    defer panel.deinit();
    dvui.labelNoFmt(@src(), tr("Jobs"), .{}, .{ .font = .theme(.heading) });
    // Newest first, at most four.
    var shown: usize = 0;
    var i = state.jobs.items.len;
    while (i > 0 and shown < 4) : (shown += 1) {
        i -= 1;
        const j = state.jobs.items[i].job;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = j.id, .margin = .{ .y = 3 } });
        defer row.deinit();
        const ic = switch (j.state) {
            .failed => icons.circle_with_cross,
            .succeeded => icons.check,
            .running => icons.hour_glass,
        };
        const col: ?dvui.Color = switch (j.state) {
            .failed => red,
            .succeeded => green,
            .running => null,
        };
        dvui.icon(@src(), "job", ic, .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .h = 16 }, .margin = .{ .w = 8 }, .color_text = if (col) |cc| .{ .color = cc } else null });
        dvui.labelNoFmt(@src(), j.title, .{}, .{ .min_size_content = .{ .w = 300 }, .gravity_y = 0.5 });
        dvui.progress(@src(), .{ .percent = @as(f32, @floatFromInt(j.percent)) / 100.0, .color = col }, .{ .min_size_content = .{ .w = 160, .h = 8 }, .gravity_y = 0.5, .corners = .all(4) });
        dvui.labelNoFmt(@src(), tr(if (j.state == .running) j.step else @tagName(j.state)), .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 90 }, .margin = .{ .x = 8 } });
        dvui.labelNoFmt(@src(), j.message, .{}, .{ .gravity_y = 0.5 });
    }
}

fn statusBar() void {
    if (state.status_len == 0) return;
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 12, .w = 8, .y = 4, .h = 4 }, .background = true, .style = if (state.status_is_error) .err else .window });
    defer bar.deinit();
    dvui.icon(@src(), "status", if (state.status_is_error) icons.warning else icons.info_with_circle, .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .h = 16 }, .margin = .{ .w = 8 } });
    dvui.labelNoFmt(@src(), state.status_buf[0..state.status_len], .{}, .{ .expand = .horizontal, .gravity_y = 0.5 });
    if (dvui.buttonIcon(@src(), tr("Dismiss"), icons.cross, .{}, .{}, .{ .gravity_y = 0.5 })) state.status_len = 0;
}
