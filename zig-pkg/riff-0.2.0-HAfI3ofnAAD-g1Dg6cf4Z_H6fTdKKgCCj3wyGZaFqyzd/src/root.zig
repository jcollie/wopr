// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! RIFF: the Resource Interchange File Format, which is a container and not a
//! format.
//!
//! A file is twelve bytes of header — `RIFF`, a length, and a four-character
//! *form type* saying what kind of file this is — and then a sequence of
//! chunks, each of which is a four-character identifier, a length, and that
//! many bytes. That is the whole of it, and it is the shape underneath WAV
//! (`WAVE`), AVI (`AVI `), WebP (`WEBP`), DLS, RMID and a good deal else.
//!
//! ```zig
//! var reader: riff.Reader = try .init(&stream);
//! if (!reader.form.is("WEBP")) return error.NotWebp;
//! while (try reader.next()) |chunk| {
//!     if (chunk.is("VP8L")) {
//!         var buf: [64]u8 = undefined;
//!         try decodeSomething(reader.payload(&buf));
//!     }
//!     // Anything not read here is skipped by the next `next`.
//! }
//! ```
//!
//! Sans-I/O: everything reads through a caller-supplied `std.Io.Reader` and
//! writes through a `std.Io.Writer`, so nothing here opens a file, and a
//! chunk walk over a network stream is the same code as one over memory.
//!
//! ## The pad byte
//!
//! **A chunk is padded to an even length, and the pad byte is not counted in
//! the chunk's length.** This is the single most common way to write a RIFF
//! parser that works on most files and desynchronises on some, because a file
//! whose chunks all happen to have even lengths never exercises it. Every
//! length here is handled through `Chunk.padded`, and the walker skips the
//! pad byte for the caller.
//!
//! ## Nesting
//!
//! A `LIST` chunk holds a four-character list type and then more chunks, and
//! that is how AVI stores almost everything. `enter` descends into one and
//! `next` climbs back out when it runs out, so a caller writes one loop and
//! not a recursive one:
//!
//! ```zig
//! while (try reader.next()) |chunk| {
//!     if (chunk.is("LIST")) {
//!         const kind = try reader.enter();
//!         if (kind.is("movi")) { ... }
//!     }
//! }
//! ```
//!
//! ## Byte order
//!
//! Almost every RIFF file is little-endian and begins `RIFF`. The
//! big-endian variant begins `RIFX` and is rare but real, and costs one
//! branch to support, so it is supported. The identifiers themselves are
//! characters and are never byte-swapped, which is a thing that is easy to
//! get wrong when adding the second order to a parser that only had the
//! first.
//!
//! ## Lengths that were never filled in
//!
//! A writer that cannot seek backwards cannot know what to put in the file's
//! length field, or in the length of the chunk it is still writing. The
//! convention is to write `0xffffffff` and let the end of the stream say
//! where things stop — which is what ffmpeg does when its output is a pipe —
//! and several encoders leave the file's length at zero instead. Both are
//! read here as "not known": the walk is then bounded by the stream, and a
//! chunk whose length was never filled in runs to the end of whatever holds
//! it. `unknown_length` is that value, and `Chunk.isUnknownLength` is how a
//! caller tells such a chunk from one that really is four gigabytes.
//!
//! ## What is deliberately not here
//!
//! **RF64**, the WAV extension for files past four gigabytes, which replaces
//! the `RIFF` tag, writes `0xffffffff` where the length goes, and puts the
//! real 64-bit sizes in a `ds64` chunk. It is recognised and refused by name
//! — `error.Rf64` — rather than being read as a corrupt RIFF, because a
//! caller that meets one should be told what it is.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const math = std.math;
const testing = std.testing;
const Allocator = mem.Allocator;

