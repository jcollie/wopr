// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Measure what this library costs.
//!
//! There are two halves to that, and only one of them is a microbenchmark.
//!
//! **The cycle.** An audio graph has a deadline: PipeWire wakes this node once
//! per quantum and everything downstream is waiting on it, so what matters is
//! not throughput but whether a cycle finishes in time, every time. The `live`
//! mode plays a tone and reports what the cycles actually cost, from the two
//! timestamps the node writes into the activation record it shares with the
//! daemon — the same two `pw-top` reads, so the numbers can be checked against
//! it. The figure to look at is the worst cycle as a fraction of the period;
//! the mean says almost nothing, because one late cycle is a dropout.
//!
//! **The hot paths.** The `micro` mode times the routines a cycle is made of
//! with no daemon involved: the ring the producer writes into, the
//! de-interleave that fills the graph's planar buffers, the channel routing,
//! and the POD encoding that every message goes through. These say where the
//! cycle's time goes and catch a regression that the live numbers would hide
//! inside a quantum's worth of headroom.
//!
//! ```console
//! $ zig build bench                      # both, at the default sizes
//! $ zig build bench -- micro
//! $ zig build bench -- live --seconds 30 --channels 6
//! ```
//!
//! Build it optimised or the numbers mean nothing; `zig build bench` does.

const std = @import("std");
const pw = @import("pipewire");

const ns_per_s = std.time.ns_per_s;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var args: std.process.Args.Iterator = .init(init.minimal.args);
    _ = args.skip();

    var run_micro = true;
    var run_live = true;
    var seconds: u32 = 10;
    var channels: u32 = 2;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "micro")) {
            run_live = false;
        } else if (std.mem.eql(u8, arg, "live")) {
            run_micro = false;
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            seconds = std.fmt.parseInt(u32, args.next() orelse "10", 10) catch 10;
        } else if (std.mem.eql(u8, arg, "--channels")) {
            channels = std.fmt.parseInt(u32, args.next() orelse "2", 10) catch 2;
        } else {
            std.debug.print(
                \\usage: bench [micro | live] [--seconds N] [--channels N]
                \\
            , .{});
            std.process.exit(2);
        }
    }

    if (@import("builtin").mode == .Debug) {
        std.debug.print("warning: this is a Debug build; the numbers are meaningless\n\n", .{});
    }

    if (run_micro) try micro(gpa);
    if (run_live) try live(gpa, init.minimal.environ, seconds, channels);
}

// --- the hot paths ----------------------------------------------------------

/// One measurement: the fastest of several runs.
///
/// The minimum rather than the mean, because everything that makes a run slower
/// than its neighbours — a scheduling slice lost, an interrupt, a migration to a
/// cold core — is noise added to the thing being measured, and none of it
/// subtracts. The fastest run is the one least contaminated.
const Result = struct {
    name: []const u8,
    /// Nanoseconds for the whole batch.
    ns: u64,
    /// What the batch did, for the per-unit figure.
    units: u64,
    unit: []const u8,

    fn perUnit(r: Result) f64 {
        return @as(f64, @floatFromInt(r.ns)) / @as(f64, @floatFromInt(r.units));
    }
};

fn report(r: Result) void {
    std.debug.print("  {s:<34} {d:>9.2} ns/{s}\n", .{ r.name, r.perUnit(), r.unit });
}

/// Run `f` several times and keep the fastest.
fn best(
    name: []const u8,
    units: u64,
    unit: []const u8,
    context: anytype,
    comptime f: fn (@TypeOf(context)) anyerror!void,
) !Result {
    var fastest: u64 = std.math.maxInt(u64);
    for (0..rounds) |_| {
        const start = pw.sys.nowNsec();
        try f(context);
        const took = pw.sys.nowNsec() - start;
        if (took < fastest) fastest = took;
    }
    return .{ .name = name, .ns = fastest, .units = units, .unit = unit };
}

/// The quantum these are sized around: PipeWire's usual default, and what this
/// machine's graph was running at when the live numbers below were taken.
const quantum = 1024;
/// Quanta per timed batch. Sixteen of them is the ring's own default capacity,
/// so the measurement walks the same amount of memory a real stream does rather
/// than one that happens to sit in cache.
const batch = 16;
const rounds = 9;

