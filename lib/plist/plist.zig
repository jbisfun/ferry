//! Thin, read-mostly wrapper over libplist.
//!
//! `Node` is a borrowed view (no ownership); `Owned` frees the tree it parsed.
//! Strings returned by `str` point into libplist memory and live as long as
//! the tree does; dupe them if they must outlive it.
const std = @import("std");
const diag = @import("diag");

pub const c = @import("c");

pub const Kind = enum { boolean, integer, real, string, array, dict, date, data, key, uid, null, none };

pub const Node = struct {
    h: c.plist_t,

    pub fn kind(self: Node) Kind {
        return switch (c.plist_get_node_type(self.h)) {
            c.PLIST_BOOLEAN => .boolean,
            c.PLIST_INT => .integer,
            c.PLIST_REAL => .real,
            c.PLIST_STRING => .string,
            c.PLIST_ARRAY => .array,
            c.PLIST_DICT => .dict,
            c.PLIST_DATE => .date,
            c.PLIST_DATA => .data,
            c.PLIST_KEY => .key,
            c.PLIST_UID => .uid,
            c.PLIST_NULL => .null,
            else => .none,
        };
    }

    pub fn get(self: Node, key: [:0]const u8) ?Node {
        if (self.kind() != .dict) return null;
        const h = c.plist_dict_get_item(self.h, key.ptr);
        return if (h == null) null else .{ .h = h };
    }

    /// Follow a chain of dict keys.
    pub fn path(self: Node, keys: []const [:0]const u8) ?Node {
        var n = self;
        for (keys) |k| n = n.get(k) orelse return null;
        return n;
    }

    pub fn str(self: Node) ?[]const u8 {
        if (self.kind() != .string) return null;
        var n: u64 = 0;
        const p = c.plist_get_string_ptr(self.h, &n) orelse return null;
        return p[0..@intCast(n)];
    }

    pub fn getStr(self: Node, key: [:0]const u8) ?[]const u8 {
        return if (self.get(key)) |n| n.str() else null;
    }

    pub fn boolean(self: Node) ?bool {
        if (self.kind() != .boolean) return null;
        var v: u8 = 0;
        c.plist_get_bool_val(self.h, &v);
        return v != 0;
    }

    pub fn int(self: Node) ?i64 {
        if (self.kind() != .integer) return null;
        var v: i64 = 0;
        c.plist_get_int_val(self.h, &v);
        return v;
    }

    pub fn real(self: Node) ?f64 {
        if (self.kind() != .real) return null;
        var v: f64 = 0;
        c.plist_get_real_val(self.h, &v);
        return v;
    }

    /// Seconds since the Unix epoch.
    pub fn date(self: Node) ?i64 {
        if (self.kind() != .date) return null;
        var v: i64 = 0;
        c.plist_get_unix_date_val(self.h, &v);
        return v;
    }

    pub fn data(self: Node) ?[]const u8 {
        if (self.kind() != .data) return null;
        var n: u64 = 0;
        const p = c.plist_get_data_ptr(self.h, &n) orelse return null;
        return p[0..@intCast(n)];
    }

    pub fn len(self: Node) usize {
        return switch (self.kind()) {
            .array => c.plist_array_get_size(self.h),
            .dict => c.plist_dict_get_size(self.h),
            else => 0,
        };
    }

    pub fn at(self: Node, i: usize) ?Node {
        if (self.kind() != .array) return null;
        const h = c.plist_array_get_item(self.h, @intCast(i));
        return if (h == null) null else .{ .h = h };
    }

    pub const Entry = struct { key: []const u8, value: Node };

    /// Iterate a dict. Keys are copied into `alloc`.
    pub fn entries(self: Node, alloc: std.mem.Allocator) ![]Entry {
        var out: std.ArrayList(Entry) = .empty;
        if (self.kind() != .dict) return out.toOwnedSlice(alloc);
        var it: c.plist_dict_iter = null;
        c.plist_dict_new_iter(self.h, &it);
        defer c.plist_mem_free(it);
        while (true) {
            var key: [*c]u8 = null;
            var val: c.plist_t = null;
            c.plist_dict_next_item(self.h, it, &key, &val);
            if (val == null) break;
            defer c.plist_mem_free(key);
            try out.append(alloc, .{ .key = try alloc.dupe(u8, std.mem.span(key)), .value = .{ .h = val } });
        }
        return out.toOwnedSlice(alloc);
    }

    /// Short human-readable rendering of a value (for key/value displays).
    pub fn render(self: Node, alloc: std.mem.Allocator) ![]u8 {
        return switch (self.kind()) {
            .string => alloc.dupe(u8, self.str() orelse ""),
            .boolean => alloc.dupe(u8, if (self.boolean().?) "true" else "false"),
            .integer => std.fmt.allocPrint(alloc, "{d}", .{self.int().?}),
            .real => std.fmt.allocPrint(alloc, "{d}", .{self.real().?}),
            .date => std.fmt.allocPrint(alloc, "@{d}", .{self.date().?}),
            .data => blk: {
                const d = self.data() orelse "";
                if (d.len <= 32) break :blk std.fmt.allocPrint(alloc, "<{x}>", .{d});
                break :blk std.fmt.allocPrint(alloc, "<{d} bytes>", .{d.len});
            },
            .array => std.fmt.allocPrint(alloc, "[{d} items]", .{self.len()}),
            .dict => std.fmt.allocPrint(alloc, "{{{d} keys}}", .{self.len()}),
            else => alloc.dupe(u8, ""),
        };
    }
};

