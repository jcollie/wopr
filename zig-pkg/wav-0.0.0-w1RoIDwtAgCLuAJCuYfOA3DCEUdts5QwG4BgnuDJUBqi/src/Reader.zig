// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Reads a WAVE file out of a `std.Io.Reader`.
//!
//! `init` walks the chunks as far as the samples and stops there, so the
//! bytes after it are the audio and nothing else. Chunks that are not `fmt `
//! or `data` — `LIST`, `fact`, `JUNK`, whatever a recorder felt like adding —
//! are stepped over, along with the pad byte an odd-length chunk carries and
//! does not count.
//!
//! The walk itself is `zig-riff`'s: the twelve byte header, the chunk
//! boundaries, the pad byte and the nesting are the container's business
//! rather than this library's, and WAVE is one of the forms built on that
//! container. What is left here is what makes a WAVE a WAVE — the `fmt `
//! chunk, and the samples in `data`.
//!
//! ```zig
//! var file: std.Io.Reader = .fixed(bytes);
//! var wav: wav.Reader = try .init(&file);
//!
//! var samples: [4096]f32 = undefined;
//! while (true) {
//!     const n = try wav.read(f32, &samples);
//!     if (n == 0) break;
//!     consume(samples[0..n]);
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const riff = @import("riff");

const format_mod = @import("format.zig");
const header_mod = @import("header.zig");
const Format = format_mod.Format;
const Header = header_mod.Header;

const Reader = @This();

/// Where the bytes come from. Positioned at the first sample once `init` has
/// returned.
input: *std.Io.Reader,
/// What the `fmt ` and `data` chunks said. `header.frames` is `null` where
/// the `data` chunk did not state a length it could state.
header: Header,
/// Frames not yet read, where the length is known; `null` where it is not and
/// reading runs to the end of the stream instead.
remaining: ?u64,

pub const Error = error{
    /// See the underlying `std.Io.Reader` for detailed diagnostics.
    ReadFailed,
    /// Not a RIFF file, or a RIFF file that is not a WAVE — an `AVI `, say.
    NotWave,
    /// A `RIFX` file: RIFF with every length the other way round. The form
    /// says `WAVE`, but a WAVE's own fields and samples are little-endian by
    /// definition, so this is a different format rather than this one
    /// byte-swapped, and it is refused by name rather than misread.
    Rifx,
    /// An RF64 or BW64 file: a WAVE past four gigabytes, whose real lengths
    /// live in a `ds64` chunk. Also refused by name.
    Rf64,
    /// A WAVE file that contradicts itself: a `fmt ` chunk too short to hold
    /// a format, no channels, `data` before `fmt `, no `data` at all, a chunk
    /// claiming more than the file holding it, or a `data` chunk shorter than
    /// the length it declared.
    MalformedWave,
    /// A format this library does not decode: A-law, µ-law, ADPCM, an
    /// extensible header whose sub-format is not PCM, or a width no PCM
    /// format has.
    UnsupportedFormat,
};

/// What `zig-riff` says, in this library's words.
fn container(err: riff.Error) Error {
    return switch (err) {
        error.NotRiff => error.NotWave,
        error.Rf64 => error.Rf64,
        // A length that runs past the file holding it, or nesting too deep to
        // be a WAVE at all.
        error.InvalidData => error.MalformedWave,
        // Everything up to the first sample was promised by the bytes in
        // front of it, so a stream that ends inside the headers is a
        // malformed file rather than an ending.
        error.EndOfStream => error.MalformedWave,
        error.ReadFailed => error.ReadFailed,
    };
}

/// The rest of the `KSDATAFORMAT_SUBTYPE_*` GUIDs, after the two bytes that
/// hold the format tag. Every subtype the specification defines shares it, so
/// a GUID that does not end this way is some other vendor's and the tag in
/// front of it means nothing.
const subformat_suffix = "\x00\x00\x00\x00\x10\x00\x80\x00\x00\xAA\x00\x38\x9B\x71";

