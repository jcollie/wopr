// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! SPA POD encoding and decoding.
//!
//! A POD ("plain old data") is PipeWire's self-describing value format. Every
//! POD is an 8-byte header — a `u32` body size and a `u32` type tag — followed
//! by that many bytes of body, then zero padding up to the next multiple of 8.
//! Containers (Struct, Object, Array, Choice) hold their children inside their
//! own body, so a whole message is one nested POD tree in native byte order.

const std = @import("std");
const spa = @import("spa.zig");

const Type = spa.Type;

pub const Error = error{
    /// The bytes ran out mid-POD, or a child claims to be larger than its parent.
    Truncated,
    /// A POD was well-formed but not of the type the caller asked for.
    UnexpectedType,
};

/// The fixed 8-byte prefix of every POD.
pub const Header = extern struct {
    size: u32,
    type: Type,
};

fn roundUp8(n: usize) usize {
    return (n + 7) & ~@as(usize, 7);
}

// --- Builder ---------------------------------------------------------------

/// Serializes a POD tree into a growable buffer.
///
/// Containers are written with a `push*` / `pop` pair: `push` emits a header
/// with a placeholder size and returns a `Frame`, and `pop` backpatches the size
/// once the children have been written. Frames must be popped in reverse order,
/// which the natural nesting of calls gives you for free.
pub const Builder = struct {
    buf: std.ArrayListAligned(u8, .@"8"),
    gpa: std.mem.Allocator,

    pub const Frame = struct { offset: usize };

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{ .buf = .empty, .gpa = gpa };
    }

    pub fn deinit(b: *Builder) void {
        b.buf.deinit(b.gpa);
    }

    pub fn clear(b: *Builder) void {
        b.buf.clearRetainingCapacity();
    }

    pub fn bytes(b: *const Builder) []const u8 {
        return b.buf.items;
    }

    fn raw(b: *Builder, data: []const u8) !void {
        try b.buf.appendSlice(b.gpa, data);
    }

    /// Append one element to an open Array or Choice, which store their values
    /// bare rather than as nested PODs.
    pub fn addRaw(b: *Builder, data: []const u8) !void {
        try b.raw(data);
    }

    /// Pad the buffer out to the next 8-byte boundary, as every POD must be.
    fn pad(b: *Builder) !void {
        const zeroes = [_]u8{0} ** 8;
        const n = roundUp8(b.buf.items.len) - b.buf.items.len;
        if (n != 0) try b.raw(zeroes[0..n]);
    }

    fn header(b: *Builder, size: u32, t: Type) !void {
        try b.raw(std.mem.asBytes(&Header{ .size = size, .type = t }));
    }

    /// Write a complete POD: header, body, padding.
    fn primitive(b: *Builder, t: Type, body: []const u8) !void {
        try b.header(@intCast(body.len), t);
        try b.raw(body);
        try b.pad();
    }

    pub fn addNone(b: *Builder) !void {
        try b.primitive(.none, &.{});
    }

    pub fn addBool(b: *Builder, v: bool) !void {
        const x: i32 = if (v) 1 else 0;
        try b.primitive(.bool, std.mem.asBytes(&x));
    }

    pub fn addId(b: *Builder, v: u32) !void {
        try b.primitive(.id, std.mem.asBytes(&v));
    }

    pub fn addInt(b: *Builder, v: i32) !void {
        try b.primitive(.int, std.mem.asBytes(&v));
    }

    pub fn addLong(b: *Builder, v: i64) !void {
        try b.primitive(.long, std.mem.asBytes(&v));
    }

    pub fn addFloat(b: *Builder, v: f32) !void {
        try b.primitive(.float, std.mem.asBytes(&v));
    }

    pub fn addDouble(b: *Builder, v: f64) !void {
        try b.primitive(.double, std.mem.asBytes(&v));
    }

    /// Strings are stored NUL-terminated and the terminator counts in the size.
    pub fn addString(b: *Builder, s: []const u8) !void {
        try b.header(@intCast(s.len + 1), .string);
        try b.raw(s);
        try b.raw(&[_]u8{0});
        try b.pad();
    }

    /// A string, or the None that the protocol uses for a null one: PipeWire's
    /// own builder writes None when handed a NULL `const char *`, so an absent
    /// name or error message arrives as a None rather than as an empty string.
    pub fn addOptionalString(b: *Builder, s: ?[]const u8) !void {
        if (s) |v| try b.addString(v) else try b.addNone();
    }

    pub fn addBytes(b: *Builder, s: []const u8) !void {
        try b.primitive(.bytes, s);
    }

    pub fn addRectangle(b: *Builder, v: spa.Rectangle) !void {
        try b.primitive(.rectangle, std.mem.asBytes(&v));
    }

    pub fn addFraction(b: *Builder, v: spa.Fraction) !void {
        try b.primitive(.fraction, std.mem.asBytes(&v));
    }

    /// An Fd POD carries an index into the message's file-descriptor array, not
    /// the descriptor number itself — the kernel rewrites descriptors in transit.
    pub fn addFd(b: *Builder, index: i64) !void {
        try b.primitive(.fd, std.mem.asBytes(&index));
    }

    /// Splice an already-encoded POD in verbatim. A null writes a None, which is
    /// how the protocol spells "this optional field is absent".
    pub fn addPod(b: *Builder, encoded: ?[]const u8) !void {
        if (encoded) |p| {
            try b.raw(p);
            try b.pad();
        } else {
            try b.addNone();
        }
    }

    pub fn pushStruct(b: *Builder) !Frame {
        const off = b.buf.items.len;
        try b.header(0, .@"struct");
        return .{ .offset = off };
    }

    pub fn pushObject(b: *Builder, object_type: u32, id: u32) !Frame {
        const off = b.buf.items.len;
        try b.header(8, .object);
        try b.raw(std.mem.asBytes(&object_type));
        try b.raw(std.mem.asBytes(&id));
        return .{ .offset = off };
    }

    pub fn pushArray(b: *Builder, child_size: u32, child_type: Type) !Frame {
        const off = b.buf.items.len;
        try b.header(8, .array);
        try b.header(child_size, child_type);
        return .{ .offset = off };
    }

    pub fn pushChoice(b: *Builder, kind: spa.Choice, child_size: u32, child_type: Type) !Frame {
        const off = b.buf.items.len;
        try b.header(8, .choice);
        try b.raw(std.mem.asBytes(&@intFromEnum(kind)));
        try b.raw(std.mem.asBytes(&@as(u32, 0))); // flags
        try b.header(child_size, child_type);
        return .{ .offset = off };
    }

    /// Start a property inside an Object. The next POD written becomes its value.
    pub fn prop(b: *Builder, key: u32, flags: u32) !void {
        try b.raw(std.mem.asBytes(&key));
        try b.raw(std.mem.asBytes(&flags));
    }

    /// Close a container, backpatching its size.
    ///
    /// The size is taken before padding: PipeWire charges a POD's trailing
    /// padding to its parent, not to itself, and a parser that trusted a size
    /// which included the padding would walk off the end of the last child.
    pub fn pop(b: *Builder, f: Frame) !void {
        const size: u32 = @intCast(b.buf.items.len - f.offset - @sizeOf(Header));
        std.mem.writeInt(u32, b.buf.items[f.offset..][0..4], size, .little);
        try b.pad();
    }

    // Convenience wrappers for the shapes that show up over and over.

    pub fn objectPropId(b: *Builder, key: u32, v: u32) !void {
        try b.prop(key, 0);
        try b.addId(v);
    }

    pub fn objectPropInt(b: *Builder, key: u32, v: i32) !void {
        try b.prop(key, 0);
        try b.addInt(v);
    }

    /// A `Range` choice: current value, then the inclusive minimum and maximum.
    pub fn objectPropRangeInt(b: *Builder, key: u32, def: i32, min: i32, max: i32) !void {
        try b.prop(key, 0);
        const f = try b.pushChoice(.range, 4, .int);
        for ([_]i32{ def, min, max }) |v| try b.raw(std.mem.asBytes(&v));
        try b.pop(f);
    }

    /// A `Step` choice: current value, minimum, maximum and the allowed step.
    pub fn objectPropStepInt(b: *Builder, key: u32, def: i32, min: i32, max: i32, step: i32) !void {
        try b.prop(key, 0);
        const f = try b.pushChoice(.step, 4, .int);
        for ([_]i32{ def, min, max, step }) |v| try b.raw(std.mem.asBytes(&v));
        try b.pop(f);
    }
};

