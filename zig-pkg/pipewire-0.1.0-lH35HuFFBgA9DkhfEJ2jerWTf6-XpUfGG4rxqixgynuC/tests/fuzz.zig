// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Fuzz targets: what this library must do with bytes nobody wrote.
//!
//! Every byte this library parses arrives over a socket from another process.
//! A PipeWire client trusts the daemon with a great deal — it maps memory the
//! daemon names, and it turns integers the daemon sends into pointers into that
//! memory — so "the daemon would never send that" is not a safety argument. The
//! targets below state what has to hold for *every* input rather than for the
//! ones somebody thought to write down:
//!
//! * **Parsing a POD terminates, and every slice it hands back is inside the
//!   input.** This is the front line: a POD is a length-prefixed tree, read
//!   recursively, out of bytes chosen by someone else.
//! * **Encoding then decoding is the identity.** A tree built by the builder
//!   comes back out of the parser with the same shape and the same values, at
//!   the alignment the protocol requires.
//! * **Framing cannot be led out of its buffer.** A message header carries a
//!   24-bit length and a descriptor count, both attacker-chosen.
//! * **Every event decoder either fails or reports what it read.** The nested
//!   counts in `PortUseBuffers` — buffers, then metadata, then data blocks —
//!   are the shape of input that gets parsers into trouble. This is the target
//!   that found `spa.Direction` being an exhaustive enum with a `u32` off the
//!   wire cast straight into it.
//! * **Every object the registry describes is decoded, or refused, and the
//!   copy kept of it belongs to us.** A session manager's view of the graph is
//!   built out of dictionaries whose item counts and string lengths are the
//!   daemon's, and those strings are then copied out of a buffer that is about
//!   to be reused — so the target checks both that nothing decoded points
//!   outside the message and that nothing kept points back into it.
//! * **A session survives any stream of messages.** Above framing sits the
//!   Core's own dispatch, which answers a ping, keeps an error and fills a pool
//!   of shared descriptors.
//! * **A buffer layout is inside its mapping, or refused.** `bufferLayout` is
//!   where the daemon's arithmetic becomes memory access, so its result is
//!   checked against the mapping it was given, not merely eyeballed.
//! * **The ring never hands out what was not written.** Its indices are free
//!   running counters that wrap, and the producer and consumer only ever meet
//!   through two atomics.
//!
//! # Running them
//!
//! ```console
//! $ zig build test                              # the corpus below
//! $ zig build fuzz --fuzz                       # Zig's fuzzer
//! $ zig build fuzz --fuzz -Dfuzz-filter=pod     # one of them
//! $ zig build fuzz-run -- --seconds 60          # ours, on an unpatched Zig
//! ```
//!
//! Each test is named `fuzz <target>: ...` so that the word after `fuzz` names
//! one; `-Dfuzz-filter` matches on it, and so does `--target` in the loop that
//! `tools/fuzz.zig` runs.
//!
//! Without `--fuzz` a fuzz test runs only the corpus it was given, so the seeds
//! at the bottom of this file are what `zig build test` and CI actually
//! exercise.
//!
//! # What the harness has to do itself
//!
//! **Bound the memory.** A POD says how long it is, and a fuzzer discovers
//! early that a large number there is interesting. Targets that allocate run
//! against `Budget`, which hands out at most `budget_bytes` before it starts
//! answering `error.OutOfMemory` — which every allocating entry point here
//! already promises to survive. So the cap keeps the fuzzer inside its machine
//! and exercises the allocation-failure paths at the same time.
//!
//! **Bound the input.** The interesting failures are in what a message *says*,
//! not in how many bytes of it there are, so the byte strings are capped at
//! `max_input`.
//!
//! # Keeping them honest
//!
//! A fuzz target that never fails is either proving something or blind, and the
//! two look identical from outside. So each of these was checked by breaking
//! the thing it watches and confirming it noticed: the parser's bounds check
//! widened, `Builder.pop` made to count its own padding, framing's
//! payload-arrived check dropped, the memory pool made to accept a descriptor
//! that never came, `bufferLayout`'s chunk-record bounds check removed, the
//! ring's writer made to ignore the wrap point, `parseVolume`'s channel count
//! taken from the wire unclamped, and `makeObject` made to keep the daemon's
//! own strings rather than copies of them. All eight were caught. The ring
//! target only caught its one after being rewritten to take its operations from
//! a byte string — asked as a run of questions, it read as "read nothing" over
//! and over and the ring never filled, let alone wrapped.

const builtin = @import("builtin");
const std = @import("std");
const pw = @import("pipewire");

const pod = pw.pod;
const spa = pw.spa;
const conn = pw.connection;
const cn = pw.client_node;
const reg = pw.registry;

const Allocator = std.mem.Allocator;
const Smith = std.testing.Smith;
const testing = std.testing;

/// What `Budget` hands out, and what a leak is detected by.
///
/// The testing allocator when these run as tests, since its leak checking is
/// half of what a fuzz target is for — and it cannot be named at all outside a
/// test build, which is why this is a variable: `tools/fuzz.zig` sets its own,
/// with the same checking, before it drives any of them.
pub var backing: Allocator = if (builtin.is_test) testing.allocator else undefined;

/// The longest byte string a target will parse.
const max_input = 4096;
/// How much any one target may allocate before it is told the machine is full.
const budget_bytes = 64 << 20;
/// The deepest POD tree the round-trip target will build. PipeWire's own
/// messages nest three or four deep; this leaves room without letting a fuzzer
/// choose recursion depth.
const max_depth = 6;

// --- the allocator the targets run against ----------------------------------

/// A cap over another allocator, and the whole of why a fuzzer can be left
/// running here.
///
/// It wraps the testing allocator rather than replacing it, so a leak is still
/// a leak and a double free is still a double free; what it adds is a total,
/// after which allocation fails the way it would on a machine that had run out.
const Budget = struct {
    parent: Allocator,
    left: usize,

    fn init(parent: Allocator, bytes: usize) Budget {
        return .{ .parent = parent, .left = bytes };
    }

    fn allocator(self: *Budget) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (len > self.left) return null;
        const got = self.parent.vtable.alloc(self.parent.ptr, len, alignment, ra) orelse return null;
        self.left -= len;
        return got;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and new_len - memory.len > self.left) return false;
        if (!self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ra)) return false;
        self.charge(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and new_len - memory.len > self.left) return null;
        const got = self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ra) orelse return null;
        self.charge(memory.len, new_len);
        return got;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ra);
        self.left += memory.len;
    }

    fn charge(self: *Budget, was: usize, now: usize) void {
        if (now > was) self.left -= now - was else self.left += was - now;
    }
};

/// The byte string a target parses.
fn inputOf(smith: *Smith, buffer: *[max_input]u8) []const u8 {
    return buffer[0..smith.slice(buffer)];
}

// --- parsing a POD ----------------------------------------------------------

test "fuzz pod: parsing anything terminates and stays inside the input" {
    try std.testing.fuzz({}, podOne, .{ .corpus = &pod_corpus });
}

fn podOne(_: void, smith: *Smith) anyerror!void {
    var buffer: [max_input]u8 = undefined;
    const input = inputOf(smith, &buffer);
    try walk(input, input, 0);
}