pub const Owned = struct {
    root: Node,

    pub fn deinit(self: Owned) void {
        c.plist_free(self.root.h);
    }
};

/// Parse XML, binary or JSON/OpenStep plist bytes.
pub fn parse(bytes: []const u8, d: ?*diag.Diag) !Owned {
    var h: c.plist_t = null;
    var fmt: c.plist_format_t = undefined;
    const rc = c.plist_from_memory(bytes.ptr, @intCast(bytes.len), &h, &fmt);
    if (rc != c.PLIST_ERR_SUCCESS or h == null) return diag.fail(d, error.BadPlist, "not a property list (libplist error {d})", .{rc});
    return .{ .root = .{ .h = h } };
}

/// Take ownership of a tree created elsewhere (e.g. returned by libimobiledevice).
pub fn adopt(h: c.plist_t) Owned {
    return .{ .root = .{ .h = h } };
}

/// The XML plist embedded in a CMS-signed blob such as a .mobileprovision.
pub fn embeddedXml(blob: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, blob, "<?xml") orelse return null;
    const end_tag = "</plist>";
    const end = std.mem.indexOfPos(u8, blob, start, end_tag) orelse return null;
    return blob[start .. end + end_tag.len];
}

test "parse xml" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<plist version="1.0"><dict>
        \\<key>CFBundleIdentifier</key><string>com.example.app</string>
        \\<key>Ent</key><dict><key>get-task-allow</key><true/></dict>
        \\<key>Devs</key><array><string>a</string><string>b</string></array>
        \\<key>N</key><integer>42</integer>
        \\</dict></plist>
    ;
    const p = try parse(xml, null);
    defer p.deinit();
    try std.testing.expectEqualStrings("com.example.app", p.root.getStr("CFBundleIdentifier").?);
    try std.testing.expect(p.root.path(&.{ "Ent", "get-task-allow" }).?.boolean().?);
    try std.testing.expectEqual(@as(usize, 2), p.root.get("Devs").?.len());
    try std.testing.expectEqualStrings("b", p.root.get("Devs").?.at(1).?.str().?);
    try std.testing.expectEqual(@as(i64, 42), p.root.get("N").?.int().?);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const es = try p.root.entries(arena.allocator());
    try std.testing.expectEqual(@as(usize, 4), es.len);
}

test "embedded xml" {
    const blob = "\x30\x82junk<?xml version=\"1.0\"?><plist><dict/></plist>\x00trailer";
    try std.testing.expectEqualStrings("<?xml version=\"1.0\"?><plist><dict/></plist>", embeddedXml(blob).?);
}