// --- Parser ----------------------------------------------------------------

/// A borrowed view of one POD: its type tag and its body bytes.
///
/// The body points into the buffer being parsed, so a `Pod` — and any string it
/// yields — lives only as long as that buffer.
pub const Pod = struct {
    type: Type,
    body: []const u8,

    /// The POD re-encoded, header included. Use this to forward a value onward
    /// without decoding it.
    encoded: []const u8,

    pub fn asBool(p: Pod) Error!bool {
        if (p.type != .bool or p.body.len < 4) return error.UnexpectedType;
        return std.mem.readInt(i32, p.body[0..4], .little) != 0;
    }

    pub fn asId(p: Pod) Error!u32 {
        if (p.type != .id or p.body.len < 4) return error.UnexpectedType;
        return std.mem.readInt(u32, p.body[0..4], .little);
    }

    pub fn asInt(p: Pod) Error!i32 {
        if (p.type != .int or p.body.len < 4) return error.UnexpectedType;
        return std.mem.readInt(i32, p.body[0..4], .little);
    }

    pub fn asLong(p: Pod) Error!i64 {
        if (p.type != .long or p.body.len < 8) return error.UnexpectedType;
        return std.mem.readInt(i64, p.body[0..8], .little);
    }

    pub fn asFd(p: Pod) Error!i64 {
        if (p.type != .fd or p.body.len < 8) return error.UnexpectedType;
        return std.mem.readInt(i64, p.body[0..8], .little);
    }

    pub fn asFloat(p: Pod) Error!f32 {
        if (p.type != .float or p.body.len < 4) return error.UnexpectedType;
        return @bitCast(std.mem.readInt(u32, p.body[0..4], .little));
    }

    pub fn asDouble(p: Pod) Error!f64 {
        if (p.type != .double or p.body.len < 8) return error.UnexpectedType;
        return @bitCast(std.mem.readInt(u64, p.body[0..8], .little));
    }

    /// The string without its NUL terminator.
    pub fn asString(p: Pod) Error![]const u8 {
        if (p.type != .string) return error.UnexpectedType;
        if (p.body.len == 0) return "";
        return std.mem.sliceTo(p.body, 0);
    }

    /// An `int`, or an `id` — the protocol is loose about which of the two it
    /// uses for small enumerated values, and both are 4 bytes.
    pub fn asIntOrId(p: Pod) Error!u32 {
        if (p.body.len < 4) return error.UnexpectedType;
        return switch (p.type) {
            .int, .id => std.mem.readInt(u32, p.body[0..4], .little),
            else => error.UnexpectedType,
        };
    }

    /// An Array's element type, size and packed element bytes.
    ///
    /// Array elements are stored bare, without a POD header each, so they are
    /// read out by size rather than by parsing.
    pub fn arrayBody(p: Pod) Error!ArrayBody {
        if (p.type != .array or p.body.len < 8) return error.UnexpectedType;
        const child_size = std.mem.readInt(u32, p.body[0..4], .little);
        const child_type: Type = @enumFromInt(std.mem.readInt(u32, p.body[4..8], .little));
        return .{
            .child_type = child_type,
            .child_size = child_size,
            .elements = p.body[8..],
        };
    }

    /// A parser over the children of a Struct.
    pub fn structFields(p: Pod) Error!Parser {
        if (p.type != .@"struct") return error.UnexpectedType;
        return Parser.init(p.body);
    }

    /// The `(type, id)` of an Object, plus a parser over its properties.
    pub fn objectBody(p: Pod) Error!ObjectBody {
        if (p.type != .object or p.body.len < 8) return error.UnexpectedType;
        return .{
            .type = std.mem.readInt(u32, p.body[0..4], .little),
            .id = std.mem.readInt(u32, p.body[4..8], .little),
            .rest = p.body[8..],
        };
    }
};

