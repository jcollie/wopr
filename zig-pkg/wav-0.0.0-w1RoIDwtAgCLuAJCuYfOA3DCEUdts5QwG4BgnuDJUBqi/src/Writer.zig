// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Writes a WAVE file into a `std.Io.Writer`.
//!
//! `init` writes the header, `write` writes samples, and that is the whole of
//! it: what comes out is a 44 byte canonical header followed by one `data`
//! chunk, which is what every player reads and what a pipe can carry.
//!
//! ```zig
//! var file: std.Io.Writer = ...;
//! var out: wav.Writer = try .init(&file, .{
//!     .sample_rate = 48_000,
//!     .channels = 2,
//!     .format = .s16,
//!     .frames = frames.len / 2,
//! });
//! try out.write(f32, frames);
//! try out.finish();
//! ```
//!
//! A caller that did not know the length in advance and is writing somewhere
//! it can seek puts the two length fields right afterwards, from `sizes`:
//!
//! ```zig
//! if (out.sizes()) |s| {
//!     try file.seekTo(wav.riff_size_offset);
//!     try file.writer().writeInt(u32, s.riff, .little);
//!     try file.seekTo(wav.data_size_offset);
//!     try file.writer().writeInt(u32, s.data, .little);
//! }
//! ```

const std = @import("std");

const format_mod = @import("format.zig");
const header_mod = @import("header.zig");
const Format = format_mod.Format;
const Header = header_mod.Header;

const Writer = @This();

/// Where the bytes go.
output: *std.Io.Writer,
/// What was written into the header. `header.frames` is what the header
/// *claims*; `samples` is what has actually been handed over.
header: Header,
/// Samples written so far, counting every channel.
samples: u64,
/// Whether `finish` has already written the pad byte, so that calling it
/// twice cannot write two.
finished: bool = false,

pub const Error = std.Io.Writer.Error;

/// Write the header. Nothing about `h` is checked against what is written
/// afterwards, since a stream of indefinite length is a thing worth writing.
pub fn init(output: *std.Io.Writer, h: Header) Error!Writer {
    try header_mod.writeHeader(output, h);
    return .{ .output = output, .header = h, .samples = 0 };
}

/// Write interleaved samples, converting them to the file's format.
///
/// `S` is `f32`, `f64` or `i32`; see `isSampleType` for what each of those
/// means. Samples past the format's range are clipped rather than wrapped.
pub fn write(w: *Writer, comptime S: type, samples: []const S) Error!void {
    try writeSamples(w.output, S, w.header.format, samples);
    w.samples += samples.len;
}

/// Write the pad byte that an odd-length `data` chunk needs, and nothing
/// where it does not need one.
///
/// A RIFF chunk is padded to an even length. The pad byte is not counted in
/// the chunk's own length and *is* counted in the file's, which is what
/// `sizes` reports — so a file whose samples come to an odd number of bytes
/// and which never gets this byte is one byte shorter than it says it is, and
/// a strict reader is right to complain. Whether one is needed is known only
/// once the writing has stopped, which is why this is a call of its own.
///
/// Only eight bit audio, and a 24 bit mono file with an odd number of frames,
/// can land on an odd length at all — but "only sometimes wrong" is the worst
/// kind of wrong, so calling this is how a file ends. It is safe to call
/// whatever was written, and safe to call twice.
pub fn finish(w: *Writer) Error!void {
    if (w.finished) return;
    w.finished = true;
    if (w.bytesWritten() & 1 != 0) try w.output.writeByte(0);
}

/// Sample bytes written so far, not counting the header or the pad byte.
pub fn bytesWritten(w: *const Writer) u64 {
    return w.samples * w.header.format.bytesPerSample();
}

/// Frames written so far. A caller that wrote a number of samples that is not
/// a whole number of frames has written a file nothing can play, and this is
/// where that shows.
pub fn framesWritten(w: *const Writer) u64 {
    return w.samples / w.header.channels;
}

/// What the two length fields should say for what has actually been written,
/// or `null` where they cannot say anything true — the audio is longer than a
/// `u32` of bytes can count.
pub fn sizes(w: *const Writer) ?header_mod.Sizes {
    var h = w.header;
    h.frames = w.framesWritten();
    return header_mod.sizes(h);
}

/// Convert `samples` to `format` and write the bytes, without a `Writer` in
/// between. What `Writer.write` is built on, and what a caller who is
/// managing the container itself wants.
pub fn writeSamples(
    output: *std.Io.Writer,
    comptime S: type,
    format: Format,
    samples: []const S,
) Error!void {
    // Divisible by every sample width there is, so a chunk is always a whole
    // number of samples.
    var buf: [4032]u8 = undefined;
    const width = format.bytesPerSample();
    const per_chunk = buf.len / width;

    var i: usize = 0;
    while (i < samples.len) {
        const n = @min(per_chunk, samples.len - i);
        try output.writeAll(format_mod.encode(S, format, samples[i..][0..n], buf[0 .. n * width]));
        i += n;
    }
}

const testing = std.testing;

