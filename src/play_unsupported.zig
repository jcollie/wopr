// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What `play.zig` becomes off Linux.
//!
//! `zig-pipewire` speaks the daemon's wire protocol over a Unix socket using
//! Linux syscalls directly, so there is nothing to port and nothing to fall
//! back to: PipeWire is a Linux daemon. `build.zig` swaps this in for the
//! real module, so `wopr` still builds and everything except `--play` still
//! works — the WAVE stream on stdout is what it was, and piping that into
//! whatever the platform does have is the answer there.
//!
//! It exists rather than the whole thing being `@compileError` so that the
//! failure is a message at runtime from a binary that built, rather than a
//! build that did not.

const std = @import("std");
const Allocator = std.mem.Allocator;

const wopr = @import("wopr");

/// False, which is what `main` checks before offering to play anything.
pub const supported = false;

pub const Options = struct {
    name: []const u8 = "wopr",
    target: ?[]const u8 = null,
    environ: ?std.process.Environ = null,
};

pub const Error = error{
    NotStreaming,
    /// This build has no way to reach an audio device.
    PlaybackUnsupported,
} || wopr.Hum.InitError;

pub const Player = struct {
    pub fn open(_: Allocator, _: wopr.Hum.Options, _: Options) !Player {
        return error.PlaybackUnsupported;
    }

    pub fn close(_: *Player) void {}

    pub fn rate(_: *Player) u32 {
        return 0;
    }

    pub fn graphChannels(_: *Player) u32 {
        return 0;
    }

    pub fn run(_: *Player, _: ?f64) !void {
        return error.PlaybackUnsupported;
    }
};
