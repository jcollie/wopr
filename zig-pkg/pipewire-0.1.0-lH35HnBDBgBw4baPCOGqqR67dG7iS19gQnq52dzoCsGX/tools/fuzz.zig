// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Run the fuzz targets in `tests/fuzz.zig` against input this makes up.
//!
//! Zig has a fuzzer of its own and `tests/fuzz.zig` is written for it, so the
//! obvious thing to run is `zig build fuzz --fuzz`. On the pinned toolchain
//! that only compiles with a patched standard library: Zig 0.16.0's own
//! `compiler/test_runner.zig` passes a `*builtin.StackTrace` to
//! `std.debug.writeStackTrace`, which wants a `*const debug.StackTrace`, and it
//! is on the path taken only when a test executable is built in fuzz mode — so
//! no project with a fuzz test can build one. This flake's devshell patches
//! that line; this loop is what runs without it.
//!
//! Even with the patch, the release populates no table of program counters, so
//! Zig's fuzzer runs without the coverage feedback that is most of its value.
//! That makes this loop worth having on its own terms rather than only as a
//! fallback: what it lacks in feedback it makes up for with the corpus, so the
//! inputs arrive looking like protocol rather than like noise.
//!
//! ```console
//! $ zig build fuzz-run                             # a minute of each target
//! $ zig build fuzz-run -- --seconds 300 --target pod
//! $ zig build fuzz-run -- --seed 12345             # run it again exactly
//! $ zig build fuzz-run -- --input fuzz-findings/pod-….bin
//! ```
//!
//! An input is a byte string that `std.testing.Smith` reads as a stream of
//! decisions, so a failure is reported as those bytes, in hex, and written to a
//! file. Feeding it back is what `--input` is for, and a shape worth keeping
//! belongs in `tests/fuzz.zig`'s corpus where `zig build test` will run it every
//! time.
//!
//! # The watchdog
//!
//! A length taken out of the input can be made to describe a great deal of
//! work, and a fuzzer that has found one just stops with nothing to show. So a
//! thread watches the clock: an iteration that outlasts `--timeout` seconds is
//! a hang, and the input that caused it is printed and saved before the process
//! gives up. There is no way to unwind out of it, so this ends the run rather
//! than continuing past it.

const std = @import("std");
const targets = @import("fuzz_targets");

const Smith = std.testing.Smith;