pub const ArrayBody = struct {
    child_type: Type,
    child_size: u32,
    elements: []const u8,

    pub fn count(a: ArrayBody) usize {
        if (a.child_size == 0) return 0;
        return a.elements.len / a.child_size;
    }

    /// The `index`th element as a `u32`, for the Id and Int arrays the protocol
    /// uses for things like channel positions.
    pub fn u32At(a: ArrayBody, index: usize) Error!u32 {
        if (a.child_size != 4 or index >= a.count()) return error.UnexpectedType;
        return std.mem.readInt(u32, a.elements[index * 4 ..][0..4], .little);
    }

    /// The `index`th element as an `f32`, for the Float arrays that carry
    /// per-channel volumes.
    pub fn f32At(a: ArrayBody, index: usize) Error!f32 {
        if (a.child_type != .float) return error.UnexpectedType;
        return @bitCast(try a.u32At(index));
    }
};

pub const Property = struct {
    key: u32,
    flags: u32,
    value: Pod,
};

pub const ObjectBody = struct {
    type: u32,
    id: u32,
    rest: []const u8,

    /// Read the next property, or null at the end of the object.
    pub fn next(o: *ObjectBody) Error!?Property {
        if (o.rest.len == 0) return null;
        if (o.rest.len < 8) return error.Truncated;
        const key = std.mem.readInt(u32, o.rest[0..4], .little);
        const flags = std.mem.readInt(u32, o.rest[4..8], .little);
        var p = Parser.init(o.rest[8..]);
        const value = try p.next() orelse return error.Truncated;
        o.rest = o.rest[8 + p.pos ..];
        return .{ .key = key, .flags = flags, .value = value };
    }
};