/// Walk every POD in `data`, descending into the containers, and check that
/// each one describes memory inside `whole`.
///
/// The depth cap is the harness's, not the parser's: a POD tree can nest as
/// deeply as its bytes allow, and this walker recurses where the library's own
/// parsing does not.
fn walk(data: []const u8, whole: []const u8, depth: usize) anyerror!void {
    if (depth > 32) return;
    var p: pod.Parser = .init(data);
    while (p.next() catch return) |item| {
        // Whatever it says about itself, what came back has to be a view of the
        // bytes handed in.
        try expectInside(item.body, whole);
        try expectInside(item.encoded, whole);
        try testing.expect(item.encoded.len >= @sizeOf(pod.Header));
        try testing.expectEqual(item.encoded.len - @sizeOf(pod.Header), item.body.len);

        switch (item.type) {
            .@"struct" => try walk(item.body, whole, depth + 1),
            .object => {
                var obj = item.objectBody() catch continue;
                while (obj.next() catch null) |prop| {
                    try expectInside(prop.value.body, whole);
                    try walk(prop.value.encoded, whole, depth + 1);
                }
            },
            .array => {
                const arr = item.arrayBody() catch continue;
                try expectInside(arr.elements, whole);
                var i: usize = 0;
                while (i < arr.count()) : (i += 1) _ = arr.u32At(i) catch {};
            },
            // The accessors must refuse a POD of the wrong type rather than
            // reinterpret its bytes, so calling all of them on all of them is
            // itself worth doing.
            else => {
                _ = item.asBool() catch {};
                _ = item.asId() catch {};
                _ = item.asInt() catch {};
                _ = item.asLong() catch {};
                _ = item.asFd() catch {};
                _ = item.asIntOrId() catch {};
                if (item.asString() catch null) |s| try expectInside(s, whole);
            },
        }
    }
}

fn expectInside(part: []const u8, whole: []const u8) !void {
    if (part.len == 0) return;
    const start = @intFromPtr(part.ptr);
    const base = @intFromPtr(whole.ptr);
    if (start < base or start + part.len > base + whole.len) {
        std.debug.print(
            "slice [{x}..{x}] escapes the input [{x}..{x}]\n",
            .{ start, start + part.len, base, base + whole.len },
        );
        return error.SliceEscapedInput;
    }
}

// --- building then parsing --------------------------------------------------

test "fuzz podroundtrip: what the builder writes is what the parser reads" {
    try std.testing.fuzz({}, roundTripOne, .{ .corpus = &value_corpus });
}

/// One POD the builder can write and the parser can be checked against.
const Value = union(enum) {
    none,
    bool: bool,
    id: u32,
    int: i32,
    long: i64,
    float: f32,
    double: f64,
    string: []const u8,
    bytes: []const u8,
    rectangle: spa.Rectangle,
    fraction: spa.Fraction,
    fd: i64,
    /// A Struct of these, which is what a message payload is.
    children: []const Value,
    /// An Object of properties, which is what every parameter is. Worth
    /// generating rather than only writing by hand: a container's size is
    /// backpatched, and its trailing padding belongs to its parent rather than
    /// to itself, which is exactly the arithmetic that is easy to get wrong.
    object: Object,
    /// An Array of Ids, which is what a channel position map is.
    ids: []const u32,
    /// A Choice, which is how a parameter offers a range instead of a value.
    choice: Choice,
};

const Object = struct {
    type: u32,
    id: u32,
    props: []const Prop,
};

const Prop = struct {
    key: u32,
    flags: u32,
    value: *const Value,
};

const Choice = struct {
    kind: spa.Choice,
    values: []const i32,
};

fn roundTripOne(_: void, smith: *Smith) anyerror!void {
    var budget: Budget = .init(backing, budget_bytes);
    const gpa = budget.allocator();

    var text: [64]u8 = undefined;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const value = buildValue(smith, arena.allocator(), &text, 0) catch |err| switch (err) {
        error.OutOfMemory => return,
    };

    var b: pod.Builder = .init(gpa);
    defer b.deinit();
    write(&b, value) catch |err| switch (err) {
        error.OutOfMemory => return,
    };

    // Every POD is padded to eight bytes, so a complete encoding is a multiple
    // of eight and nothing else.
    try testing.expectEqual(@as(usize, 0), b.bytes().len % 8);

    var p: pod.Parser = .init(b.bytes());
    const decoded = (try p.next()) orelse return error.NothingDecoded;
    try check(decoded, value);
    try testing.expect(p.atEnd());
}

/// Make up a value, recursing no deeper than `max_depth`.
fn buildValue(smith: *Smith, arena: Allocator, text: *[64]u8, depth: usize) error{OutOfMemory}!Value {
    const Kind = std.meta.Tag(Value);
    const kind: Kind = if (depth >= max_depth)
        // At the bottom, anything but another container.
        @enumFromInt(smith.valueRangeLessThan(u8, 0, @intFromEnum(Kind.children)))
    else
        smith.value(Kind);

    return switch (kind) {
        .none => .none,
        .bool => .{ .bool = smith.value(bool) },
        .id => .{ .id = smith.value(u32) },
        .int => .{ .int = smith.value(i32) },
        .long => .{ .long = smith.value(i64) },
        // A NaN is not equal to itself, and this target compares for equality;
        // whether the builder copies eight bytes correctly does not turn on it.
        .float => .{ .float = nonNan(f32, smith.value(f32)) },
        .double => .{ .double = nonNan(f64, smith.value(f64)) },
        // A string is stored NUL-terminated, so an embedded NUL would come back
        // shorter than it went in. That is the format, not a bug, so the
        // generated strings stop at the first one.
        .string => .{ .string = try arena.dupe(u8, upToNul(text[0..smith.slice(text)])) },
        .bytes => .{ .bytes = try arena.dupe(u8, text[0..smith.slice(text)]) },
        .rectangle => .{ .rectangle = .{
            .width = smith.value(u32),
            .height = smith.value(u32),
        } },
        .fraction => .{ .fraction = .{
            .num = smith.value(u32),
            .denom = smith.value(u32),
        } },
        .fd => .{ .fd = smith.value(i64) },
        .children => {
            const n: usize = smith.valueRangeAtMost(u32, 0, 8);
            const kids = try arena.alloc(Value, n);
            for (kids) |*kid| kid.* = try buildValue(smith, arena, text, depth + 1);
            return .{ .children = kids };
        },
        .object => {
            const n: usize = smith.valueRangeAtMost(u32, 0, 8);
            const props = try arena.alloc(Prop, n);
            for (props) |*prop| {
                const value = try arena.create(Value);
                value.* = try buildValue(smith, arena, text, depth + 1);
                prop.* = .{
                    .key = smith.value(u32),
                    .flags = smith.value(u32),
                    .value = value,
                };
            }
            return .{ .object = .{
                .type = smith.value(u32),
                .id = smith.value(u32),
                .props = props,
            } };
        },
        .ids => {
            const n: usize = smith.valueRangeAtMost(u32, 0, 16);
            const ids = try arena.alloc(u32, n);
            for (ids) |*id| id.* = smith.value(u32);
            return .{ .ids = ids };
        },
        .choice => {
            const n: usize = smith.valueRangeAtMost(u32, 0, 8);
            const values = try arena.alloc(i32, n);
            for (values) |*v| v.* = smith.value(i32);
            return .{ .choice = .{ .kind = smith.value(spa.Choice), .values = values } };
        },
    };
}

fn nonNan(comptime T: type, x: T) T {
    return if (std.math.isNan(x)) 0 else x;
}

fn upToNul(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
}

