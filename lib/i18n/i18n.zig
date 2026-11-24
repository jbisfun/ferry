//! Translations. Catalogs are GNU gettext: translators edit `po/<lang>.po`
//! with any PO editor, `msgfmt --check` compiles them at build time, and the
//! resulting .mo files are embedded in the binaries. Lookup reads the .mo
//! directly, so translations work even when the matching system locale is
//! not generated (glibc's gettext() silently falls back to English then).
//!
//! Language: $FERRY_LANG, else the first usable entry of $LANGUAGE, $LC_ALL,
//! $LC_MESSAGES, $LANG. zh_TW, zh_HK, zh_MO and zh_Hant all select zh_TW.
//!
//! Messages with arguments use numbered placeholders, "{0}", "{1}", so a
//! translation may reorder them.
const std = @import("std");

pub const Language = enum {
    en,
    zh_TW,

    pub fn displayName(self: Language) []const u8 {
        return switch (self) {
            .en => "English",
            .zh_TW => "繁體中文",
        };
    }

    pub fn code(self: Language) []const u8 {
        return @tagName(self);
    }
};

const mo_zh_TW = @embedFile("mo_zh_TW");

/// Read-only view of a GNU .mo file.
pub const Catalog = struct {
    data: []const u8,
    count: u32,
    orig_off: u32,
    trans_off: u32,
    big_endian: bool,

    pub fn init(data: []const u8) !Catalog {
        if (data.len < 28) return error.BadCatalog;
        const magic = std.mem.readInt(u32, data[0..4], .little);
        const be = switch (magic) {
            0x950412de => false,
            0xde120495 => true,
            else => return error.BadCatalog,
        };
        var c: Catalog = .{ .data = data, .count = 0, .orig_off = 0, .trans_off = 0, .big_endian = be };
        c.count = c.word(8);
        c.orig_off = c.word(12);
        c.trans_off = c.word(16);
        if (@as(u64, c.orig_off) + @as(u64, c.count) * 8 > data.len or @as(u64, c.trans_off) + @as(u64, c.count) * 8 > data.len) return error.BadCatalog;
        return c;
    }

    fn word(self: Catalog, off: usize) u32 {
        return std.mem.readInt(u32, self.data[off..][0..4], if (self.big_endian) .big else .little);
    }

    fn string(self: Catalog, table: u32, i: u32) []const u8 {
        const len = self.word(table + i * 8);
        const off = self.word(table + i * 8 + 4);
        if (@as(u64, off) + len > self.data.len) return "";
        return self.data[off..][0..len];
    }

    /// msgfmt writes originals sorted by bytes, so binary search works.
    pub fn lookup(self: Catalog, msgid: []const u8) ?[]const u8 {
        var lo: u32 = 0;
        var hi: u32 = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.string(self.orig_off, mid), msgid)) {
                .eq => {
                    const t = self.string(self.trans_off, mid);
                    return if (t.len == 0) null else t;
                },
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }
};

var current: Language = .en;
var catalog: ?Catalog = null;

pub fn set(lang: Language) void {
    current = lang;
    catalog = switch (lang) {
        .en => null,
        .zh_TW => Catalog.init(mo_zh_TW) catch null,
    };
}

pub fn language() Language {
    return current;
}

/// Map a POSIX locale name ("zh_TW.UTF-8", "zh-Hant", "en_US") to a language.
pub fn parse(name: []const u8) ?Language {
    if (name.len == 0) return null;
    const base = name[0 .. std.mem.indexOfAny(u8, name, ".@") orelse name.len];
    if (std.ascii.eqlIgnoreCase(base, "C") or std.ascii.eqlIgnoreCase(base, "POSIX")) return .en;
    if (std.ascii.startsWithIgnoreCase(base, "en")) return .en;
    if (std.ascii.startsWithIgnoreCase(base, "zh")) {
        const rest = base[2..];
        inline for (.{ "_TW", "-TW", "_HK", "-HK", "_MO", "-MO", "_Hant", "-Hant" }) |s| {
            if (std.ascii.startsWithIgnoreCase(rest, s)) return .zh_TW;
        }
    }
    return null;
}

/// Pick the language from the environment (see module docs).
pub fn initFromEnv() void {
    set(detect(libcGetenv));
}

fn libcGetenv(name: [:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name.ptr)) |v| std.mem.span(v) else null;
}

fn detect(getenv: *const fn ([:0]const u8) ?[]const u8) Language {
    if (getenv("FERRY_LANG")) |v| if (parse(v)) |l| return l;
    if (getenv("LANGUAGE")) |v| {
        var it = std.mem.tokenizeScalar(u8, v, ':');
        while (it.next()) |part| if (parse(part)) |l| return l;
    }
    inline for (.{ "LC_ALL", "LC_MESSAGES", "LANG" }) |k| {
        if (getenv(k)) |v| if (v.len > 0) return parse(v) orelse .en;
    }
    return .en;
}

/// Translate `msgid` (falls back to msgid itself).
pub fn tr(msgid: []const u8) []const u8 {
    if (catalog) |c| if (c.lookup(msgid)) |t| return t;
    return msgid;
}

/// Mark a string for extraction without translating it here (translate the
/// value later with `tr`), e.g. step names stored in data.
pub fn N_(msgid: []const u8) []const u8 {
    return msgid;
}

/// Translate, then substitute {0}..{9} with `args`.
pub fn trf(alloc: std.mem.Allocator, msgid: []const u8, args: []const []const u8) ![]u8 {
    return substitute(alloc, tr(msgid), args);
}

/// Same as `trf` but into a caller buffer; truncates on overflow.
pub fn trfBuf(buf: []u8, msgid: []const u8, args: []const []const u8) []const u8 {
    var fba = std.heap.FixedBufferAllocator.init(buf);
    return substitute(fba.allocator(), tr(msgid), args) catch buf[0..0];
}

pub fn substitute(alloc: std.mem.Allocator, pattern: []const u8, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] == '{' and i + 2 < pattern.len and std.ascii.isDigit(pattern[i + 1]) and pattern[i + 2] == '}') {
            const n = pattern[i + 1] - '0';
            if (n < args.len) try out.appendSlice(alloc, args[n]);
            i += 3;
        } else {
            try out.append(alloc, pattern[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

test "zh_TW catalog loads and translates" {
    set(.zh_TW);
    defer set(.en);
    try std.testing.expect(catalog != null);
    try std.testing.expectEqualStrings("裝置", tr("Devices"));
    try std.testing.expectEqualStrings("no such msgid", tr("no such msgid"));
}

test "placeholders reorder" {
    const a = std.testing.allocator;
    const s = try substitute(a, "{1} <- {0} {9}", &.{ "x", "y" });
    defer a.free(s);
    try std.testing.expectEqualStrings("y <- x ", s);
}

test "locale parsing" {
    try std.testing.expectEqual(Language.zh_TW, parse("zh_TW.UTF-8").?);
    try std.testing.expectEqual(Language.zh_TW, parse("zh-Hant").?);
    try std.testing.expectEqual(Language.zh_TW, parse("zh_HK").?);
    try std.testing.expectEqual(Language.en, parse("en_US.UTF-8").?);
    try std.testing.expectEqual(@as(?Language, null), parse("zh_CN.UTF-8"));
    try std.testing.expectEqual(@as(?Language, null), parse("fr_FR"));
}

test "every catalog entry is valid UTF-8" {
    const c = try Catalog.init(mo_zh_TW);
    var i: u32 = 0;
    while (i < c.count) : (i += 1) try std.testing.expect(std.unicode.utf8ValidateSlice(c.string(c.trans_off, i)));
}
