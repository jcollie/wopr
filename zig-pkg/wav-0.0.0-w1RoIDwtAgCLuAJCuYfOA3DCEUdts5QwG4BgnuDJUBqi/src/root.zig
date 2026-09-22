// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Reads and writes RIFF/WAVE files.
//!
//! It is sans-IO: `Reader` takes a `std.Io.Reader` and `Writer` takes a
//! `std.Io.Writer`, so a file, a socket, a pipe and a slice of memory are all
//! the same thing to it. It allocates nothing unless asked to — `readAlloc`
//! is the only function here that takes an allocator.
//!
//! The container is `zig-riff`'s and not this library's. RIFF is what a WAVE
//! file *is* — twelve bytes of header, then chunks with their lengths and
//! their pad bytes — and WAVE is one of the forms built on it, alongside AVI
//! and WebP. So the chunk walk lives there, this lives here, and what is here
//! is only what makes a WAVE a WAVE: the `fmt ` chunk, the samples in `data`,
//! and the conversion between those samples and numbers.
//!
//! ```zig
//! const wav = @import("wav");
//!
//! var input: std.Io.Reader = .fixed(bytes);
//! var file: wav.Reader = try .init(&input);
//! const samples = try file.readAlloc(gpa, f32, 48_000 * 60);
//! defer gpa.free(samples);
//!
//! var out: wav.Writer = try .init(sink, .{
//!     .sample_rate = file.header.sample_rate,
//!     .channels = file.header.channels,
//!     .format = .s16,
//!     .frames = samples.len / file.header.channels,
//! });
//! try out.write(f32, samples);
//! try out.finish();
//! ```
//!
//! Samples come out and go in as `f32`, `f64` or `i32`, whatever the file
//! holds. The float types are normalized so that full scale is ±1, which is
//! what a signal processing path wants; `i32` is the sample exactly as the
//! file holds it, which is what a lossless path wants. `isSampleType` says
//! what each means in full.
//!
//! ## What is understood
//!
//! Integer PCM at 8, 16, 24 and 32 bits, and IEEE float at 32 and 64, in a
//! plain `WAVE_FORMAT_PCM` or `WAVE_FORMAT_IEEE_FLOAT` header or in a
//! `WAVE_FORMAT_EXTENSIBLE` one carrying either of those as its sub-format.
//! Chunks that are neither `fmt ` nor `data` are stepped over. A `data` chunk
//! whose length was never filled in — which is what a WAVE file written to a
//! pipe looks like, and what ffmpeg writes byte for byte — is read to the end
//! of the stream.
//!
//! ## What is not
//!
//! The compressed payloads: A-law, µ-law, ADPCM and the rest of the tag
//! registry. The big-endian `RIFX` container, whose lengths are the other way
//! round while a WAVE's own fields are little-endian by definition. RF64 and
//! BW64, which is how a file longer than four gigabytes says so. Each of
//! those is refused by name — `error.UnsupportedFormat`, `error.Rifx`,
//! `error.Rf64` — rather than misread. What is written is always the canonical 44 byte header,
//! so a file with more than two channels is written without the channel mask
//! that would have said which speaker each one is for, and a file read with
//! one loses it.

const format_mod = @import("format.zig");
const header_mod = @import("header.zig");
const writer_mod = @import("Writer.zig");

/// Reading a WAVE file.
pub const Reader = @import("Reader.zig");
/// Writing one.
pub const Writer = writer_mod;

/// How samples are laid out in the `data` chunk.
pub const Format = format_mod.Format;
/// What a WAVE file says about the samples in it.
pub const Header = header_mod.Header;
/// The two length fields of a header, for a caller that is patching them.
pub const Sizes = header_mod.Sizes;

/// Which sample types `encode`, `decode`, `Reader.read` and `Writer.write`
/// speak, and what each of them means.
pub const isSampleType = format_mod.isSampleType;
/// Samples in a `data` chunk, as numbers.
pub const decode = format_mod.decode;
/// Numbers, as samples in a `data` chunk.
pub const encode = format_mod.encode;

/// Render the 44 byte header into a buffer.
pub const render = header_mod.render;
/// Write the 44 byte header.
pub const writeHeader = header_mod.writeHeader;
/// Convert samples and write them, without a `Writer` in between.
pub const writeSamples = writer_mod.writeSamples;
/// What the length fields of a header should say.
pub const sizes = header_mod.sizes;

/// The size of the header this library writes.
pub const header_size = header_mod.header_size;
/// Where the `RIFF` chunk's length field sits within it.
pub const riff_size_offset = header_mod.riff_size_offset;
/// Where the `data` chunk's length field sits within it.
pub const data_size_offset = header_mod.data_size_offset;
/// What both length fields carry when the length is not known.
pub const unknown_length = header_mod.unknown_length;

/// `WAVE_FORMAT_PCM`.
pub const format_pcm = format_mod.format_pcm;
/// `WAVE_FORMAT_IEEE_FLOAT`.
pub const format_ieee_float = format_mod.format_ieee_float;
/// `WAVE_FORMAT_EXTENSIBLE`.
pub const format_extensible = format_mod.format_extensible;

test {
    // Reaches the files above so that `zig build test` runs every test in the
    // module rather than only the ones written here.
    @import("std").testing.refAllDecls(@This());
    _ = Reader;
    _ = Writer;
    _ = format_mod;
    _ = header_mod;
}

test "a file, out and back" {
    const std = @import("std");
    const testing = std.testing;

    const frames = 480;
    var samples: [frames * 2]f32 = undefined;
    for (0..frames) |i| {
        const phase = @as(f32, @floatFromInt(i)) / 48.0;
        samples[i * 2] = @sin(phase);
        samples[i * 2 + 1] = @cos(phase);
    }

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var w: Writer = try .init(&out.writer, .{
        .sample_rate = 48000,
        .channels = 2,
        .format = .s24,
        .frames = frames,
    });
    try w.write(f32, &samples);
    try w.finish();

    var input: std.Io.Reader = .fixed(out.written());
    var r: Reader = try .init(&input);
    try testing.expectEqual(@as(u32, 48000), r.header.sample_rate);
    try testing.expectEqual(@as(u16, 2), r.header.channels);
    try testing.expectEqual(Format.s24, r.header.format);
    try testing.expectEqual(@as(?u64, frames), r.header.frames);

    const back = try r.readAlloc(testing.allocator, f32, frames);
    defer testing.allocator.free(back);
    try testing.expectEqual(samples.len, back.len);
    // 24 bits is a step of about 1.2e-7, so a sample is back to within one.
    for (samples, back) |before, after| {
        try testing.expectApproxEqAbs(before, after, 1.0 / 8388608.0);
    }
}