/// Milliseconds on a clock that only goes forwards while the machine is up.
fn nowMs(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

/// What the watchdog needs to see, written before each iteration begins.
const Watch = struct {
    /// When the running iteration started, in milliseconds, or zero between
    /// iterations.
    started_ms: std.atomic.Value(i64) = .init(0),
    /// The input it is running, which is what a hang has to report.
    input: []const u8 = &.{},
    target: []const u8 = "",
    /// How long an iteration may take before it is called a hang.
    timeout_s: u32 = 10,
    /// Where a failing input is written.
    dir: []const u8 = "",
};

var watch: Watch = .{};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Two allocators, and they have to be two. The targets are written to run
    // against the testing allocator, which cannot be named outside a test
    // build; this is the same thing by another route, a debug allocator whose
    // outstanding allocations are counted after every input, since a leak is
    // one of the things being fuzzed for. Nothing else may allocate from it —
    // the loop's own buffer would be indistinguishable from a target's leak —
    // so everything here uses the process allocator instead.
    var checked: std.heap.DebugAllocator(.{}) = .init;
    defer _ = checked.deinit();
    targets.backing = checked.allocator();
    const gpa = init.gpa;

    var seconds: u32 = 60;
    var iterations: ?u64 = null;
    var seed: u64 = @bitCast(@as(i64, @truncate(std.Io.Timestamp.now(io, .real).nanoseconds)));
    var only: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    var dir: []const u8 = "fuzz-findings";
    var timeout_s: u32 = 10;

    var args: std.process.Args.Iterator = .init(init.minimal.args);
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--seconds")) {
            seconds = std.fmt.parseInt(u32, args.next() orelse "60", 10) catch 60;
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            iterations = std.fmt.parseInt(u64, args.next() orelse "0", 10) catch null;
        } else if (std.mem.eql(u8, arg, "--seed")) {
            seed = std.fmt.parseInt(u64, args.next() orelse "0", 10) catch seed;
        } else if (std.mem.eql(u8, arg, "--target")) {
            only = args.next();
        } else if (std.mem.eql(u8, arg, "--input")) {
            input_path = args.next();
        } else if (std.mem.eql(u8, arg, "--findings")) {
            dir = args.next() orelse dir;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            timeout_s = std.fmt.parseInt(u32, args.next() orelse "10", 10) catch 10;
        } else {
            std.debug.print(
                \\usage: fuzz [--target NAME] [--seconds N | --iterations N] [--seed S]
                \\            [--timeout S] [--findings DIR] [--input FILE]
                \\
                \\Targets: {s}
                \\
            , .{targetNames()});
            std.process.exit(2);
        }
    }

    watch.timeout_s = timeout_s;
    watch.dir = dir;

    // One input, from a file, and nothing else: this is how a finding is looked
    // at again after it has been fixed.
    if (input_path) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        const name = only orelse targets.all[0].name;
        const target = find(name) orelse {
            std.debug.print("no target called {s}; there are: {s}\n", .{ name, targetNames() });
            std.process.exit(2);
        };
        watch.input = bytes;
        watch.target = target.name;
        watch.started_ms.store(nowMs(io), .release);
        const thread = try std.Thread.spawn(.{}, watchdog, .{io});
        thread.detach();
        target.run(bytes) catch |err| {
            std.debug.print("{s}: {t}\n", .{ target.name, err });
            std.process.exit(1);
        };
        std.debug.print("{s}: that input is fine now\n", .{target.name});
        return;
    }

    const thread = try std.Thread.spawn(.{}, watchdog, .{io});
    thread.detach();

    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);

    std.debug.print("seed {d}\n", .{seed});
    var failures: usize = 0;
    for (targets.all) |target| {
        if (only) |name| if (!std.mem.eql(u8, name, target.name)) continue;

        var runs: u64 = 0;
        const deadline = nowMs(io) + @as(i64, seconds) * 1000;
        while (if (iterations) |n| runs < n else nowMs(io) < deadline) : (runs += 1) {
            try makeInput(gpa, &buffer, random, target);
            watch.input = buffer.items;
            watch.target = target.name;
            watch.started_ms.store(nowMs(io), .release);
            const result = target.run(buffer.items);
            watch.started_ms.store(0, .release);
            if (checked.detectLeaks() != 0) {
                std.debug.print("\n{s}: leaked\n", .{target.name});
                try report(io, dir, target.name, buffer.items);
                std.process.exit(1);
            }
            result catch |err| {
                failures += 1;
                std.debug.print("\n{s}: {t}\n", .{ target.name, err });
                try report(io, dir, target.name, buffer.items);
                // Keep going: one shape of failure is usually many inputs, and
                // stopping at the first says less than a handful does.
                if (failures >= 10) {
                    std.debug.print("ten failures; stopping\n", .{});
                    std.process.exit(1);
                }
            };
        }
        std.debug.print("{s}: {d} runs\n", .{ target.name, runs });
    }
    if (failures != 0) std.process.exit(1);
}

