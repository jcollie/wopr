// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The optional diagnostics callback, shared by everything in this library that
//! has something to report.

const std = @import("std");

/// Optional diagnostics. Called from whichever thread hit the event, so it must
/// be safe to call concurrently.
pub const Log = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, level: Level, msg: []const u8) void,

    pub const Level = enum { err, warn, info, debug };

    /// Format a line and hand it over. The message is built on the stack and
    /// truncated rather than allocated, because some of the callers are holding
    /// a lock or are on the real-time thread.
    pub fn printf(l: ?Log, level: Level, comptime fmt: []const u8, args: anytype) void {
        const sink = l orelse return;
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "log message too long";
        sink.func(sink.ctx, level, msg);
    }
};