test "the writer writes a header and then the samples" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var w: Writer = try .init(&out.writer, .{
        .sample_rate = 44100,
        .channels = 2,
        .format = .s16,
        .frames = 2,
    });
    try w.write(f32, &.{ 0.0, -1.0, 1.0, 0.5 });

    try testing.expectEqual(@as(u64, 2), w.framesWritten());
    try testing.expectEqual(header_mod.header_size + 8, out.written().len);
    try testing.expectEqualStrings("RIFF", out.written()[0..4]);
    try testing.expectEqual(
        @as(i16, -32768),
        std.mem.readInt(i16, out.written()[header_mod.header_size + 2 ..][0..2], .little),
    );
}

test "the sizes a writer reports are the ones for what it wrote" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    // The header said nothing about the length, which is what a stream going
    // to a pipe looks like.
    var w: Writer = try .init(&out.writer, .{
        .sample_rate = 8000,
        .channels = 1,
        .format = .u8,
    });
    try testing.expectEqual(header_mod.unknown_length, std.mem.readInt(
        u32,
        out.written()[header_mod.data_size_offset..][0..4],
        .little,
    ));

    try w.write(i32, &.{ 0, 1, 2, 3, 4 });
    // Five bytes of eight bit mono: an odd chunk, so the file is a pad byte
    // longer than the chunk, and `finish` is what writes it.
    try w.finish();
    const s = w.sizes().?;
    try testing.expectEqual(@as(u32, 5), s.data);
    try testing.expectEqual(@as(u32, 5 + 1 + header_mod.header_size - 8), s.riff);
    try testing.expectEqual(header_mod.header_size + 6, out.written().len);

    // Which a caller that can seek writes back over the header.
    const bytes = out.written();
    std.mem.writeInt(u32, bytes[header_mod.riff_size_offset..][0..4], s.riff, .little);
    std.mem.writeInt(u32, bytes[header_mod.data_size_offset..][0..4], s.data, .little);

    var input: std.Io.Reader = .fixed(bytes);
    const r: @import("Reader.zig") = try .init(&input);
    try testing.expectEqual(@as(?u64, 5), r.header.frames);
}

test "the pad byte is written once, and only when it is needed" {
    // An even length needs none, however many times it is asked for.
    var even: std.Io.Writer.Allocating = .init(testing.allocator);
    defer even.deinit();
    var a: Writer = try .init(&even.writer, .{ .sample_rate = 8000, .channels = 2, .format = .s16 });
    try a.write(i32, &.{ 1, 2 });
    try a.finish();
    try a.finish();
    try testing.expectEqual(header_mod.header_size + 4, even.written().len);

    // An odd one needs exactly one, however many times it is asked for.
    var odd: std.Io.Writer.Allocating = .init(testing.allocator);
    defer odd.deinit();
    var b: Writer = try .init(&odd.writer, .{ .sample_rate = 8000, .channels = 1, .format = .u8 });
    try b.write(i32, &.{ 1, 2, 3 });
    try b.finish();
    try b.finish();
    try testing.expectEqual(header_mod.header_size + 4, odd.written().len);
    try testing.expectEqual(@as(u8, 0), odd.written()[header_mod.header_size + 3]);
}

test "writing in pieces is the same as writing at once" {
    const samples = [_]f32{ 0.1, -0.2, 0.3, -0.4, 0.5, -0.6, 0.7, -0.8 };

    var whole: std.Io.Writer.Allocating = .init(testing.allocator);
    defer whole.deinit();
    var a: Writer = try .init(&whole.writer, .{ .sample_rate = 8000, .channels = 2, .format = .s24 });
    try a.write(f32, &samples);

    var pieces: std.Io.Writer.Allocating = .init(testing.allocator);
    defer pieces.deinit();
    var b: Writer = try .init(&pieces.writer, .{ .sample_rate = 8000, .channels = 2, .format = .s24 });
    for (0..samples.len) |i| try b.write(f32, samples[i..][0..1]);

    try testing.expectEqualSlices(u8, whole.written(), pieces.written());
    try testing.expectEqual(a.samples, b.samples);
}

test "a chunk boundary is not a sample boundary" {
    // More samples than the internal buffer holds at every width, so that a
    // width whose samples do not divide the buffer would show up as a
    // misplaced byte rather than passing on a short write.
    inline for ([_]Format{ .u8, .s16, .s24, .s32, .f32, .f64 }) |format| {
        const count = 5000;
        var samples: [count]f32 = undefined;
        for (&samples, 0..) |*s, i| s.* = @as(f32, @floatFromInt(i % 200)) / 200.0 - 0.5;

        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var w: Writer = try .init(&out.writer, .{
            .sample_rate = 48000,
            .channels = 1,
            .format = format,
            .frames = count,
        });
        try w.write(f32, &samples);

        var input: std.Io.Reader = .fixed(out.written());
        var r: @import("Reader.zig") = try .init(&input);
        var back: [count]f32 = undefined;
        try testing.expectEqual(@as(usize, count), try r.read(f32, &back));

        // Every format here holds at least eight bits, so a value that came
        // from a two hundredth of full scale survives to within that.
        for (samples, back) |before, after| {
            try testing.expectApproxEqAbs(before, after, 1.0 / 128.0);
        }
    }
}