fn find(name: []const u8) ?targets.Target {
    for (targets.all) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

fn targetNames() []const u8 {
    comptime var names: []const u8 = "";
    inline for (targets.all, 0..) |t, i| {
        names = names ++ (if (i == 0) "" else ", ") ++ t.name;
    }
    return names;
}

/// Make the next input: usually a mutation of one of the target's own seeds,
/// sometimes a string of random bytes.
///
/// The bias towards the corpus is the whole of what stands in for coverage
/// feedback. A POD is a length-prefixed tree whose lengths have to agree with
/// each other before anything inside it is reached, and random bytes almost
/// never agree; starting from something that already parses is what gets the
/// fuzzer past the outermost header.
fn makeInput(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    random: std.Random,
    target: targets.Target,
) !void {
    out.clearRetainingCapacity();
    if (target.corpus.len == 0 or random.uintLessThan(u8, 10) == 0) {
        // An invented input, led by decisions the target can use — see
        // `Target.decisions` for why that has to be there and why its length is
        // the target's business rather than a constant.
        try decisions(gpa, out, random, target.decisions);
        const len = random.uintLessThan(usize, 512);
        try out.ensureUnusedCapacity(gpa, len);
        for (0..len) |_| out.appendAssumeCapacity(random.int(u8));
        return;
    }

    // A corpus entry is already a complete input, decisions included.
    try out.appendSlice(gpa, target.corpus[random.uintLessThan(usize, target.corpus.len)]);
    const rounds = 1 + random.uintLessThan(usize, 8);
    for (0..rounds) |_| {
        if (out.items.len == 0) break;
        switch (random.uintLessThan(u8, 12)) {
            // A byte, replaced. The commonest useful mutation.
            0, 1 => out.items[random.uintLessThan(usize, out.items.len)] = random.int(u8),
            // A byte, replaced by one of the values a protocol field holds.
            2, 3 => out.items[random.uintLessThan(usize, out.items.len)] =
                interesting[random.uintLessThan(usize, interesting.len)],
            // A whole little-endian word, replaced. Everything in a POD is
            // four-byte aligned, so a size or a type tag is only reachable as a
            // unit: mutating one byte of a length usually just makes it huge,
            // which the outermost bounds check rejects before anything nested
            // is looked at.
            4, 5 => {
                const words = out.items.len / 4;
                if (words == 0) continue;
                const at = random.uintLessThan(usize, words) * 4;
                const value: u32 = switch (random.uintLessThan(u8, 4)) {
                    0 => random.uintLessThan(u32, 64),
                    1 => random.uintLessThan(u32, 24), // a POD type tag
                    2 => random.int(u32),
                    else => @as(u32, random.uintLessThan(u32, 16)) * 8, // a plausible size
                };
                std.mem.writeInt(u32, out.items[at..][0..4], value, .little);
            },
            // Something inserted, which shifts everything after it out of
            // alignment — a case the parser has to survive too.
            6 => try out.insert(gpa, random.uintLessThan(usize, out.items.len), random.int(u8)),
            // Bytes on the end, which is how an input grows past the seed it
            // came from. On its own this reaches nothing — the length below
            // decides how much of it is looked at — but a decision the seed was
            // too short to answer reads them, and so does a lengthened string.
            7 => for (0..8 + random.uintLessThan(usize, 64)) |_| {
                try out.append(gpa, random.int(u8));
            },
            // One of the leading decisions, changed to another small number.
            8 => {
                const words = @min(target.decisions, out.items.len / 8);
                if (words == 0) continue;
                const at = random.uintLessThan(usize, words) * 8;
                std.mem.writeInt(
                    u64,
                    out.items[at..][0..8],
                    random.uintLessThan(u64, 0x1000000),
                    .little,
                );
            },
            // The length in front of the byte string, moved.
            //
            // This is what makes inserting and appending worth anything for a
            // target that parses bytes. `Smith.slice` copies the *smaller* of
            // the length it reads and what is left of the input, so bytes added
            // past the end of a seed are otherwise never looked at, and bytes
            // taken out leave the length describing memory that is no longer
            // there. A length that overstates what follows is worth trying on
            // its own too, since it is exactly what a hostile sender writes.
            //
            // Every target here reads its decisions and then one byte string,
            // so the length is the word just past them.
            9, 10 => {
                const at = target.decisions * 8;
                if (out.items.len < at + 4) continue;
                const rest = out.items.len - at - 4;
                const len: u32 = switch (random.uintLessThan(u8, 4)) {
                    0 => @intCast(rest),
                    1 => @intCast(rest + random.uintLessThan(usize, 64)),
                    2 => @intCast(rest -| random.uintLessThan(usize, 64)),
                    else => random.int(u32),
                };
                std.mem.writeInt(u32, out.items[at..][0..4], len, .little);
            },
            // And something taken out.
            else => _ = out.orderedRemove(random.uintLessThan(usize, out.items.len)),
        }
    }
}

/// Lead an input with values a `Smith` will actually use.
///
/// This is not a nicety, it is the difference between fuzzing the choices and
/// not fuzzing them at all. `Smith.value` reads **eight bytes as a little
/// endian u64 and returns the minimum of the asked-for range unless that u64 is
/// already inside it** — it does not reduce modulo the range. So a stream of
/// random bytes makes `value(bool)` false every time, every enum its first tag,
/// and every `valueRangeAtMost(u32, 1, 8)` a one. Only `slice` behaves as you
/// would hope: it takes a length and then copies the bytes across.
///
/// So the front of every input is a run of eight-byte words holding small
/// numbers, which is what those questions can answer with. A target that asks
/// its questions before it asks for its bytes gets varied answers; the rest of
/// the input stays random, and the slices get it.
fn decisions(gpa: std.mem.Allocator, out: *std.ArrayList(u8), random: std.Random, count: usize) !void {
    for (0..count) |_| {
        // A mixture, because the ranges are: a bool wants 0 or 1, an enum a
        // tag, a mapping length the whole of a megabyte.
        const value: u64 = switch (random.uintLessThan(u8, 20)) {
            0...7 => random.uintLessThan(u64, 4),
            8...12 => random.uintLessThan(u64, 16),
            13...16 => random.uintLessThan(u64, 0x10000),
            else => random.uintLessThan(u64, 0x1000000),
        };
        var word: [8]u8 = undefined;
        std.mem.writeInt(u64, &word, value, .little);
        try out.appendSlice(gpa, &word);
    }
}

/// The byte values a protocol field is made of: the small integers a size, a
/// count or a type tag holds, the alignment boundaries, and the ends of the
/// range where the arithmetic wraps.
const interesting = blk: {
    var set: []const u8 = &[_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x07, 0x08, 0x0f, 0x10 };
    set = set ++ &[_]u8{ 0x14, 0x18, 0x20, 0x3f, 0x40, 0x7f, 0x80, 0xfe, 0xff };
    break :blk set;
};

/// Print a failing input and write it where it can be fed back.
fn report(io: std.Io, dir: []const u8, target: []const u8, input: []const u8) !void {
    show(input);

    var name: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&name, "{s}/{s}-{x:0>16}.bin", .{
        dir,
        target,
        std.hash.Wyhash.hash(0, input),
    }) catch return;

    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        std.debug.print("(could not write {s}: {t})\n", .{ path, err });
        return;
    };
    defer file.close(io);
    file.writeStreamingAll(io, input) catch {};
    std.debug.print("written to {s}, and `--input {s}` runs it again\n", .{ path, path });
}