/// Walks a sequence of PODs laid end to end, as found in a message payload or
/// inside a Struct body.
pub const Parser = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Parser {
        return .{ .data = data };
    }

    pub fn atEnd(p: *const Parser) bool {
        return p.pos >= p.data.len;
    }

    /// Read the next POD, or null once the buffer is exhausted.
    pub fn next(p: *Parser) Error!?Pod {
        if (p.pos >= p.data.len) return null;
        if (p.data.len - p.pos < @sizeOf(Header)) return error.Truncated;
        const size = std.mem.readInt(u32, p.data[p.pos..][0..4], .little);
        const t: Type = @enumFromInt(std.mem.readInt(u32, p.data[p.pos + 4 ..][0..4], .little));
        const body_start = p.pos + @sizeOf(Header);
        const body_end = std.math.add(usize, body_start, size) catch return error.Truncated;
        if (body_end > p.data.len) return error.Truncated;
        const pod: Pod = .{
            .type = t,
            .body = p.data[body_start..body_end],
            .encoded = p.data[p.pos..body_end],
        };
        // Advance past the padding as well; a trailing POD may be unpadded at
        // the very end of a buffer, so clamp rather than fail.
        p.pos = @min(roundUp8(body_end), p.data.len);
        return pod;
    }

    fn expect(p: *Parser, t: Type) Error!Pod {
        const pod = try p.next() orelse return error.Truncated;
        if (pod.type != t) return error.UnexpectedType;
        return pod;
    }

    pub fn nextInt(p: *Parser) Error!i32 {
        return (try p.expect(.int)).asInt();
    }

    pub fn nextLong(p: *Parser) Error!i64 {
        return (try p.expect(.long)).asLong();
    }

    pub fn nextId(p: *Parser) Error!u32 {
        const pod = try p.next() orelse return error.Truncated;
        return pod.asIntOrId();
    }

    pub fn nextFd(p: *Parser) Error!i64 {
        return (try p.expect(.fd)).asFd();
    }

    pub fn nextString(p: *Parser) Error![]const u8 {
        return (try p.expect(.string)).asString();
    }

    /// The next POD as a string, or null if it is the None that stands in for a
    /// null one. Most of the strings the daemon sends are optional this way:
    /// a node with nothing wrong with it still has an `error` field.
    pub fn nextOptionalString(p: *Parser) Error!?[]const u8 {
        const pod = try p.next() orelse return error.Truncated;
        return switch (pod.type) {
            .string => try pod.asString(),
            .none => null,
            else => error.UnexpectedType,
        };
    }

    pub fn nextStruct(p: *Parser) Error!Parser {
        return (try p.expect(.@"struct")).structFields();
    }

    /// The next POD whatever it is, or null for the None that stands in for an
    /// absent optional value.
    pub fn nextOptionalPod(p: *Parser) Error!?Pod {
        const pod = try p.next() orelse return error.Truncated;
        return if (pod.type == .none) null else pod;
    }

    /// The next POD if it is an Object, or null if it is the None that stands in
    /// for an absent optional value.
    pub fn nextOptionalObject(p: *Parser) Error!?Pod {
        const pod = try p.next() orelse return error.Truncated;
        return switch (pod.type) {
            .object => pod,
            .none => null,
            else => error.UnexpectedType,
        };
    }
};

// --- Tests -----------------------------------------------------------------