/// Read as far as the first sample.
pub fn init(input: *std.Io.Reader) Error!Reader {
    var file: riff.Reader = riff.Reader.init(input) catch |err| return container(err);
    if (!file.form.is("WAVE")) return error.NotWave;
    if (file.order == .big) return error.Rifx;

    var described: ?Header = null;
    while (file.next() catch |err| return container(err)) |chunk| {
        if (chunk.is("fmt ")) {
            described = try readFmt(&file, chunk);
        } else if (chunk.is("data")) {
            var h = described orelse return error.MalformedWave;
            // Zero and all ones both mean "this was written to something that
            // could not be seeked back to". A genuinely empty `data` chunk is
            // indistinguishable from the first of those, and reading it to
            // the end of the stream finds nothing, which is the same answer.
            const unknown = chunk.len == 0 or chunk.len == header_mod.unknown_length;
            h.frames = if (unknown) null else chunk.len / h.blockAlign();
            // The walk stops here. What is left of the stream is the samples,
            // and they are read straight out of it rather than through the
            // container, because there is nothing after `data` that this
            // library wants and a bounded reader would only be a second
            // accounting of the same bytes.
            return .{ .input = input, .header = h, .remaining = h.frames };
        }
        // Anything else -- `LIST`, `fact`, `JUNK` -- is stepped over by the
        // next `next`, pad byte and all.
    }
    // The chunks ran out without one of them being the samples.
    return error.MalformedWave;
}

/// Read interleaved samples into `out` as `S`, which is `f32`, `f64` or
/// `i32`; see `isSampleType` for what each of those means.
///
/// Returns how many values were written, which is always a whole number of
/// frames and is short only at the end of the audio. A partial frame at the
/// end of a stream that never said how long it was is not a frame and is
/// dropped; where the `data` chunk did state a length, a stream that ends
/// before delivering it is `error.MalformedWave` rather than an ending.
pub fn read(r: *Reader, comptime S: type, out: []S) Error!usize {
    const channels = r.header.channels;
    const width = r.header.format.bytesPerSample();
    const available: u64 = if (r.remaining) |rem| rem else std.math.maxInt(u64);
    const wanted: usize = @intCast(@min(out.len / channels, available) * channels);

    // Divisible by every sample width there is, so a chunk is always a whole
    // number of samples and only the frame boundary has to be thought about.
    var buf: [4032]u8 = undefined;
    const per_chunk = buf.len / width;

    var produced: usize = 0;
    var short = false;
    while (produced < wanted) {
        const n = @min(per_chunk, wanted - produced);
        const got = r.input.readSliceShort(buf[0 .. n * width]) catch return error.ReadFailed;
        const decoded = got / width;
        _ = format_mod.decode(S, r.header.format, buf[0 .. decoded * width], out[produced..][0..decoded]);
        produced += decoded;
        if (decoded < n) {
            short = true;
            break;
        }
    }

    // What is left over is part of a frame rather than one, whatever was
    // decoded into `out` past this point.
    const frames = produced / channels;
    if (short and r.remaining != null) return error.MalformedWave;
    if (r.remaining) |*rem| rem.* -= frames;
    return frames * channels;
}

/// Read the whole of the audio, allocating as it goes.
///
/// `max_frames` bounds what an untrusted file can make this allocate: a
/// `data` chunk may declare four gigabytes and deliver nothing, so the
/// declared length is a hint for the first allocation and never a promise.
/// What it bounds is *frames*, so the memory it allows is that many times
/// `header.channels` times the width of `S` -- and the channel count is the
/// file's to choose, up to 65535. A caller sizing a limit against how much
/// memory it has divides by `header.channels`, which `init` has already read
/// by the time this can be called.
/// Reading stops at `max_frames` without complaint, so a caller that needs to
/// know whether there was more asks for one frame more than it will accept.
///
/// The caller owns the returned slice.
pub fn readAlloc(
    r: *Reader,
    gpa: Allocator,
    comptime S: type,
    max_frames: usize,
) (Error || Allocator.Error)![]S {
    const channels = r.header.channels;
    var list: std.ArrayList(S) = .empty;
    errdefer list.deinit(gpa);

    if (r.remaining) |rem| {
        // Saturating, because a declared length of four gigabytes times a
        // channel count of sixty thousand is not a number of samples: the
        // allocation then fails as an error rather than wrapping into a
        // small one that everything afterwards writes past.
        const hint: usize = @intCast(@min(rem, max_frames));
        try list.ensureTotalCapacityPrecise(gpa, hint *| @as(usize, channels));
    }

    while (list.items.len / channels < max_frames) {
        const left: usize = max_frames - list.items.len / channels;
        // A file that said how long it is gets asked for the rest of itself
        // in one go, since the capacity for exactly that was reserved above.
        // One that did not is read in batches, because the alternative is to
        // believe a length that is not there.
        //
        // Both halves are annotated `usize` on purpose. `@min` against a
        // literal narrows its result to the smallest type that can hold it --
        // a thirteen bit one, for a bound of 4096 -- and the multiplication
        // that follows would then be done in that width and overflow at a few
        // hundred channels.
        const batch: usize = if (r.remaining) |rem|
            @intCast(@min(@as(u64, left), rem))
        else
            @min(left, 4096);
        if (batch == 0) break;
        const want: usize = batch * channels;
        const dest = try list.addManyAsSlice(gpa, want);
        const got = try r.read(S, dest);
        list.shrinkRetainingCapacity(list.items.len - (want - got));
        if (got < want) break;
    }
    return list.toOwnedSlice(gpa);
}