fn write(b: *pod.Builder, v: Value) !void {
    switch (v) {
        .none => try b.addNone(),
        .bool => |x| try b.addBool(x),
        .id => |x| try b.addId(x),
        .int => |x| try b.addInt(x),
        .long => |x| try b.addLong(x),
        .float => |x| try b.addFloat(x),
        .double => |x| try b.addDouble(x),
        .string => |x| try b.addString(x),
        .bytes => |x| try b.addBytes(x),
        .rectangle => |x| try b.addRectangle(x),
        .fraction => |x| try b.addFraction(x),
        .fd => |x| try b.addFd(x),
        .children => |kids| {
            const f = try b.pushStruct();
            for (kids) |kid| try write(b, kid);
            try b.pop(f);
        },
        .object => |o| {
            const f = try b.pushObject(o.type, o.id);
            for (o.props) |prop| {
                try b.prop(prop.key, prop.flags);
                try write(b, prop.value.*);
            }
            try b.pop(f);
        },
        .ids => |xs| {
            const f = try b.pushArray(@sizeOf(u32), .id);
            for (xs) |x| try b.addRaw(std.mem.asBytes(&x));
            try b.pop(f);
        },
        .choice => |c| {
            const f = try b.pushChoice(c.kind, @sizeOf(i32), .int);
            for (c.values) |x| try b.addRaw(std.mem.asBytes(&x));
            try b.pop(f);
        },
    }
}

fn check(decoded: pod.Pod, expected: Value) anyerror!void {
    switch (expected) {
        .none => try testing.expectEqual(spa.Type.none, decoded.type),
        .bool => |x| try testing.expectEqual(x, try decoded.asBool()),
        .id => |x| try testing.expectEqual(x, try decoded.asId()),
        .int => |x| try testing.expectEqual(x, try decoded.asInt()),
        .long => |x| try testing.expectEqual(x, try decoded.asLong()),
        .float => |x| {
            try testing.expectEqual(spa.Type.float, decoded.type);
            try testing.expectEqual(x, std.mem.bytesToValue(f32, decoded.body[0..4]));
        },
        .double => |x| {
            try testing.expectEqual(spa.Type.double, decoded.type);
            try testing.expectEqual(x, std.mem.bytesToValue(f64, decoded.body[0..8]));
        },
        .string => |x| try testing.expectEqualStrings(x, try decoded.asString()),
        .bytes => |x| {
            try testing.expectEqual(spa.Type.bytes, decoded.type);
            try testing.expectEqualSlices(u8, x, decoded.body);
        },
        .rectangle => |x| {
            try testing.expectEqual(spa.Type.rectangle, decoded.type);
            try testing.expectEqual(x, std.mem.bytesToValue(spa.Rectangle, decoded.body[0..8]));
        },
        .fraction => |x| {
            try testing.expectEqual(spa.Type.fraction, decoded.type);
            try testing.expectEqual(x, std.mem.bytesToValue(spa.Fraction, decoded.body[0..8]));
        },
        .fd => |x| try testing.expectEqual(x, try decoded.asFd()),
        .children => |kids| {
            var fields = try decoded.structFields();
            for (kids) |kid| {
                const got = (try fields.next()) orelse return error.MissingChild;
                try check(got, kid);
            }
            try testing.expect(fields.atEnd());
        },
        .object => |o| {
            var body = try decoded.objectBody();
            try testing.expectEqual(o.type, body.type);
            try testing.expectEqual(o.id, body.id);
            for (o.props) |prop| {
                const got = (try body.next()) orelse return error.MissingProperty;
                try testing.expectEqual(prop.key, got.key);
                try testing.expectEqual(prop.flags, got.flags);
                try check(got.value, prop.value.*);
            }
            try testing.expect((try body.next()) == null);
        },
        .ids => |xs| {
            const arr = try decoded.arrayBody();
            try testing.expectEqual(spa.Type.id, arr.child_type);
            try testing.expectEqual(@as(u32, @sizeOf(u32)), arr.child_size);
            try testing.expectEqual(xs.len, arr.count());
            for (xs, 0..) |x, i| try testing.expectEqual(x, try arr.u32At(i));
        },
        .choice => |c| {
            try testing.expectEqual(spa.Type.choice, decoded.type);
            // A choice body is the kind, some flags, the header describing one
            // value, and then the values themselves laid bare.
            const head = 4 + 4 + @sizeOf(pod.Header);
            try testing.expectEqual(head + c.values.len * @sizeOf(i32), decoded.body.len);
            try testing.expectEqual(
                @intFromEnum(c.kind),
                std.mem.readInt(u32, decoded.body[0..4], .little),
            );
            for (c.values, 0..) |v, i| {
                try testing.expectEqual(
                    v,
                    std.mem.readInt(i32, decoded.body[head + i * 4 ..][0..4], .little),
                );
            }
        },
    }
}

// --- message framing --------------------------------------------------------

test "fuzz message: framing never reports a message outside its buffer" {
    try std.testing.fuzz({}, messageOne, .{ .corpus = &message_corpus });
}

fn messageOne(_: void, smith: *Smith) anyerror!void {
    var buffer: [max_input]u8 = undefined;
    const input = inputOf(smith, &buffer);

    var budget: Budget = .init(backing, budget_bytes);
    const gpa = budget.allocator();

    // A socketpair, so the bytes travel the path they would in the real thing —
    // including the header being read in pieces.
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return;

    var writer: conn.Connection = .init(gpa, fds[0]);
    defer writer.deinit();
    var reader: conn.Connection = .init(gpa, fds[1]);
    defer reader.deinit();

    // A socket buffer will not take an unbounded write, and what is being
    // tested is the reader.
    _ = pw.sys.sendmsgFds(writer.fd, input[0..@min(input.len, 8192)], &.{}) catch return;

    // Non-blocking, because a stream socket swallows a zero-byte write: an
    // empty input would leave a blocking read waiting for bytes that are never
    // coming.
    reader.fill(true) catch return;
    var seen: usize = 0;
    while (reader.next() catch return) |msg| : (seen += 1) {
        defer reader.release(msg);
        try expectInside(msg.data, reader.in.items);
        // A message may claim descriptors only if that many actually arrived.
        try testing.expect(msg.fds.len == 0);
        // Anything it hands out has to parse or fail, not fault.
        try walk(msg.data, msg.data, 0);
        if (seen > 1024) break;
    }
}

// --- the core object --------------------------------------------------------

test "fuzz core: a session survives any stream of messages" {
    try std.testing.fuzz({}, coreOne, .{ .corpus = &core_corpus });
}

/// Drive `Core`'s own dispatch with whatever the socket says.
///
/// This is the layer above framing: the events the Core acts on itself — the
/// reply to a sync, a ping to answer, an error to keep, and the pair that adds
/// and removes pooled memory — each read fields out of the message and two of
/// them allocate.
fn coreOne(_: void, smith: *Smith) anyerror!void {
    var buffer: [max_input]u8 = undefined;
    const input = inputOf(smith, &buffer);

    var budget: Budget = .init(backing, budget_bytes);
    const gpa = budget.allocator();

    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return;

    // A Core built straight onto a socket, rather than through `connect`: the
    // handshake is not what is being tested and there is nobody to answer it.
    const core = gpa.create(pw.core.Core) catch {
        pw.sys.close(fds[0]);
        pw.sys.close(fds[1]);
        return;
    };
    core.* = .{ .gpa = gpa, .c = .init(gpa, fds[1]), .scratch = .init(gpa) };
    defer core.deinit();
    defer pw.sys.close(fds[0]);

    _ = pw.sys.sendmsgFds(fds[0], input[0..@min(input.len, 8192)], &.{}) catch return;

    core.c.fill(true) catch return;
    core.dispatchBuffered() catch return;

    // Whatever it made of that, the pool holds only descriptors it was given,
    // and it was given none.
    try testing.expectEqual(@as(usize, 0), core.mem.count());
}

// --- event decoding ---------------------------------------------------------

test "fuzz clientnode: every event decoder either fails or reports what it read" {
    try std.testing.fuzz({}, clientNodeOne, .{ .corpus = &event_corpus });
}

