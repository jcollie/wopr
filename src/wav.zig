// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Just enough of RIFF/WAVE to put a stream of samples somewhere a player
//! will accept it.
//!
//! This reads nothing and supports one chunk layout: a 44 byte canonical
//! header followed by one `data` chunk. That is all `wopr` emits and all
//! anything needs to consume it.

const std = @import("std");
const Writer = std.Io.Writer;

/// How samples are laid out in the `data` chunk.
pub const Format = enum {
    /// 16 bit signed, little-endian. What everything reads.
    s16,
    /// 24 bit signed, little-endian, packed three bytes to a sample.
    s24,
    /// 32 bit IEEE float, little-endian, nominally in [-1, 1].
    f32,

    pub fn bytesPerSample(f: Format) u8 {
        return switch (f) {
            .s16 => 2,
            .s24 => 3,
            .f32 => 4,
        };
    }

    /// The `wFormatTag` the header carries: 1 for integer PCM, 3 for float.
    fn tag(f: Format) u16 {
        return switch (f) {
            .s16, .s24 => 1,
            .f32 => 3,
        };
    }
};

pub const Header = struct {
    sample_rate: u32,
    channels: u8,
    format: Format,
    /// The number of frames the `data` chunk will hold, if it is known.
    ///
    /// `null` means it is not — the stream is endless, or is going somewhere
    /// that cannot be seeked back to afterwards. The two length fields are
    /// then written as `0xFFFFFFFF`, which is the convention for a WAVE
    /// stream of indefinite length: a player reads until the pipe closes
    /// rather than stopping at a length that was a guess. Players that
    /// insist on a real length want a file, and a file has a `frames`.
    frames: ?u64 = null,
};

pub const unknown_length: u32 = 0xFFFF_FFFF;

/// The fixed size of what `writeHeader` emits.
pub const header_size = 44;

/// Render the 44 byte header into `buf`.
pub fn header(h: Header, buf: *[header_size]u8) void {
    const block_align: u32 = @as(u32, h.channels) * h.format.bytesPerSample();
    const byte_rate: u32 = h.sample_rate * block_align;
    const data_bytes: u32 = if (h.frames) |n|
        std.math.cast(u32, n * block_align) orelse unknown_length
    else
        unknown_length;
    const riff_size: u32 = if (data_bytes == unknown_length)
        unknown_length
    else
        data_bytes + header_size - 8;

    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], riff_size, .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], h.format.tag(), .little);
    std.mem.writeInt(u16, buf[22..24], h.channels, .little);
    std.mem.writeInt(u32, buf[24..28], h.sample_rate, .little);
    std.mem.writeInt(u32, buf[28..32], byte_rate, .little);
    std.mem.writeInt(u16, buf[32..34], @intCast(block_align), .little);
    std.mem.writeInt(u16, buf[34..36], @as(u16, h.format.bytesPerSample()) * 8, .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_bytes, .little);
}

pub fn writeHeader(w: *Writer, h: Header) Writer.Error!void {
    var buf: [header_size]u8 = undefined;
    header(h, &buf);
    try w.writeAll(&buf);
}

/// Convert `in` to `format` and write the bytes.
///
/// Samples outside [-1, 1] are clipped rather than wrapped, for the integer
/// formats. Wrapping a sample that went a hair over full scale turns a
/// moment of loudness into a full-scale discontinuity, which is a click; the
/// hum is a continuous signal, so a clipped sample is inaudible and a wrapped
/// one is the only thing anybody would hear.
pub fn writeSamples(w: *Writer, format: Format, in: []const f32) Writer.Error!void {
    var buf: [1024 * 4]u8 = undefined;
    const per = format.bytesPerSample();
    const chunk = buf.len / per;

    var i: usize = 0;
    while (i < in.len) {
        const n = @min(chunk, in.len - i);
        const bytes = encode(format, in[i..][0..n], buf[0 .. n * per]);
        try w.writeAll(bytes);
        i += n;
    }
}

/// Convert `in` into `out`, which must be exactly
/// `in.len * format.bytesPerSample()` bytes. Returns `out`.
pub fn encode(format: Format, in: []const f32, out: []u8) []u8 {
    std.debug.assert(out.len == in.len * format.bytesPerSample());
    switch (format) {
        .s16 => for (in, 0..) |s, i| {
            std.mem.writeInt(i16, out[i * 2 ..][0..2], quantize(i16, s), .little);
        },
        .s24 => for (in, 0..) |s, i| {
            // No i24 slot in the output, so the low three bytes of an i32
            // are written by hand. Little-endian puts them first.
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(i32, &tmp, quantize(i24, s), .little);
            @memcpy(out[i * 3 ..][0..3], tmp[0..3]);
        },
        .f32 => for (in, 0..) |s, i| {
            std.mem.writeInt(u32, out[i * 4 ..][0..4], @bitCast(s), .little);
        },
    }
    return out;
}