/// The `fmt ` chunk: sixteen bytes that every WAVE has, and twenty-four more
/// that an extensible one adds.
///
/// Whatever else the chunk holds is left where it is. A `fmt ` chunk is often
/// eighteen bytes rather than sixteen — two of them an extension size of zero
/// — and stepping over the remainder, and over the pad byte if the length was
/// odd, is the container's job rather than this function's.
fn readFmt(file: *riff.Reader, chunk: riff.Chunk) Error!Header {
    if (chunk.len < 16) return error.MalformedWave;
    var head: [16]u8 = undefined;
    file.readSome(&head) catch |err| return container(err);

    var tag = std.mem.readInt(u16, head[0..2], .little);
    const channels = std.mem.readInt(u16, head[2..4], .little);
    const sample_rate = std.mem.readInt(u32, head[4..8], .little);
    // Bytes 8 to 14 are the average byte rate and the block alignment, both
    // derivable from the four fields around them. A file whose copies
    // disagree is far more common than one where they are the truth, so they
    // are read past rather than believed.
    const bits = std.mem.readInt(u16, head[14..16], .little);

    if (tag == format_mod.format_extensible) {
        // Two bytes of extension size, then twenty-two of extension: the
        // valid bit count, the channel mask, and a sixteen byte sub-format
        // GUID whose first two bytes are the tag the header would have
        // carried had it not been extensible.
        if (chunk.len < 40) return error.MalformedWave;
        var extension: [24]u8 = undefined;
        file.readSome(&extension) catch |err| return container(err);

        // Bytes 0 to 2 are the extension size, and 2 to 4 the valid bit
        // count, which may be less than the container's width -- a 20 bit
        // recording in 24 bit words. The container's width is what is read,
        // since the low bits of such a sample are zero and reading them costs
        // nothing. Bytes 4 to 8 are the channel mask, which says which
        // speaker each channel is for; nothing here has anywhere to put it.
        tag = std.mem.readInt(u16, extension[8..10], .little);
        if (!std.mem.eql(u8, extension[10..24], subformat_suffix)) {
            return error.UnsupportedFormat;
        }
    }

    if (channels == 0) return error.MalformedWave;
    const format = Format.fromTag(tag, bits) orelse return error.UnsupportedFormat;
    return .{ .sample_rate = sample_rate, .channels = channels, .format = format };
}

const testing = std.testing;
const writeHeader = header_mod.writeHeader;

test "a file this library wrote is one it can read" {
    const h: Header = .{ .sample_rate = 44100, .channels = 2, .format = .s24, .frames = 3 };
    const samples = [_]i32{ 0, -1, 8388607, -8388608, 1234567, -7654321 };

    var buffer: [header_mod.header_size + samples.len * 3]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try writeHeader(&w, h);
    var encoded: [samples.len * 3]u8 = undefined;
    try w.writeAll(format_mod.encode(i32, .s24, &samples, &encoded));

    var input: std.Io.Reader = .fixed(&buffer);
    var r: Reader = try .init(&input);
    try testing.expectEqual(h, r.header);

    var out: [samples.len]i32 = undefined;
    try testing.expectEqual(@as(usize, samples.len), try r.read(i32, &out));
    try testing.expectEqualSlices(i32, &samples, &out);
    try testing.expectEqual(@as(?u64, 0), r.remaining);
    try testing.expectEqual(@as(usize, 0), try r.read(i32, &out));
}

