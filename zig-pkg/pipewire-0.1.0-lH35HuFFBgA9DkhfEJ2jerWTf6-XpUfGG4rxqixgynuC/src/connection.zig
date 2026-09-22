// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The PipeWire native protocol connection: framing, buffering and descriptor
//! passing over the daemon's Unix socket.
//!
//! Each message is a 16-byte header of four native-endian `u32`s —
//!
//!     [0] id      target object id
//!     [1] opcode in the high 8 bits, payload size in the low 24
//!     [2] seq     sequence number, echoed back by Sync/Done
//!     [3] n_fds   how many of the connection's pending descriptors are this
//!                 message's
//!
//! — followed by the payload, which is a single POD (usually a Struct), and
//! optionally a second "footer" POD that this library does not send and ignores
//! on receipt. Descriptors travel out of band as SCM_RIGHTS, and a message
//! refers to them by index rather than by number.

const std = @import("std");
const sys = @import("sys.zig");
const pod = @import("pod.zig");

pub const header_size = 16;
pub const max_payload = 0xffffff;

/// The sequence counter wraps within this mask, matching `SPA_ASYNC_SEQ_MASK`.
pub const seq_mask: u32 = 0x3fffffff;

pub const Error = sys.Error || std.mem.Allocator.Error || error{ProtocolError};

/// One received message. `data` and `fds` borrow the connection's buffers and
/// stay valid until `release` is called or another message is read.
pub const Message = struct {
    id: u32,
    opcode: u8,
    seq: u32,
    data: []const u8,
    fds: []i32,

    /// A parser over the message payload. The payload is a single POD; any
    /// footer after it is left alone.
    pub fn parser(m: Message) pod.Parser {
        return pod.Parser.init(m.data);
    }

    /// Take ownership of the descriptor at `index`, so that `release` will not
    /// close it. Returns -1 if the index is out of range or already taken.
    pub fn takeFd(m: Message, index: i64) i32 {
        if (index < 0 or index >= m.fds.len) return -1;
        const i: usize = @intCast(index);
        const fd = m.fds[i];
        m.fds[i] = -1;
        return fd;
    }
};