fn clientNodeOne(_: void, smith: *Smith) anyerror!void {
    // The two decisions this target makes come first, so that an input which is
    // otherwise random still answers them; see `decisions` in `tools/fuzz.zig`.
    const map_len: usize = smith.valueRangeAtMost(u32, 0, 1 << 20);
    const base: usize = smith.value(u64);

    var buffer: [max_input]u8 = undefined;
    const input = inputOf(smith, &buffer);

    // No descriptors: a decoder that reaches for one gets -1, which every
    // caller has to cope with anyway.
    const msg: conn.Message = .{
        .id = 2,
        .opcode = 0,
        .seq = 0,
        .data = input,
        .fds = &.{},
    };

    if (cn.parseTransport(msg) catch null) |t| {
        try testing.expectEqual(@as(i32, -1), t.read_fd);
        try testing.expectEqual(@as(i32, -1), t.write_fd);
    }
    _ = cn.parseSetParam(msg) catch {};
    _ = cn.parseSetIo(msg) catch {};
    _ = cn.parsePortSetIo(msg) catch {};
    _ = cn.parseSetActivation(msg) catch {};
    _ = cn.parsePortSetMixInfo(msg) catch {};
    _ = cn.parseCommand(msg) catch {};

    if (cn.parsePortSetParam(msg) catch null) |sp| {
        if (sp.param) |param| {
            try expectInside(param.encoded, input);
            // The one param the stream acts on, so its decoder is worth
            // reaching through every message shape that gets this far.
            if (cn.parseAudioLayout(param) catch null) |layout| {
                try testing.expect(layout.channels > 0);
                try testing.expect(layout.channels <= cn.max_layout_channels);
            }
        }
    }

    var ub: cn.UseBuffers = undefined;
    if (cn.parseUseBuffers(msg, &ub)) |_| {
        try testing.expect(ub.n_buffers <= cn.max_buffers);
        for (ub.slice()) |desc| {
            try testing.expect(desc.n_metas <= cn.max_metas);
            try testing.expect(desc.n_datas <= cn.max_datas);
            // Every buffer the decoder accepted is then laid out, against a
            // mapping length it has no say over.
            try checkLayout(desc, map_len, base);
        }
    } else |_| {}
}

// --- the registry -----------------------------------------------------------

test "fuzz registry: every object decoder either fails or reports what it read" {
    try std.testing.fuzz({}, registryOne, .{ .corpus = &registry_corpus });
}

/// Every decoder in `registry.zig`, over the same bytes.
///
/// One message can only be one of these, so all but one call will fail on any
/// given input; what is being asked is that the ones which do not fail have
/// read only what they were given, and that what a session keeps of them is its
/// own memory rather than a view of a buffer about to be overwritten.
fn registryOne(_: void, smith: *Smith) anyerror!void {
    var buffer: [max_input]u8 = undefined;
    const input = inputOf(smith, &buffer);

    var budget: Budget = .init(backing, budget_bytes);
    const gpa = budget.allocator();

    const msg: conn.Message = .{
        .id = 2,
        .opcode = 0,
        .seq = 0,
        .data = input,
        .fds = &.{},
    };

    if (reg.parseGlobal(msg) catch null) |global| {
        try expectInside(global.type_name, input);
        try testing.expectEqual(reg.ObjectType.fromInterface(global.type_name), global.type);
        try walkDict(global.props, input);

        // And the copy a session takes of it, which is the allocating half.
        if (pw.session.makeObject(gpa, global) catch null) |object| {
            defer {
                object.deinit(gpa);
                gpa.destroy(object);
            }
            try expectOutside(object.type_name, input);
            try testing.expectEqualStrings(global.type_name, object.type_name);
            for (object.props) |prop| {
                try expectOutside(prop.key, input);
                try expectOutside(prop.value, input);
            }
        }
    }

    if (reg.parseGlobalRemove(msg) catch null) |_| {}

    if (reg.node.parseInfo(msg) catch null) |info| {
        if (info.error_message) |text| try expectInside(text, input);
        try walkDict(info.props, input);
        try walkParams(info.params);
    }
    if (reg.device.parseInfo(msg) catch null) |info| {
        try walkDict(info.props, input);
        try walkParams(info.params);
    }
    if (reg.port.parseInfo(msg) catch null) |info| {
        try walkDict(info.props, input);
        try walkParams(info.params);
    }
    if (reg.client.parseInfo(msg) catch null) |info| {
        try walkDict(info.props, input);
    }
    if (reg.link.parseInfo(msg) catch null) |info| {
        if (info.error_message) |text| try expectInside(text, input);
        if (info.format) |format| try expectInside(format.encoded, input);
        try walkDict(info.props, input);
    }
    if (reg.metadata.parseProperty(msg) catch null) |property| {
        for ([_]?[]const u8{ property.key, property.type, property.value }) |field| {
            if (field) |text| try expectInside(text, input);
        }
    }

    if (reg.parseParam(msg) catch null) |param| {
        const value = param.param orelse return;
        try expectInside(value.encoded, input);
        // The two parameter objects a session acts on. Either may be what the
        // message held, and neither may believe a count it was handed.
        if (reg.parseVolume(value) catch null) |volume| {
            try testing.expect(volume.channels <= reg.max_volume_channels);
            try testing.expect(volume.has.channel_volumes or volume.channels == 0);
        }
        if (reg.route.parse(value) catch null) |route| {
            if (route.name) |text| try expectInside(text, input);
            if (route.props) |props| {
                try expectInside(props.encoded, input);
                if (reg.parseVolume(props) catch null) |volume| {
                    try testing.expect(volume.channels <= reg.max_volume_channels);
                }
            }
        }
    }
}

/// Read a dictionary to its end, checking that every string it hands back is a
/// view of the message rather than of somewhere else.
fn walkDict(dict: reg.Dict, whole: []const u8) !void {
    var it = dict;
    while (it.next() catch return) |prop| {
        try expectInside(prop.key, whole);
        try expectInside(prop.value, whole);
    }
}

fn walkParams(params: reg.ParamInfos) !void {
    var it = params;
    while (it.next() catch return) |_| {}
}

/// The other half of `expectInside`: what a session kept has to be its own.
fn expectOutside(part: []const u8, whole: []const u8) !void {
    if (part.len == 0 or whole.len == 0) return;
    const start = @intFromPtr(part.ptr);
    const low = @intFromPtr(whole.ptr);
    if (start >= low and start < low + whole.len) return error.CopyPointsAtTheMessage;
}

// --- buffer layout ----------------------------------------------------------

test "fuzz buffers: a buffer layout is inside its mapping or refused" {
    try std.testing.fuzz({}, layoutOne, .{ .corpus = &layout_corpus });
}

fn layoutOne(_: void, smith: *Smith) anyerror!void {
    var desc: cn.BufferDesc = .{
        .mem_id = smith.value(u32),
        .offset = smith.value(u32),
        .size = smith.value(u32),
        .n_metas = smith.valueRangeAtMost(u32, 0, cn.max_metas),
        .n_datas = smith.valueRangeAtMost(u32, 0, cn.max_datas),
        .metas = undefined,
        .datas = undefined,
    };
    for (desc.metas[0..desc.n_metas]) |*m| {
        m.* = .{ .type = smith.value(u32), .size = smith.value(u32) };
    }
    for (desc.datas[0..desc.n_datas]) |*d| {
        d.* = .{
            .type = @enumFromInt(smith.valueRangeAtMost(u32, 0, 6)),
            .data_id = smith.value(u32),
            .flags = smith.value(u32),
            .mapoffset = smith.value(u32),
            .maxsize = smith.value(u32),
        };
    }
    const map_len: usize = smith.valueRangeAtMost(u32, 0, 1 << 20);
    // Any base, including ones no allocator would return: alignment is part of
    // what is being checked, and the real base comes from mmap.
    const base: usize = smith.value(u64);
    try checkLayout(desc, map_len, base);
}

