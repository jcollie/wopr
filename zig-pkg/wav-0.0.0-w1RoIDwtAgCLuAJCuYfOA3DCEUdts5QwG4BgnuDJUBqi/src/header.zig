// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What a WAVE file says about the samples in it, and the 44 bytes that say
//! it.

const std = @import("std");
const Writer = std.Io.Writer;

const format_mod = @import("format.zig");
const Format = format_mod.Format;

/// What a WAVE file says its samples are: the same description whether it was
/// read out of a file or is about to be written into one.
pub const Header = struct {
    sample_rate: u32,
    channels: u16,
    format: Format,
    /// Frames — interchannel samples — in the `data` chunk, if that is known.
    ///
    /// `null` means it is not: the stream is endless, or is going somewhere
    /// that cannot be seeked back to afterwards, or was read from a file
    /// whose length fields were never filled in. The two length fields are
    /// then written as `0xFFFFFFFF`, which is the convention for a WAVE
    /// stream of indefinite length: a player reads until the pipe closes
    /// rather than stopping at a length that was a guess.
    frames: ?u64 = null,

    /// Bytes per frame: one sample in each channel.
    pub fn blockAlign(h: Header) u32 {
        return @as(u32, h.channels) * h.format.bytesPerSample();
    }

    /// Bytes per second of audio, which is what the header calls the average
    /// byte rate and what a player sizes its buffers from.
    pub fn byteRate(h: Header) u32 {
        return h.sample_rate *% h.blockAlign();
    }

    /// The size of the `data` chunk, when `frames` says what it is.
    pub fn dataBytes(h: Header) ?u64 {
        return (h.frames orelse return null) * h.blockAlign();
    }
};

/// The value both length fields carry when the length is not known.
pub const unknown_length: u32 = 0xFFFF_FFFF;

/// The size of the header `render` and `writeHeader` produce: the `RIFF`
/// chunk, a 16 byte `fmt ` chunk, and the `data` chunk's own header.
pub const header_size = 44;

/// Where the `RIFF` chunk's length field sits, for a caller who could not
/// know the length in advance and can seek back to put it right.
pub const riff_size_offset = 4;
/// Where the `data` chunk's length field sits, likewise.
pub const data_size_offset = 40;

/// The two length fields, for a caller writing them back over a header that
/// was written before the length was known.
pub const Sizes = struct {
    /// Goes at `riff_size_offset`.
    riff: u32,
    /// Goes at `data_size_offset`.
    data: u32,
};

/// What the length fields of `h` should say, or `null` where they cannot say
/// anything true — the length is unknown, or is past what a `u32` of bytes
/// can count.
///
/// A `data` chunk of odd length is followed by a pad byte. That byte is not
/// counted in the chunk's own length and *is* counted in the file's, which is
/// the one place in a WAVE file where the two lengths are not a fixed
/// distance apart — and getting it wrong makes a file that a strict reader
/// refuses, since the chunk then claims one byte more than the file holding
/// it has left. `Writer.finish` is what writes that byte.
pub fn sizes(h: Header) ?Sizes {
    const data = std.math.cast(u32, h.dataBytes() orelse return null) orelse return null;
    const pad: u32 = data & 1;
    if (data > std.math.maxInt(u32) - (header_size - 8) - pad) return null;
    return .{ .riff = data + pad + header_size - 8, .data = data };
}

/// Render the 44 byte header into `buf`.
///
/// The header is the canonical one — `WAVE_FORMAT_PCM` or
/// `WAVE_FORMAT_IEEE_FLOAT` in sixteen bytes of `fmt `, and nothing between
/// it and the samples — rather than the extensible header the specification
/// asks for above two channels or sixteen bits. It is what every player
/// reads, and it is a fixed 44 bytes, which is what lets a stream going to a
/// pipe be written without knowing anything about what follows.
pub fn render(h: Header, buf: *[header_size]u8) void {
    const block_align = h.blockAlign();
    const data_bytes: u32 = if (sizes(h)) |s| s.data else unknown_length;
    const riff_size: u32 = if (sizes(h)) |s| s.riff else unknown_length;

    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], riff_size, .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], h.format.tag(), .little);
    std.mem.writeInt(u16, buf[22..24], h.channels, .little);
    std.mem.writeInt(u32, buf[24..28], h.sample_rate, .little);
    std.mem.writeInt(u32, buf[28..32], h.byteRate(), .little);
    std.mem.writeInt(u16, buf[32..34], @truncate(block_align), .little);
    std.mem.writeInt(u16, buf[34..36], h.format.bitsPerSample(), .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_bytes, .little);
}

