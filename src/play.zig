// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Playing the hum into PipeWire, without a player in between.
//!
//! `wopr | pw-play -` works and always did, but it makes the hum a file that
//! something else happens to be reading: it appears in `wpctl status` as
//! `pw-play`, its volume belongs to `pw-play`, and the WAVE header has to
//! claim a length it does not have. Opening the graph directly makes it a
//! node of its own called `wopr`, which a mixer can see, move to another
//! sink and turn down like anything else.
//!
//! This is the push half of `zig-pipewire`'s playback API: frames go into a
//! lock-free ring and the daemon's real-time thread drains it. The pull half
//! would suit an endless generator just as well — `Hum.render` allocates
//! nothing and cannot fail, so it is safe on that thread — but push is what
//! the file path already does, and it means one loop rather than two.
//!
//! Nothing here paces anything: `writeAll` sleeps when the ring is full, so
//! the graph's own clock sets the rate, exactly as the pipe's backpressure
//! used to.
//!
//! Linux only. `play_unsupported.zig` stands in for this everywhere else and
//! `build.zig` chooses between them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const pw = @import("pipewire");
const wopr = @import("wopr");

/// True when this is the real thing rather than the stand-in.
pub const supported = true;

pub const Options = struct {
    /// What a mixer shows this as.
    name: []const u8 = "wopr",
    /// A sink name or id to play to instead of the default.
    target: ?[]const u8 = null,
    /// Where the socket is found, the way every other PipeWire client finds
    /// it. Zig 0.16 hands this to `main`.
    environ: ?std.process.Environ = null,
};

/// Everything a `Player` can fail with: reaching the daemon and negotiating
/// with it, and building the synthesiser once it has answered.
pub const Error = pw.StreamError || wopr.Hum.InitError || error{
    /// The daemon answered but the graph never started the stream.
    NotStreaming,
};

pub const Player = struct {
    gpa: Allocator,
    stream: *pw.Stream,
    hum: wopr.Hum,

    /// Connect to the graph and build a synthesiser to match it.
    ///
    /// The order matters. PipeWire may run at a rate other than the one
    /// asked for -- the graph has one rate and everything in it lives with
    /// it -- so the stream is opened first and the `Hum` built afterwards at
    /// whatever `rate()` reports. Building it first and resampling would put
    /// a resampler in the way of a synthesiser that can simply be asked for
    /// the other rate.
    pub fn open(gpa: Allocator, hum_options: wopr.Hum.Options, options: Options) Error!Player {
        const stream = try pw.Stream.open(gpa, .{
            .name = options.name,
            .media_name = "machine room hum",
            .channels = hum_options.channels,
            .rate = hum_options.sample_rate,
            .target = options.target,
            .environ = options.environ,
        });
        errdefer stream.close();

        if (!stream.waitStreaming(5000)) return error.NotStreaming;

        var tuned = hum_options;
        tuned.sample_rate = stream.rate();
        const hum: wopr.Hum = try .init(gpa, tuned);

        return .{ .gpa = gpa, .stream = stream, .hum = hum };
    }

    pub fn close(p: *Player) void {
        // The last frames handed over are still in the ring and then still
        // in a graph cycle, so the tail is played out rather than cut off.
        p.stream.drain(2000);
        p.hum.deinit(p.gpa);
        p.stream.close();
        p.* = undefined;
    }

    /// The rate the graph settled on, which may not be the one asked for.
    pub fn rate(p: *Player) u32 {
        return p.stream.rate();
    }

    /// How many channels the graph gave the node. The stream maps what is
    /// written onto these, so a stereo hum plays through a mono sink.
    pub fn graphChannels(p: *Player) u32 {
        return p.stream.graphChannels();
    }

    /// Render until `seconds` have played, or forever when it is `null`.
    pub fn run(p: *Player, seconds: ?f64) pw.StreamError!void {
        const channels = p.hum.channels;
        // 4096 frames is about 85 ms at 48 kHz: long enough that the
        // per-block work disappears and short enough that `--duration` lands
        // within a block of where it was asked for.
        var block: [4096 * 2]f32 = undefined;

        const total: ?u64 = if (seconds) |s|
            @intFromFloat(@round(s * @as(f64, @floatFromInt(p.rate()))))
        else
            null;

        var rendered: u64 = 0;
        while (true) {
            var frames: usize = block.len / channels;
            if (total) |limit| {
                if (rendered >= limit) break;
                frames = @intCast(@min(frames, limit - rendered));
            }
            const samples = block[0 .. frames * channels];
            p.hum.render(samples);
            try p.stream.writeAll(samples);
            rendered += frames;
        }
    }
};