pub const Connection = struct {
    gpa: std.mem.Allocator,
    fd: i32,

    in: std.ArrayListAligned(u8, .@"8") = .empty,
    /// How much of `in` has been handed out as complete messages.
    in_pos: usize = 0,
    in_fds: std.ArrayList(i32) = .empty,
    /// How many of `in_fds` belong to messages already handed out.
    in_fds_pos: usize = 0,

    out: std.ArrayList(u8) = .empty,
    out_fds: std.ArrayList(i32) = .empty,

    seq: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, fd: i32) Connection {
        return .{ .gpa = gpa, .fd = fd };
    }

    pub fn deinit(c: *Connection) void {
        for (c.in_fds.items[c.in_fds_pos..]) |fd| sys.close(fd);
        c.in.deinit(c.gpa);
        c.in_fds.deinit(c.gpa);
        c.out.deinit(c.gpa);
        c.out_fds.deinit(c.gpa);
        sys.close(c.fd);
        c.fd = -1;
    }

    // --- sending ---

    /// Queue a message. `fds` are duplicated into the outgoing queue by index,
    /// so `payload` must already refer to them by the indices `addFd` returned.
    pub fn send(c: *Connection, id: u32, opcode: u8, payload: []const u8, n_fds: u32) Error!u32 {
        if (payload.len > max_payload) return error.ProtocolError;

        const seq = c.seq;
        c.seq = (c.seq + 1) & seq_mask;

        var hdr: [4]u32 = .{
            id,
            (@as(u32, opcode) << 24) | @as(u32, @intCast(payload.len)),
            seq,
            n_fds,
        };
        try c.out.appendSlice(c.gpa, std.mem.sliceAsBytes(hdr[0..]));
        try c.out.appendSlice(c.gpa, payload);
        return seq;
    }

    /// Register a descriptor for the message being built and return the index to
    /// put in its Fd POD. The descriptor is closed once the message is flushed.
    pub fn addFd(c: *Connection, fd: i32) Error!i64 {
        const index = c.out_fds.items.len;
        try c.out_fds.append(c.gpa, fd);
        return @intCast(index);
    }

    /// Write everything queued to the socket.
    ///
    /// Descriptors must accompany the message that owns them, so a batch is cut
    /// short at `max_fds_per_msg`; the C implementation does the same.
    pub fn flush(c: *Connection) Error!void {
        var data: []const u8 = c.out.items;
        var fds: []const i32 = c.out_fds.items;
        var closed: usize = 0;

        defer {
            // Whatever went out is dropped from the queues; anything left stays
            // for the next flush.
            for (c.out_fds.items[0..closed]) |fd| sys.close(fd);
            const remaining_fds = c.out_fds.items.len - closed;
            std.mem.copyForwards(i32, c.out_fds.items[0..remaining_fds], c.out_fds.items[closed..]);
            c.out_fds.shrinkRetainingCapacity(remaining_fds);

            const sent = c.out.items.len - data.len;
            const remaining = c.out.items.len - sent;
            std.mem.copyForwards(u8, c.out.items[0..remaining], c.out.items[sent..]);
            c.out.shrinkRetainingCapacity(remaining);
        }

        while (data.len > 0) {
            const batch_fds = @min(fds.len, sys.max_fds_per_msg);
            // When more descriptors are queued than one message may carry, send
            // a token amount of payload with them and let the rest follow.
            const batch_len = if (fds.len > sys.max_fds_per_msg)
                @min(data.len, @sizeOf(u32))
            else
                data.len;

            const n = sys.sendmsgFds(c.fd, data[0..batch_len], fds[0..batch_fds]) catch |err| switch (err) {
                error.Interrupted => continue,
                else => return err,
            };
            data = data[n..];
            fds = fds[batch_fds..];
            closed += batch_fds;
        }
    }

    // --- receiving ---

    /// Read whatever the socket has available into the input buffer.
    ///
    /// With `nonblocking` set this returns `error.Again` when nothing is ready.
    pub fn fill(c: *Connection, nonblocking: bool) Error!void {
        c.compactInput();
        // Grow by a page at a time; PipeWire's own buffer starts at 32 KiB.
        const chunk = 32 * 1024;
        try c.in.ensureUnusedCapacity(c.gpa, chunk);
        try c.in_fds.ensureUnusedCapacity(c.gpa, sys.max_fds_per_msg);

        const spare = c.in.unusedCapacitySlice();
        const fd_spare = c.in_fds.unusedCapacitySlice();

        while (true) {
            const r = sys.recvmsgFds(c.fd, spare, fd_spare, nonblocking) catch |err| switch (err) {
                error.Interrupted => continue,
                else => return err,
            };
            c.in.items.len += r.len;
            c.in_fds.items.len += r.n_fds;
            return;
        }
    }

    /// Drop already-consumed bytes and descriptors from the front of the input
    /// buffers so they do not grow without bound.
    fn compactInput(c: *Connection) void {
        if (c.in_pos > 0) {
            const remaining = c.in.items.len - c.in_pos;
            std.mem.copyForwards(u8, c.in.items[0..remaining], c.in.items[c.in_pos..]);
            c.in.shrinkRetainingCapacity(remaining);
            c.in_pos = 0;
        }
        if (c.in_fds_pos > 0) {
            const remaining = c.in_fds.items.len - c.in_fds_pos;
            std.mem.copyForwards(i32, c.in_fds.items[0..remaining], c.in_fds.items[c.in_fds_pos..]);
            c.in_fds.shrinkRetainingCapacity(remaining);
            c.in_fds_pos = 0;
        }
    }

    /// The next complete message in the buffer, or null if more bytes are needed.
    ///
    /// The caller must `release` each message before asking for the next one.
    pub fn next(c: *Connection) Error!?Message {
        const avail = c.in.items[c.in_pos..];
        if (avail.len < header_size) return null;

        const words = std.mem.bytesAsSlice(u32, avail[0..header_size]);
        const id = words[0];
        const opcode: u8 = @intCast(words[1] >> 24);
        const size: usize = words[1] & 0xffffff;
        const seq = words[2];
        const n_fds: usize = words[3];

        if (avail.len < header_size + size) return null;

        const fds_avail = c.in_fds.items.len - c.in_fds_pos;
        if (n_fds > fds_avail) {
            // The payload arrived before its descriptors; wait for another read.
            return null;
        }

        const msg: Message = .{
            .id = id,
            .opcode = opcode,
            .seq = seq,
            .data = avail[header_size..][0..size],
            .fds = c.in_fds.items[c.in_fds_pos..][0..n_fds],
        };
        c.in_pos += header_size + size;
        c.in_fds_pos += n_fds;
        return msg;
    }

    /// Close any descriptors of `msg` the handler did not take.
    pub fn release(c: *Connection, msg: Message) void {
        _ = c;
        for (msg.fds) |fd| sys.close(fd);
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "framing round-trips over a socketpair" {
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);
    try testing.expectEqual(@as(usize, 0), rc);

    var a = Connection.init(testing.allocator, fds[0]);
    defer a.deinit();
    var b = Connection.init(testing.allocator, fds[1]);
    defer b.deinit();

    var builder = pod.Builder.init(testing.allocator);
    defer builder.deinit();
    const f = try builder.pushStruct();
    try builder.addInt(3);
    try builder.addString("hi");
    try builder.pop(f);

    _ = try a.send(7, 5, builder.bytes(), 0);
    try a.flush();

    try b.fill(false);
    const msg = (try b.next()) orelse return error.TestUnexpectedResult;
    defer b.release(msg);

    try testing.expectEqual(@as(u32, 7), msg.id);
    try testing.expectEqual(@as(u8, 5), msg.opcode);
    try testing.expectEqual(@as(usize, 0), msg.fds.len);

    var p = msg.parser();
    var fields = try p.nextStruct();
    try testing.expectEqual(@as(i32, 3), try fields.nextInt());
    try testing.expectEqualStrings("hi", try fields.nextString());
}