/// The property: whatever `bufferLayout` returns describes memory inside a
/// mapping of `map_len` bytes at `base`, correctly aligned for what will be
/// cast onto it.
fn checkLayout(desc: cn.BufferDesc, map_len: usize, base: usize) !void {
    const layout = cn.bufferLayout(desc, map_len, base) catch return;

    try testing.expect(layout.chunk_offset + @sizeOf(spa.Chunk) <= map_len);
    try testing.expect(layout.data_offset + layout.data_len <= map_len);
    try testing.expectEqual(@as(usize, 0), layout.data_len % @sizeOf(f32));
    try testing.expectEqual(@as(usize, 0), (base +% layout.chunk_offset) % @alignOf(spa.Chunk));
    try testing.expectEqual(@as(usize, 0), (base +% layout.data_offset) % @alignOf(f32));
}

// --- the ring ---------------------------------------------------------------

test "fuzz ring: reads never see what was not written" {
    try std.testing.fuzz({}, ringOne, .{ .corpus = &ring_corpus });
}

fn ringOne(_: void, smith: *Smith) anyerror!void {
    var budget: Budget = .init(backing, budget_bytes);
    const gpa = budget.allocator();

    const channels = smith.valueRangeAtMost(u32, 1, 8);
    const capacity = smith.valueRangeAtMost(u32, 1, 512);

    // The operations come from a byte string rather than from a run of
    // questions, because `Smith` answers a question by taking eight bytes as a
    // number and falling back to the bottom of the range unless that number is
    // already inside it — so asked one at a time, a random input reads as "read
    // nothing" over and over and the ring never fills, let alone wraps. A byte
    // string is the one thing `Smith` passes through as given, so each byte here
    // is an operation: the low bit says write or read and the rest says how many
    // frames.
    var script: [512]u8 = undefined;
    const ops = script[0..smith.slice(&script)];

    var ring = pw.ring.Ring.init(gpa, channels, capacity) catch return;
    defer ring.deinit(gpa);

    var in_buf: [128 * 8]f32 = undefined;
    var out_buf: [128 * 8]f32 = undefined;
    var planes: [8][]f32 = undefined;

    // A counter carried through the ring: whatever comes out has to be a value
    // that went in, in the order it went in, and never a value from the future.
    var next_written: f32 = 1;
    var next_expected: f32 = 1;

    for (ops) |op| {
        const frames: u32 = op >> 1;
        if (op & 1 != 0) {
            for (0..frames * channels) |i| {
                in_buf[i] = next_written;
                if (i % channels == channels - 1) next_written += 1;
            }
            const before = ring.filled();
            const wrote = ring.write(in_buf[0 .. frames * channels]);
            try testing.expect(wrote <= frames);
            try testing.expectEqual(before + wrote, ring.filled());
            try testing.expect(ring.filled() <= ring.capacity);
            // Rewind the counter over the frames that did not fit.
            next_written -= @floatFromInt(frames - wrote);
        } else {
            for (0..channels) |c| planes[c] = out_buf[c * 128 ..][0..frames];
            const before = ring.filled();
            const read = ring.readPlanar(planes[0..channels], frames);
            try testing.expect(read <= frames);
            try testing.expectEqual(before - read, ring.filled());

            for (0..read) |i| {
                for (planes[0..channels]) |plane| {
                    try testing.expectEqual(next_expected, plane[i]);
                }
                next_expected += 1;
            }
            // Whatever was not available is silence, not stale data.
            for (planes[0..channels]) |plane| {
                for (plane[read..frames]) |sample| try testing.expectEqual(@as(f32, 0), sample);
            }
        }
        try testing.expectEqual(ring.capacity - ring.filled(), ring.writable());
    }
}

// --- the seam with the standalone loop --------------------------------------

/// One target, reachable both through `std.testing.fuzz` above and through a
/// plain call from `tools/fuzz.zig`, which drives the same functions on a Zig
/// whose fuzzer cannot be built.
pub const Target = struct {
    name: []const u8,
    run: *const fn (input: []const u8) anyerror!void,
    corpus: []const []const u8,
    /// How many eight-byte decisions this target reads before it asks for
    /// bytes.
    ///
    /// A corpus entry is already a complete input, so this is only used when
    /// the loop makes one up: `Smith` answers a question with eight bytes read
    /// as a little-endian `u64`, and hands back the bottom of the range unless
    /// that number is already inside it, so a random byte string answers every
    /// question the same way. Leading an invented input with this many small
    /// numbers is what stops that. `Smith.slice`, on the other hand, reads a
    /// four-byte length and then copies — so a target that asks for its bytes
    /// first would consume the whole prefix as one short string, which is why
    /// the count is per target rather than fixed.
    decisions: usize,
};

pub const all = [_]Target{
    .{ .name = "pod", .run = runPod, .corpus = &pod_corpus, .decisions = 0 },
    .{ .name = "podroundtrip", .run = runRoundTrip, .corpus = &value_corpus, .decisions = 48 },
    .{ .name = "message", .run = runMessage, .corpus = &message_corpus, .decisions = 0 },
    .{ .name = "clientnode", .run = runClientNode, .corpus = &event_corpus, .decisions = 2 },
    .{ .name = "core", .run = runCore, .corpus = &core_corpus, .decisions = 0 },
    .{ .name = "registry", .run = runRegistry, .corpus = &registry_corpus, .decisions = 0 },
    .{ .name = "buffers", .run = runLayout, .corpus = &layout_corpus, .decisions = 64 },
    .{ .name = "ring", .run = runRing, .corpus = &ring_corpus, .decisions = 2 },
};

fn runPod(input: []const u8) anyerror!void {
    var smith: Smith = .{ .in = input };
    return podOne({}, &smith);
}

fn runRoundTrip(input: []const u8) anyerror!void {
    var smith: Smith = .{ .in = input };
    return roundTripOne({}, &smith);
}

fn runMessage(input: []const u8) anyerror!void {
    var smith: Smith = .{ .in = input };
    return messageOne({}, &smith);
}

fn runClientNode(input: []const u8) anyerror!void {
    var smith: Smith = .{ .in = input };
    return clientNodeOne({}, &smith);
}

fn runCore(input: []const u8) anyerror!void {
    var smith: Smith = .{ .in = input };
    return coreOne({}, &smith);
}

fn runRegistry(input: []const u8) anyerror!void {
    var smith: Smith = .{ .in = input };
    return registryOne({}, &smith);
}

fn runLayout(input: []const u8) anyerror!void {
    var smith: Smith = .{ .in = input };
    return layoutOne({}, &smith);
}

fn runRing(input: []const u8) anyerror!void {
    var smith: Smith = .{ .in = input };
    return ringOne({}, &smith);
}

// --- seeds ------------------------------------------------------------------

/// A corpus entry is a `Smith` input, and `Smith` reads it a decision at a time
/// in the order the target asks. The two shapes are these.
///
/// `seed` is what `Smith.slice` reads: a little-endian `u32` length and then
/// that many bytes.
fn seed(comptime bytes: []const u8) []const u8 {
    return std.mem.toBytes(@as(u32, bytes.len))[0..] ++ bytes;
}

