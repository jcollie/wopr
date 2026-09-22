// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What the reader and the sample conversion must do with input nobody wrote.
//!
//! The weak property is the usual one — **return, do not crash**. An error is
//! a fine answer and so is a file full of samples; a panic, an out-of-bounds
//! index, a leak or an allocation the size of a declared length is a failure
//! in whatever embedded this library rather than in the file that caused it.
//! A WAVE file is very often something a stranger sent, and its two length
//! fields, its channel count and its chunk sizes are all attacker-controlled
//! numbers that this library divides by, multiplies and allocates from.
//!
//! The strong one is the interesting one: **what was read, written back and
//! read again must be the same samples**. A reader and a writer drift apart
//! easily, because nothing else compares them, and a sample width read one
//! way and written another is invisible until somebody's recording comes back
//! quiet, inverted or an octave out.
//!
//! A third is about the conversion alone: **decoding what was encoded is a
//! fixed point**. Bytes decode to numbers, numbers encode back to bytes, and
//! decoding those must give the numbers again — for every format, on bytes
//! that were never a sample of anything.
//!
//! `backing` is how a target gets an allocator in both worlds:
//! `std.testing.allocator` does not exist outside a test build, so the
//! standalone driver in `tools/fuzz.zig` points this at a `DebugAllocator` it
//! checks for leaks after every input.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const wav = @import("wav");

/// The allocator every target uses. A test build gets the testing allocator,
/// which fails the test on a leak; the standalone driver sets this to one it
/// owns.
pub var backing: Allocator = if (builtin.is_test) std.testing.allocator else undefined;

/// What a target will read from one input, in samples across all channels, so
/// that a declared length is never an instruction to allocate. Large enough
/// that no seed is cut short.
///
/// It is a sample count rather than a frame count because the frame is what a
/// hostile file controls: a header may claim sixty thousand channels, and a
/// limit in frames would then be a limit of sixty thousand times as much
/// memory. A caller of `readAlloc` has the same arithmetic to do, and
/// `header.channels` to do it with.
const max_samples = 1 << 16;

/// The frame limit that comes to, for a file with this many channels.
fn frameLimit(channels: u16) usize {
    return @max(1, max_samples / @as(usize, channels));
}

pub const Target = struct {
    name: []const u8,
    run: *const fn (input: []const u8) anyerror!void,
    /// Inputs that have broken something, or that reach a part of the target
    /// random bytes never would.
    seeds: []const []const u8,
};

pub const targets = [_]Target{
    .{ .name = "reader", .run = fuzzReader, .seeds = &file_seeds },
    .{ .name = "reader-alloc", .run = fuzzReaderAlloc, .seeds = &file_seeds },
    .{ .name = "roundtrip", .run = fuzzRoundTrip, .seeds = &file_seeds },
    .{ .name = "samples", .run = fuzzSamples, .seeds = &sample_seeds },
};

/// Read the file a frame at a time, into a buffer that is deliberately not a
/// multiple of anything.
fn fuzzReader(input: []const u8) anyerror!void {
    var stream: std.Io.Reader = .fixed(input);
    var r: wav.Reader = wav.Reader.init(&stream) catch return;

    // The header has to describe something possible, whatever the file said.
    if (r.header.channels == 0) return error.NoChannels;
    if (r.header.blockAlign() == 0) return error.NoWidth;

    var out: [333]f32 = undefined;
    var frames: u64 = 0;
    while (frames < frameLimit(r.header.channels)) {
        const n = r.read(f32, &out) catch return;
        if (n == 0) break;
        if (n % r.header.channels != 0) return error.PartialFrame;
        frames += n / r.header.channels;
        // An integer sample is a fraction of full scale and cannot leave
        // [-1, 1], so one that has is a width read as another width. A float
        // file is under no such obligation: what it holds is whatever was
        // written, including values past full scale and values that are not
        // numbers, and passing those through unchanged is the point.
        if (!r.header.format.isFloat()) {
            for (out[0..n]) |sample| {
                if (!(sample >= -1.0 and sample <= 1.0)) return error.SampleOutOfRange;
            }
        }
    }
}

/// The same file, read in one allocation, which is where a declared length
/// becomes an allocation size.
fn fuzzReaderAlloc(input: []const u8) anyerror!void {
    var stream: std.Io.Reader = .fixed(input);
    var r: wav.Reader = wav.Reader.init(&stream) catch return;

    const samples = r.readAlloc(backing, i32, frameLimit(r.header.channels)) catch return;
    defer backing.free(samples);

    if (samples.len % r.header.channels != 0) return error.PartialFrame;
    // What was read cannot be more than the file could hold, whatever its
    // length fields claimed.
    if (samples.len * r.header.format.bytesPerSample() > input.len) return error.ReadMoreThanExists;
}