/// Scale a float sample to a signed integer of `T`, saturating.
///
/// Full scale is the negative extreme, `-(2^(n-1))`, because that is the
/// value an integer of `n` bits actually has; +1.0 therefore maps one step
/// short of the positive extreme rather than one step past it, which is what
/// wraps.
fn quantize(comptime T: type, sample: f32) T {
    const scale: f32 = -@as(f32, std.math.minInt(T));
    const v = @round(std.math.clamp(sample, -1, 1) * scale);
    return @intFromFloat(std.math.clamp(v, std.math.minInt(T), std.math.maxInt(T)));
}

test "header describes what follows it" {
    var buf: [header_size]u8 = undefined;
    header(.{ .sample_rate = 44100, .channels = 2, .format = .s16, .frames = 100 }, &buf);

    try std.testing.expectEqualStrings("RIFF", buf[0..4]);
    try std.testing.expectEqualStrings("WAVE", buf[8..12]);
    try std.testing.expectEqualStrings("fmt ", buf[12..16]);
    try std.testing.expectEqualStrings("data", buf[36..40]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[20..22], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, buf[22..24], .little));
    try std.testing.expectEqual(@as(u32, 44100), std.mem.readInt(u32, buf[24..28], .little));
    try std.testing.expectEqual(@as(u32, 44100 * 4), std.mem.readInt(u32, buf[28..32], .little));
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, buf[32..34], .little));
    try std.testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, buf[34..36], .little));
    try std.testing.expectEqual(@as(u32, 400), std.mem.readInt(u32, buf[40..44], .little));
    try std.testing.expectEqual(@as(u32, 400 + 36), std.mem.readInt(u32, buf[4..8], .little));
}

test "an endless stream declares itself as one" {
    var buf: [header_size]u8 = undefined;
    header(.{ .sample_rate = 48000, .channels = 1, .format = .f32 }, &buf);
    try std.testing.expectEqual(unknown_length, std.mem.readInt(u32, buf[4..8], .little));
    try std.testing.expectEqual(unknown_length, std.mem.readInt(u32, buf[40..44], .little));
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, buf[20..22], .little));
    try std.testing.expectEqual(@as(u16, 32), std.mem.readInt(u16, buf[34..36], .little));
}

test "a length too big for the field falls back to declaring it unknown" {
    // Nine hours of 24 bit stereo at 96 kHz is past 4 GiB, which the field
    // cannot hold. Saying "unknown" is honest; truncating the count is not.
    var buf: [header_size]u8 = undefined;
    header(.{ .sample_rate = 96000, .channels = 2, .format = .s24, .frames = 96000 * 3600 * 9 }, &buf);
    try std.testing.expectEqual(unknown_length, std.mem.readInt(u32, buf[40..44], .little));
}

test "quantising saturates instead of wrapping" {
    try std.testing.expectEqual(@as(i16, -32768), quantize(i16, -1.0));
    try std.testing.expectEqual(@as(i16, 32767), quantize(i16, 1.0));
    try std.testing.expectEqual(@as(i16, -32768), quantize(i16, -4.0));
    try std.testing.expectEqual(@as(i16, 32767), quantize(i16, 4.0));
    try std.testing.expectEqual(@as(i16, 0), quantize(i16, 0.0));
    try std.testing.expectEqual(@as(i24, -8388608), quantize(i24, -1.0));
    try std.testing.expectEqual(@as(i24, 8388607), quantize(i24, 1.0));
}

test "encoding round-trips through each format" {
    const in = [_]f32{ 0.0, 0.5, -0.5, 1.0, -1.0 };

    var s16: [in.len * 2]u8 = undefined;
    _ = encode(.s16, &in, &s16);
    try std.testing.expectEqual(@as(i16, 16384), std.mem.readInt(i16, s16[2..4], .little));
    try std.testing.expectEqual(@as(i16, -16384), std.mem.readInt(i16, s16[4..6], .little));

    var s24: [in.len * 3]u8 = undefined;
    _ = encode(.s24, &in, &s24);
    try std.testing.expectEqual(@as(i24, 4194304), std.mem.readInt(i24, s24[3..6], .little));

    var f: [in.len * 4]u8 = undefined;
    _ = encode(.f32, &in, &f);
    try std.testing.expectEqual(@as(f32, -0.5), @as(f32, @bitCast(std.mem.readInt(u32, f[8..12], .little))));
}