/// And `pick` is what everything else reads — `value`, `valueRangeAtMost`,
/// `index`, a `bool`, an enum — which is eight bytes of little-endian
/// whatever-it-is, taken as the value when the target's own bounds allow it and
/// as their minimum when they do not.
///
/// Worth knowing: an input that runs dry is not an input that stops. Every
/// decision after the last byte comes back as the minimum, so a corpus of short
/// entries leaves a target taking the same first branch over and over.
fn pick(comptime value: u64) []const u8 {
    return std.mem.toBytes(@as(u64, value))[0..];
}

/// A POD header, which is what most of these are built out of: a body size and
/// a type tag, both little-endian `u32`.
fn header(comptime size: u32, comptime t: spa.Type) []const u8 {
    return std.mem.toBytes(size)[0..] ++ std.mem.toBytes(@intFromEnum(t))[0..];
}

/// PODs worth having in the corpus: nothing, each of the fixed-width kinds, a
/// string, the containers, and several that lie about their own length.
const pod_corpus = [_][]const u8{
    seed(""),
    seed(header(0, .none)),
    seed(header(4, .int) ++ "\x2a\x00\x00\x00\x00\x00\x00\x00"),
    seed(header(8, .long) ++ "\x01\x00\x00\x00\x00\x00\x00\x00"),
    seed(header(6, .string) ++ "hello\x00\x00\x00"),
    // A Struct of an Int and a String, which is the shape of nearly every
    // message this library sends or receives.
    seed(header(32, .@"struct") ++
        header(4, .int) ++ "\x01\x00\x00\x00\x00\x00\x00\x00" ++
        header(3, .string) ++ "hi\x00\x00\x00\x00\x00"),
    // An Object with one Id property, which is what a Format is.
    seed(header(24, .object) ++
        "\x03\x00\x04\x00" ++ "\x03\x00\x00\x00" ++
        "\x01\x00\x00\x00" ++ "\x00\x00\x00\x00" ++
        header(4, .id) ++ "\x01\x00\x00\x00\x00\x00\x00\x00"),
    // An Array of four Ids: a channel position map.
    seed(header(24, .array) ++ header(4, .id) ++
        "\x03\x00\x00\x00\x04\x00\x00\x00\x05\x00\x00\x00\x06\x00\x00\x00"),
    // A body longer than the bytes that follow it.
    seed(header(0xffff, .string) ++ "short"),
    // A Struct whose size covers bytes it does not have.
    seed(header(0xff, .@"struct") ++ header(4, .int)),
    // A size that would overflow if it were added to an offset without care.
    seed(header(0xffffffff, .bytes)),
    // A type tag no version of the protocol defines.
    seed(header(4, @enumFromInt(9999)) ++ "\x00\x00\x00\x00\x00\x00\x00\x00"),
    // Nested containers, to a depth the walker will follow.
    seed(header(16, .@"struct") ++ header(8, .@"struct") ++ header(0, .none)),
};

/// Round-trip seeds are decisions, not bytes: a kind, then whatever that kind
/// needs. These name the empty struct, a plain int, a string, and a struct of
/// several things.
const value_corpus = [_][]const u8{
    pick(@intFromEnum(std.meta.Tag(Value).none)),
    pick(@intFromEnum(std.meta.Tag(Value).int)) ++ pick(0),
    pick(@intFromEnum(std.meta.Tag(Value).long)) ++ pick(0xdeadbeef),
    pick(@intFromEnum(std.meta.Tag(Value).string)) ++ seed("hello"),
    pick(@intFromEnum(std.meta.Tag(Value).bytes)) ++ seed("\x00\x01\x02"),
    pick(@intFromEnum(std.meta.Tag(Value).children)) ++ pick(3) ++
        pick(@intFromEnum(std.meta.Tag(Value).int)) ++ pick(1) ++
        pick(@intFromEnum(std.meta.Tag(Value).string)) ++ seed("x") ++
        pick(@intFromEnum(std.meta.Tag(Value).fd)) ++ pick(0),
    // An Array of Ids, the shape of a channel position map.
    pick(@intFromEnum(std.meta.Tag(Value).ids)) ++ pick(2) ++ pick(3) ++ pick(4),
    // A Choice of three Ints, the shape of a buffer-size range.
    pick(@intFromEnum(std.meta.Tag(Value).choice)) ++ pick(3) ++
        pick(2) ++ pick(1) ++ pick(32) ++ pick(@intFromEnum(spa.Choice.range)),
    // An Object of one Id property, the shape of a Format.
    pick(@intFromEnum(std.meta.Tag(Value).object)) ++ pick(1) ++
        pick(@intFromEnum(std.meta.Tag(Value).id)) ++ pick(1) ++
        pick(spa.format.media_type) ++ pick(0) ++
        pick(spa.object_type.format) ++ pick(@intFromEnum(spa.Param.enum_format)),
    // An Object whose property is a Choice, which is where a container's size
    // and the padding after it have to agree.
    pick(@intFromEnum(std.meta.Tag(Value).object)) ++ pick(1) ++
        pick(@intFromEnum(std.meta.Tag(Value).choice)) ++ pick(3) ++
        pick(2) ++ pick(1) ++ pick(32) ++ pick(@intFromEnum(spa.Choice.range)) ++
        pick(spa.param_buffers.buffers) ++ pick(0) ++
        pick(spa.object_type.param_buffers) ++ pick(@intFromEnum(spa.Param.buffers)),
};

/// A message header is four little-endian `u32`s: the target object id, the
/// opcode in the top eight bits of the second word with the payload size in the
/// low twenty-four, a sequence number, and a descriptor count.
fn frame(comptime id: u32, comptime opcode: u8, comptime n_fds: u32, comptime payload: []const u8) []const u8 {
    return std.mem.toBytes(id)[0..] ++
        std.mem.toBytes((@as(u32, opcode) << 24) | @as(u32, payload.len))[0..] ++
        std.mem.toBytes(@as(u32, 0))[0..] ++
        std.mem.toBytes(n_fds)[0..] ++
        payload;
}

