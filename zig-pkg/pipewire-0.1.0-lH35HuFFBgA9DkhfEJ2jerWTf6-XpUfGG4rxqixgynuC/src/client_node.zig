// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Encoding and decoding for the `client-node` interface.
//!
//! A client-node is a node in the daemon's graph whose processing happens in our
//! process. The daemon drives it: it tells us what format a port settled on,
//! hands us shared buffers and the small "io" areas used to pass buffers between
//! peers, and gives us an eventfd pair plus an activation record so the graph can
//! wake us once per cycle.
//!
//! This module only turns those messages into and out of PODs. The state machine
//! that acts on them lives in `stream.zig`.

const std = @import("std");
const spa = @import("spa.zig");
const pod = @import("pod.zig");
const conn = @import("connection.zig");
const core_mod = @import("core.zig");

pub const version: u32 = 6;

pub const method = struct {
    pub const get_node: u8 = 1;
    pub const update: u8 = 2;
    pub const port_update: u8 = 3;
    pub const set_active: u8 = 4;
    pub const event: u8 = 5;
    pub const port_buffers: u8 = 6;
};

pub const event = struct {
    pub const transport: u8 = 0;
    pub const set_param: u8 = 1;
    pub const set_io: u8 = 2;
    pub const event: u8 = 3;
    pub const command: u8 = 4;
    pub const add_port: u8 = 5;
    pub const remove_port: u8 = 6;
    pub const port_set_param: u8 = 7;
    pub const port_use_buffers: u8 = 8;
    pub const port_set_io: u8 = 9;
    pub const set_activation: u8 = 10;
    pub const port_set_mix_info: u8 = 11;
};

/// `change_mask` bits for the Update and PortUpdate methods.
pub const update_mask = struct {
    pub const params: u32 = 1 << 0;
    pub const info: u32 = 1 << 1;
};

pub const ParamInfo = struct {
    id: spa.Param,
    flags: u32,
};

pub const NodeInfo = struct {
    max_input_ports: u32,
    max_output_ports: u32,
    change_mask: u64,
    flags: u64,
    props: []const core_mod.Prop,
    params: []const ParamInfo,
};

pub const PortInfo = struct {
    change_mask: u64,
    flags: u64,
    rate: spa.Fraction = .{ .num = 0, .denom = 1 },
    props: []const core_mod.Prop,
    params: []const ParamInfo,
};

// --- outgoing methods ------------------------------------------------------

/// `ClientNode.Update`: our node's parameters and info.
pub fn writeUpdate(
    b: *pod.Builder,
    change_mask: u32,
    params: []const []const u8,
    info: ?NodeInfo,
) !void {
    const f = try b.pushStruct();
    try b.addInt(@bitCast(change_mask));
    try b.addInt(@intCast(params.len));
    for (params) |p| try b.addPod(p);

    if (info) |i| {
        const g = try b.pushStruct();
        try b.addInt(@bitCast(i.max_input_ports));
        try b.addInt(@bitCast(i.max_output_ports));
        try b.addLong(@bitCast(i.change_mask));
        try b.addLong(@bitCast(i.flags));
        try writeDictItems(b, i.props, i.change_mask & spa.node_change.props != 0);
        try writeParamInfo(b, i.params, i.change_mask & spa.node_change.params != 0);
        try b.pop(g);
    } else {
        try b.addPod(null);
    }
    try b.pop(f);
}

/// `ClientNode.PortUpdate`: one port's parameters and info.
pub fn writePortUpdate(
    b: *pod.Builder,
    direction: spa.Direction,
    port_id: u32,
    change_mask: u32,
    params: []const []const u8,
    info: ?PortInfo,
) !void {
    const f = try b.pushStruct();
    try b.addInt(@bitCast(@intFromEnum(direction)));
    try b.addInt(@bitCast(port_id));
    try b.addInt(@bitCast(change_mask));
    try b.addInt(@intCast(params.len));
    for (params) |p| try b.addPod(p);

    if (info) |i| {
        const g = try b.pushStruct();
        try b.addLong(@bitCast(i.change_mask));
        try b.addLong(@bitCast(i.flags));
        try b.addInt(@bitCast(i.rate.num));
        try b.addInt(@bitCast(i.rate.denom));
        try writeDictItems(b, i.props, true);
        // Unlike the node Update, the port form always writes its param list.
        try writeParamInfo(b, i.params, true);
        try b.pop(g);
    } else {
        try b.addPod(null);
    }
    try b.pop(f);
}

pub fn writeSetActive(b: *pod.Builder, active: bool) !void {
    const f = try b.pushStruct();
    try b.addBool(active);
    try b.pop(f);
}

