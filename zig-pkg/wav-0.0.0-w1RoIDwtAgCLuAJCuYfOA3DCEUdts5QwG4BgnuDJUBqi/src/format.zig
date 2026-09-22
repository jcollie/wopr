// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! How samples are laid out in a `data` chunk, and the conversion between
//! those bytes and the numbers a program would rather work in.
//!
//! Nothing here reads or writes a stream: `encode` and `decode` are slice to
//! slice, so the same code serves a file, a socket and a buffer somebody else
//! owns.

const std = @import("std");

/// The `wFormatTag` of integer PCM.
pub const format_pcm: u16 = 0x0001;
/// The `wFormatTag` of IEEE floating point PCM.
pub const format_ieee_float: u16 = 0x0003;
/// The `wFormatTag` that says the real one is in the extension's sub-format
/// GUID, which is where a file with more than two channels, or more than
/// sixteen bits, is supposed to put it.
pub const format_extensible: u16 = 0xFFFE;

/// How samples are laid out in the `data` chunk.
///
/// Every one of these is little-endian, which is what `WAVE` means; the
/// big-endian `RIFX` variant is a different container and is not read here.
pub const Format = enum {
    /// 8 bit unsigned, centred on 128. WAVE's only unsigned width, which is a
    /// historical accident rather than a pattern.
    u8,
    /// 16 bit signed. What everything reads.
    s16,
    /// 24 bit signed, packed three bytes to a sample with no padding.
    s24,
    /// 32 bit signed.
    s32,
    /// 32 bit IEEE float, nominally in [-1, 1].
    f32,
    /// 64 bit IEEE float, nominally in [-1, 1].
    f64,

    pub fn bytesPerSample(f: Format) u8 {
        return switch (f) {
            .u8 => 1,
            .s16 => 2,
            .s24 => 3,
            .s32, .f32 => 4,
            .f64 => 8,
        };
    }

    pub fn bitsPerSample(f: Format) u16 {
        return @as(u16, f.bytesPerSample()) * 8;
    }

    pub fn isFloat(f: Format) bool {
        return switch (f) {
            .f32, .f64 => true,
            else => false,
        };
    }

    /// The `wFormatTag` a header carries for this format.
    pub fn tag(f: Format) u16 {
        return if (f.isFloat()) format_ieee_float else format_pcm;
    }

    /// The format a `fmt ` chunk describes, or `null` for one this library
    /// does not decode — A-law, µ-law, ADPCM, and every other compressed
    /// payload the tag registry names.
    ///
    /// `t` is the tag after an extensible header's sub-format GUID has been
    /// resolved, since the first two bytes of that GUID are the tag the
    /// header would have carried had it not been extensible.
    pub fn fromTag(t: u16, bits: u16) ?Format {
        return switch (t) {
            format_pcm => switch (bits) {
                8 => .u8,
                16 => .s16,
                24 => .s24,
                32 => .s32,
                else => null,
            },
            format_ieee_float => switch (bits) {
                32 => .f32,
                64 => .f64,
                else => null,
            },
            else => null,
        };
    }
};

/// The sample types `encode` and `decode` convert to and from.
///
/// `f32` and `f64` are normalized: full scale is ±1, whatever the file's
/// width. `i32` is the sample as the file itself holds it — an `.s16` file
/// hands back values in [-32768, 32767], and `Format.bitsPerSample` is what
/// says so — which is what a lossless path wants, since nothing is scaled and
/// nothing is rounded. A float *file* read as `i32`, or written from one, is
/// scaled as though it were `.s32`, there being no narrower width in the file
/// to take the scale from.
pub fn isSampleType(comptime S: type) bool {
    return S == f32 or S == f64 or S == i32;
}

fn assertSampleType(comptime S: type) void {
    if (!isSampleType(S)) @compileError(
        "samples are f32, f64 or i32, not " ++ @typeName(S),
    );
}

