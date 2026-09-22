// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Reads a WAVE file with this library and writes it back out, so that
//! another implementation can be asked whether the two agree.
//!
//! `tools/crosscheck.sh` is what drives it: ffmpeg writes a file at each
//! width, this reads it and writes a copy, and ffmpeg decodes both to raw
//! `f64` and compares. A difference anywhere — a width read as another width,
//! a sign convention, an eight bit file read as signed, a header field
//! written where nothing looks for it — shows up as two hashes that are not
//! the same.
//!
//! It is also the shortest complete example of using the library, which is
//! why it is worth reading:
//!
//!     zig build crosscheck              # the whole comparison
//!     ./wav-crosscheck in.wav out.wav   # one file, by hand

const std = @import("std");
const Io = std.Io;
const wav = @import("wav");

/// What a file is allowed to be, in bytes and in frames. A cross-check runs
/// on a second of audio; anything past these is somebody pointing this at
/// something it was not meant for.
const max_bytes: usize = 1 << 28;
const max_frames: usize = 1 << 24;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout.interface;

    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 3) {
        try out.writeAll("usage: wav-crosscheck <in.wav> <out.wav>\n");
        try out.flush();
        std.process.exit(2);
    }

    const bytes = try Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(max_bytes));
    var input: Io.Reader = .fixed(bytes);
    var file: wav.Reader = try .init(&input);

    try out.print("{s}: {d} Hz, {d} ch, {t}, frames {?d}\n", .{
        args[1],
        file.header.sample_rate,
        file.header.channels,
        file.header.format,
        file.header.frames,
    });
    try out.flush();

    // An integer file goes round as `i32` and a float file as `f64`, because
    // those are the types that hold what the file holds exactly. Reading an
    // integer file as a float would be a rounding, and reading a float file
    // as an integer would be a quantisation; either would make the comparison
    // a test of the conversion rather than of the container.
    const written = switch (file.header.format) {
        .u8, .s16, .s24, .s32 => try copy(i32, gpa, &file),
        .f32, .f64 => try copy(f64, gpa, &file),
    };
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = written });
}

fn copy(comptime S: type, gpa: std.mem.Allocator, file: *wav.Reader) ![]u8 {
    const samples = try file.readAlloc(gpa, S, max_frames);
    defer gpa.free(samples);

    var written: Io.Writer.Allocating = .init(gpa);
    var w: wav.Writer = try .init(&written.writer, .{
        .sample_rate = file.header.sample_rate,
        .channels = file.header.channels,
        .format = file.header.format,
        .frames = samples.len / file.header.channels,
    });
    try w.write(S, samples);
    // The pad byte, where the samples came to an odd number of bytes. ffmpeg
    // writes one and counts it in the file's length, and a file that skips it
    // is a byte shorter than it says it is.
    try w.finish();

    // Which is worth checking here rather than trusting: what was written has
    // to be as long as it says it is, and the RIFF length counts everything
    // after the eight bytes of its own chunk header. An odd-length `data`
    // chunk is the only place where that arithmetic has anything in it, and
    // it is exactly the place this library had wrong.
    if (w.sizes()) |declared| {
        if (@as(u64, declared.riff) + 8 != written.written().len) return error.LengthDisagrees;
    }
    return written.toOwnedSlice();
}