test "chunks in the way are stepped over, and an extensible header is understood" {
    // A `JUNK` chunk of odd length before `fmt `, an extensible format chunk,
    // a `LIST` after it, and then the data: everything a real file does that
    // the simple path does not cover.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("RIFF");
    try w.writeInt(u32, 0, .little);
    try w.writeAll("WAVE");

    try w.writeAll("JUNK");
    try w.writeInt(u32, 5, .little);
    try w.writeAll("INFO\x00");
    try w.writeByte(0); // the pad byte an odd chunk needs

    try w.writeAll("fmt ");
    try w.writeInt(u32, 40, .little);
    try w.writeInt(u16, format_mod.format_extensible, .little);
    try w.writeInt(u16, 6, .little);
    try w.writeInt(u32, 48000, .little);
    try w.writeInt(u32, 48000 * 12, .little);
    try w.writeInt(u16, 12, .little);
    try w.writeInt(u16, 16, .little);
    try w.writeInt(u16, 22, .little); // extension size
    try w.writeInt(u16, 16, .little); // valid bits
    try w.writeInt(u32, 0x3F, .little); // 5.1 channel mask
    try w.writeInt(u16, format_mod.format_pcm, .little);
    try w.writeAll(subformat_suffix);

    try w.writeAll("LIST");
    try w.writeInt(u32, 4, .little);
    try w.writeAll("INFO");

    try w.writeAll("data");
    try w.writeInt(u32, 24, .little);
    for (0..12) |i| try w.writeInt(i16, @intCast(i), .little);

    var input: std.Io.Reader = .fixed(out.written());
    var r: Reader = try .init(&input);
    try testing.expectEqual(@as(u32, 48000), r.header.sample_rate);
    try testing.expectEqual(@as(u16, 6), r.header.channels);
    try testing.expectEqual(Format.s16, r.header.format);
    try testing.expectEqual(@as(?u64, 2), r.header.frames);

    var samples: [12]i32 = undefined;
    try testing.expectEqual(@as(usize, 12), try r.read(i32, &samples));
    try testing.expectEqualSlices(i32, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }, &samples);
}

test "a sub-format GUID that is not one of the standard ones is refused" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("RIFF\x00\x00\x00\x00WAVEfmt ");
    try w.writeInt(u32, 40, .little);
    try w.writeInt(u16, format_mod.format_extensible, .little);
    try w.writeInt(u16, 2, .little);
    try w.writeInt(u32, 44100, .little);
    try w.writeInt(u32, 44100 * 4, .little);
    try w.writeInt(u16, 4, .little);
    try w.writeInt(u16, 16, .little);
    try w.writeInt(u16, 22, .little);
    try w.writeInt(u16, 16, .little);
    try w.writeInt(u32, 3, .little);
    try w.writeInt(u16, format_mod.format_pcm, .little);
    // The tag says PCM and the GUID says somebody else's format. The GUID is
    // the one that means anything.
    try w.writeAll("\x00\x00\x00\x00\x10\x00\x80\x00\x00\xAA\x00\x38\x9B\x72");

    var input: std.Io.Reader = .fixed(out.written());
    try testing.expectError(error.UnsupportedFormat, Reader.init(&input));
}

test "a data chunk with no usable size reads to the end of the stream" {
    // What a WAVE file written to a pipe looks like: the length fields could
    // not be filled in afterwards, so they say all ones.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const w = &out.writer;
    try writeHeader(w, .{ .sample_rate = 44100, .channels = 2, .format = .s16 });
    for ([_]i16{ 1, -1, 2, -2, 3, -3 }) |sample| try w.writeInt(i16, sample, .little);
    // And half a frame, which is not a frame.
    try w.writeInt(i16, 99, .little);

    var input: std.Io.Reader = .fixed(out.written());
    var r: Reader = try .init(&input);
    try testing.expectEqual(@as(?u64, null), r.header.frames);
    try testing.expectEqual(@as(?u64, null), r.remaining);

    var samples: [16]i32 = undefined;
    try testing.expectEqual(@as(usize, 6), try r.read(i32, &samples));
    try testing.expectEqualSlices(i32, &.{ 1, -1, 2, -2, 3, -3 }, samples[0..6]);
    try testing.expectEqual(@as(usize, 0), try r.read(i32, &samples));
}

test "a file that ends inside its stated data is truncated" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeHeader(&out.writer, .{
        .sample_rate = 44100,
        .channels = 2,
        .format = .s16,
        .frames = 4,
    });
    try out.writer.writeInt(i16, 1, .little);

    var input: std.Io.Reader = .fixed(out.written());
    var r: Reader = try .init(&input);
    var samples: [8]i32 = undefined;
    try testing.expectError(error.MalformedWave, r.read(i32, &samples));
}

test "reading the whole thing at once" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeHeader(&out.writer, .{
        .sample_rate = 8000,
        .channels = 1,
        .format = .u8,
        .frames = 5,
    });
    try out.writer.writeAll(&[_]u8{ 0, 64, 128, 192, 255 });

    var input: std.Io.Reader = .fixed(out.written());
    var r: Reader = try .init(&input);
    const samples = try r.readAlloc(testing.allocator, f32, 1024);
    defer testing.allocator.free(samples);
    try testing.expectEqual(@as(usize, 5), samples.len);
    try testing.expectEqual(@as(f32, -1.0), samples[0]);
    try testing.expectEqual(@as(f32, 0.0), samples[2]);

    // And with a limit below what the file holds, which stops early rather
    // than complaining.
    var again: std.Io.Reader = .fixed(out.written());
    var r2: Reader = try .init(&again);
    const some = try r2.readAlloc(testing.allocator, f32, 2);
    defer testing.allocator.free(some);
    try testing.expectEqual(@as(usize, 2), some.len);
}