/// Read, write what was read, read that: the samples must survive.
fn fuzzRoundTrip(input: []const u8) anyerror!void {
    var stream: std.Io.Reader = .fixed(input);
    var r: wav.Reader = wav.Reader.init(&stream) catch return;

    // A float file is round-tripped through `f64`, which holds every value
    // either float format can; an integer file through `i32`, which holds
    // every value any of the integer widths can. Either way nothing is
    // scaled, so anything that comes back changed is a fault rather than a
    // rounding.
    return switch (r.header.format) {
        .u8, .s16, .s24, .s32 => roundTrip(i32, &r),
        .f32, .f64 => roundTrip(f64, &r),
    };
}

fn roundTrip(comptime S: type, r: *wav.Reader) anyerror!void {
    const first = r.readAlloc(backing, S, frameLimit(r.header.channels)) catch return;
    defer backing.free(first);

    var written: std.Io.Writer.Allocating = .init(backing);
    defer written.deinit();

    var w: wav.Writer = try .init(&written.writer, .{
        .sample_rate = r.header.sample_rate,
        .channels = r.header.channels,
        .format = r.header.format,
        .frames = first.len / r.header.channels,
    });
    try w.write(S, first);
    try w.finish();

    var again: std.Io.Reader = .fixed(written.written());
    var second: wav.Reader = wav.Reader.init(&again) catch |err| {
        std.debug.print("what was written did not read again: {t}\n", .{err});
        return error.RoundTripFailed;
    };

    if (second.header.sample_rate != r.header.sample_rate) return error.SampleRateChanged;
    if (second.header.channels != r.header.channels) return error.ChannelsChanged;
    if (second.header.format != r.header.format) return error.FormatChanged;
    // A file with no samples in it writes a `data` chunk of zero bytes, which
    // is the same thing on the page as a length that was never filled in, so
    // that one case comes back as `null` rather than as zero.
    const expected = first.len / r.header.channels;
    if (expected != 0 and second.header.frames != expected) return error.LengthChanged;

    const back = second.readAlloc(backing, S, frameLimit(r.header.channels)) catch |err| {
        std.debug.print("what was written did not read again: {t}\n", .{err});
        return error.RoundTripFailed;
    };
    defer backing.free(back);

    if (back.len != first.len) return error.LengthChanged;
    for (first, back) |before, after| {
        if (before == after) continue;
        // A file may hold a sample that is not a number, which is never equal
        // to itself and is not a difference.
        if (S != i32 and std.math.isNan(before) and std.math.isNan(after)) continue;
        return error.SamplesChanged;
    }
}

/// The conversion on its own: bytes that were never a sample of anything,
/// decoded and encoded until they settle.
///
/// The first byte chooses the format, so that a mutator reaches all six
/// rather than only the one a fixed choice would pin it to.
fn fuzzSamples(input: []const u8) anyerror!void {
    if (input.len < 2) return;
    const formats = [_]wav.Format{ .u8, .s16, .s24, .s32, .f32, .f64 };
    const format = formats[input[0] % formats.len];
    const bytes = input[1..];

    const width = format.bytesPerSample();
    // `usize` on purpose: `@min` against a literal narrows its result type,
    // and this is multiplied by a width afterwards.
    const count: usize = @min(bytes.len / width, 4096);
    if (count == 0) return;

    var first: [4096]f64 = undefined;
    _ = wav.decode(f64, format, bytes[0 .. count * width], first[0..count]);

    var encoded: [4096 * 8]u8 = undefined;
    _ = wav.encode(f64, format, first[0..count], encoded[0 .. count * width]);

    var second: [4096]f64 = undefined;
    _ = wav.decode(f64, format, encoded[0 .. count * width], second[0..count]);

    for (first[0..count], second[0..count]) |before, after| {
        if (before == after) continue;
        if (std.math.isNan(before) and std.math.isNan(after)) continue;
        std.debug.print("{s}: {d} became {d}\n", .{ @tagName(format), before, after });
        return error.NotAFixedPoint;
    }

    // And an integer file's samples must land inside the width they came out
    // of, since that is the promise `i32` samples make.
    if (!format.isFloat()) {
        var ints: [4096]i32 = undefined;
        _ = wav.decode(i32, format, bytes[0 .. count * width], ints[0..count]);
        const limit = @as(i64, 1) << @intCast(format.bitsPerSample() - 1);
        for (ints[0..count]) |sample| {
            if (sample < -limit or sample >= limit) return error.SampleOutOfWidth;
        }
    }
}