test "descriptors arrive with their message" {
    var fds: [2]i32 = undefined;
    _ = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);

    var a = Connection.init(testing.allocator, fds[0]);
    defer a.deinit();
    var b = Connection.init(testing.allocator, fds[1]);
    defer b.deinit();

    const ev = try sys.eventfd(0, 0);
    const index = try a.addFd(ev);
    try testing.expectEqual(@as(i64, 0), index);

    var builder = pod.Builder.init(testing.allocator);
    defer builder.deinit();
    const f = try builder.pushStruct();
    try builder.addFd(index);
    try builder.pop(f);

    _ = try a.send(0, 1, builder.bytes(), 1);
    try a.flush();

    try b.fill(false);
    const msg = (try b.next()) orelse return error.TestUnexpectedResult;
    defer b.release(msg);
    try testing.expectEqual(@as(usize, 1), msg.fds.len);

    var p = msg.parser();
    var fields = try p.nextStruct();
    const got = msg.takeFd(try fields.nextFd());
    try testing.expect(got >= 0);
    // The descriptor is a working eventfd on this side of the socket too.
    try sys.eventfdWrite(got, 5);
    try testing.expectEqual(@as(u64, 5), try sys.eventfdRead(got));
    sys.close(got);
    // Taking it means release must not close it a second time.
    try testing.expectEqual(@as(i32, -1), msg.fds[0]);
}

test "a message split across reads is only returned once whole" {
    var fds: [2]i32 = undefined;
    _ = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);

    var a = Connection.init(testing.allocator, fds[0]);
    defer a.deinit();
    var b = Connection.init(testing.allocator, fds[1]);
    defer b.deinit();

    var builder = pod.Builder.init(testing.allocator);
    defer builder.deinit();
    const f = try builder.pushStruct();
    try builder.addString("a somewhat longer payload to split");
    try builder.pop(f);
    _ = try a.send(1, 2, builder.bytes(), 0);

    // Hand the receiver the header and a few bytes, then the rest.
    const all = a.out.items;
    _ = try sys.sendmsgFds(a.fd, all[0 .. header_size + 4], &.{});
    try b.fill(false);
    try testing.expect(try b.next() == null);

    _ = try sys.sendmsgFds(a.fd, all[header_size + 4 ..], &.{});
    a.out.clearRetainingCapacity();
    try b.fill(false);
    const msg = (try b.next()) orelse return error.TestUnexpectedResult;
    defer b.release(msg);
    var p = msg.parser();
    var fields = try p.nextStruct();
    try testing.expectEqualStrings("a somewhat longer payload to split", try fields.nextString());
}