/// Decode `in`, which holds samples in `format`, into `out`.
///
/// `in` must be exactly `out.len * format.bytesPerSample()` bytes. Returns
/// `out`.
pub fn decode(comptime S: type, format: Format, in: []const u8, out: []S) []S {
    comptime assertSampleType(S);
    std.debug.assert(in.len == out.len * format.bytesPerSample());
    switch (format) {
        .u8 => for (out, 0..) |*o, i| {
            // Unsigned, centred on 128, so the signed value is 128 below it.
            o.* = fromInt(S, 8, @as(i32, in[i]) - 128);
        },
        .s16 => for (out, 0..) |*o, i| {
            o.* = fromInt(S, 16, std.mem.readInt(i16, in[i * 2 ..][0..2], .little));
        },
        .s24 => for (out, 0..) |*o, i| {
            // No `readInt(i24, ...)` on a three byte slice, so the three bytes
            // are assembled and the sign carried down from bit 23.
            const b = in[i * 3 ..][0..3];
            const raw: u32 = @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16);
            o.* = fromInt(S, 24, @as(i32, @bitCast(raw << 8)) >> 8);
        },
        .s32 => for (out, 0..) |*o, i| {
            o.* = fromInt(S, 32, std.mem.readInt(i32, in[i * 4 ..][0..4], .little));
        },
        .f32 => for (out, 0..) |*o, i| {
            o.* = fromFloat(S, @as(f32, @bitCast(std.mem.readInt(u32, in[i * 4 ..][0..4], .little))));
        },
        .f64 => for (out, 0..) |*o, i| {
            o.* = fromFloat(S, @as(f64, @bitCast(std.mem.readInt(u64, in[i * 8 ..][0..8], .little))));
        },
    }
    return out;
}

/// Encode `in` into `out` as samples in `format`.
///
/// `out` must be exactly `in.len * format.bytesPerSample()` bytes. Returns
/// `out`.
///
/// Samples outside the format's range are clipped rather than wrapped.
/// Wrapping a sample that went a hair over full scale turns a moment of
/// loudness into a full-scale discontinuity, which is a click; a clipped
/// sample is not one.
pub fn encode(comptime S: type, format: Format, in: []const S, out: []u8) []u8 {
    comptime assertSampleType(S);
    std.debug.assert(out.len == in.len * format.bytesPerSample());
    switch (format) {
        .u8 => for (in, 0..) |s, i| {
            out[i] = @intCast(toInt(S, 8, s) + 128);
        },
        .s16 => for (in, 0..) |s, i| {
            std.mem.writeInt(i16, out[i * 2 ..][0..2], @intCast(toInt(S, 16, s)), .little);
        },
        .s24 => for (in, 0..) |s, i| {
            const v: u32 = @bitCast(toInt(S, 24, s));
            out[i * 3 ..][0..3].* = .{
                @truncate(v),
                @truncate(v >> 8),
                @truncate(v >> 16),
            };
        },
        .s32 => for (in, 0..) |s, i| {
            std.mem.writeInt(i32, out[i * 4 ..][0..4], toInt(S, 32, s), .little);
        },
        .f32 => for (in, 0..) |s, i| {
            std.mem.writeInt(u32, out[i * 4 ..][0..4], @bitCast(toFloat(f32, S, s)), .little);
        },
        .f64 => for (in, 0..) |s, i| {
            std.mem.writeInt(u64, out[i * 8 ..][0..8], @bitCast(toFloat(f64, S, s)), .little);
        },
    }
    return out;
}

/// An integer sample of `bits` bits, as `S`.
fn fromInt(comptime S: type, comptime bits: u8, value: i32) S {
    if (S == i32) return value;
    return @as(S, @floatFromInt(value)) / fullScale(S, bits);
}

/// A floating point sample, as `S`.
fn fromFloat(comptime S: type, value: anytype) S {
    if (S == i32) return quantize(32, value);
    return @floatCast(value);
}

/// `S` as an integer sample of `bits` bits, saturating.
fn toInt(comptime S: type, comptime bits: u8, sample: S) i32 {
    if (S == i32) return @intCast(std.math.clamp(@as(i64, sample), minOf(bits), maxOf(bits)));
    return quantize(bits, sample);
}

/// The extremes of a signed integer of `bits` bits, as `i64` because the
/// positive one does not fit an `i32` when `bits` is 32.
fn minOf(comptime bits: u8) i64 {
    return -(@as(i64, 1) << (bits - 1));
}

fn maxOf(comptime bits: u8) i64 {
    return (@as(i64, 1) << (bits - 1)) - 1;
}

/// `S` as a floating point sample.
fn toFloat(comptime F: type, comptime S: type, sample: S) F {
    if (S == i32) return @as(F, @floatFromInt(sample)) / fullScale(F, 32);
    return @floatCast(sample);
}