/// A WAVE file with the canonical header this library writes.
fn file(comptime h: wav.Header, comptime data: []const u8) *const [wav.header_size + data.len]u8 {
    comptime {
        var buf: [wav.header_size + data.len]u8 = undefined;
        wav.render(h, buf[0..wav.header_size]);
        @memcpy(buf[wav.header_size..], data);
        const out = buf;
        return &out;
    }
}

const file_seeds = [_][]const u8{
    // One of each format, so that every decoding path is reachable from a
    // seed rather than only from a lucky mutation.
    file(.{ .sample_rate = 8000, .channels = 1, .format = .u8, .frames = 5 }, "\x00\x40\x80\xC0\xFF"),
    file(
        .{ .sample_rate = 44100, .channels = 2, .format = .s16, .frames = 3 },
        "\x00\x00\xFF\x7F\x00\x80\x01\x00\x34\x12\xCD\xAB",
    ),
    file(
        .{ .sample_rate = 48000, .channels = 1, .format = .s24, .frames = 3 },
        "\x00\x00\x00\xFF\xFF\x7F\x00\x00\x80",
    ),
    file(
        .{ .sample_rate = 96000, .channels = 1, .format = .s32, .frames = 2 },
        "\xFF\xFF\xFF\x7F\x00\x00\x00\x80",
    ),
    file(
        .{ .sample_rate = 48000, .channels = 2, .format = .f32, .frames = 2 },
        "\x00\x00\x00\x00\x00\x00\x80\x3F\x00\x00\x80\xBF\x00\x00\xC0\x7F",
    ),
    file(
        .{ .sample_rate = 48000, .channels = 1, .format = .f64, .frames = 2 },
        "\x00\x00\x00\x00\x00\x00\xF0\x3F\x00\x00\x00\x00\x00\x00\xF8\x7F",
    ),
    // The lengths left unfilled, which is what a file written to a pipe looks
    // like, and the same file with an odd byte on the end that is not a
    // frame.
    file(.{ .sample_rate = 44100, .channels = 2, .format = .s16 }, "\x01\x00\x02\x00\x03\x00\x04\x00"),
    file(.{ .sample_rate = 44100, .channels = 2, .format = .s16 }, "\x01\x00\x02\x00\x03"),
    // A length far past what follows it.
    file(.{ .sample_rate = 44100, .channels = 2, .format = .s16, .frames = 100000 }, "\x01\x00\x02\x00"),
    // Many channels, where the frame is wider than most things expect.
    file(.{ .sample_rate = 48000, .channels = 8, .format = .s16, .frames = 1 }, "\x00\x00" ** 8),
    // An extensible header: the tag says "look at the GUID", and the GUID
    // says integer PCM. Written by hand, since this library never writes one.
    "RIFF\x44\x00\x00\x00WAVEfmt \x28\x00\x00\x00" ++
        "\xFE\xFF\x02\x00\x44\xAC\x00\x00\x10\xB1\x02\x00\x04\x00\x10\x00" ++
        "\x16\x00\x10\x00\x03\x00\x00\x00" ++
        "\x01\x00\x00\x00\x00\x00\x10\x00\x80\x00\x00\xAA\x00\x38\x9B\x71" ++
        "data\x08\x00\x00\x00\x01\x00\x02\x00\x03\x00\x04\x00",
    // Chunks in the way, one of them of odd length so that the pad byte
    // matters, and a `LIST` after the format chunk.
    "RIFF\x4C\x00\x00\x00WAVE" ++
        "JUNK\x05\x00\x00\x00INFO\x00\x00" ++
        "fmt \x10\x00\x00\x00\x01\x00\x01\x00\x40\x1F\x00\x00\x80\x3E\x00\x00\x02\x00\x10\x00" ++
        "LIST\x04\x00\x00\x00INFO" ++
        "data\x04\x00\x00\x00\x01\x00\x02\x00",
    // Formats and widths nothing here decodes: µ-law, and twelve bit PCM.
    "RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00" ++
        "\x07\x00\x01\x00\x40\x1F\x00\x00\x40\x1F\x00\x00\x01\x00\x08\x00" ++
        "data\x02\x00\x00\x00\xFF\xFF",
    "RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00" ++
        "\x01\x00\x01\x00\x40\x1F\x00\x00\x80\x3E\x00\x00\x02\x00\x0C\x00" ++
        "data\x02\x00\x00\x00\xFF\xFF",
    // No channels, which would be a division by zero everywhere downstream.
    "RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00" ++
        "\x01\x00\x00\x00\x40\x1F\x00\x00\x80\x3E\x00\x00\x02\x00\x10\x00" ++
        "data\x02\x00\x00\x00\xFF\xFF",
    // A chunk whose size runs off the end of the file, and a format chunk
    // that claims to be enormous.
    "RIFF\x24\x00\x00\x00WAVEJUNK\xFF\xFF\xFF\xFFfmt ",
    "RIFF\x24\x00\x00\x00WAVEfmt \xFF\xFF\xFF\xFF\x01\x00\x02\x00",
    // What ffmpeg writes when its output is a pipe: all ones in both length
    // fields, and a `LIST` in between that it could size because it was
    // finished with it.
    "RIFF\xFF\xFF\xFF\xFFWAVE" ++
        "fmt \x10\x00\x00\x00\x01\x00\x01\x00\x44\xAC\x00\x00\x88\x58\x01\x00\x02\x00\x10\x00" ++
        "LIST\x0C\x00\x00\x00INFOISFT\x00\x00\x00\x00" ++
        "data\xFF\xFF\xFF\xFF\x01\x00\x02\x00\x03\x00",
    // An odd-length `data` chunk with its pad byte, which is the one place
    // where the file's length and the chunk's are not a fixed distance apart.
    "RIFF\x2A\x00\x00\x00WAVE" ++
        "fmt \x10\x00\x00\x00\x01\x00\x01\x00\x40\x1F\x00\x00\x40\x1F\x00\x00\x01\x00\x08\x00" ++
        "data\x05\x00\x00\x00\x80\x81\x82\x83\x84\x00",
    // RF64 and RIFX: a WAVE past four gigabytes, and a WAVE with every length
    // the other way round. Both are refused by name rather than misread.
    "RF64\xFF\xFF\xFF\xFFWAVEds64\x1C\x00\x00\x00" ++ ("\x00" ** 28),
    "RIFX\x00\x00\x00\x24WAVEfmt \x00\x00\x00\x10\x00\x01\x00\x01\x00\x00\x1F\x40",
    // Shapes that are not files at all.
    "",
    "RIFF",
    "RIFF\x00\x00\x00\x00WAVE",
    "RIFX\x24\x00\x00\x00WAVE",
    "fLaC\x00\x00\x00\x22",
};