test "primitives round-trip with correct padding" {
    var b = Builder.init(std.testing.allocator);
    defer b.deinit();

    const f = try b.pushStruct();
    try b.addInt(-7);
    try b.addLong(1 << 40);
    try b.addString("hello");
    try b.addId(42);
    try b.pop(f);

    // Struct header + Int(8+4+4) + Long(8+8) + String(8+6+pad2) + Id(8+4+4)
    try std.testing.expectEqual(@as(usize, 8 + 16 + 16 + 16 + 16), b.bytes().len);

    var p = Parser.init(b.bytes());
    var fields = try p.nextStruct();
    try std.testing.expectEqual(@as(i32, -7), try fields.nextInt());
    try std.testing.expectEqual(@as(i64, 1 << 40), try fields.nextLong());
    try std.testing.expectEqualStrings("hello", try fields.nextString());
    try std.testing.expectEqual(@as(u32, 42), try fields.nextId());
    try std.testing.expect(fields.atEnd());
}

test "object properties round-trip" {
    var b = Builder.init(std.testing.allocator);
    defer b.deinit();

    const f = try b.pushObject(spa.object_type.format, @intFromEnum(spa.Param.enum_format));
    try b.objectPropId(spa.format.media_type, spa.media_type.audio);
    try b.objectPropId(spa.format.media_subtype, spa.media_subtype.dsp);
    try b.objectPropId(spa.format.audio_format, spa.audio_format.dsp_f32);
    try b.pop(f);

    var p = Parser.init(b.bytes());
    const pod = try p.next() orelse return error.Truncated;
    var obj = try pod.objectBody();
    try std.testing.expectEqual(spa.object_type.format, obj.type);
    try std.testing.expectEqual(@intFromEnum(spa.Param.enum_format), obj.id);

    const expect_keys = [_]u32{ spa.format.media_type, spa.format.media_subtype, spa.format.audio_format };
    const expect_vals = [_]u32{ spa.media_type.audio, spa.media_subtype.dsp, spa.audio_format.dsp_f32 };
    for (expect_keys, expect_vals) |k, v| {
        const prop = try obj.next() orelse return error.Truncated;
        try std.testing.expectEqual(k, prop.key);
        try std.testing.expectEqual(v, try prop.value.asId());
    }
    try std.testing.expect(try obj.next() == null);
}

test "choice encodes as current value plus bounds" {
    var b = Builder.init(std.testing.allocator);
    defer b.deinit();

    const f = try b.pushObject(spa.object_type.param_buffers, @intFromEnum(spa.Param.buffers));
    try b.objectPropRangeInt(spa.param_buffers.buffers, 2, 1, 32);
    try b.pop(f);

    var p = Parser.init(b.bytes());
    const pod = try p.next() orelse return error.Truncated;
    var obj = try pod.objectBody();
    const prop = try obj.next() orelse return error.Truncated;
    try std.testing.expectEqual(Type.choice, prop.value.type);
    // Choice body: kind, flags, child header, then three i32 values.
    try std.testing.expectEqual(@as(usize, 16 + 12), prop.value.body.len);
    try std.testing.expectEqual(
        @intFromEnum(spa.Choice.range),
        std.mem.readInt(u32, prop.value.body[0..4], .little),
    );
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, prop.value.body[16..20], .little));
    try std.testing.expectEqual(@as(i32, 32), std.mem.readInt(i32, prop.value.body[24..28], .little));
}

test "an id array reads back element by element" {
    var b = Builder.init(std.testing.allocator);
    defer b.deinit();

    const f = try b.pushArray(4, .id);
    for ([_]u32{ 3, 4, 5 }) |v| try b.addRaw(std.mem.asBytes(&v));
    try b.pop(f);

    var p = Parser.init(b.bytes());
    const arr = try (try p.next() orelse return error.Truncated).arrayBody();
    try std.testing.expectEqual(Type.id, arr.child_type);
    try std.testing.expectEqual(@as(usize, 3), arr.count());
    try std.testing.expectEqual(@as(u32, 3), try arr.u32At(0));
    try std.testing.expectEqual(@as(u32, 5), try arr.u32At(2));
}

test "parser rejects a body that runs past the buffer" {
    var bad: [8]u8 = undefined;
    std.mem.writeInt(u32, bad[0..4], 999, .little);
    std.mem.writeInt(u32, bad[4..8], @intFromEnum(Type.string), .little);
    var p = Parser.init(&bad);
    try std.testing.expectError(error.Truncated, p.next());
}