/// Dictionary items written inline (a count then key/value pairs), which is how
/// the info structs carry properties — note there is no enclosing Struct here,
/// unlike `core.writeDict`.
fn writeDictItems(b: *pod.Builder, props: []const core_mod.Prop, include: bool) !void {
    const n: usize = if (include) props.len else 0;
    try b.addInt(@intCast(n));
    for (props[0..n]) |p| {
        try b.addString(p.key);
        try b.addString(p.value);
    }
}

fn writeParamInfo(b: *pod.Builder, params: []const ParamInfo, include: bool) !void {
    const n: usize = if (include) params.len else 0;
    try b.addInt(@intCast(n));
    for (params[0..n]) |p| {
        try b.addId(@intFromEnum(p.id));
        try b.addInt(@bitCast(p.flags));
    }
}

// --- incoming events -------------------------------------------------------

pub const Transport = struct {
    /// eventfd the graph writes to wake us; we read it once per cycle.
    read_fd: i32,
    /// eventfd we would write to wake the graph. Unused for a driven node.
    write_fd: i32,
    mem_id: u32,
    offset: u32,
    size: u32,
};

pub const SetIo = struct {
    id: spa.IoType,
    mem_id: u32,
    offset: u32,
    size: u32,
};

pub const PortSetIo = struct {
    direction: spa.Direction,
    port_id: u32,
    mix_id: u32,
    id: spa.IoType,
    mem_id: u32,
    offset: u32,
    size: u32,
};

pub const SetActivation = struct {
    node_id: u32,
    /// eventfd to wake this peer, or -1 when the peer is going away.
    signal_fd: i32,
    mem_id: u32,
    offset: u32,
    size: u32,
};

pub const SetParam = struct {
    id: spa.Param,
    flags: u32,
    /// The parameter object, or null to clear it.
    param: ?pod.Pod,
};

pub const PortSetParam = struct {
    direction: spa.Direction,
    port_id: u32,
    id: spa.Param,
    flags: u32,
    /// The parameter object, or null to clear it.
    param: ?pod.Pod,
};

pub const PortSetMixInfo = struct {
    direction: spa.Direction,
    port_id: u32,
    mix_id: u32,
    /// The port we are now linked to, or `spa.id_invalid` when unlinked.
    peer_id: u32,
};

pub const MetaDesc = struct {
    type: u32,
    size: u32,
};

pub const DataDesc = struct {
    type: spa.DataType,
    /// For a `mem_ptr` block this is the byte offset within the buffer's own
    /// mapping; for a `mem_id` block it is the id of another pooled block.
    data_id: u32,
    flags: u32,
    mapoffset: u32,
    maxsize: u32,
};

/// One buffer as the daemon describes it: a region of a pooled memory block that
/// holds the metadata, the chunk records and the sample data all together.
pub const BufferDesc = struct {
    mem_id: u32,
    offset: u32,
    size: u32,
    n_metas: u32,
    n_datas: u32,
    metas: [max_metas]MetaDesc,
    datas: [max_datas]DataDesc,

    pub fn metaSlice(d: *const BufferDesc) []const MetaDesc {
        return d.metas[0..d.n_metas];
    }

    pub fn dataSlice(d: *const BufferDesc) []const DataDesc {
        return d.datas[0..d.n_datas];
    }
};

/// Caps on what one `PortUseBuffers` may describe. A DSP audio port uses one
/// data block and no metadata, so these are generous.
pub const max_buffers = 64;
pub const max_metas = 8;
pub const max_datas = 8;

pub const UseBuffers = struct {
    direction: spa.Direction,
    port_id: u32,
    mix_id: u32,
    flags: u32,
    n_buffers: u32,
    buffers: [max_buffers]BufferDesc,

    pub fn slice(u: *const UseBuffers) []const BufferDesc {
        return u.buffers[0..u.n_buffers];
    }
};

pub const ParseError = pod.Error || error{TooManyBuffers};

pub fn parseTransport(msg: conn.Message) ParseError!Transport {
    var p = msg.parser();
    var s = try p.nextStruct();
    const read_index = try s.nextFd();
    const write_index = try s.nextFd();
    return .{
        .read_fd = msg.takeFd(read_index),
        .write_fd = msg.takeFd(write_index),
        .mem_id = @bitCast(try s.nextInt()),
        .offset = @bitCast(try s.nextInt()),
        .size = @bitCast(try s.nextInt()),
    };
}

