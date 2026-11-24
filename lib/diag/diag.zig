//! Human-readable error detail that travels next to a Zig error.
//!
//! Zig errors are bare tags; every fallible library call also takes an
//! optional `*Diag` and writes a sentence into it, so front ends can show
//! "lockdown: pairing record missing for <udid>" instead of `error.Lockdown`.
const std = @import("std");

pub const Diag = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch blk: {
            const tail = "...";
            @memcpy(self.buf[self.buf.len - tail.len ..], tail);
            break :blk self.buf[0..];
        };
        self.len = s.len;
    }

    pub fn message(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Record a message (if a Diag was supplied) and return `err`.
pub fn fail(d: ?*Diag, err: anyerror, comptime fmt: []const u8, args: anytype) anyerror {
    if (d) |dd| dd.set(fmt, args);
    return err;
}

/// Message for `err`, preferring the Diag text when one was recorded.
pub fn describe(d: *const Diag, err: anyerror) []const u8 {
    return if (d.len > 0) d.message() else @errorName(err);
}

test "set and truncate" {
    var d: Diag = .{};
    d.set("hello {s}", .{"world"});
    try std.testing.expectEqualStrings("hello world", d.message());
    const long: [2000]u8 = @splat('x');
    d.set("{s}", .{&long});
    try std.testing.expect(std.mem.endsWith(u8, d.message(), "..."));
}