test "a declared length far past what the file holds allocates nothing like it" {
    // The `data` chunk claims four gigabytes of samples and delivers eight
    // bytes. `max_frames` is what stops a file like this from being an
    // allocation of its own choosing.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("RIFF\x00\x00\x00\x00WAVEfmt ");
    try w.writeInt(u32, 16, .little);
    try w.writeInt(u16, format_mod.format_pcm, .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u32, 44100, .little);
    try w.writeInt(u32, 88200, .little);
    try w.writeInt(u16, 2, .little);
    try w.writeInt(u16, 16, .little);
    try w.writeAll("data");
    try w.writeInt(u32, 0xFFFF_FFFE, .little);
    try w.writeAll(&[_]u8{ 1, 0, 2, 0, 3, 0, 4, 0 });

    var input: std.Io.Reader = .fixed(out.written());
    var r: Reader = try .init(&input);
    try testing.expectError(error.MalformedWave, r.readAlloc(testing.allocator, i32, 64));
}

test "files that are not WAVE files are refused" {
    var not_riff: std.Io.Reader = .fixed("fLaC\x00\x00\x00\x22");
    try testing.expectError(error.NotWave, Reader.init(&not_riff));

    var not_wave: std.Io.Reader = .fixed("RIFF\x08\x00\x00\x00AVI ");
    try testing.expectError(error.NotWave, Reader.init(&not_wave));

    var empty: std.Io.Reader = .fixed("");
    try testing.expectError(error.NotWave, Reader.init(&empty));

    // RIFX is the same layout with every field the other way round, which is
    // a different format rather than this one read sideways -- so it is
    // refused by name.
    var rifx: std.Io.Reader = .fixed("RIFX\x00\x00\x00\x24WAVEfmt \x00\x00\x00\x10");
    try testing.expectError(error.Rifx, Reader.init(&rifx));

    // And RF64, which is a WAVE past four gigabytes and whose real lengths
    // are in a chunk this library does not read.
    var rf64: std.Io.Reader = .fixed("RF64\xff\xff\xff\xffWAVEds64\x1c\x00\x00\x00");
    try testing.expectError(error.Rf64, Reader.init(&rf64));

    // A WAVE whose format chunk is too short to be one.
    var stunted: std.Io.Reader = .fixed("RIFF\x14\x00\x00\x00WAVEfmt \x08\x00\x00\x00\x01\x00\x02\x00\x44\xAC\x00\x00");
    try testing.expectError(error.MalformedWave, Reader.init(&stunted));

    // A WAVE with no data chunk at all.
    var headless: std.Io.Writer.Allocating = .init(testing.allocator);
    defer headless.deinit();
    try headless.writer.writeAll("RIFF\x00\x00\x00\x00WAVEfmt ");
    try headless.writer.writeInt(u32, 16, .little);
    try headless.writer.writeInt(u16, format_mod.format_pcm, .little);
    try headless.writer.writeInt(u16, 1, .little);
    try headless.writer.writeInt(u32, 8000, .little);
    try headless.writer.writeInt(u32, 16000, .little);
    try headless.writer.writeInt(u16, 2, .little);
    try headless.writer.writeInt(u16, 16, .little);
    var input: std.Io.Reader = .fixed(headless.written());
    try testing.expectError(error.MalformedWave, Reader.init(&input));
}

test "a format nothing here decodes is refused by name" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("RIFF\x00\x00\x00\x00WAVEfmt ");
    try w.writeInt(u32, 16, .little);
    try w.writeInt(u16, 0x0007, .little); // µ-law
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u32, 8000, .little);
    try w.writeInt(u32, 8000, .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u16, 8, .little);
    var input: std.Io.Reader = .fixed(out.written());
    try testing.expectError(error.UnsupportedFormat, Reader.init(&input));
}

test "a data chunk before the format chunk is malformed" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.writeAll("RIFF\x00\x00\x00\x00WAVEdata\x04\x00\x00\x00\x01\x02\x03\x04");
    var input: std.Io.Reader = .fixed(out.written());
    try testing.expectError(error.MalformedWave, Reader.init(&input));
}