/// The input in hex, and the words at the front of it read as decisions, since
/// an input is a decision stream rather than a file and the bytes alone do not
/// say what the target was given.
fn show(input: []const u8) void {
    std.debug.print("input, {d} bytes:\n ", .{input.len});
    for (input, 0..) |b, i| {
        if (i != 0 and i % 32 == 0) std.debug.print("\n ", .{});
        std.debug.print(" {x:0>2}", .{b});
    }
    std.debug.print("\n", .{});

    const words = @min(@as(usize, 16), input.len / 8);
    if (words != 0) {
        std.debug.print("leading decisions:", .{});
        for (0..words) |i| {
            std.debug.print(" {d}", .{std.mem.readInt(u64, input[i * 8 ..][0..8], .little)});
        }
        std.debug.print("\n", .{});
    }
}

/// Watch for an iteration that never ends.
fn watchdog(io: std.Io) void {
    while (true) {
        std.Io.sleep(io, .fromMilliseconds(500), .awake) catch return;
        const started = watch.started_ms.load(.acquire);
        if (started == 0) continue;
        const elapsed = nowMs(io) - started;
        if (elapsed < @as(i64, watch.timeout_s) * 1000) continue;

        std.debug.print(
            "\n{s}: no answer after {d} seconds, which is a hang\n",
            .{ watch.target, @divTrunc(elapsed, 1000) },
        );
        show(watch.input);
        var name: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&name, "{s}/{s}-hang-{x:0>16}.bin", .{
            watch.dir,
            watch.target,
            std.hash.Wyhash.hash(0, watch.input),
        }) catch std.process.exit(3);
        std.Io.Dir.cwd().createDirPath(io, watch.dir) catch {};
        if (std.Io.Dir.cwd().createFile(io, path, .{})) |file| {
            defer file.close(io);
            file.writeStreamingAll(io, watch.input) catch {};
            std.debug.print("written to {s}\n", .{path});
        } else |_| {}
        std.process.exit(3);
    }
}