/// Bytes for the conversion, whose first byte picks the format.
const sample_seeds = [_][]const u8{
    "\x00" ++ "\x00\x40\x80\xC0\xFF", // u8
    "\x01" ++ "\x00\x00\xFF\x7F\x00\x80\x01\x80", // s16, including both extremes
    "\x02" ++ "\xFF\xFF\x7F\x00\x00\x80\x00\x00\x00", // s24
    "\x03" ++ "\xFF\xFF\xFF\x7F\x00\x00\x00\x80", // s32
    "\x04" ++ "\x00\x00\x80\x3F\x00\x00\x80\xBF", // f32: +1 and -1
    "\x04" ++ "\x00\x00\xC0\x7F\x00\x00\x80\x7F\x00\x00\x80\xFF", // f32: NaN, ±inf
    "\x04" ++ "\xFF\xFF\x7F\x7F\x01\x00\x00\x00", // f32: the largest finite, and a subnormal
    "\x05" ++ "\x00\x00\x00\x00\x00\x00\xF0\x3F", // f64: +1
    "\x05" ++ "\x00\x00\x00\x00\x00\x00\xF8\x7F", // f64: NaN
    "\x05" ++ "\xFF\xFF\xFF\xFF\xFF\xFF\xEF\x7F", // f64: the largest finite
    "\x00",
    "",
};

// -- the same properties, as ordinary tests over the seeds ---------------------

test "every seed, through every target" {
    for (targets) |target| {
        for (target.seeds) |seed| {
            target.run(seed) catch |err| {
                std.debug.print("{s} failed on a seed of {d} bytes: {t}\n", .{
                    target.name, seed.len, err,
                });
                return err;
            };
        }
    }
}

test "every seed of one target, through the others" {
    // A file is also a string of bytes the conversion can be pointed at, and
    // a string of sample bytes is also something the reader must refuse
    // rather than crash on.
    for (targets) |target| {
        for (file_seeds ++ sample_seeds) |seed| {
            try target.run(seed);
        }
    }
}

test "a truncation of every seed, through every target" {
    // Every prefix of every seed, which is the cheapest way to reach every
    // "the file ends here" branch there is.
    for (targets) |target| {
        for (target.seeds) |seed| {
            for (0..seed.len) |n| {
                target.run(seed[0..n]) catch |err| {
                    std.debug.print("{s} failed on {d} bytes of a seed: {t}\n", .{
                        target.name, n, err,
                    });
                    return err;
                };
            }
        }
    }
}
