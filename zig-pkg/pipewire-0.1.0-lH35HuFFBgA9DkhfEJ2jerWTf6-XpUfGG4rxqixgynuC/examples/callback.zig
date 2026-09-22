// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Plays a chord using the pull API: PipeWire calls back once per graph cycle
//! and the callback fills the buffers in place, with no intermediate copy.
//!
//!     zig build run-callback -- [seconds]

const std = @import("std");
const pw = @import("pipewire");

/// Three sine oscillators making an A major triad, advanced by the callback.
const Chord = struct {
    phase: [3]f32 = @splat(0),
    step: [3]f32 = @splat(0),

    const frequencies = [3]f32{ 440.0, 554.37, 659.25 };

    fn tune(c: *Chord, rate: u32) void {
        for (&c.step, frequencies) |*s, f| {
            s.* = 2.0 * std.math.pi * f / @as(f32, @floatFromInt(rate));
        }
    }

    /// Runs on the real-time thread once per cycle: no allocation, no locks.
    fn process(ctx: *anyopaque, planes: []const []f32, frames: u32) void {
        const c: *Chord = @ptrCast(@alignCast(ctx));
        for (0..frames) |i| {
            var sample: f32 = 0;
            for (&c.phase, c.step) |*phase, step| {
                sample += @sin(phase.*) / 6.0;
                phase.* += step;
                if (phase.* > 2.0 * std.math.pi) phase.* -= 2.0 * std.math.pi;
            }
            for (planes) |plane| plane[i] = sample;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const seconds = std.fmt.parseFloat(f32, args.next() orelse "3") catch 3.0;

    var chord: Chord = .{};
    // The rate is not known until the graph says so, so start from the rate we
    // ask for and retune once it is settled.
    chord.tune(48000);

    const stream = try pw.Stream.open(init.gpa, .{
        .name = "zig-pipewire chord",
        .channels = 2,
        .rate = 48000,
        .environ = init.minimal.environ,
        .process = .{ .ctx = @ptrCast(&chord), .func = Chord.process },
    });
    defer stream.close();

    if (!stream.waitStreaming(5000)) return error.NotStreaming;
    if (stream.rate() != 48000) chord.tune(stream.rate());

    std.debug.print("playing a chord for {d} s at {d} Hz\n", .{ seconds, stream.rate() });
    pw.sleep(@intFromFloat(seconds * std.time.ns_per_s));
}