fn micro(gpa: std.mem.Allocator) !void {
    std.debug.print(
        "hot paths, best of {d} batches of {d} frames\n\n",
        .{ rounds, batch * quantum },
    );
    for ([_]u32{ 1, 2, 6 }) |channels| try microRing(gpa, channels);
    try microPod(gpa);
    std.debug.print("\n", .{});
}

/// Time the two sides of the ring separately.
///
/// They are separate because only one of them has a deadline: the write happens
/// on whatever thread the application calls from, and the read happens inside
/// the graph cycle, where being late is a dropout. Draining between the timed
/// batches is deliberately left out of the timing, since a ring that is full
/// returns from `write` without doing anything and would flatter the result.
fn microRing(gpa: std.mem.Allocator, channels: u32) !void {
    var ring = try pw.ring.Ring.init(gpa, channels, quantum * (batch + 1));
    defer ring.deinit(gpa);

    const interleaved = try gpa.alloc(f32, quantum * channels);
    defer gpa.free(interleaved);
    @memset(interleaved, 0.5);

    const planar = try gpa.alloc(f32, quantum * channels);
    defer gpa.free(planar);
    var plane_storage: [8][]f32 = undefined;
    for (0..channels) |c| plane_storage[c] = planar[c * quantum ..][0..quantum];
    const planes = plane_storage[0..channels];

    var write_best: u64 = std.math.maxInt(u64);
    var read_best: u64 = std.math.maxInt(u64);

    for (0..rounds) |_| {
        while (ring.filled() > 0) _ = ring.readPlanar(planes, quantum);

        const w0 = pw.sys.nowNsec();
        for (0..batch) |_| _ = ring.write(interleaved);
        const w1 = pw.sys.nowNsec();

        const r0 = pw.sys.nowNsec();
        for (0..batch) |_| _ = ring.readPlanar(planes, quantum);
        const r1 = pw.sys.nowNsec();

        write_best = @min(write_best, w1 - w0);
        read_best = @min(read_best, r1 - r0);
    }

    const frames = batch * quantum;
    var name: [64]u8 = undefined;
    report(.{
        .name = try std.fmt.bufPrint(&name, "ring write, {d} ch", .{channels}),
        .ns = write_best,
        .units = frames,
        .unit = "frame",
    });
    var name2: [64]u8 = undefined;
    report(.{
        .name = try std.fmt.bufPrint(&name2, "ring read + de-interleave, {d} ch", .{channels}),
        .ns = read_best,
        .units = frames,
        .unit = "frame",
    });
}

/// Encoding and decoding a parameter.
///
/// Off the audio path — messages are built and parsed on the protocol thread,
/// which has no deadline — so these are here as a regression guard rather than
/// because a cycle waits on them.
fn microPod(gpa: std.mem.Allocator) !void {
    const iterations = 4096;
    var builder: pw.pod.Builder = .init(gpa);
    defer builder.deinit();

    const Ctx = struct { b: *pw.pod.Builder };
    const ctx: Ctx = .{ .b = &builder };

    report(try best("build a Format object", iterations, "object", ctx, struct {
        fn run(c: Ctx) anyerror!void {
            for (0..iterations) |_| {
                c.b.clear();
                const f = try c.b.pushObject(pw.spa.object_type.format, 3);
                try c.b.objectPropId(pw.spa.format.media_type, pw.spa.media_type.audio);
                try c.b.objectPropId(pw.spa.format.media_subtype, pw.spa.media_subtype.raw);
                try c.b.objectPropId(pw.spa.format.audio_format, pw.spa.audio_format.f32p);
                try c.b.objectPropInt(pw.spa.format.audio_rate, 48000);
                try c.b.objectPropInt(pw.spa.format.audio_channels, 2);
                try c.b.prop(pw.spa.format.audio_position, 0);
                const arr = try c.b.pushArray(4, .id);
                for ([_]u32{ 3, 4 }) |v| try c.b.addRaw(std.mem.asBytes(&v));
                try c.b.pop(arr);
                try c.b.pop(f);
            }
        }
    }.run));

    // Parse the object that was just built, walking every property.
    const encoded = try gpa.dupe(u8, builder.bytes());
    defer gpa.free(encoded);

    const PCtx = struct { bytes: []const u8 };
    report(try best("parse a Format object", iterations, "object", PCtx{ .bytes = encoded }, struct {
        fn run(c: PCtx) anyerror!void {
            for (0..iterations) |_| {
                var p: pw.pod.Parser = .init(c.bytes);
                const item = (try p.next()) orelse return error.NothingParsed;
                var obj = try item.objectBody();
                while (try obj.next()) |prop| std.mem.doNotOptimizeAway(prop.key);
            }
        }
    }.run));
}

