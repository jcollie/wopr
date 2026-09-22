// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A single-producer, single-consumer ring of interleaved `f32` audio frames.
//!
//! The application thread writes and the real-time thread reads, so neither ever
//! blocks or allocates. The capacity is rounded up to a power of two so that the
//! indices can be masked rather than divided, and the head and tail are free
//! running counters — the difference between them is the fill level, which stays
//! correct across wraparound.

const std = @import("std");

pub const Ring = struct {
    /// `frames * channels` samples.
    samples: []f32,
    /// Frames of capacity; always a power of two.
    capacity: u32,
    channels: u32,

    /// Frames written, only advanced by the producer.
    head: std.atomic.Value(u32) = .init(0),
    /// Frames read, only advanced by the consumer.
    tail: std.atomic.Value(u32) = .init(0),

    /// Frames the consumer wanted but did not get, for reporting underruns.
    underruns: std.atomic.Value(u32) = .init(0),
    /// Set by the first write. Reads before that are not counted as underruns:
    /// silence played before the producer has offered anything is the stream
    /// starting up, not the producer falling behind.
    started: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: std.mem.Allocator, channels: u32, min_frames: u32) !Ring {
        const capacity = std.math.ceilPowerOfTwo(u32, @max(min_frames, 2)) catch return error.OutOfMemory;
        const samples = try gpa.alloc(f32, capacity * channels);
        @memset(samples, 0);
        return .{ .samples = samples, .capacity = capacity, .channels = channels };
    }

    pub fn deinit(r: *Ring, gpa: std.mem.Allocator) void {
        gpa.free(r.samples);
    }

    /// Frames currently readable.
    pub fn filled(r: *const Ring) u32 {
        return r.head.load(.acquire) -% r.tail.load(.acquire);
    }

    /// Frames the producer may write without overwriting unread data.
    pub fn writable(r: *const Ring) u32 {
        return r.capacity - r.filled();
    }

    /// Producer side. Copies as many whole frames of `interleaved` as fit and
    /// returns how many frames that was.
    pub fn write(r: *Ring, interleaved: []const f32) u32 {
        const ch = r.channels;
        const want: u32 = @intCast(interleaved.len / ch);
        const n = @min(want, r.writable());
        if (n == 0) return 0;

        const head = r.head.load(.monotonic);
        const start = head & (r.capacity - 1);
        const first = @min(n, r.capacity - start);

        @memcpy(r.samples[start * ch ..][0 .. first * ch], interleaved[0 .. first * ch]);
        if (n > first) {
            @memcpy(r.samples[0 .. (n - first) * ch], interleaved[first * ch ..][0 .. (n - first) * ch]);
        }
        // Publish the data before the index that makes it visible.
        r.head.store(head +% n, .release);
        r.started.store(true, .release);
        return n;
    }

    /// Consumer side. De-interleaves up to `frames` into `planes`, one plane per
    /// channel, zero-filling any shortfall so a starved stream outputs silence
    /// rather than stale samples. Returns the number of real frames delivered.
    pub fn readPlanar(r: *Ring, planes: []const []f32, frames: u32) u32 {
        const ch = r.channels;
        std.debug.assert(planes.len == ch);

        const avail = @min(frames, r.filled());
        const tail = r.tail.load(.monotonic);

        var i: u32 = 0;
        while (i < avail) : (i += 1) {
            const src = ((tail +% i) & (r.capacity - 1)) * ch;
            for (planes, 0..) |plane, c| plane[i] = r.samples[src + c];
        }
        for (planes) |plane| @memset(plane[avail..frames], 0);

        if (avail > 0) r.tail.store(tail +% avail, .release);
        if (avail < frames and r.started.load(.acquire)) {
            _ = r.underruns.fetchAdd(frames - avail, .monotonic);
        }
        return avail;
    }
};

const testing = std.testing;

test "writes and planar reads round-trip" {
    var r = try Ring.init(testing.allocator, 2, 8);
    defer r.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 8), r.capacity);
    try testing.expectEqual(@as(u32, 8), r.writable());

    const in = [_]f32{ 1, -1, 2, -2, 3, -3 };
    try testing.expectEqual(@as(u32, 3), r.write(&in));
    try testing.expectEqual(@as(u32, 3), r.filled());

    var left: [4]f32 = undefined;
    var right: [4]f32 = undefined;
    const planes = [_][]f32{ &left, &right };
    // Asking for more than is buffered pads with silence and counts an underrun,
    // now that the producer has written at least once.
    try testing.expectEqual(@as(u32, 3), r.readPlanar(&planes, 4));
    try testing.expectEqualSlices(f32, &.{ 1, 2, 3, 0 }, &left);
    try testing.expectEqualSlices(f32, &.{ -1, -2, -3, 0 }, &right);
    try testing.expectEqual(@as(u32, 1), r.underruns.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), r.filled());
}

test "silence before the first write is not an underrun" {
    var r = try Ring.init(testing.allocator, 1, 4);
    defer r.deinit(testing.allocator);

    var out: [4]f32 = undefined;
    const planes = [_][]f32{&out};
    try testing.expectEqual(@as(u32, 0), r.readPlanar(&planes, 4));
    try testing.expectEqual(@as(u32, 0), r.underruns.load(.monotonic));

    _ = r.write(&.{1});
    try testing.expectEqual(@as(u32, 1), r.readPlanar(&planes, 4));
    try testing.expectEqual(@as(u32, 3), r.underruns.load(.monotonic));
}

test "the ring refuses to overwrite unread frames" {
    var r = try Ring.init(testing.allocator, 1, 4);
    defer r.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 4), r.write(&.{ 1, 2, 3, 4, 5, 6 }));
    try testing.expectEqual(@as(u32, 0), r.writable());
    try testing.expectEqual(@as(u32, 0), r.write(&.{7}));
}

test "reads and writes stay aligned across the wrap point" {
    var r = try Ring.init(testing.allocator, 1, 4);
    defer r.deinit(testing.allocator);

    var out: [3]f32 = undefined;
    const planes = [_][]f32{&out};

    // Walk the ring around several times; each pass leaves the indices offset
    // from the start of the buffer.
    var expected: f32 = 0;
    for (0..10) |_| {
        var in: [3]f32 = undefined;
        for (&in) |*v| {
            v.* = expected;
            expected += 1;
        }
        try testing.expectEqual(@as(u32, 3), r.write(&in));
        try testing.expectEqual(@as(u32, 3), r.readPlanar(&planes, 3));
        try testing.expectEqualSlices(f32, &in, &out);
    }
}
