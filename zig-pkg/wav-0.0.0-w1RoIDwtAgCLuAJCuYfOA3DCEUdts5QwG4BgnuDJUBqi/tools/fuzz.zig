// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A fuzzing loop of our own, because Zig 0.16.0's cannot be used here.
//!
//! Two separate defects stand in the way. The first is that a test executable
//! cannot be built in fuzz mode at all: `compiler/test_runner.zig` reports a
//! failing input by handing what `@errorReturnTrace()` returned to
//! `std.debug.writeStackTrace`, and those are two different types. The
//! devshell patches that one line, which is what `fuzzableZig` in `flake.nix`
//! is for.
//!
//! The second has no workaround. Nothing in the release populates the table of
//! program counters, so a bounded run ends with `corrupted coverage file:
//! pcs_len was zero` and an unbounded one panics in the build runner's
//! coverage thread. Neither is a finding. What is left is a fuzzer with no
//! coverage feedback, which is not worth much.
//!
//! So this drives the same targets with a corpus and a mutator instead. What
//! it has in place of coverage is a corpus of inputs that are already valid --
//! real headers, real chunk layouts, real samples at every width -- which for
//! a parser is most of the way there: the interesting inputs are the ones that
//! are nearly right, and a WAVE file is mostly lengths and widths that agree
//! with each other until one of them is changed by a byte.
//!
//!     zig build fuzz-run                        # until interrupted
//!     zig build fuzz-run -- --iterations 500000
//!     zig build fuzz-run -- --seconds 600 --target roundtrip

const std = @import("std");
const Io = std.Io;
const targets_mod = @import("fuzz_targets");

const usage =
    \\usage: wav-fuzz [options]
    \\
    \\Mutates the seed corpus of each fuzz target and reports anything that
    \\does not merely return or fail.
    \\
    \\options:
    \\      --iterations N   stop after N inputs (default: unbounded)
    \\      --seconds N      stop after N seconds
    \\      --target NAME    only the target whose name is NAME
    \\      --seed N         start from this random seed rather than the clock
    \\  -h, --help           show this message
    \\
;

/// The largest input the mutator will build. Long enough for a file with a
/// few thousand samples in it, short enough that a failure is readable.
const max_input = 64 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout.interface;

    var iterations: ?usize = null;
    var seconds: ?u64 = null;
    var only: ?[]const u8 = null;
    // The clock comes from the `Io`, which is where 0.16 keeps it.
    var seed: u64 = @bitCast(@as(i64, Io.Timestamp.now(io, .real).toMilliseconds()));

    const args = try init.minimal.args.toSlice(arena);
    var i: usize = @min(1, args.len);
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage);
            try out.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            i += 1;
            iterations = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            i += 1;
            seconds = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            only = args[i];
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            seed = try std.fmt.parseInt(u64, args[i], 10);
        } else {
            try out.print("unknown option {s}\n", .{arg});
            try out.flush();
            std.process.exit(2);
        }
    }

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    // The targets cannot name `std.testing.allocator`, which does not exist
    // outside a test build, so they take one from here instead -- and this one
    // reports a leak, which is a finding as much as a crash is.
    targets_mod.backing = gpa;

    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();

    var buffer: [max_input]u8 = undefined;
    // `awake` rather than `real`: a run bounded by `--seconds` must not end
    // early because the system clock was adjusted under it.
    const start = Io.Timestamp.now(io, .awake);

    try out.print("seed {d}\n", .{seed});
    try out.flush();

    var count: usize = 0;
    var failures: usize = 0;
    while (true) {
        if (iterations) |limit| {
            if (count >= limit) break;
        }
        if (seconds) |limit| {
            const elapsed = start.durationTo(Io.Timestamp.now(io, .awake));
            if (elapsed.toSeconds() >= limit) break;
        }

        for (targets_mod.targets) |target| {
            if (only) |name| {
                if (!std.mem.eql(u8, name, target.name)) continue;
            }
            const input = mutate(random, target.seeds, &buffer);
            count += 1;
            target.run(input) catch |err| {
                failures += 1;
                try out.print("\n{s}: {t}\ninput ({d} bytes):\n", .{
                    target.name, err, input.len,
                });
                try hexdump(out, input);
                try out.flush();
            };
        }

        // Progress often enough to show the loop is alive, rarely enough not
        // to be what the run spends its time on. A whole line rather than a
        // carriage return, because most of these runs are read out of a CI log
        // rather than watched.
        if (count % 500_000 < targets_mod.targets.len) {
            try out.print("{d} inputs, {d} failures\n", .{ count, failures });
            try out.flush();
        }
    }

    try out.print("{d} inputs, {d} failures\n", .{ count, failures });
    try out.flush();
    if (failures != 0) std.process.exit(1);
}