pub fn parseSetIo(msg: conn.Message) ParseError!SetIo {
    var p = msg.parser();
    var s = try p.nextStruct();
    return .{
        .id = @enumFromInt(try s.nextId()),
        .mem_id = @bitCast(try s.nextInt()),
        .offset = @bitCast(try s.nextInt()),
        .size = @bitCast(try s.nextInt()),
    };
}

pub fn parsePortSetIo(msg: conn.Message) ParseError!PortSetIo {
    var p = msg.parser();
    var s = try p.nextStruct();
    return .{
        .direction = @enumFromInt(@as(u32, @bitCast(try s.nextInt()))),
        .port_id = @bitCast(try s.nextInt()),
        .mix_id = @bitCast(try s.nextInt()),
        .id = @enumFromInt(try s.nextId()),
        .mem_id = @bitCast(try s.nextInt()),
        .offset = @bitCast(try s.nextInt()),
        .size = @bitCast(try s.nextInt()),
    };
}

pub fn parseSetActivation(msg: conn.Message) ParseError!SetActivation {
    var p = msg.parser();
    var s = try p.nextStruct();
    const node_id: u32 = @bitCast(try s.nextInt());
    const fd_index = try s.nextFd();
    return .{
        .node_id = node_id,
        .signal_fd = msg.takeFd(fd_index),
        .mem_id = @bitCast(try s.nextInt()),
        .offset = @bitCast(try s.nextInt()),
        .size = @bitCast(try s.nextInt()),
    };
}

pub fn parseSetParam(msg: conn.Message) ParseError!SetParam {
    var p = msg.parser();
    var s = try p.nextStruct();
    return .{
        .id = @enumFromInt(try s.nextId()),
        .flags = @bitCast(try s.nextInt()),
        .param = try s.nextOptionalObject(),
    };
}

pub fn parsePortSetParam(msg: conn.Message) ParseError!PortSetParam {
    var p = msg.parser();
    var s = try p.nextStruct();
    return .{
        .direction = @enumFromInt(@as(u32, @bitCast(try s.nextInt()))),
        .port_id = @bitCast(try s.nextInt()),
        .id = @enumFromInt(try s.nextId()),
        .flags = @bitCast(try s.nextInt()),
        .param = try s.nextOptionalObject(),
    };
}

pub fn parsePortSetMixInfo(msg: conn.Message) ParseError!PortSetMixInfo {
    var p = msg.parser();
    var s = try p.nextStruct();
    return .{
        .direction = @enumFromInt(@as(u32, @bitCast(try s.nextInt()))),
        .port_id = @bitCast(try s.nextInt()),
        .mix_id = @bitCast(try s.nextInt()),
        .peer_id = @bitCast(try s.nextInt()),
    };
}

/// The id of a `SPA_TYPE_COMMAND_Node` object, e.g. Start or Pause.
pub fn parseCommand(msg: conn.Message) ParseError!spa.NodeCommand {
    var p = msg.parser();
    var s = try p.nextStruct();
    const obj = try s.nextOptionalObject() orelse return error.UnexpectedType;
    const body = try obj.objectBody();
    if (body.type != spa.command_node) return error.UnexpectedType;
    return @enumFromInt(body.id);
}

pub fn parseUseBuffers(msg: conn.Message, out: *UseBuffers) ParseError!void {
    var p = msg.parser();
    var s = try p.nextStruct();
    out.direction = @enumFromInt(@as(u32, @bitCast(try s.nextInt())));
    out.port_id = @bitCast(try s.nextInt());
    out.mix_id = @bitCast(try s.nextInt());
    out.flags = @bitCast(try s.nextInt());
    out.n_buffers = @bitCast(try s.nextInt());
    if (out.n_buffers > max_buffers) return error.TooManyBuffers;

    for (out.buffers[0..out.n_buffers]) |*buf| {
        buf.mem_id = @bitCast(try s.nextInt());
        buf.offset = @bitCast(try s.nextInt());
        buf.size = @bitCast(try s.nextInt());
        buf.n_metas = @bitCast(try s.nextInt());
        if (buf.n_metas > max_metas) return error.TooManyBuffers;
        for (buf.metas[0..buf.n_metas]) |*m| {
            m.type = try s.nextId();
            m.size = @bitCast(try s.nextInt());
        }
        buf.n_datas = @bitCast(try s.nextInt());
        if (buf.n_datas > max_datas) return error.TooManyBuffers;
        for (buf.datas[0..buf.n_datas]) |*d| {
            d.type = @enumFromInt(try s.nextId());
            d.data_id = @bitCast(try s.nextInt());
            d.flags = @bitCast(try s.nextInt());
            d.mapoffset = @bitCast(try s.nextInt());
            d.maxsize = @bitCast(try s.nextInt());
        }
    }
}