/// A four-character identifier: a chunk's name, a file's form type, a list's
/// type.
///
/// Four bytes of ASCII, space-padded — `AVI ` and `VP8 ` both end in one, and
/// a comparison that trims it will match things it should not.
pub const FourCc = extern struct {
    bytes: [4]u8,

    pub fn init(name: *const [4]u8) FourCc {
        return .{ .bytes = name.* };
    }

    pub fn is(self: FourCc, name: *const [4]u8) bool {
        return mem.eql(u8, &self.bytes, name);
    }

    pub fn eql(self: FourCc, other: FourCc) bool {
        return mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Prints the four characters, with anything unprintable as a dot, so
    /// that a mangled identifier in an error message is still readable.
    pub fn format(self: FourCc, w: *Io.Writer) Io.Writer.Error!void {
        for (self.bytes) |b| {
            try w.writeByte(if (b >= 0x20 and b < 0x7f) b else '.');
        }
    }
};

/// Which way round the lengths are.
pub const ByteOrder = enum {
    /// `RIFF`. Everything, practically speaking.
    little,
    /// `RIFX`. Rare, and real.
    big,

    fn endian(self: ByteOrder) std.builtin.Endian {
        return switch (self) {
            .little => .little,
            .big => .big,
        };
    }
};

pub const Error = error{
    /// The stream does not begin with a RIFF header.
    NotRiff,
    /// An RF64 file: a WAV past four gigabytes, whose real sizes live in a
    /// `ds64` chunk. Named rather than read as a broken RIFF.
    Rf64,
    /// A length that runs past the end of the container holding it, a `LIST`
    /// too short to hold its own type, or nesting deeper than `max_depth`.
    InvalidData,
} || Io.Reader.Error;

/// What a level's remaining byte count holds when it has no bound but the
/// end of the stream. Subtracting from it saturates rather than wrapping, and
/// `Io.Limit.limited64` reads a count this large as `.unlimited`, so it
/// behaves as "everything" in both of the places it is used.
const unbounded: u64 = math.maxInt(u64);

/// How many levels of `LIST` may be open at once.
///
/// The file itself is one, so this allows seven nested lists inside it. AVI,
/// which is the format that actually nests, uses three.
pub const max_depth = 8;

/// The length a writer that could not seek backwards puts in a field it was
/// unable to fill in.
///
/// Four gigabytes minus one is not a length any real chunk has -- a RIFF file
/// that big is the thing RF64 exists for -- so it is unambiguous as a marker,
/// and it is what ffmpeg writes into both the file's length and the `data`
/// chunk's when its output is a pipe.
pub const unknown_length: u32 = 0xffff_ffff;

/// One chunk's identifier and payload length.
pub const Chunk = struct {
    id: FourCc,
    /// The payload, not counting the pad byte. `unknown_length` where the
    /// writer could not fill it in, which `isUnknownLength` is the way to
    /// ask about.
    len: u32,

    pub fn is(self: Chunk, name: *const [4]u8) bool {
        return self.id.is(name);
    }

    /// Whether this chunk's length was never filled in, and it therefore runs
    /// to the end of whatever holds it.
    pub fn isUnknownLength(self: Chunk) bool {
        return self.len == unknown_length;
    }

    /// The payload plus its pad byte, which is what a walk has to step over.
    ///
    /// Meaningless for a chunk whose length is unknown: what such a chunk has
    /// to step over is the rest of the container, which only the walk knows.
    pub fn padded(self: Chunk) u64 {
        return @as(u64, self.len) + (self.len & 1);
    }
};

/// Whether `bytes` begins a RIFF file of the given form.
///
/// Twelve bytes, and the signature is in two halves with the file's length
/// between them — which is why this is a function rather than a prefix
/// comparison, and why a caller detecting formats by signature needs it.
pub fn looksLike(bytes: []const u8, form: *const [4]u8) bool {
    if (bytes.len < 12) return false;
    if (!mem.eql(u8, bytes[0..4], "RIFF") and !mem.eql(u8, bytes[0..4], "RIFX")) return false;
    return mem.eql(u8, bytes[8..12], form);
}

/// Whether a window too short to decide could still turn out to be one.
///
/// What makes a small peek usable: a caller can tell "not this" from "not
/// yet", and ask for more bytes only in the second case.
pub fn couldBe(bytes: []const u8, form: *const [4]u8) bool {
    const head = @min(bytes.len, 4);
    if (!mem.eql(u8, bytes[0..head], "RIFF"[0..head]) and
        !mem.eql(u8, bytes[0..head], "RIFX"[0..head])) return false;
    if (bytes.len <= 8) return true;
    const tail = @min(bytes.len - 8, 4);
    return mem.eql(u8, bytes[8..][0..tail], form[0..tail]);
}

/// Walks the chunks of a RIFF stream.
///
/// Forward only, like the stream underneath it. A chunk is returned by `next`
/// and its payload is then the caller's to read, ignore, or descend into;
/// whatever is left of it is stepped over by the following `next`, pad byte
/// and all.
pub const Reader = struct {
    source: *Io.Reader,
    order: ByteOrder,
    /// What kind of file this is: `WAVE`, `AVI `, `WEBP`.
    form: FourCc,

    /// Bytes still unread at each open level, innermost last. Level zero is
    /// the file itself. `unbounded` where a length was never filled in and
    /// the end of the stream is what says where the level stops.
    left: [max_depth]u64 = @splat(0),
    depth: usize = 1,
    /// The chunk `next` returned, with its payload not yet stepped over.
    pending: ?Chunk = null,
    /// How much of the pending chunk has been read already.
    consumed: u64 = 0,
    /// The bounded reader `payload` handed out, kept here so that whatever it
    /// took can be put back into the accounting without the caller having to
    /// say. Live only between `payload` and the following `next`, which is
    /// also the only window in which this `Reader` must not be moved: a
    /// bounded reader finds its own state by the address of its interface.
    bounded: ?Io.Reader.Limited = null,
    /// What that bounded reader was given, so that what is left of it says
    /// what it took.
    bounded_from: u64 = 0,

    /// Reads the twelve-byte header.
    pub fn init(source: *Io.Reader) Error!Reader {
        var head: [12]u8 = undefined;
        source.readSliceAll(&head) catch |err| switch (err) {
            error.EndOfStream => return error.NotRiff,
            error.ReadFailed => |e| return e,
        };

        if (mem.eql(u8, head[0..4], "RF64")) return error.Rf64;
        const order: ByteOrder = if (mem.eql(u8, head[0..4], "RIFF"))
            .little
        else if (mem.eql(u8, head[0..4], "RIFX"))
            .big
        else
            return error.NotRiff;

        // The declared length covers the form type and everything after it.
        // Files exist whose header length is wrong --- a recorder that was
        // killed before it could go back and fix it writes one every time ---
        // so this is a bound and not a promise: the walk also stops at the
        // end of the stream.
        //
        // Zero and `unknown_length` are not wrong lengths but absent ones:
        // they are what a writer puts there when its output is a pipe and it
        // can never come back to fix the number. Believing either would end
        // the walk before the first chunk, so the file is bounded by the
        // stream instead.
        const declared = mem.readInt(u32, head[4..8], order.endian());
        var self: Reader = .{
            .source = source,
            .order = order,
            .form = .init(head[8..12]),
        };
        self.left[0] = if (declared == 0 or declared == unknown_length)
            unbounded
        else if (declared >= 4)
            declared - 4
        else
            0;
        return self;
    }

    /// The next chunk at this level, or null at the end of the file.
    ///
    /// Anything left of the previous chunk is skipped first, so a caller may
    /// read as much or as little of a payload as it likes. Climbing out of a
    /// `LIST` that has run out happens here too, which is what lets one loop
    /// walk a nested file.
    pub fn next(self: *Reader) Error!?Chunk {
        self.reconcile();
        if (self.pending) |chunk| {
            self.pending = null;
            // A chunk whose length was never filled in is the rest of the
            // level, so stepping over it is stepping over everything that is
            // left --- which, where the level is itself unbounded, is the
            // rest of the stream and the end of the walk.
            const read = if (chunk.isUnknownLength())
                self.left[self.depth - 1]
            else
                chunk.padded() - self.consumedOf(chunk);
            try self.discard(read);
        }

        while (true) {
            // A level with less than a chunk header left in it is finished.
            // Trailing bytes there are padding or junk and are stepped over.
            if (self.left[self.depth - 1] < 8) {
                const slack = self.left[self.depth - 1];
                if (self.depth == 1) {
                    // Nothing more in the file. What is left of the stream
                    // past the declared length is not ours.
                    self.left[0] = 0;
                    return null;
                }
                try self.discard(slack);
                self.depth -= 1;
                continue;
            }

            var head: [8]u8 = undefined;
            self.source.readSliceAll(&head) catch |err| switch (err) {
                // A file that stops on a chunk boundary is complete enough:
                // the walk ends rather than failing, which is how a truncated
                // recording is still readable up to where it stops.
                error.EndOfStream => {
                    self.left[self.depth - 1] = 0;
                    if (self.depth == 1) return null;
                    self.depth -= 1;
                    continue;
                },
                error.ReadFailed => |e| return e,
            };
            self.take(8);

            const chunk: Chunk = .{
                .id = .init(head[0..4]),
                .len = mem.readInt(u32, head[4..8], self.order.endian()),
            };
            // A chunk claiming more than the container holding it has left is
            // a file contradicting itself, and believing it would walk off
            // the end of the parent. A chunk that claims nothing at all ---
            // one whose length was never filled in --- claims exactly what is
            // left, so there is nothing to contradict.
            if (!chunk.isUnknownLength() and chunk.padded() > self.left[self.depth - 1]) {
                return error.InvalidData;
            }

            self.pending = chunk;
            self.consumed = 0;
            return chunk;
        }
    }

    /// Descends into the pending chunk, which must be a `LIST`, and returns
    /// its list type.
    ///
    /// The chunks inside it then come out of `next` exactly like any others,
    /// and `next` climbs back out when they run out.
    pub fn enter(self: *Reader) Error!FourCc {
        const chunk = self.pending orelse return error.InvalidData;
        // A list is its four-character type and then chunks, so one that
        // cannot hold the type is malformed rather than empty.
        if (chunk.len < 4) return error.InvalidData;

        var kind: [4]u8 = undefined;
        try self.readExactly(&kind);
        try self.descend();
        return .init(&kind);
    }

    /// Descends into the pending chunk, treating whatever has already been
    /// read of it as its header and the rest as chunks.
    ///
    /// `enter` is this with a four-byte header, which is what a `LIST`
    /// carries — but **not every container is a `LIST`**. WebP's `ANMF` holds
    /// a sixteen-byte frame header and then chunks; the file itself is a
    /// four-byte form type and then chunks. A caller reads the header it
    /// knows about with `readSome` and then calls this, and the chunks inside
    /// come out of `next` like any others.
    pub fn descend(self: *Reader) Error!void {
        self.reconcile();
        const chunk = self.pending orelse return error.InvalidData;
        if (self.depth == max_depth) return error.InvalidData;

        const used: u32 = @intCast(@min(self.consumed, chunk.len));
        self.pending = null;
        self.left[self.depth] = chunk.len - used;
        self.depth += 1;
    }

    /// A reader bounded to what is left of the pending chunk's payload.
    ///
    /// `buffer` is the bounded reader's own read-ahead, and nothing it holds
    /// escapes the chunk: the bound is what stops a decoder handed this from
    /// reading into the chunk after it. Whatever it leaves is skipped by the
    /// next `next`, and how much it took is worked out from what is left of
    /// its bound rather than being reported by the caller — a bounded reader
    /// pulls bytes the walk would otherwise never see, and a walk that had to
    /// be told about them would desynchronise the first time somebody forgot.
    pub fn payload(self: *Reader, buffer: []u8) *Io.Reader {
        self.reconcile();
        const chunk = self.pending orelse {
            self.bounded_from = 0;
            self.bounded = self.source.limited(.nothing, buffer);
            return &self.bounded.?.interface;
        };
        // An unknown length is not a length: such a chunk runs to the end of
        // the level, and where that is unbounded too the reader handed out is
        // unbounded, since `Limit.limited64` reads a count that large as
        // exactly that.
        const remaining = if (chunk.isUnknownLength())
            self.left[self.depth - 1]
        else
            chunk.len - @min(self.consumed, chunk.len);
        self.bounded_from = remaining;
        self.bounded = self.source.limited(.limited64(remaining), buffer);
        return &self.bounded.?.interface;
    }

    /// Puts what a bounded payload reader took back into the accounting.
    fn reconcile(self: *Reader) void {
        const bounded = &(if (self.bounded) |*b| b else return).*;
        if (self.bounded_from == unbounded) {
            // The reader handed out had no bound, because the chunk's length
            // was never filled in and neither was its container's. What it
            // took cannot be measured and does not need to be: such a chunk
            // holds the rest of the stream, so however much of it was read,
            // the walk is over.
            self.bounded = null;
            self.bounded_from = 0;
            for (self.left[0..self.depth]) |*l| l.* = 0;
            return;
        }
        const left: u64 = bounded.remaining.toInt() orelse 0;
        const took = self.bounded_from - @min(self.bounded_from, left);
        self.bounded = null;
        self.bounded_from = 0;
        self.take(took);
        self.consumed += took;
    }

    /// Reads the whole of the pending chunk's payload into `buf`, which must
    /// be exactly its length.
    pub fn readAll(self: *Reader, buf: []u8) Error!void {
        const chunk = self.pending orelse return error.InvalidData;
        if (buf.len != chunk.len - @min(self.consumed, chunk.len)) return error.InvalidData;
        try self.readExactly(buf);
    }

    /// Reads part of the pending chunk's payload, for a caller that wants a
    /// fixed-size header out of a variable-length chunk.
    pub fn readSome(self: *Reader, buf: []u8) Error!void {
        const chunk = self.pending orelse return error.InvalidData;
        if (buf.len > chunk.len - @min(self.consumed, chunk.len)) return error.InvalidData;
        try self.readExactly(buf);
    }

    fn consumedOf(self: Reader, chunk: Chunk) u64 {
        return @min(self.consumed, chunk.padded());
    }

    fn readExactly(self: *Reader, buf: []u8) Error!void {
        self.source.readSliceAll(buf) catch |err| switch (err) {
            error.EndOfStream => return error.InvalidData,
            error.ReadFailed => |e| return e,
        };
        self.take(buf.len);
        self.consumed += buf.len;
    }

    fn discard(self: *Reader, n: u64) Error!void {
        if (n == 0) return;
        if (n == unbounded) {
            // Everything that is left, which is also the end of the walk.
            // `discardAll64` cannot be asked for a count this large: it adds
            // the count to the stream's seek position, and that overflows.
            // "The rest of the stream" is what `discardRemaining` is for.
            _ = self.source.discardRemaining() catch |err| switch (err) {
                error.ReadFailed => |e| return e,
            };
            for (self.left[0..self.depth]) |*l| l.* = 0;
            return;
        }
        self.source.discardAll64(n) catch |err| switch (err) {
            error.EndOfStream => {
                // Truncated. Everything open is finished.
                for (self.left[0..self.depth]) |*l| l.* = 0;
                return;
            },
            error.ReadFailed => |e| return e,
        };
        self.take(n);
    }

    /// Bytes consumed from the stream come out of every level at once, since
    /// the levels nest.
    ///
    /// A level with no bound but the end of the stream is not used up by
    /// reading: `unbounded` stays `unbounded`, so that it is still
    /// recognisable as "no bound" a thousand chunks later rather than being a
    /// merely enormous number that the arithmetic elsewhere would have to
    /// keep guessing about.
    fn take(self: *Reader, n: u64) void {
        for (self.left[0..self.depth]) |*l| {
            if (l.* == unbounded) continue;
            l.* -= @min(l.*, n);
        }
    }
};

/// Builds a RIFF file.
///
/// **Everything is held until `finish`, and it has to be.** The header
/// carries the length of everything after it and a `LIST` carries the length
/// of everything inside it, and neither is known until the thing is complete
/// — so a forward-only writer either buffers or seeks backwards, and this one
/// is sans-I/O and cannot seek.
pub const Writer = struct {
    form: FourCc,
    order: ByteOrder = .little,
    body: std.ArrayList(u8) = .empty,
    /// Where each open `LIST`'s length field sits in `body`, so that it can
    /// be filled in when the list is closed.
    open: [max_depth]usize = @splat(0),
    depth: usize = 0,

    pub const WriteError = error{
        /// More nesting than `max_depth`, or a `finish` with a list still
        /// open.
        InvalidNesting,
    } || Allocator.Error || Io.Writer.Error;

    pub fn init(form: *const [4]u8) Writer {
        return .{ .form = .init(form) };
    }

    pub fn deinit(self: *Writer, gpa: Allocator) void {
        self.body.deinit(gpa);
        self.* = undefined;
    }

    /// Appends a whole chunk.
    pub fn chunk(self: *Writer, gpa: Allocator, id: *const [4]u8, bytes: []const u8) WriteError!void {
        try self.header(gpa, id, @intCast(bytes.len));
        try self.body.appendSlice(gpa, bytes);
        // Even lengths, and the pad byte is not counted in the length above.
        if (bytes.len & 1 != 0) try self.body.append(gpa, 0);
    }

    /// Opens a `LIST`. Everything written until the matching `close` goes
    /// inside it.
    pub fn openList(self: *Writer, gpa: Allocator, kind: *const [4]u8) WriteError!void {
        if (self.depth == max_depth) return error.InvalidNesting;
        try self.body.appendSlice(gpa, "LIST");
        const at = self.body.items.len;
        try self.body.appendSlice(gpa, &.{ 0, 0, 0, 0 });
        try self.body.appendSlice(gpa, kind);
        self.open[self.depth] = at;
        self.depth += 1;
    }

    pub fn close(self: *Writer) WriteError!void {
        if (self.depth == 0) return error.InvalidNesting;
        self.depth -= 1;
        const at = self.open[self.depth];
        const len: u32 = @intCast(self.body.items.len - at - 4);
        mem.writeInt(u32, self.body.items[at..][0..4], len, self.order.endian());
        // A list is padded like any other chunk, and its own length does not
        // count the pad byte either.
        if (len & 1 != 0) try self.bodyAppendPad();
    }

    fn bodyAppendPad(self: *Writer) WriteError!void {
        _ = self;
        // Deliberately unreachable in the current shape: `chunk` pads every
        // chunk it writes, so a list's contents are always even. Kept as a
        // statement of the rule rather than removed, in case a future
        // `openList` gains a way to write unpadded bytes.
        return;
    }

    /// Writes the file out.
    pub fn finish(self: *Writer, w: *Io.Writer) WriteError!void {
        if (self.depth != 0) return error.InvalidNesting;
        try w.writeAll(if (self.order == .little) "RIFF" else "RIFX");
        var len: [4]u8 = undefined;
        mem.writeInt(u32, &len, @intCast(self.body.items.len + 4), self.order.endian());
        try w.writeAll(&len);
        try w.writeAll(&self.form.bytes);
        try w.writeAll(self.body.items);
    }

    fn header(self: *Writer, gpa: Allocator, id: *const [4]u8, len: u32) WriteError!void {
        try self.body.appendSlice(gpa, id);
        var raw: [4]u8 = undefined;
        mem.writeInt(u32, &raw, len, self.order.endian());
        try self.body.appendSlice(gpa, &raw);
    }
};

// -- tests -------------------------------------------------------------------

test "a four-character code keeps its spaces" {
    const avi: FourCc = .init("AVI ");
    try testing.expect(avi.is("AVI "));
    try testing.expect(!avi.is("AVIX"));

    var buf: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.print("{f}", .{FourCc.init("\x00VP8")});
    try testing.expectEqualStrings(".VP8", w.buffered());
}

test "the header is read and the form type comes back" {
    var stream: Io.Reader = .fixed("RIFF\x04\x00\x00\x00WEBP");
    var r: Reader = try .init(&stream);
    try testing.expect(r.form.is("WEBP"));
    try testing.expectEqual(ByteOrder.little, r.order);
    try testing.expectEqual(@as(?Chunk, null), try r.next());
}

test "a big-endian file reads its lengths the other way round" {
    var stream: Io.Reader = .fixed("RIFX\x00\x00\x00\x10WAVEfmt \x00\x00\x00\x04abcd");
    var r: Reader = try .init(&stream);
    try testing.expectEqual(ByteOrder.big, r.order);
    try testing.expect(r.form.is("WAVE"));

    const chunk = (try r.next()).?;
    // The identifiers are characters and are never swapped, whatever the
    // lengths do.
    try testing.expect(chunk.is("fmt "));
    try testing.expectEqual(@as(u32, 4), chunk.len);
}

test "a chunk of odd length is followed by a pad byte that is not in its length" {
    // Three bytes of payload, one of padding, and then a chunk that a parser
    // which forgot the pad byte would read one byte early.
    var stream: Io.Reader = .fixed(
        "RIFF\x1c\x00\x00\x00TEST" ++
            "one \x03\x00\x00\x00abc\x00" ++
            "two \x04\x00\x00\x00wxyz",
    );
    var r: Reader = try .init(&stream);

    const first = (try r.next()).?;
    try testing.expect(first.is("one "));
    try testing.expectEqual(@as(u32, 3), first.len);
    try testing.expectEqual(@as(u64, 4), first.padded());

    const second = (try r.next()).?;
    try testing.expect(second.is("two "));
    try testing.expectEqual(@as(u32, 4), second.len);

    var buf: [4]u8 = undefined;
    try r.readAll(&buf);
    try testing.expectEqualStrings("wxyz", &buf);
    try testing.expectEqual(@as(?Chunk, null), try r.next());
}

test "a payload may be read in part, and the rest is stepped over" {
    var stream: Io.Reader = .fixed(
        "RIFF\x20\x00\x00\x00TEST" ++
            "big \x0a\x00\x00\x000123456789" ++
            "end \x02\x00\x00\x00hi",
    );
    var r: Reader = try .init(&stream);

    _ = try r.next();
    var head: [3]u8 = undefined;
    try r.readSome(&head);
    try testing.expectEqualStrings("012", &head);

    // The other seven bytes are skipped without the caller saying so.
    const next = (try r.next()).?;
    try testing.expect(next.is("end "));
}

test "a LIST is descended into and climbed out of by the same loop" {
    var stream: Io.Reader = .fixed(
        // The LIST holds its four-character type and one twelve-byte chunk:
        // sixteen bytes, and the file holds the form type, the LIST and the
        // index, which is forty.
        "RIFF\x28\x00\x00\x00AVI " ++
            "LIST\x10\x00\x00\x00hdrlavih\x04\x00\x00\x00\x01\x02\x03\x04" ++
            "idx1\x04\x00\x00\x00zzzz",
    );
    var r: Reader = try .init(&stream);

    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(testing.allocator);

    while (try r.next()) |chunk| {
        if (chunk.is("LIST")) {
            const kind = try r.enter();
            try testing.expect(kind.is("hdrl"));
            continue;
        }
        try seen.append(testing.allocator, switch (chunk.id.bytes[0]) {
            'a' => "avih",
            else => "idx1",
        });
    }

    // The inner chunk and the outer one, in order, out of one loop --- the
    // climb back out of the list happened without the caller asking.
    try testing.expectEqual(@as(usize, 2), seen.items.len);
    try testing.expectEqualStrings("avih", seen.items[0]);
    try testing.expectEqualStrings("idx1", seen.items[1]);
}

test "a container that is not a LIST is descended into just the same" {
    // WebP's shape: an `ANMF` chunk whose payload is a sixteen-byte frame
    // header and then the frame's own chunks. There is no list type and
    // nothing here is a `LIST`, which is why `descend` takes the header from
    // whatever the caller has already read rather than assuming four bytes.
    var stream: Io.Reader = .fixed(
        // The ANMF holds its sixteen-byte header and one twelve-byte chunk:
        // twenty-eight bytes. The file holds the form type, the ANMF and the
        // metadata, which is fifty-two.
        "RIFF\x34\x00\x00\x00WEBP" ++
            "ANMF\x1c\x00\x00\x00" ++
            "0123456789abcdef" ++
            "VP8L\x04\x00\x00\x00pixe" ++
            "EXIF\x04\x00\x00\x00meta",
    );
    var r: Reader = try .init(&stream);

    const anmf = (try r.next()).?;
    try testing.expect(anmf.is("ANMF"));
    var frame_header: [16]u8 = undefined;
    try r.readSome(&frame_header);
    try testing.expectEqualStrings("0123456789abcdef", &frame_header);
    try r.descend();

    const inner = (try r.next()).?;
    try testing.expect(inner.is("VP8L"));

    // And out again, to the chunk that followed the container.
    const after = (try r.next()).?;
    try testing.expect(after.is("EXIF"));
}

test "a file written to a pipe says its lengths are unknown, and reads anyway" {
    // Byte for byte what ffmpeg writes when its output cannot be seeked: all
    // ones in the file's length, a `LIST` it could size because it was
    // complete, and all ones again in the `data` chunk it was still writing
    // when the stream ended.
    var stream: Io.Reader = .fixed(
        "RIFF\xff\xff\xff\xffWAVE" ++
            "fmt \x10\x00\x00\x00\x01\x00\x01\x00\x44\xac\x00\x00\x88\x58\x01\x00\x02\x00\x10\x00" ++
            "LIST\x0c\x00\x00\x00INFOISFT\x00\x00\x00\x00" ++
            "data\xff\xff\xff\xff\x01\x00\x02\x00\x03\x00",
    );
    var r: Reader = try .init(&stream);
    try testing.expect(r.form.is("WAVE"));

    const fmt = (try r.next()).?;
    try testing.expect(fmt.is("fmt "));
    try testing.expect(!fmt.isUnknownLength());
    try testing.expectEqual(@as(u32, 16), fmt.len);

    const list = (try r.next()).?;
    try testing.expect(list.is("LIST"));

    const data = (try r.next()).?;
    try testing.expect(data.is("data"));
    try testing.expect(data.isUnknownLength());

    // Its payload is whatever is left of the stream, which is where such a
    // chunk ends by definition.
    var buffer: [8]u8 = undefined;
    const payload = r.payload(&buffer);
    var samples: [6]u8 = undefined;
    try payload.readSliceAll(&samples);
    try testing.expectEqualSlices(u8, "\x01\x00\x02\x00\x03\x00", &samples);

    // And there is nothing after it, because there cannot be.
    try testing.expectEqual(@as(?Chunk, null), try r.next());
}

test "a file whose header length was left at zero is not an empty file" {
    // The other spelling of the same thing: several encoders leave the
    // header's length at zero rather than writing all ones. Believing it
    // would end the walk before the first chunk.
    var stream: Io.Reader = .fixed(
        "RIFF\x00\x00\x00\x00WAVE" ++
            "fmt \x04\x00\x00\x00abcd" ++
            "data\x04\x00\x00\x00\x01\x02\x03\x04",
    );
    var r: Reader = try .init(&stream);

    const fmt = (try r.next()).?;
    try testing.expect(fmt.is("fmt "));
    const data = (try r.next()).?;
    try testing.expect(data.is("data"));
    try testing.expectEqual(@as(u32, 4), data.len);
    try testing.expectEqual(@as(?Chunk, null), try r.next());
}

test "an unknown length in the middle of a file swallows the rest of it" {
    // Which is the honest answer rather than a convenient one: a chunk that
    // does not say how long it is ends where its container does, so anything
    // written after it is inside it, and a walk that pretended otherwise
    // would be guessing.
    var stream: Io.Reader = .fixed(
        "RIFF\x24\x00\x00\x00WAVE" ++
            "data\xff\xff\xff\xff\x01\x02\x03\x04" ++
            "junk\x04\x00\x00\x00\x05\x06\x07\x08",
    );
    var r: Reader = try .init(&stream);
    const data = (try r.next()).?;
    try testing.expect(data.is("data"));
    try testing.expect(data.isUnknownLength());
    try testing.expectEqual(@as(?Chunk, null), try r.next());
}

test "a chunk longer than the container holding it is refused" {
    var stream: Io.Reader = .fixed(
        "RIFF\x10\x00\x00\x00TEST" ++
            "big \xff\xff\x00\x00nope",
    );
    var r: Reader = try .init(&stream);
    try testing.expectError(error.InvalidData, r.next());
}

test "a truncated file reads up to where it stops" {
    // A recorder killed mid-write: the header promises more than arrived.
    var stream: Io.Reader = .fixed(
        "RIFF\x40\x00\x00\x00WAVE" ++
            "fmt \x04\x00\x00\x00abcd" ++
            "data\x10\x00\x00\x00only eight",
    );
    var r: Reader = try .init(&stream);

    try testing.expect((try r.next()).?.is("fmt "));
    try testing.expect((try r.next()).?.is("data"));
    // And then it ends, rather than failing: what arrived is readable.
    try testing.expectEqual(@as(?Chunk, null), try r.next());
}

test "what is not RIFF says so, and RF64 says what it is" {
    var not: Io.Reader = .fixed("not a riff file at all");
    try testing.expectError(error.NotRiff, Reader.init(&not));

    var short: Io.Reader = .fixed("RIFF");
    try testing.expectError(error.NotRiff, Reader.init(&short));

    var big: Io.Reader = .fixed("RF64\xff\xff\xff\xffWAVEds64");
    try testing.expectError(error.Rf64, Reader.init(&big));
}

test "detection works on a window too short to be sure" {
    try testing.expect(looksLike("RIFF\x00\x00\x00\x00WEBP", "WEBP"));
    try testing.expect(!looksLike("RIFF\x00\x00\x00\x00WAVE", "WEBP"));
    try testing.expect(!looksLike("RIFF\x00\x00\x00\x00WE", "WEBP"));

    // Not yet decidable, and still consistent.
    try testing.expect(couldBe("RI", "WEBP"));
    try testing.expect(couldBe("RIFF\x00\x00\x00\x00", "WEBP"));
    try testing.expect(couldBe("RIFF\x00\x00\x00\x00WE", "WEBP"));
    // Decidably not.
    try testing.expect(!couldBe("RIFX\x00\x00\x00\x00WA", "WEBP"));
    try testing.expect(!couldBe("GIF8", "WEBP"));
}

test "what is written comes back" {
    const gpa = testing.allocator;
    var writer: Writer = .init("WAVE");
    defer writer.deinit(gpa);

    try writer.chunk(gpa, "fmt ", &.{ 1, 0, 2, 0 });
    try writer.openList(gpa, "INFO");
    // Odd length on purpose: the pad byte is the thing most likely to be got
    // wrong, so the round trip has to contain one.
    try writer.chunk(gpa, "INAM", "odd");
    try writer.close();
    try writer.chunk(gpa, "data", &.{ 9, 9, 9, 9 });

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    var out: Io.Writer.Allocating = .fromArrayList(gpa, &list);
    defer list = out.toArrayList();
    try writer.finish(&out.writer);

    var stream: Io.Reader = .fixed(out.written());
    var r: Reader = try .init(&stream);
    try testing.expect(r.form.is("WAVE"));

    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    while (try r.next()) |chunk| {
        if (chunk.is("LIST")) {
            const kind = try r.enter();
            try testing.expect(kind.is("INFO"));
            continue;
        }
        try names.appendSlice(gpa, &chunk.id.bytes);
    }
    try testing.expectEqualStrings("fmt INAMdata", names.items);
}

test "a bounded payload cannot read into the chunk after it" {
    var stream: Io.Reader = .fixed(
        // Four bytes of form type and two twelve-byte chunks: twenty-eight.
        "RIFF\x1c\x00\x00\x00TEST" ++
            "aaaa\x04\x00\x00\x00keep" ++
            "bbbb\x04\x00\x00\x00away",
    );
    var r: Reader = try .init(&stream);
    _ = try r.next();

    var buf: [8]u8 = undefined;
    const bounded = r.payload(&buf);
    var got: [16]u8 = undefined;
    // Four bytes are there and the fifth is not, however much is really in
    // the stream behind it.
    try bounded.readSliceAll(got[0..4]);
    try testing.expectEqualStrings("keep", got[0..4]);
    try testing.expectError(error.EndOfStream, bounded.readSliceAll(got[0..1]));

    // And the walk knows what the bounded reader took without being told, so
    // the chunk after it is the one that comes back.
    const after = (try r.next()).?;
    try testing.expect(after.is("bbbb"));
}

test "a walk over arbitrary bytes terminates and stays inside them" {
    // The property that matters for a container parser handed a hostile
    // file: every length in it is attacker-chosen, and the walk has to end,
    // stay within the stream, and never report more content than arrived.
    const Property = struct {
        fn run(_: void, input: []const u8) anyerror!void {
            var stream: Io.Reader = .fixed(input);
            var r = Reader.init(&stream) catch return;

            var total: u64 = 0;
            var count: usize = 0;
            while (r.next() catch return) |chunk| {
                count += 1;
                // Bounded by the input: a chunk cannot claim more than the
                // whole file, whatever its length field says. A chunk whose
                // length was never filled in claims nothing and runs to the
                // end of what holds it, so it has no number of its own to
                // check -- only that the walk ends, which is below.
                if (!chunk.isUnknownLength()) {
                    try testing.expect(chunk.len <= input.len);
                    total += chunk.padded();
                    try testing.expect(total <= input.len);
                }
                // And it must end. Eight bytes a chunk is the smallest a
                // chunk can be, so more than that many is a walk that is not
                // advancing.
                try testing.expect(count <= input.len / 8 + 1);

                if (chunk.is("LIST")) _ = r.enter() catch {};
            }
        }
    };

    try Property.run({}, "RIFF\x20\x00\x00\x00WAVEfmt \x04\x00\x00\x00abcd");
    try Property.run({}, "RIFF\xff\xff\xff\xffAVI LIST\xff\xff\xff\xffmovi");
    try Property.run({}, "RIFX\x00\x00\x00\x08WEBPVP8L\x00\x00\x00\x00");

    // `Smith` reads a four-byte little-endian length and then that many
    // bytes, and a length past the buffer yields nothing at all rather than
    // being reduced into range --- so the buffer a target reads into is part
    // of its contract with the generator.
    const Driven = struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            try Property.run({}, buf[0..smith.slice(&buf)]);
        }
    };
    try testing.fuzz({}, Driven.run, .{});
}