/// Builds one input by taking a seed and damaging it.
///
/// The mutations are the ones that matter for a binary format with lengths in
/// it: flip a byte, write a length that is interesting rather than random,
/// paste in a chunk identifier, cut a run out, repeat one. What makes this
/// work without coverage feedback is that every seed is already a file the
/// reader accepts, so a small change lands near the boundary rather than in
/// the vast space of inputs rejected on the first four bytes.
fn mutate(random: std.Random, seeds: []const []const u8, buffer: []u8) []const u8 {
    const base = seeds[random.uintLessThan(usize, seeds.len)];
    const len = @min(base.len, buffer.len);
    @memcpy(buffer[0..len], base[0..len]);
    var out = buffer[0..len];

    // Between one and four edits, so that a single flip is common and a
    // thorough scramble is not.
    const edits = 1 + random.uintLessThan(usize, 4);
    for (0..edits) |_| {
        switch (random.uintLessThan(u8, 7)) {
            // Flip a byte.
            0 => if (out.len != 0) {
                out[random.uintLessThan(usize, out.len)] = random.int(u8);
            },
            // Replace a byte with one of the ones that sit at a boundary: the
            // extremes of a sample, and the ends of a length field.
            1 => if (out.len != 0) {
                const interesting = "\x00\x01\x7F\x80\xFF\xFE";
                out[random.uintLessThan(usize, out.len)] =
                    interesting[random.uintLessThan(usize, interesting.len)];
            },
            // Write a four byte length that is interesting. Half the trouble
            // a WAVE file can cause is a size field that disagrees with the
            // bytes after it, and a random one is almost always simply too
            // large; these are the ones that are nearly right.
            2 => if (out.len >= 4) {
                const lengths = [_]u32{
                    0,                    1,
                    2,                    3,
                    4,                    16,
                    18,                   40,
                    0x7FFF_FFFF,          0x8000_0000,
                    0xFFFF_FFFE,          0xFFFF_FFFF,
                    std.math.maxInt(u16), @as(u32, std.math.maxInt(u16)) + 1,
                };
                const at = random.uintLessThan(usize, out.len - 3);
                std.mem.writeInt(
                    u32,
                    out[at..][0..4],
                    lengths[random.uintLessThan(usize, lengths.len)],
                    .little,
                );
            },
            // Paste in a chunk identifier or a format tag, so that a mutation
            // can grow a file a chunk the corpus never had.
            3 => if (out.len >= 4) {
                const words = [_][]const u8{
                    "RIFF", "RIFX", "WAVE", "fmt ",             "data",             "LIST",             "JUNK", "fact",
                    "ds64", "bext", "cue ", "\x01\x00\x08\x00", "\x03\x00\x20\x00", "\xFE\xFF\x02\x00",
                };
                const word = words[random.uintLessThan(usize, words.len)];
                const at = random.uintLessThan(usize, out.len - 3);
                @memcpy(out[at..][0..4], word[0..4]);
            },
            // Cut a run out.
            4 => if (out.len > 1) {
                const at = random.uintLessThan(usize, out.len);
                const take = 1 + random.uintLessThan(usize, @min(16, out.len - at));
                std.mem.copyForwards(u8, out[at..], out[at + take ..]);
                out = out[0 .. out.len - take];
            },
            // Repeat a run, which is how a file grows chunks and samples it
            // did not have.
            5 => if (out.len != 0) {
                const at = random.uintLessThan(usize, out.len);
                const take = 1 + random.uintLessThan(usize, @min(64, out.len - at));
                const times = 1 + random.uintLessThan(usize, 8);
                var written = out.len;
                for (0..times) |_| {
                    if (written + take > buffer.len) break;
                    @memcpy(buffer[written..][0..take], out[at..][0..take]);
                    written += take;
                }
                out = buffer[0..written];
            },
            // Truncate, which is what a file that was still being written
            // looks like.
            6 => if (out.len != 0) {
                out = out[0..random.uintLessThan(usize, out.len)];
            },
            else => unreachable,
        }
    }
    return out;
}

/// Prints a failing input the way a binary format has to be printed: as
/// bytes, with the identifiers still readable down the right hand side.
fn hexdump(out: *Io.Writer, input: []const u8) !void {
    var offset: usize = 0;
    while (offset < input.len) : (offset += 16) {
        const row = input[offset..@min(offset + 16, input.len)];
        try out.print("{x:0>8}  ", .{offset});
        for (0..16) |i| {
            if (i < row.len) try out.print("{x:0>2} ", .{row[i]}) else try out.writeAll("   ");
            if (i == 7) try out.writeAll(" ");
        }
        try out.writeAll(" |");
        for (row) |byte| {
            try out.writeByte(if (byte >= 0x20 and byte < 0x7F) byte else '.');
        }
        try out.writeAll("|\n");
    }
}

const testing = std.testing;

test "a mutation stays inside the buffer" {
    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();
    // Deliberately small, so that every growing mutation runs into the end of
    // it and has to refuse rather than overrun.
    var buffer: [64]u8 = undefined;
    const seeds = [_][]const u8{ "", "RIFF\x24\x00\x00\x00WAVE", "x" ** 60 };
    for (0..20_000) |_| {
        const out = mutate(random, &seeds, &buffer);
        try testing.expect(out.len <= buffer.len);
    }
}

test "a hexdump prints every byte it was given" {
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try hexdump(&w, "RIFF\x24\x00\x00\x00WAVEfmt \x10");
    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "|RIFF$...WAVE") != null);
    try testing.expect(std.mem.indexOf(u8, text, "52 49 46 46") != null);
}