// --- interpreting what the events describe ---------------------------------

/// Where the pieces of one buffer sit inside its mapping.
///
/// The daemon describes a buffer with a handful of integers and the client is
/// expected to turn them into pointers, so this is the one place where numbers
/// from another process become memory accesses. Everything it returns is
/// checked to lie inside the mapping and to be aligned for what will be cast
/// onto it.
pub const Layout = struct {
    /// Byte offset of the `spa_chunk` record within the mapping.
    chunk_offset: usize,
    /// Byte offset of the sample data within the mapping.
    data_offset: usize,
    /// Length of the sample data, a whole number of `f32`.
    data_len: usize,
};

pub const LayoutError = error{
    /// More than one data block; this library only handles single-block audio.
    MultipleBlocks,
    /// The block is a dmabuf or an id into the pool rather than plain memory.
    NotSharedMemory,
    /// Some part of the buffer falls outside the mapping.
    OutOfBounds,
    /// The chunk record or the samples are not aligned for their type.
    Misaligned,
};

/// Work out where a buffer's chunk record and samples are.
///
/// A mapping holds the metadata first, each rounded up to eight bytes, then one
/// chunk record per data block, then the sample areas the blocks point into.
/// `base` is the address the mapping starts at, which alignment depends on
/// because the offsets are relative to it.
pub fn bufferLayout(desc: BufferDesc, map_len: usize, base: usize) LayoutError!Layout {
    if (desc.n_datas != 1) return error.MultipleBlocks;
    const d = desc.datas[0];
    if (d.type != .mem_ptr) return error.NotSharedMemory;

    // The metadata sits before the chunk records, so its total size is where
    // they start. Every size here is a u32 from the wire, so the running total
    // is kept in u64 to keep a long list of them from wrapping.
    var meta_end: u64 = 0;
    for (desc.metaSlice()) |m| meta_end += std.mem.alignForward(u64, m.size, 8);

    const chunk_end = meta_end + @sizeOf(spa.Chunk);
    const data_offset: u64 = d.data_id;
    const data_len: u64 = d.maxsize / @sizeOf(f32) * @sizeOf(f32);
    const data_end = data_offset + data_len;

    if (chunk_end > map_len or data_end > map_len) return error.OutOfBounds;

    // The offsets are relative to the mapping, so what has to be aligned is the
    // address they land on.
    if ((base +% meta_end) % @alignOf(spa.Chunk) != 0) return error.Misaligned;
    if ((base +% data_offset) % @alignOf(f32) != 0) return error.Misaligned;

    return .{
        .chunk_offset = @intCast(meta_end),
        .data_offset = @intCast(data_offset),
        .data_len = @intCast(data_len),
    };
}

/// The most channels `parseAudioLayout` will report. PipeWire's own limit on a
/// format's position array is the same number.
pub const max_layout_channels = 64;

/// The channel count and speaker positions of a raw audio format.
pub const AudioLayout = struct {
    channels: u32,
    /// True when the format carried a position for every channel. Without it
    /// the caller has to fall back on the conventional layout for the count.
    positioned: bool,
    /// `enum spa_audio_channel` ids, the first `channels` of them meaningful.
    positions: [max_layout_channels]u32,
};