// --- the cycle --------------------------------------------------------------

fn live(gpa: std.mem.Allocator, environ: std.process.Environ, seconds: u32, channels: u32) !void {
    const stream = pw.Stream.open(gpa, .{
        .name = "zig-pipewire bench",
        .channels = channels,
        .rate = 48000,
        .environ = environ,
    }) catch |err| {
        std.debug.print("could not connect to PipeWire: {t}\n", .{err});
        return;
    };
    defer stream.close();

    if (!stream.waitStreaming(5000)) {
        std.debug.print("stream did not start (state: {t})\n", .{stream.getState()});
        return;
    }

    const rate = stream.rate();
    const chunk_frames = 512;
    const chunk = try gpa.alloc(f32, chunk_frames * channels);
    defer gpa.free(chunk);

    var phase: f32 = 0;
    const step = 2.0 * std.math.pi * 440.0 / @as(f32, @floatFromInt(rate));

    // Fill the ring, then start the clock: the cycles spent linking up are not
    // what is being measured.
    while (stream.writable() >= chunk_frames) {
        fillChunk(chunk, channels, &phase, step);
        _ = stream.write(chunk);
    }
    stream.resetStats();

    std.debug.print("cycle, {d} s at {d} Hz, quantum {d}, {d} ch in / {d} ch out\n\n", .{
        seconds,
        rate,
        stream.quantum(),
        channels,
        stream.graphChannels(),
    });

    const deadline = pw.sys.nowNsec() + @as(u64, seconds) * ns_per_s;
    while (pw.sys.nowNsec() < deadline) {
        fillChunk(chunk, channels, &phase, step);
        try stream.writeAll(chunk);
    }

    const s = stream.stats();
    const period = @as(f64, @floatFromInt(s.period_ns));
    std.debug.print("  cycles                             {d:>12}\n", .{s.cycles});
    std.debug.print("  period                             {d:>12.1} us\n", .{period / 1000});
    printSummary("wake  (pw-top WAIT)", s.wake, s.period_ns);
    printSummary("process (pw-top BUSY)", s.process, s.period_ns);
    std.debug.print("  missed cycles                      {d:>12}\n", .{s.missed_cycles});
    std.debug.print("  underrun frames                    {d:>12}\n", .{s.underrun_frames});
    std.debug.print("\n", .{});
}

fn printSummary(name: []const u8, sm: pw.Summary, period_ns: u64) void {
    std.debug.print(
        "  {s:<34} {d:>7.1} / {d:>7.1} / {d:>7.1} us  min/mean/max, worst {d:.2}% of period\n",
        .{
            name,
            @as(f64, @floatFromInt(sm.min_ns)) / 1000,
            @as(f64, @floatFromInt(sm.mean_ns)) / 1000,
            @as(f64, @floatFromInt(sm.max_ns)) / 1000,
            sm.fractionOfPeriod(period_ns) * 100,
        },
    );
}

fn fillChunk(chunk: []f32, channels: u32, phase: *f32, step: f32) void {
    const frames = chunk.len / channels;
    for (0..frames) |i| {
        const sample = 0.2 * @sin(phase.*);
        for (0..channels) |c| chunk[i * channels + c] = sample;
        phase.* += step;
        if (phase.* > 2.0 * std.math.pi) phase.* -= 2.0 * std.math.pi;
    }
}