/// Streams of framing: nothing, a header with no body, a well-formed message, a
/// length that lies in each direction, and a message claiming descriptors that
/// did not come with it.
const message_corpus = [_][]const u8{
    seed(""),
    seed("\x00\x00\x00\x00"),
    seed(frame(0, 1, 0, header(0, .none))),
    seed(frame(0, 1, 0, header(4, .int) ++ "\x04\x00\x00\x00\x00\x00\x00\x00")),
    // Two messages back to back, which is how they usually arrive.
    seed(frame(0, 1, 0, header(0, .none)) ++ frame(2, 8, 0, header(0, .none))),
    // A payload longer than the bytes that follow.
    seed(frame(0, 1, 0, header(0, .none))[0..16] ++ "\x00"),
    // The largest length the field can hold.
    seed("\x00\x00\x00\x00" ++ "\xff\xff\xff\x00" ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x00"),
    // Descriptors claimed but none sent.
    seed(frame(2, 0, 4, header(0, .none))),
};

/// The PODs a registry message is made of, at the sizes and paddings the
/// protocol requires. Written out here rather than built with the `Builder`
/// because a corpus entry has to be a compile-time constant.
fn podInt(comptime v: i32) []const u8 {
    return header(4, .int) ++ std.mem.toBytes(v)[0..] ++ "\x00\x00\x00\x00";
}

fn podId(comptime v: u32) []const u8 {
    return header(4, .id) ++ std.mem.toBytes(v)[0..] ++ "\x00\x00\x00\x00";
}

fn podLong(comptime v: i64) []const u8 {
    return header(8, .long) ++ std.mem.toBytes(v)[0..];
}

fn podFloat(comptime v: f32) []const u8 {
    return header(4, .float) ++ std.mem.toBytes(v)[0..] ++ "\x00\x00\x00\x00";
}

fn podNone() []const u8 {
    return header(0, .none);
}

/// A string is stored with its terminator, and the whole POD is padded out to
/// the next multiple of eight.
fn podString(comptime text: []const u8) []const u8 {
    const pad = (8 - ((text.len + 1) % 8)) % 8;
    return header(@intCast(text.len + 1), .string) ++ text ++ "\x00" ++ ("\x00" ** pad);
}

fn podStruct(comptime body: []const u8) []const u8 {
    return header(@intCast(body.len), .@"struct") ++ body;
}

fn podObject(comptime object_type: u32, comptime id: u32, comptime body: []const u8) []const u8 {
    return header(@intCast(body.len + 8), .object) ++
        std.mem.toBytes(object_type)[0..] ++ std.mem.toBytes(id)[0..] ++ body;
}

fn podProp(comptime key: u32, comptime value: []const u8) []const u8 {
    return std.mem.toBytes(key)[0..] ++ std.mem.toBytes(@as(u32, 0))[0..] ++ value;
}

fn podFloatArray(comptime values: []const f32) []const u8 {
    comptime var body: []const u8 = header(4, .float);
    inline for (values) |v| body = body ++ std.mem.toBytes(v)[0..];
    const pad = (8 - (body.len % 8)) % 8;
    return header(@intCast(body.len), .array) ++ body ++ ("\x00" ** pad);
}

/// A properties dictionary: the item count, then that many pairs.
fn podDict(comptime items: []const [2][]const u8) []const u8 {
    comptime var body: []const u8 = podInt(@intCast(items.len));
    inline for (items) |item| body = body ++ podString(item[0]) ++ podString(item[1]);
    return podStruct(body);
}

/// Registry and object messages: the shapes a session is built out of, and the
/// ways each of them can be malformed.
const registry_corpus = blk: {
    // Every one of these is assembled out of nested `++` at compile time, which
    // is more steps than the default quota allows.
    @setEvalBranchQuota(100_000);
    break :blk [_][]const u8{
        seed(""),
        // Registry.Global for an audio sink, which is the message a listing is made
        // of.
        seed(podStruct(podInt(39) ++ podInt(0o700) ++ podString("PipeWire:Interface:Node") ++
            podInt(3) ++ podDict(&.{
            .{ "node.name", "alsa_output.pci" },
            .{ "media.class", "Audio/Sink" },
            .{ "object.serial", "64" },
        }))),
        // The same, promising more properties than it carries.
        seed(podStruct(podInt(39) ++ podInt(0o700) ++ podString("PipeWire:Interface:Node") ++
            podInt(3) ++ podStruct(podInt(99) ++ podString("node.name") ++ podString("x")))),
        // A global of an interface with no name here, and none of its own.
        seed(podStruct(podInt(1) ++ podInt(0) ++ podString("") ++ podInt(0) ++ podDict(&.{}))),
        // Registry.GlobalRemove.
        seed(podStruct(podInt(39))),
        // Node.Info: running, no error, one property, two parameters.
        seed(podStruct(podInt(7) ++ podInt(0) ++ podInt(64) ++ podLong(0b11100) ++
            podInt(0) ++ podInt(2) ++ podId(3) ++ podNone() ++
            podDict(&.{.{ "node.name", "sink" }}) ++
            podStruct(podInt(2) ++ podId(2) ++ podInt(6) ++ podId(4) ++ podInt(2)))),
        // Node.Info whose state is a number no version of PipeWire defines, and
        // whose parameter count runs past the message.
        seed(podStruct(podInt(7) ++ podInt(0) ++ podInt(0) ++ podLong(-1) ++
            podInt(0) ++ podInt(0) ++ podId(0xffffffff) ++ podString("broken") ++
            podDict(&.{}) ++ podStruct(podInt(2147483647)))),
        // Port.Info, which differs from a node's by having a direction and no state.
        seed(podStruct(podInt(93) ++ podId(1) ++ podLong(0b11) ++
            podDict(&.{ .{ "port.direction", "out" }, .{ "audio.channel", "FL" } }) ++
            podStruct(podInt(0)))),
        // Link.Info, whose format is a POD that may or may not be there.
        seed(podStruct(podInt(60) ++ podInt(91) ++ podInt(93) ++ podInt(39) ++ podInt(65) ++
            podLong(0b111) ++ podId(4) ++ podNone() ++ podNone() ++ podDict(&.{}))),
        // Metadata.Property, setting and then clearing.
        seed(podStruct(podInt(0) ++ podString("default.audio.sink") ++
            podString("Spa:String:JSON") ++ podString("{\"name\":\"alsa_output.pci\"}"))),
        seed(podStruct(podInt(60) ++ podNone() ++ podNone() ++ podNone())),
        // A Param event carrying a node's Props: mute and two channel volumes.
        seed(podStruct(podInt(0) ++ podId(2) ++ podInt(0) ++ podInt(1) ++
            podObject(0x40002, 2, podProp(0x10004, header(4, .bool) ++
                "\x00\x00\x00\x00\x00\x00\x00\x00") ++
                podProp(0x10008, podFloatArray(&.{ 0.25, 0.5 }))))),
        // A Param event carrying a device Route, which is where a card's volume is.
        seed(podStruct(podInt(0) ++ podId(13) ++ podInt(0) ++ podInt(1) ++
            podObject(0x40009, 13, podProp(1, podInt(5)) ++ podProp(3, podInt(11)) ++
                podProp(10, podObject(0x40002, 2, podProp(0x10003, podFloat(1.0)) ++
                    podProp(0x10008, podFloatArray(&.{ 0.9, 0.9 }))))))),
        // A channel-volume array with more channels than this library will
        // read, which is what the fixed-size array behind a `Volume` is for.
        seed(podStruct(podInt(0) ++ podId(2) ++ podInt(0) ++ podInt(0) ++
            podObject(0x40002, 2, podProp(0x10008, podFloatArray(&([_]f32{0.5} ** 70)))))),
        // A channel-volume array claiming more channels than any layout has.
        seed(podStruct(podInt(0) ++ podId(2) ++ podInt(0) ++ podInt(0) ++
            podObject(0x40002, 2, podProp(0x10008, header(0xffff, .array) ++
                header(4, .float) ++ "\x00\x00\x00\x00")))),
        // A Param event whose parameter is absent, which is how a parameter that is
        // not set arrives.
        seed(podStruct(podInt(0) ++ podId(2) ++ podInt(0) ++ podInt(0) ++ podNone())),
    };
};

/// Streams of Core events: a Done, a Ping the Core has to answer, an Error it
/// has to keep a copy of, an AddMem naming a descriptor that did not come, and
/// a RemoveMem for memory that was never added.
const core_corpus = [_][]const u8{
    seed(""),
    // Done(id, seq)
    seed(frame(0, 1, 0, header(32, .@"struct") ++
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++
        header(4, .int) ++ "\x00\x00\x00\x40\x00\x00\x00\x00")),
    // Ping(id, seq)
    seed(frame(0, 2, 0, header(32, .@"struct") ++
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++
        header(4, .int) ++ "\x07\x00\x00\x00\x00\x00\x00\x00")),
    // Error(id, seq, res, message)
    seed(frame(0, 3, 0, header(64, .@"struct") ++
        header(4, .int) ++ "\x02\x00\x00\x00\x00\x00\x00\x00" ++
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++
        header(4, .int) ++ "\xea\xff\xff\xff\x00\x00\x00\x00" ++
        header(7, .string) ++ "no good\x00")),
    // AddMem(id, type, fd index, flags)
    seed(frame(0, 6, 0, header(48, .@"struct") ++
        header(4, .int) ++ "\x01\x00\x00\x00\x00\x00\x00\x00" ++
        header(4, .id) ++ "\x02\x00\x00\x00\x00\x00\x00\x00" ++
        header(8, .fd) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00")),
    // RemoveMem(id) for something never added.
    seed(frame(0, 7, 0, header(16, .@"struct") ++
        header(4, .int) ++ "\x63\x00\x00\x00\x00\x00\x00\x00")),
    // Several at once, and one addressed to an object that does not exist.
    seed(frame(0, 1, 0, header(0, .none)) ++ frame(9, 3, 0, header(0, .none))),
};

/// The mapping length and base the `clientnode` target reads before its
/// payload: a page, at an aligned address.
const layoutArgs = pick(4096) ++ pick(0);

/// Payloads shaped like the events the daemon sends, and several that stop part
/// way through what they promise.
const event_corpus = [_][]const u8{
    layoutArgs ++ seed(""),
    // Transport: two Fd indices then three Ints.
    layoutArgs ++ seed(header(64, .@"struct") ++
        header(8, .fd) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++
        header(8, .fd) ++ "\x01\x00\x00\x00\x00\x00\x00\x00" ++
        header(4, .int) ++ "\x01\x00\x00\x00\x00\x00\x00\x00" ++
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++
        header(4, .int) ++ "\x08\x09\x00\x00\x00\x00\x00\x00"),
    // PortUseBuffers: one buffer, no metadata, one data block.
    layoutArgs ++ seed(header(160, .@"struct") ++
        header(4, .int) ++ "\x01\x00\x00\x00\x00\x00\x00\x00" ++ // direction
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++ // port
        header(4, .int) ++ "\xff\xff\xff\xff\x00\x00\x00\x00" ++ // mix
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++ // flags
        header(4, .int) ++ "\x01\x00\x00\x00\x00\x00\x00\x00" ++ // one buffer
        header(4, .int) ++ "\x07\x00\x00\x00\x00\x00\x00\x00" ++ // mem id
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++ // offset
        header(4, .int) ++ "\x00\x10\x00\x00\x00\x00\x00\x00" ++ // size
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++ // no metas
        header(4, .int) ++ "\x01\x00\x00\x00\x00\x00\x00\x00" ++ // one data
        header(4, .id) ++ "\x01\x00\x00\x00\x00\x00\x00\x00" ++ // MemPtr
        header(4, .int) ++ "\x40\x00\x00\x00\x00\x00\x00\x00" ++ // offset in map
        header(4, .int) ++ "\x03\x00\x00\x00\x00\x00\x00\x00" ++ // flags
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++ // mapoffset
        header(4, .int) ++ "\x00\x04\x00\x00\x00\x00\x00\x00"), // maxsize
    // A buffer count far past the cap.
    layoutArgs ++ seed(header(40, .@"struct") ++
        header(4, .int) ++ "\x01\x00\x00\x00\x00\x00\x00\x00" ++
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++
        header(4, .int) ++ "\xff\xff\xff\x7f\x00\x00\x00\x00"),
    // A direction that is neither input nor output, which used to be decoded
    // straight into a two-valued enum.
    layoutArgs ++ seed(header(64, .@"struct") ++
        header(4, .int) ++ "\xff\xff\xff\x7f\x00\x00\x00\x00" ++ // direction
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++ // port
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++ // mix
        header(4, .id) ++ "\x01\x00\x00\x00\x00\x00\x00\x00" ++ // io id
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00"), // mem id
    // A Start command.
    layoutArgs ++ seed(header(24, .@"struct") ++
        header(8, .object) ++ "\x02\x00\x03\x00" ++ "\x02\x00\x00\x00"),
    // PortSetParam carrying a positioned stereo format.
    layoutArgs ++ seed(header(128, .@"struct") ++
        header(4, .int) ++ "\x01\x00\x00\x00\x00\x00\x00\x00" ++
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++
        header(4, .id) ++ "\x04\x00\x00\x00\x00\x00\x00\x00" ++
        header(4, .int) ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++
        header(72, .object) ++ "\x03\x00\x04\x00" ++ "\x04\x00\x00\x00" ++
        "\x04\x00\x01\x00" ++ "\x00\x00\x00\x00" ++
        header(4, .int) ++ "\x02\x00\x00\x00\x00\x00\x00\x00" ++
        "\x05\x00\x01\x00" ++ "\x00\x00\x00\x00" ++
        header(16, .array) ++ header(4, .id) ++ "\x03\x00\x00\x00\x04\x00\x00\x00"),
};

/// Layout decisions: the shape a real buffer has, one whose data runs past the
/// mapping, one with metadata before the chunk, and one asking for a block type
/// that is not plain memory.
const layout_corpus = [_][]const u8{
    // mem_id, offset, size, n_metas, n_datas, then the block, then map and base.
    pick(7) ++ pick(0) ++ pick(4096) ++ pick(0) ++ pick(1) ++
        pick(@intFromEnum(spa.DataType.mem_ptr)) ++ pick(64) ++ pick(3) ++ pick(0) ++ pick(1024) ++
        pick(4096) ++ pick(0),
    pick(7) ++ pick(0) ++ pick(64) ++ pick(0) ++ pick(1) ++
        pick(@intFromEnum(spa.DataType.mem_ptr)) ++ pick(0) ++ pick(0) ++ pick(0) ++ pick(0xffffffff) ++
        pick(64) ++ pick(0),
    pick(7) ++ pick(0) ++ pick(4096) ++ pick(2) ++ pick(1) ++
        pick(16) ++ pick(8) ++ pick(32) ++ pick(8) ++
        pick(@intFromEnum(spa.DataType.mem_ptr)) ++ pick(64) ++ pick(3) ++ pick(0) ++ pick(512) ++
        pick(4096) ++ pick(0),
    pick(7) ++ pick(0) ++ pick(4096) ++ pick(0) ++ pick(1) ++
        pick(@intFromEnum(spa.DataType.dma_buf)) ++ pick(0) ++ pick(0) ++ pick(0) ++ pick(1024) ++
        pick(4096) ++ pick(0),
    // An odd base, so nothing is aligned.
    pick(7) ++ pick(0) ++ pick(4096) ++ pick(0) ++ pick(1) ++
        pick(@intFromEnum(spa.DataType.mem_ptr)) ++ pick(1) ++ pick(0) ++ pick(0) ++ pick(64) ++
        pick(4096) ++ pick(1),
};

/// Ring inputs: the channel count and the capacity, then a string of operation
/// bytes — the low bit writes or reads and the rest is the frame count.
///
/// The shapes worth seeding are a ring that stays half full, one written past
/// its capacity, one read while empty, and one whose writes and reads are large
/// enough relative to its capacity that the indices go round several times.
const ring_corpus = [_][]const u8{
    pick(2) ++ pick(8) ++ seed(&.{ 0x09, 0x08, 0x09, 0x08, 0x09, 0x08 }),
    pick(1) ++ pick(4) ++ seed(&.{ 0x7f, 0x7e, 0x7f, 0x7e }),
    pick(2) ++ pick(16) ++ seed(&.{ 0x10, 0x20, 0x0e }),
    pick(8) ++ pick(2) ++ seed(&.{ 0x0b, 0x0a, 0x0b, 0x0a, 0x0b, 0x0a, 0x0b, 0x0a }),
    // Writes and reads of three frames through a ring of four, so every pass
    // lands at a different offset and one of them straddles the wrap.
    pick(3) ++ pick(4) ++ seed(&.{ 0x07, 0x06, 0x07, 0x06, 0x07, 0x06, 0x07, 0x06, 0x07, 0x06 }),
};