/// Read the channel layout out of a Format object, or null when it does not
/// describe one this library could use.
pub fn parseAudioLayout(param: pod.Pod) pod.Error!?AudioLayout {
    var channels: u32 = 0;
    var positions: ?pod.ArrayBody = null;

    var obj = try param.objectBody();
    while (try obj.next()) |prop| {
        switch (prop.key) {
            spa.format.audio_channels => {
                const n = try prop.value.asIntOrId();
                if (n == 0 or n > max_layout_channels) return null;
                channels = n;
            },
            // A format that names no positions is still usable, so a position
            // array of the wrong shape is treated as absent rather than fatal.
            spa.format.audio_position => positions = prop.value.arrayBody() catch null,
            else => {},
        }
    }
    if (channels == 0) return null;

    var out: AudioLayout = .{ .channels = channels, .positioned = false, .positions = @splat(0) };
    const array = positions orelse return out;
    if (array.count() < channels) return out;
    for (0..channels) |i| out.positions[i] = array.u32At(i) catch return out;
    out.positioned = true;
    return out;
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "port update encodes params before info" {
    var b = pod.Builder.init(testing.allocator);
    defer b.deinit();

    var fmt = pod.Builder.init(testing.allocator);
    defer fmt.deinit();
    const of = try fmt.pushObject(spa.object_type.format, @intFromEnum(spa.Param.enum_format));
    try fmt.objectPropId(spa.format.media_type, spa.media_type.audio);
    try fmt.pop(of);

    try writePortUpdate(&b, .output, 0, update_mask.params | update_mask.info, &.{fmt.bytes()}, .{
        .change_mask = spa.port_change.flags | spa.port_change.props | spa.port_change.params,
        .flags = spa.port_flag.no_ref,
        .props = &.{.{ .key = "port.name", .value = "output_FL" }},
        .params = &.{.{ .id = .enum_format, .flags = spa.param_info.read }},
    });

    var p = pod.Parser.init(b.bytes());
    var s = try p.nextStruct();
    try testing.expectEqual(@as(i32, 1), try s.nextInt()); // direction: output
    try testing.expectEqual(@as(i32, 0), try s.nextInt()); // port id
    try testing.expectEqual(
        @as(i32, update_mask.params | update_mask.info),
        try s.nextInt(),
    );
    try testing.expectEqual(@as(i32, 1), try s.nextInt()); // one param

    const param = try s.next() orelse return error.TestUnexpectedResult;
    const obj = try param.objectBody();
    try testing.expectEqual(spa.object_type.format, obj.type);

    var info = try s.nextStruct();
    try testing.expectEqual(
        @as(i64, spa.port_change.flags | spa.port_change.props | spa.port_change.params),
        try info.nextLong(),
    );
    try testing.expectEqual(@as(i64, spa.port_flag.no_ref), try info.nextLong());
    _ = try info.nextInt(); // rate.num
    _ = try info.nextInt(); // rate.denom
    try testing.expectEqual(@as(i32, 1), try info.nextInt());
    try testing.expectEqualStrings("port.name", try info.nextString());
    try testing.expectEqualStrings("output_FL", try info.nextString());
    try testing.expectEqual(@as(i32, 1), try info.nextInt());
    try testing.expectEqual(@intFromEnum(spa.Param.enum_format), try info.nextId());
    try testing.expectEqual(@as(i32, spa.param_info.read), try info.nextInt());
}

test "use-buffers describes each buffer's metas and data blocks" {
    // Build the message the daemon would send for two single-block buffers.
    var b = pod.Builder.init(testing.allocator);
    defer b.deinit();
    const f = try b.pushStruct();
    try b.addInt(1); // direction: output
    try b.addInt(0); // port id
    try b.addInt(0); // mix id
    try b.addInt(0); // flags
    try b.addInt(2); // two buffers
    for (0..2) |i| {
        try b.addInt(@intCast(7 + i)); // mem id
        try b.addInt(@intCast(i * 4096)); // offset
        try b.addInt(4096); // size
        try b.addInt(0); // no metas
        try b.addInt(1); // one data block
        try b.addId(@intFromEnum(spa.DataType.mem_ptr));
        try b.addInt(64); // offset of the samples inside the buffer
        try b.addInt(3); // flags
        try b.addInt(0); // mapoffset
        try b.addInt(1024); // maxsize
    }
    try b.pop(f);

    var out: UseBuffers = undefined;
    const msg: conn.Message = .{
        .id = 2,
        .opcode = event.port_use_buffers,
        .seq = 0,
        .data = b.bytes(),
        .fds = &.{},
    };
    try parseUseBuffers(msg, &out);

    try testing.expectEqual(spa.Direction.output, out.direction);
    try testing.expectEqual(@as(u32, 2), out.n_buffers);
    for (out.slice(), 0..) |buf, i| {
        try testing.expectEqual(@as(u32, @intCast(7 + i)), buf.mem_id);
        try testing.expectEqual(@as(u32, @intCast(i * 4096)), buf.offset);
        try testing.expectEqual(@as(u32, 0), buf.n_metas);
        try testing.expectEqual(@as(u32, 1), buf.n_datas);
        try testing.expectEqual(spa.DataType.mem_ptr, buf.datas[0].type);
        try testing.expectEqual(@as(u32, 64), buf.datas[0].data_id);
        try testing.expectEqual(@as(u32, 1024), buf.datas[0].maxsize);
    }
}

test "a Start command decodes to its node-command id" {
    var b = pod.Builder.init(testing.allocator);
    defer b.deinit();
    const f = try b.pushStruct();
    const o = try b.pushObject(spa.command_node, @intFromEnum(spa.NodeCommand.start));
    try b.pop(o);
    try b.pop(f);

    const msg: conn.Message = .{
        .id = 2,
        .opcode = event.command,
        .seq = 0,
        .data = b.bytes(),
        .fds = &.{},
    };
    try testing.expectEqual(spa.NodeCommand.start, try parseCommand(msg));
}