/// Write the 44 byte header.
pub fn writeHeader(w: *Writer, h: Header) Writer.Error!void {
    var buf: [header_size]u8 = undefined;
    render(h, &buf);
    try w.writeAll(&buf);
}

const testing = std.testing;

test "the header describes what follows it" {
    var buf: [header_size]u8 = undefined;
    render(.{ .sample_rate = 44100, .channels = 2, .format = .s16, .frames = 100 }, &buf);

    try testing.expectEqualStrings("RIFF", buf[0..4]);
    try testing.expectEqualStrings("WAVE", buf[8..12]);
    try testing.expectEqualStrings("fmt ", buf[12..16]);
    try testing.expectEqualStrings("data", buf[36..40]);
    try testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, buf[16..20], .little));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[20..22], .little));
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, buf[22..24], .little));
    try testing.expectEqual(@as(u32, 44100), std.mem.readInt(u32, buf[24..28], .little));
    try testing.expectEqual(@as(u32, 44100 * 4), std.mem.readInt(u32, buf[28..32], .little));
    try testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, buf[32..34], .little));
    try testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, buf[34..36], .little));
    try testing.expectEqual(@as(u32, 400), std.mem.readInt(u32, buf[40..44], .little));
    try testing.expectEqual(@as(u32, 400 + 36), std.mem.readInt(u32, buf[4..8], .little));
}

test "an endless stream declares itself as one" {
    var buf: [header_size]u8 = undefined;
    render(.{ .sample_rate = 48000, .channels = 1, .format = .f32 }, &buf);
    try testing.expectEqual(unknown_length, std.mem.readInt(u32, buf[4..8], .little));
    try testing.expectEqual(unknown_length, std.mem.readInt(u32, buf[40..44], .little));
    try testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, buf[20..22], .little));
    try testing.expectEqual(@as(u16, 32), std.mem.readInt(u16, buf[34..36], .little));
}

test "a length too big for the field falls back to declaring it unknown" {
    // Nine hours of 24 bit stereo at 96 kHz is past 4 GiB, which the field
    // cannot hold. Saying "unknown" is honest; truncating the count is not.
    const h: Header = .{
        .sample_rate = 96000,
        .channels = 2,
        .format = .s24,
        .frames = 96000 * 3600 * 9,
    };
    try testing.expectEqual(@as(?Sizes, null), sizes(h));

    var buf: [header_size]u8 = undefined;
    render(h, &buf);
    try testing.expectEqual(unknown_length, std.mem.readInt(u32, buf[40..44], .little));
    try testing.expectEqual(unknown_length, std.mem.readInt(u32, buf[4..8], .little));
}

test "an odd data chunk is one byte longer than it says, in the file's length" {
    // The pad byte: not in the chunk's own length, in the file's. Five bytes
    // of eight bit mono is the smallest thing that shows it.
    const h: Header = .{ .sample_rate = 8000, .channels = 1, .format = .u8, .frames = 5 };
    const s = sizes(h).?;
    try testing.expectEqual(@as(u32, 5), s.data);
    try testing.expectEqual(@as(u32, 5 + 1 + header_size - 8), s.riff);

    // And an even one is exactly the header apart, as everything else is.
    const even: Header = .{ .sample_rate = 8000, .channels = 1, .format = .u8, .frames = 6 };
    const t = sizes(even).?;
    try testing.expectEqual(@as(u32, 6), t.data);
    try testing.expectEqual(@as(u32, 6 + header_size - 8), t.riff);
}

test "the offsets are where the length fields are" {
    var buf: [header_size]u8 = undefined;
    const h: Header = .{ .sample_rate = 8000, .channels = 1, .format = .u8, .frames = 3 };
    render(h, &buf);
    const s = sizes(h).?;
    try testing.expectEqual(s.riff, std.mem.readInt(u32, buf[riff_size_offset..][0..4], .little));
    try testing.expectEqual(s.data, std.mem.readInt(u32, buf[data_size_offset..][0..4], .little));
    try testing.expectEqual(@as(u32, 3), s.data);
}

test "a header knows its own arithmetic" {
    const h: Header = .{ .sample_rate = 48000, .channels = 6, .format = .s24, .frames = 10 };
    try testing.expectEqual(@as(u32, 18), h.blockAlign());
    try testing.expectEqual(@as(u32, 48000 * 18), h.byteRate());
    try testing.expectEqual(@as(?u64, 180), h.dataBytes());
    try testing.expectEqual(@as(?u64, null), (Header{
        .sample_rate = 48000,
        .channels = 1,
        .format = .s16,
    }).dataBytes());
}
