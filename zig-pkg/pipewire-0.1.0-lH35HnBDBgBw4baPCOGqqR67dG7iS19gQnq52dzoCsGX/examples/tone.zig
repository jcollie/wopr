// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Plays a test tone using the push API: audio is written into the stream's
//! internal ring from the main thread and drained by the real-time thread.
//!
//!     zig build run-tone -- [seconds] [hz] [channels]

const std = @import("std");
const pw = @import("pipewire");

fn logLine(_: *anyopaque, level: pw.LogLevel, msg: []const u8) void {
    std.debug.print("[pipewire {t}] {s}\n", .{ level, msg });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.next(); // program name
    const seconds = parseFloat(args.next(), 3.0);
    const tone_hz = parseFloat(args.next(), 440.0);
    const channels = parseInt(args.next(), 2);

    var log_ctx: u8 = 0;
    const stream = try pw.Stream.open(gpa, .{
        .name = "zig-pipewire tone",
        .media_name = "Test tone",
        .channels = channels,
        .rate = 48000,
        .environ = init.minimal.environ,
        .log = .{ .ctx = @ptrCast(&log_ctx), .func = logLine },
    });
    defer stream.close();

    // The tone is generated at the rate we asked for; the graph is free to run
    // at another, in which case the pitch shifts by that ratio.
    const nominal_rate: f32 = 48000;
    const total: u64 = @intFromFloat(seconds * nominal_rate);
    const chunk_frames = 512;
    const chunk = try gpa.alloc(f32, chunk_frames * channels);
    defer gpa.free(chunk);

    var tone: Tone = .{
        .step = 2.0 * std.math.pi * tone_hz / nominal_rate,
        .fade_frames = @intFromFloat(nominal_rate / 20),
        .total = total,
    };

    // The graph starts pulling the moment it links, so fill the ring first:
    // whatever is queued by then is heard without a gap at the start.
    var written: u64 = 0;
    while (written < total and stream.writable() >= chunk_frames) {
        written = tone.fill(chunk, channels, written, stream, .nonblocking);
    }

    if (!stream.waitStreaming(5000)) {
        std.debug.print("stream did not start (state: {t})\n", .{stream.getState()});
        return error.NotStreaming;
    }

    std.debug.print("playing {d} Hz for {d} s: {d} ch in, {d} ch out at {d} Hz, quantum {d}\n", .{
        tone_hz,
        seconds,
        channels,
        stream.graphChannels(),
        stream.rate(),
        stream.quantum(),
    });

    while (written < total) {
        written = tone.fill(chunk, channels, written, stream, .blocking);
    }

    stream.drain(2000);
    // A quantum or so of this is the silence after the tone ends, not a fault.
    std.debug.print("done; {d} underrun frames\n", .{stream.underruns()});
}

fn parseFloat(arg: ?[:0]const u8, default: f32) f32 {
    return std.fmt.parseFloat(f32, arg orelse return default) catch default;
}

fn parseInt(arg: ?[:0]const u8, default: u32) u32 {
    return std.fmt.parseInt(u32, arg orelse return default, 10) catch default;
}

/// A fading sine, generated a chunk at a time.
const Tone = struct {
    phase: f32 = 0,
    step: f32,
    fade_frames: u64,
    total: u64,

    const Mode = enum { blocking, nonblocking };

    /// Generate from frame `written` onward and hand it to the stream. Returns
    /// the new total; in nonblocking mode that may be short of a full chunk.
    fn fill(
        t: *Tone,
        chunk: []f32,
        channels: u32,
        written: u64,
        stream: *pw.Stream,
        mode: Mode,
    ) u64 {
        const room: usize = switch (mode) {
            .blocking => chunk.len / channels,
            .nonblocking => @min(chunk.len / channels, stream.writable()),
        };
        const n: usize = @intCast(@min(@as(u64, room), t.total - written));
        if (n == 0) return written;

        for (0..n) |i| {
            // Fade in and out so the tone starts and stops without a click.
            const from_start = written + i;
            const to_end = t.total - from_start;
            const fade = @as(f32, @floatFromInt(@min(@min(from_start, to_end), t.fade_frames))) /
                @as(f32, @floatFromInt(t.fade_frames));
            const sample = 0.25 * fade * @sin(t.phase);
            for (0..channels) |c| chunk[i * channels + c] = sample;
            t.phase += t.step;
            if (t.phase > 2.0 * std.math.pi) t.phase -= 2.0 * std.math.pi;
        }

        const samples = chunk[0 .. n * channels];
        switch (mode) {
            .blocking => stream.writeAll(samples) catch return t.total,
            .nonblocking => _ = stream.write(samples),
        }
        return written + n;
    }
};