/// Full scale for `bits` bits: `2^(bits-1)`, which is the magnitude of the
/// *negative* extreme, because that is the value an integer of that many bits
/// actually has. Dividing by it maps the negative extreme to exactly −1 and
/// the positive extreme to one step short of +1, which is the pair of
/// conventions that does not wrap on the way back.
fn fullScale(comptime F: type, comptime bits: u8) F {
    return @floatFromInt(@as(i64, 1) << (bits - 1));
}

/// Scale a float sample to a signed integer of `bits` bits, saturating.
///
/// The arithmetic is done in `f64` whatever the sample was, which is exact
/// for an `f32` and is what makes the clamp safe: the largest `i32` is not a
/// representable `f32`, so clamping a full-scale sample in `f32` rounds it
/// *up* past the maximum and `@intFromFloat` then has nowhere to put it.
///
/// A NaN becomes zero rather than an extreme, since `@intFromFloat` on a NaN
/// is undefined behaviour and silence is the only sample a value that is not
/// a number can honestly become.
fn quantize(comptime bits: u8, sample: anytype) i32 {
    const v: f64 = sample;
    if (std.math.isNan(v)) return 0;
    const low: f64 = @floatFromInt(minOf(bits));
    const high: f64 = @floatFromInt(maxOf(bits));
    const scaled = @round(std.math.clamp(v, -1, 1) * fullScale(f64, bits));
    return @intFromFloat(std.math.clamp(scaled, low, high));
}

const testing = std.testing;

test "a format describes its own width and tag" {
    try testing.expectEqual(@as(u8, 1), Format.u8.bytesPerSample());
    try testing.expectEqual(@as(u8, 3), Format.s24.bytesPerSample());
    try testing.expectEqual(@as(u16, 24), Format.s24.bitsPerSample());
    try testing.expectEqual(format_pcm, Format.s24.tag());
    try testing.expectEqual(format_ieee_float, Format.f64.tag());
    try testing.expect(!Format.s32.isFloat());
    try testing.expect(Format.f32.isFloat());
}

test "a tag and a width name a format, or nothing" {
    try testing.expectEqual(Format.u8, Format.fromTag(format_pcm, 8).?);
    try testing.expectEqual(Format.s32, Format.fromTag(format_pcm, 32).?);
    try testing.expectEqual(Format.f32, Format.fromTag(format_ieee_float, 32).?);
    try testing.expectEqual(Format.f64, Format.fromTag(format_ieee_float, 64).?);
    // A width the tag does not have, a width nothing has, and µ-law.
    try testing.expectEqual(@as(?Format, null), Format.fromTag(format_ieee_float, 16));
    try testing.expectEqual(@as(?Format, null), Format.fromTag(format_pcm, 12));
    try testing.expectEqual(@as(?Format, null), Format.fromTag(0x0007, 8));
}

test "quantising saturates instead of wrapping" {
    try testing.expectEqual(@as(i32, -32768), quantize(16, @as(f32, -1.0)));
    try testing.expectEqual(@as(i32, 32767), quantize(16, @as(f32, 1.0)));
    try testing.expectEqual(@as(i32, -32768), quantize(16, @as(f32, -4.0)));
    try testing.expectEqual(@as(i32, 32767), quantize(16, @as(f32, 4.0)));
    try testing.expectEqual(@as(i32, 0), quantize(16, @as(f32, 0.0)));
    try testing.expectEqual(@as(i32, -8388608), quantize(24, @as(f32, -1.0)));
    try testing.expectEqual(@as(i32, 8388607), quantize(24, @as(f32, 1.0)));
    try testing.expectEqual(@as(i32, 2147483647), quantize(32, @as(f64, 1.0)));
    // Not a number, and the infinities that clamp before they are scaled.
    try testing.expectEqual(@as(i32, 0), quantize(16, @as(f32, std.math.nan(f32))));
    try testing.expectEqual(@as(i32, 32767), quantize(16, std.math.inf(f32)));
    try testing.expectEqual(@as(i32, -32768), quantize(16, -std.math.inf(f32)));
}

test "floats encode to each integer width at the extremes" {
    const in = [_]f32{ 0.0, 0.5, -0.5, 1.0, -1.0 };

    var eight: [in.len]u8 = undefined;
    _ = encode(f32, .u8, &in, &eight);
    try testing.expectEqualSlices(u8, &.{ 128, 192, 64, 255, 0 }, &eight);

    var s16: [in.len * 2]u8 = undefined;
    _ = encode(f32, .s16, &in, &s16);
    try testing.expectEqual(@as(i16, 16384), std.mem.readInt(i16, s16[2..4], .little));
    try testing.expectEqual(@as(i16, -16384), std.mem.readInt(i16, s16[4..6], .little));
    try testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, s16[6..8], .little));
    try testing.expectEqual(@as(i16, -32768), std.mem.readInt(i16, s16[8..10], .little));

    var s24: [in.len * 3]u8 = undefined;
    _ = encode(f32, .s24, &in, &s24);
    try testing.expectEqual(@as(i24, 4194304), std.mem.readInt(i24, s24[3..6], .little));
    try testing.expectEqual(@as(i24, -8388608), std.mem.readInt(i24, s24[12..15], .little));

    var f: [in.len * 4]u8 = undefined;
    _ = encode(f32, .f32, &in, &f);
    try testing.expectEqual(@as(f32, -0.5), @as(f32, @bitCast(std.mem.readInt(u32, f[8..12], .little))));
}

test "integer samples keep the file's own width" {
    // An .s16 file holds i16 values, and reading it as i32 is a widening and
    // nothing else: no scaling, no rounding, nothing to argue about.
    const bytes = [_]u8{ 0x00, 0x80, 0xFF, 0x7F, 0x00, 0x00 };
    var out: [3]i32 = undefined;
    _ = decode(i32, .s16, &bytes, &out);
    try testing.expectEqualSlices(i32, &.{ -32768, 32767, 0 }, &out);

    var back: [6]u8 = undefined;
    _ = encode(i32, .s16, &out, &back);
    try testing.expectEqualSlices(u8, &bytes, &back);

    // And a sample too big for the width clips rather than wrapping.
    const loud = [_]i32{ 40000, -40000 };
    var clipped: [4]u8 = undefined;
    _ = encode(i32, .s16, &loud, &clipped);
    try testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, clipped[0..2], .little));
    try testing.expectEqual(@as(i16, -32768), std.mem.readInt(i16, clipped[2..4], .little));
}

test "every format decodes its own extremes to the same three numbers" {
    inline for ([_]Format{ .u8, .s16, .s24, .s32, .f32, .f64 }) |format| {
        const samples = [_]f64{ -1.0, 0.0, 1.0 };
        var bytes: [samples.len * 8]u8 = undefined;
        const width = format.bytesPerSample();
        _ = encode(f64, format, &samples, bytes[0 .. samples.len * width]);

        var out: [samples.len]f64 = undefined;
        _ = decode(f64, format, bytes[0 .. samples.len * width], &out);

        try testing.expectEqual(@as(f64, -1.0), out[0]);
        try testing.expectEqual(@as(f64, 0.0), out[1]);
        // +1 is one step short of full scale everywhere but the float
        // formats, which hold it exactly.
        if (format.isFloat()) {
            try testing.expectEqual(@as(f64, 1.0), out[2]);
        } else {
            const step = 1.0 / @as(f64, @floatFromInt(@as(i64, 1) << @intCast(format.bitsPerSample() - 1)));
            try testing.expectApproxEqAbs(@as(f64, 1.0), out[2], step);
            try testing.expect(out[2] < 1.0);
        }
    }
}

test "an 8 bit file is unsigned and centred on 128" {
    const bytes = [_]u8{ 0, 128, 255 };
    var out: [3]f32 = undefined;
    _ = decode(f32, .u8, &bytes, &out);
    try testing.expectEqual(@as(f32, -1.0), out[0]);
    try testing.expectEqual(@as(f32, 0.0), out[1]);
    try testing.expect(out[2] > 0.99 and out[2] < 1.0);
}

test "decoding what was encoded is a fixed point" {
    // Every value a 16 bit file can hold, out and back. This is the property
    // the fuzz target checks over arbitrary bytes; here it is exhaustive.
    var i: i32 = -32768;
    while (i <= 32767) : (i += 1) {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(i16, &bytes, @intCast(i), .little);

        var as_float: [1]f32 = undefined;
        _ = decode(f32, .s16, &bytes, &as_float);
        var again: [2]u8 = undefined;
        _ = encode(f32, .s16, &as_float, &again);
        try testing.expectEqualSlices(u8, &bytes, &again);
    }
}
