// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Encoding and decoding for the registry and the objects it lists.
//!
//! The registry is how a client sees the rest of the graph. Asking the Core for
//! one starts a stream of `Global` events, one for every object the daemon has
//! and one for every object that appears afterwards, each carrying an id, an
//! interface name and a properties dictionary. Binding to a global by that id
//! gives a proxy on which that interface's own methods and events can be
//! exchanged — a Node's parameters, a Metadata store's key/value pairs.
//!
//! This module only turns those messages into and out of PODs; the object graph
//! that acts on them lives in `session.zig`. The shapes here are those of
//! PipeWire's own `page_native_protocol` documentation, which is the normative
//! description of what goes over the socket.
//!
//! Everything decoded here borrows the message buffer it was parsed from, which
//! the connection reuses as soon as the message is released. A caller that keeps
//! anything past its handler copies it first.

const std = @import("std");
const spa = @import("spa.zig");
const pod = @import("pod.zig");
const conn = @import("connection.zig");
const core_mod = @import("core.zig");

pub const Prop = core_mod.Prop;
pub const ParseError = pod.Error;

/// Interface names, as they appear in a `Global` event and in a `Bind` request.
pub const interface = struct {
    pub const core = "PipeWire:Interface:Core";
    pub const client = "PipeWire:Interface:Client";
    pub const registry = "PipeWire:Interface:Registry";
    pub const node = "PipeWire:Interface:Node";
    pub const port = "PipeWire:Interface:Port";
    pub const link = "PipeWire:Interface:Link";
    pub const device = "PipeWire:Interface:Device";
    pub const factory = "PipeWire:Interface:Factory";
    pub const module = "PipeWire:Interface:Module";
    pub const profiler = "PipeWire:Interface:Profiler";
    pub const metadata = "PipeWire:Interface:Metadata";
    pub const client_node = "PipeWire:Interface:ClientNode";
    pub const security_context = "PipeWire:Interface:SecurityContext";
};

/// The interface versions this library implements.
///
/// A bind names the version the *client* speaks, and the daemon then keeps
/// within it, so these are a promise about what we can decode rather than a
/// request for something newer.
pub const version = struct {
    pub const registry: u32 = 3;
    pub const node: u32 = 3;
    pub const port: u32 = 3;
    pub const link: u32 = 3;
    pub const device: u32 = 3;
    pub const client: u32 = 3;
    pub const factory: u32 = 3;
    pub const module: u32 = 3;
    pub const metadata: u32 = 3;
};

/// What a global is, as far as this library is concerned.
pub const ObjectType = enum {
    core,
    client,
    registry,
    node,
    port,
    link,
    device,
    factory,
    module,
    profiler,
    metadata,
    client_node,
    security_context,
    /// An interface this library has no name for. The name is kept as it
    /// arrived, so such an object still lists and can still be destroyed.
    other,

    pub fn fromInterface(name: []const u8) ObjectType {
        const table = .{
            .{ interface.core, ObjectType.core },
            .{ interface.client, ObjectType.client },
            .{ interface.registry, ObjectType.registry },
            .{ interface.node, ObjectType.node },
            .{ interface.port, ObjectType.port },
            .{ interface.link, ObjectType.link },
            .{ interface.device, ObjectType.device },
            .{ interface.factory, ObjectType.factory },
            .{ interface.module, ObjectType.module },
            .{ interface.profiler, ObjectType.profiler },
            .{ interface.metadata, ObjectType.metadata },
            .{ interface.client_node, ObjectType.client_node },
            .{ interface.security_context, ObjectType.security_context },
        };
        inline for (table) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .other;
    }

    /// The interface name to bind this type with, or null for one this library
    /// has no name for — which cannot be bound, only listed.
    pub fn interfaceName(t: ObjectType) ?[]const u8 {
        return switch (t) {
            .core => interface.core,
            .client => interface.client,
            .registry => interface.registry,
            .node => interface.node,
            .port => interface.port,
            .link => interface.link,
            .device => interface.device,
            .factory => interface.factory,
            .module => interface.module,
            .profiler => interface.profiler,
            .metadata => interface.metadata,
            .client_node => interface.client_node,
            .security_context => interface.security_context,
            .other => null,
        };
    }

    /// The version to bind this type at.
    pub fn bindVersion(t: ObjectType) u32 {
        return switch (t) {
            .node => version.node,
            .port => version.port,
            .link => version.link,
            .device => version.device,
            .client => version.client,
            .factory => version.factory,
            .module => version.module,
            .metadata => version.metadata,
            else => 3,
        };
    }
};

/// Permission bits carried by a `Global` event, from `PW_PERM_*`.
pub const perm = struct {
    /// The object can be seen and its events received.
    pub const r: u32 = 0o400;
    /// The object can be modified: its params set, its metadata written.
    pub const w: u32 = 0o200;
    /// The object's methods can be called at all.
    pub const x: u32 = 0o100;
    /// The object can be used as the subject of a metadata entry.
    pub const m: u32 = 0o010;
    pub const rwx: u32 = r | w | x;
};

// --- the registry itself ----------------------------------------------------

pub const method = struct {
    pub const bind: u8 = 1;
    pub const destroy: u8 = 2;
};

pub const event = struct {
    pub const global: u8 = 0;
    pub const global_remove: u8 = 1;
};

/// One object in the daemon's graph, as the registry announces it.
pub const Global = struct {
    id: u32,
    permissions: u32,
    type_name: []const u8,
    type: ObjectType,
    version: u32,
    props: Dict,
};

pub fn parseGlobal(msg: conn.Message) ParseError!Global {
    var p = msg.parser();
    var s = try p.nextStruct();
    const id: u32 = @bitCast(try s.nextInt());
    const permissions: u32 = @bitCast(try s.nextInt());
    const type_name = try s.nextString();
    const object_version: u32 = @bitCast(try s.nextInt());
    return .{
        .id = id,
        .permissions = permissions,
        .type_name = type_name,
        .type = .fromInterface(type_name),
        .version = object_version,
        .props = try readDict(&s),
    };
}

/// `Registry.GlobalRemove`: the id of an object that has gone away.
pub fn parseGlobalRemove(msg: conn.Message) ParseError!u32 {
    var p = msg.parser();
    var s = try p.nextStruct();
    return @bitCast(try s.nextInt());
}

/// `Registry.Bind`: take a proxy on an existing global.
pub fn writeBind(
    b: *pod.Builder,
    id: u32,
    type_name: []const u8,
    bind_version: u32,
    new_id: u32,
) !void {
    const f = try b.pushStruct();
    try b.addInt(@bitCast(id));
    try b.addString(type_name);
    try b.addInt(@bitCast(bind_version));
    try b.addInt(@bitCast(new_id));
    try b.pop(f);
}

/// `Registry.Destroy`: ask for a global to be removed from the graph.
pub fn writeDestroy(b: *pod.Builder, id: u32) !void {
    const f = try b.pushStruct();
    try b.addInt(@bitCast(id));
    try b.pop(f);
}

// --- dictionaries and param info --------------------------------------------

/// The key/value pairs of a properties dictionary, read one at a time out of
/// the message they arrived in.
///
/// The count is the daemon's, so it is not trusted for anything but stopping:
/// a dictionary that claims more items than it carries runs out of POD and
/// fails rather than reading past the message.
pub const Dict = struct {
    fields: pod.Parser,
    remaining: u32,

    pub fn next(d: *Dict) ParseError!?Prop {
        if (d.remaining == 0) return null;
        d.remaining -= 1;
        return .{
            .key = try d.fields.nextString(),
            .value = try d.fields.nextString(),
        };
    }

    /// The value for a key, or null. Linear, which is what a dictionary of a
    /// dozen entries deserves.
    pub fn get(d: Dict, key: []const u8) ?[]const u8 {
        var it = d;
        while (it.next() catch null) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }

    pub const empty: Dict = .{ .fields = .init(&.{}), .remaining = 0 };
};

/// Read a dictionary, leaving `p` positioned after it.
pub fn readDict(p: *pod.Parser) ParseError!Dict {
    var s = try p.nextStruct();
    const n = try s.nextInt();
    return .{ .fields = s, .remaining = if (n < 0) 0 else @intCast(n) };
}

pub const ParamInfo = struct {
    id: spa.Param,
    flags: u32,
};

/// What parameters an object has and whether they can be read or written, read
/// one at a time the way `Dict` is.
pub const ParamInfos = struct {
    fields: pod.Parser,
    remaining: u32,

    pub fn next(p: *ParamInfos) ParseError!?ParamInfo {
        if (p.remaining == 0) return null;
        p.remaining -= 1;
        return .{
            .id = @enumFromInt(try p.fields.nextId()),
            .flags = @bitCast(try p.fields.nextInt()),
        };
    }

    /// The flags for one parameter, or null when the object does not have it.
    pub fn get(p: ParamInfos, id: spa.Param) ?u32 {
        var it = p;
        while (it.next() catch null) |info| {
            if (info.id == id) return info.flags;
        }
        return null;
    }

    pub const empty: ParamInfos = .{ .fields = .init(&.{}), .remaining = 0 };
};

pub fn readParamInfos(p: *pod.Parser) ParseError!ParamInfos {
    var s = try p.nextStruct();
    const n = try s.nextInt();
    return .{ .fields = s, .remaining = if (n < 0) 0 else @intCast(n) };
}

// --- params, which three interfaces share -----------------------------------

/// A `Param` event, sent by a Node, Port or Device in reply to `EnumParams` or
/// because of `SubscribeParams`.
pub const Param = struct {
    seq: i32,
    id: spa.Param,
    index: u32,
    next_index: u32,
    /// The parameter itself, or null when the object has none of this id.
    param: ?pod.Pod,
};

pub fn parseParam(msg: conn.Message) ParseError!Param {
    var p = msg.parser();
    var s = try p.nextStruct();
    return .{
        .seq = try s.nextInt(),
        .id = @enumFromInt(try s.nextId()),
        .index = @bitCast(try s.nextInt()),
        .next_index = @bitCast(try s.nextInt()),
        .param = try s.nextOptionalPod(),
    };
}

/// `EnumParams`, in the shape Node, Port and Device all share.
pub fn writeEnumParams(
    b: *pod.Builder,
    seq: i32,
    id: spa.Param,
    index: u32,
    num: u32,
    filter: ?[]const u8,
) !void {
    const f = try b.pushStruct();
    try b.addInt(seq);
    try b.addId(@intFromEnum(id));
    try b.addInt(@bitCast(index));
    try b.addInt(@bitCast(num));
    try b.addPod(filter);
    try b.pop(f);
}

/// `SetParam`, as Node and Device take it.
pub fn writeSetParam(b: *pod.Builder, id: spa.Param, flags: u32, param: ?[]const u8) !void {
    const f = try b.pushStruct();
    try b.addId(@intFromEnum(id));
    try b.addInt(@bitCast(flags));
    try b.addPod(param);
    try b.pop(f);
}

/// `SubscribeParams`: ask to be told when these parameters change.
pub fn writeSubscribeParams(b: *pod.Builder, ids: []const spa.Param) !void {
    const f = try b.pushStruct();
    const a = try b.pushArray(4, .id);
    for (ids) |id| {
        const raw: u32 = @intFromEnum(id);
        try b.addRaw(std.mem.asBytes(&raw));
    }
    try b.pop(a);
    try b.pop(f);
}

// --- Node -------------------------------------------------------------------

pub const node = struct {
    pub const method = struct {
        pub const subscribe_params: u8 = 1;
        pub const enum_params: u8 = 2;
        pub const set_param: u8 = 3;
        pub const send_command: u8 = 4;
    };

    pub const event = struct {
        pub const info: u8 = 0;
        pub const param: u8 = 1;
    };

    /// `enum pw_node_state`. Non-exhaustive, like every other enum decoded from
    /// the wire: the value arrives from another process.
    pub const State = enum(i32) {
        @"error" = -1,
        creating = 0,
        suspended = 1,
        idle = 2,
        running = 3,
        _,

        pub fn name(s: State) []const u8 {
            return switch (s) {
                .@"error" => "error",
                .creating => "creating",
                .suspended => "suspended",
                .idle => "idle",
                .running => "running",
                _ => "unknown",
            };
        }
    };

    /// `change_mask` bits of a `Node.Info` event.
    pub const change = struct {
        pub const input_ports: u64 = 1 << 0;
        pub const output_ports: u64 = 1 << 1;
        pub const state: u64 = 1 << 2;
        pub const props: u64 = 1 << 3;
        pub const params: u64 = 1 << 4;
    };

    pub const Info = struct {
        id: u32,
        max_input_ports: u32,
        max_output_ports: u32,
        change_mask: u64,
        n_input_ports: u32,
        n_output_ports: u32,
        state: State,
        /// Why the node is in the error state, when it is.
        error_message: ?[]const u8,
        props: Dict,
        params: ParamInfos,
    };

    pub fn parseInfo(msg: conn.Message) ParseError!Info {
        var p = msg.parser();
        var s = try p.nextStruct();
        const id: u32 = @bitCast(try s.nextInt());
        const max_input_ports: u32 = @bitCast(try s.nextInt());
        const max_output_ports: u32 = @bitCast(try s.nextInt());
        const change_mask: u64 = @bitCast(try s.nextLong());
        const n_input_ports: u32 = @bitCast(try s.nextInt());
        const n_output_ports: u32 = @bitCast(try s.nextInt());
        const state: State = @enumFromInt(@as(i32, @bitCast(try s.nextId())));
        const error_message = try s.nextOptionalString();
        const props = try readDict(&s);
        return .{
            .id = id,
            .max_input_ports = max_input_ports,
            .max_output_ports = max_output_ports,
            .change_mask = change_mask,
            .n_input_ports = n_input_ports,
            .n_output_ports = n_output_ports,
            .state = state,
            .error_message = error_message,
            .props = props,
            .params = try readParamInfos(&s),
        };
    }
};

// --- Device -----------------------------------------------------------------

pub const device = struct {
    pub const method = struct {
        pub const subscribe_params: u8 = 1;
        pub const enum_params: u8 = 2;
        pub const set_param: u8 = 3;
    };

    pub const event = struct {
        pub const info: u8 = 0;
        pub const param: u8 = 1;
    };

    pub const change = struct {
        pub const props: u64 = 1 << 0;
        pub const params: u64 = 1 << 1;
    };

    pub const Info = struct {
        id: u32,
        change_mask: u64,
        props: Dict,
        params: ParamInfos,
    };

    pub fn parseInfo(msg: conn.Message) ParseError!Info {
        var p = msg.parser();
        var s = try p.nextStruct();
        const id: u32 = @bitCast(try s.nextInt());
        const change_mask: u64 = @bitCast(try s.nextLong());
        const props = try readDict(&s);
        return .{
            .id = id,
            .change_mask = change_mask,
            .props = props,
            .params = try readParamInfos(&s),
        };
    }
};

// --- Port -------------------------------------------------------------------

pub const port = struct {
    pub const method = struct {
        pub const subscribe_params: u8 = 1;
        pub const enum_params: u8 = 2;
    };

    pub const event = struct {
        pub const info: u8 = 0;
        pub const param: u8 = 1;
    };

    pub const change = struct {
        pub const props: u64 = 1 << 0;
        pub const params: u64 = 1 << 1;
    };

    pub const Info = struct {
        id: u32,
        direction: spa.Direction,
        change_mask: u64,
        props: Dict,
        params: ParamInfos,
    };

    pub fn parseInfo(msg: conn.Message) ParseError!Info {
        var p = msg.parser();
        var s = try p.nextStruct();
        const id: u32 = @bitCast(try s.nextInt());
        const direction: spa.Direction = @enumFromInt(try s.nextId());
        const change_mask: u64 = @bitCast(try s.nextLong());
        const props = try readDict(&s);
        return .{
            .id = id,
            .direction = direction,
            .change_mask = change_mask,
            .props = props,
            .params = try readParamInfos(&s),
        };
    }
};

// --- Link -------------------------------------------------------------------

pub const link = struct {
    pub const event = struct {
        pub const info: u8 = 0;
    };

    pub const change = struct {
        pub const state: u64 = 1 << 0;
        pub const format: u64 = 1 << 1;
        pub const props: u64 = 1 << 2;
    };

    /// `enum pw_link_state`.
    pub const State = enum(i32) {
        @"error" = -2,
        unlinked = -1,
        init = 0,
        negotiating = 1,
        allocating = 2,
        paused = 3,
        active = 4,
        _,

        pub fn name(s: State) []const u8 {
            return switch (s) {
                .@"error" => "error",
                .unlinked => "unlinked",
                .init => "init",
                .negotiating => "negotiating",
                .allocating => "allocating",
                .paused => "paused",
                .active => "active",
                _ => "unknown",
            };
        }
    };

    /// The factory that makes links, and the property keys it takes.
    pub const factory_name = "link-factory";
    pub const key_output_node = "link.output.node";
    pub const key_output_port = "link.output.port";
    pub const key_input_node = "link.input.node";
    pub const key_input_port = "link.input.port";
    /// Whether the link outlives the client that asked for it.
    pub const key_linger = "object.linger";

    pub const Info = struct {
        id: u32,
        output_node_id: u32,
        output_port_id: u32,
        input_node_id: u32,
        input_port_id: u32,
        change_mask: u64,
        state: State,
        error_message: ?[]const u8,
        /// The format the two ports settled on, when there is one.
        format: ?pod.Pod,
        props: Dict,
    };

    pub fn parseInfo(msg: conn.Message) ParseError!Info {
        var p = msg.parser();
        var s = try p.nextStruct();
        const id: u32 = @bitCast(try s.nextInt());
        const output_node_id: u32 = @bitCast(try s.nextInt());
        const output_port_id: u32 = @bitCast(try s.nextInt());
        const input_node_id: u32 = @bitCast(try s.nextInt());
        const input_port_id: u32 = @bitCast(try s.nextInt());
        const change_mask: u64 = @bitCast(try s.nextLong());
        const state: State = @enumFromInt(@as(i32, @bitCast(try s.nextId())));
        const error_message = try s.nextOptionalString();
        const format = try s.nextOptionalPod();
        return .{
            .id = id,
            .output_node_id = output_node_id,
            .output_port_id = output_port_id,
            .input_node_id = input_node_id,
            .input_port_id = input_port_id,
            .change_mask = change_mask,
            .state = state,
            .error_message = error_message,
            .format = format,
            .props = try readDict(&s),
        };
    }
};

// --- Client -----------------------------------------------------------------

pub const client = struct {
    pub const event = struct {
        pub const info: u8 = 0;
        pub const permissions: u8 = 1;
    };

    pub const Info = struct {
        id: u32,
        change_mask: u64,
        props: Dict,
    };

    pub fn parseInfo(msg: conn.Message) ParseError!Info {
        var p = msg.parser();
        var s = try p.nextStruct();
        const id: u32 = @bitCast(try s.nextInt());
        const change_mask: u64 = @bitCast(try s.nextLong());
        return .{
            .id = id,
            .change_mask = change_mask,
            .props = try readDict(&s),
        };
    }
};

// --- Metadata ---------------------------------------------------------------

pub const metadata = struct {
    pub const method = struct {
        pub const set_property: u8 = 1;
        pub const clear: u8 = 2;
    };

    pub const event = struct {
        pub const property: u8 = 0;
    };

    /// The property naming a metadata store, which is how the one wanted is
    /// found among the several the session manager keeps.
    pub const key_name = "metadata.name";

    /// The store the session manager keeps the graph-wide defaults in.
    pub const name_default = "default";

    /// The type the session manager writes its values with. A value of this
    /// type is a JSON document — usually `{"name":"<node name>"}` for a default
    /// device, or a bare JSON string or number for a target.
    pub const type_json = "Spa:String:JSON";

    /// One key/value pair of a metadata store.
    ///
    /// `subject` is the global id the entry is about, or 0 for the store as a
    /// whole. A null `key` clears every entry for the subject and a null
    /// `value` clears the one entry, which is the same event either way: what
    /// was there is gone.
    pub const Property = struct {
        subject: u32,
        key: ?[]const u8,
        type: ?[]const u8,
        value: ?[]const u8,
    };

    pub fn parseProperty(msg: conn.Message) ParseError!Property {
        var p = msg.parser();
        var s = try p.nextStruct();
        return .{
            .subject = @bitCast(try s.nextInt()),
            .key = try s.nextOptionalString(),
            .type = try s.nextOptionalString(),
            .value = try s.nextOptionalString(),
        };
    }

    pub fn writeSetProperty(
        b: *pod.Builder,
        subject: u32,
        key: ?[]const u8,
        value_type: ?[]const u8,
        value: ?[]const u8,
    ) !void {
        const f = try b.pushStruct();
        try b.addInt(@bitCast(subject));
        try b.addOptionalString(key);
        try b.addOptionalString(value_type);
        try b.addOptionalString(value);
        try b.pop(f);
    }

    pub fn writeClear(b: *pod.Builder) !void {
        const f = try b.pushStruct();
        try b.pop(f);
    }
};

// --- Props ------------------------------------------------------------------

/// The most per-channel volumes this library will read out of a `Props` object.
/// PipeWire's own limit on a channel layout is 64.
pub const max_volume_channels = 64;

/// What a node's `Props` parameter says about its volume.
///
/// Volumes are linear amplitudes: 1.0 is unattenuated and 0.0 is silence.
/// `wpctl` and `pavucontrol` show a cubic scale instead, so a reading of 0.4
/// there is `0.4³ = 0.064` here; `cubicToLinear` and `linearToCubic` convert.
pub const Volume = struct {
    /// How many channels one of these can hold, for a caller sizing a buffer
    /// of its own to hand to `Session.setChannelVolumes`.
    pub const channel_capacity = max_volume_channels;

    /// The master gain, applied on top of the per-channel ones.
    volume: f32 = 1.0,
    mute: bool = false,
    channels: u32 = 0,
    channel_volumes: [max_volume_channels]f32 = @splat(1.0),
    /// Which of the fields above the object actually carried.
    ///
    /// This matters because an object reports the properties it has and no
    /// others, and because an enumeration answers with more than one of them:
    /// a node lists a full `Props` and then an empty one, so a reader that
    /// takes the last answer as the whole truth reads every volume as 1.0.
    has: Fields = .{},

    pub const Fields = struct {
        volume: bool = false,
        mute: bool = false,
        channel_volumes: bool = false,
    };

    /// Whether this object said anything about volume at all.
    pub fn any(v: *const Volume) bool {
        return v.has.volume or v.has.mute or v.has.channel_volumes;
    }

    /// Take from `other` the fields it carried, leaving the rest alone.
    pub fn merge(v: *Volume, other: Volume) void {
        if (other.has.volume) {
            v.volume = other.volume;
            v.has.volume = true;
        }
        if (other.has.mute) {
            v.mute = other.mute;
            v.has.mute = true;
        }
        if (other.has.channel_volumes) {
            v.channels = other.channels;
            v.channel_volumes = other.channel_volumes;
            v.has.channel_volumes = true;
        }
    }

    pub fn channelSlice(v: *const Volume) []const f32 {
        return v.channel_volumes[0..v.channels];
    }

    /// The loudest channel, which is the single number a mixer shows.
    pub fn peak(v: *const Volume) f32 {
        var m: f32 = 0;
        for (v.channelSlice()) |c| m = @max(m, c);
        return if (v.channels == 0) v.volume else m;
    }

    pub fn cubicToLinear(x: f32) f32 {
        return x * x * x;
    }

    pub fn linearToCubic(x: f32) f32 {
        return std.math.cbrt(x);
    }
};

/// Read the volume out of a `SPA_TYPE_OBJECT_Props` object.
///
/// Every field is optional: a node reports the properties it has, and one with
/// no volume control of its own reports none of these.
pub fn parseVolume(param: pod.Pod) ParseError!Volume {
    var obj = try param.objectBody();
    if (obj.type != spa.object_type.props) return error.UnexpectedType;

    var out: Volume = .{};
    while (try obj.next()) |property| {
        switch (property.key) {
            spa.prop.volume => {
                out.volume = property.value.asFloat() catch continue;
                out.has.volume = true;
            },
            spa.prop.mute => {
                out.mute = property.value.asBool() catch continue;
                out.has.mute = true;
            },
            spa.prop.channel_volumes => {
                const array = property.value.arrayBody() catch continue;
                const n = @min(array.count(), max_volume_channels);
                out.channels = 0;
                for (0..n) |i| {
                    out.channel_volumes[i] = array.f32At(i) catch break;
                    out.channels += 1;
                }
                out.has.channel_volumes = out.channels > 0;
            },
            else => {},
        }
    }
    return out;
}

// --- Routes -----------------------------------------------------------------

/// A device route: one way in or out of a sound card, and where that card's
/// volume is kept.
///
/// A node belonging to a device carries `device.id` and `card.profile.device`;
/// the route whose `device` matches the latter is the one whose volume a mixer
/// is showing. The node's own `Props` are not it — on an ALSA sink they sit at
/// 1.0 whatever the volume is, which is how a mixer built on them comes to
/// disagree with `wpctl` about every device in the machine.
pub const route = struct {
    pub const Info = struct {
        index: u32,
        direction: spa.Direction,
        device: u32,
        name: ?[]const u8 = null,
        description: ?[]const u8 = null,
        /// The `Props` object holding this route's volume, when it has one.
        props: ?pod.Pod = null,
    };

    pub fn parse(param: pod.Pod) ParseError!Info {
        var obj = try param.objectBody();
        if (obj.type != spa.object_type.param_route) return error.UnexpectedType;

        var out: Info = .{ .index = 0, .direction = .output, .device = 0 };
        while (try obj.next()) |property| {
            switch (property.key) {
                spa.param_route.index => out.index = property.value.asIntOrId() catch continue,
                spa.param_route.direction => out.direction =
                    @enumFromInt(property.value.asIntOrId() catch continue),
                spa.param_route.device => out.device = property.value.asIntOrId() catch continue,
                spa.param_route.name => out.name = property.value.asString() catch continue,
                spa.param_route.description => out.description =
                    property.value.asString() catch continue,
                spa.param_route.props => out.props = property.value,
                else => {},
            }
        }
        return out;
    }

    /// A `Route` object setting one route's volume, in the shape
    /// `Device.SetParam` takes.
    ///
    /// `index` and `device` say which route is meant and have to be the ones
    /// read back from the device; `save` asks the session manager to remember
    /// the change, which is what makes a volume stick across a reboot.
    pub fn writeVolume(
        b: *pod.Builder,
        index: u32,
        device_index: u32,
        mute: ?bool,
        channel_volumes: ?[]const f32,
        save: bool,
    ) !void {
        const f = try b.pushObject(spa.object_type.param_route, @intFromEnum(spa.Param.route));
        try b.objectPropInt(spa.param_route.index, @bitCast(index));
        try b.objectPropInt(spa.param_route.device, @bitCast(device_index));
        try b.prop(spa.param_route.props, 0);
        try writeVolumeProps(b, .{ .mute = mute, .channel_volumes = channel_volumes });
        try b.prop(spa.param_route.save, 0);
        try b.addBool(save);
        try b.pop(f);
    }
};

/// The fields of a `Props` object to write. Those left null are left out, and
/// an object says nothing about what it does not mention: that is how a mixer
/// changes the mute without touching the volume, and how a node reports only
/// the controls it has.
pub const VolumeProps = struct {
    volume: ?f32 = null,
    mute: ?bool = null,
    channel_volumes: ?[]const f32 = null,
    /// One `spa_audio_channel` per entry of `channel_volumes`, saying which
    /// speaker each of them is. A node reporting its volume gives this so that
    /// a mixer can label the faders.
    channel_map: ?[]const u32 = null,
};

/// A `Props` object carrying the fields that are given and no others.
pub fn writeVolumeProps(b: *pod.Builder, props: VolumeProps) !void {
    const f = try b.pushObject(spa.object_type.props, @intFromEnum(spa.Param.props));
    if (props.volume) |v| {
        try b.prop(spa.prop.volume, 0);
        try b.addFloat(v);
    }
    if (props.mute) |m| {
        try b.prop(spa.prop.mute, 0);
        try b.addBool(m);
    }
    if (props.channel_volumes) |vols| {
        try b.prop(spa.prop.channel_volumes, 0);
        const a = try b.pushArray(4, .float);
        for (vols) |v| try b.addRaw(std.mem.asBytes(&v));
        try b.pop(a);
    }
    if (props.channel_map) |positions| {
        try b.prop(spa.prop.channel_map, 0);
        const a = try b.pushArray(4, .id);
        for (positions) |position| try b.addRaw(std.mem.asBytes(&position));
        try b.pop(a);
    }
    try b.pop(f);
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;

fn message(data: []const u8, opcode: u8) conn.Message {
    return .{ .id = 2, .opcode = opcode, .seq = 0, .data = data, .fds = &.{} };
}

test "a registry global decodes its interface and its properties" {
    var b = pod.Builder.init(testing.allocator);
    defer b.deinit();

    const f = try b.pushStruct();
    try b.addInt(42);
    try b.addInt(@bitCast(perm.rwx));
    try b.addString(interface.node);
    try b.addInt(3);
    try core_mod.writeDict(&b, &.{
        .{ .key = "node.name", .value = "alsa_output.usb" },
        .{ .key = "media.class", .value = "Audio/Sink" },
    });
    try b.pop(f);

    const global = try parseGlobal(message(b.bytes(), event.global));
    try testing.expectEqual(@as(u32, 42), global.id);
    try testing.expectEqual(ObjectType.node, global.type);
    try testing.expectEqualStrings(interface.node, global.type_name);
    try testing.expectEqualStrings("Audio/Sink", global.props.get("media.class").?);
    try testing.expect(global.props.get("node.nick") == null);
}

test "a node's info carries its state, its properties and what params it has" {
    var b = pod.Builder.init(testing.allocator);
    defer b.deinit();

    const f = try b.pushStruct();
    try b.addInt(7); // id
    try b.addInt(0); // max input ports
    try b.addInt(64); // max output ports
    try b.addLong(@bitCast(node.change.state | node.change.props | node.change.params));
    try b.addInt(0); // n input ports
    try b.addInt(2); // n output ports
    try b.addId(@bitCast(@intFromEnum(node.State.running)));
    // No error, which the daemon sends as a null string: a None.
    try b.addOptionalString(null);
    try core_mod.writeDict(&b, &.{.{ .key = "node.name", .value = "sink" }});
    const params = try b.pushStruct();
    try b.addInt(2);
    try b.addId(@intFromEnum(spa.Param.props));
    try b.addInt(@bitCast(spa.param_info.readwrite));
    try b.addId(@intFromEnum(spa.Param.format));
    try b.addInt(@bitCast(spa.param_info.read));
    try b.pop(params);
    try b.pop(f);

    const info = try node.parseInfo(message(b.bytes(), node.event.info));
    try testing.expectEqual(@as(u32, 7), info.id);
    try testing.expectEqual(node.State.running, info.state);
    try testing.expect(info.error_message == null);
    try testing.expectEqualStrings("sink", info.props.get("node.name").?);
    try testing.expectEqual(spa.param_info.readwrite, info.params.get(.props).?);
    try testing.expect(info.params.get(.route) == null);
}

test "a node state the daemon invents decodes rather than trapping" {
    var b = pod.Builder.init(testing.allocator);
    defer b.deinit();

    const f = try b.pushStruct();
    try b.addInt(7);
    try b.addInt(0);
    try b.addInt(0);
    try b.addLong(@bitCast(node.change.state));
    try b.addInt(0);
    try b.addInt(0);
    try b.addId(9999);
    try b.addOptionalString(null);
    try core_mod.writeDict(&b, &.{});
    const params = try b.pushStruct();
    try b.addInt(0);
    try b.pop(params);
    try b.pop(f);

    const info = try node.parseInfo(message(b.bytes(), node.event.info));
    try testing.expectEqual(@as(i32, 9999), @intFromEnum(info.state));
    try testing.expectEqualStrings("unknown", info.state.name());
}

test "a metadata property with no value is a removal" {
    var b = pod.Builder.init(testing.allocator);
    defer b.deinit();

    const f = try b.pushStruct();
    try b.addInt(60);
    try b.addString("target.object");
    try b.addOptionalString(null);
    try b.addOptionalString(null);
    try b.pop(f);

    const property = try metadata.parseProperty(message(b.bytes(), metadata.event.property));
    try testing.expectEqual(@as(u32, 60), property.subject);
    try testing.expectEqualStrings("target.object", property.key.?);
    try testing.expect(property.type == null);
    try testing.expect(property.value == null);
}

test "a volume round-trips through the Props encoder" {
    var b = pod.Builder.init(testing.allocator);
    defer b.deinit();

    const levels = [_]f32{ 0.25, 0.5 };
    try writeVolumeProps(&b, .{ .mute = true, .channel_volumes = &levels });

    var p = pod.Parser.init(b.bytes());
    const value = try p.next() orelse return error.Truncated;
    const volume = try parseVolume(value);
    try testing.expect(volume.mute);
    try testing.expectEqual(@as(u32, 2), volume.channels);
    try testing.expectEqual(@as(f32, 0.5), volume.peak());
    try testing.expect(volume.has.mute and volume.has.channel_volumes);
    // Nothing was said about the master gain, so nothing is claimed about it.
    try testing.expect(!volume.has.volume);
}

test "an empty Props object does not erase what a full one said" {
    var b = pod.Builder.init(testing.allocator);
    defer b.deinit();

    const levels = [_]f32{0.75};
    try writeVolumeProps(&b, .{ .mute = false, .channel_volumes = &levels });
    const full_len = b.bytes().len;
    try writeVolumeProps(&b, .{});

    var p = pod.Parser.init(b.bytes());
    var volume = try parseVolume(try p.next() orelse return error.Truncated);
    const empty = try parseVolume(try p.next() orelse return error.Truncated);
    try testing.expect(b.bytes().len > full_len);
    try testing.expect(!empty.any());

    volume.merge(empty);
    try testing.expectEqual(@as(f32, 0.75), volume.peak());
}

test "a route says which device it belongs to and how loud it is" {
    var b = pod.Builder.init(testing.allocator);
    defer b.deinit();

    const levels = [_]f32{ 0.1, 0.1 };
    try route.writeVolume(&b, 5, 11, false, &levels, true);

    var p = pod.Parser.init(b.bytes());
    const info = try route.parse(try p.next() orelse return error.Truncated);
    try testing.expectEqual(@as(u32, 5), info.index);
    try testing.expectEqual(@as(u32, 11), info.device);

    const volume = try parseVolume(info.props.?);
    try testing.expectEqual(@as(u32, 2), volume.channels);
    try testing.expectApproxEqAbs(@as(f32, 0.1), volume.peak(), 0.0001);
}

test "a dictionary that claims more than it carries fails rather than reads on" {
    var b = pod.Builder.init(testing.allocator);
    defer b.deinit();

    const f = try b.pushStruct();
    try b.addInt(4); // four items promised
    try b.addString("only");
    try b.addString("one");
    try b.pop(f);

    var p = pod.Parser.init(b.bytes());
    var dict = try readDict(&p);
    try testing.expectEqualStrings("only", (try dict.next()).?.key);
    try testing.expectError(error.Truncated, dict.next());
}

test "every interface name round-trips through ObjectType" {
    for ([_]ObjectType{ .node, .port, .link, .device, .client, .metadata, .factory }) |t| {
        try testing.expectEqual(t, ObjectType.fromInterface(t.interfaceName().?));
    }
    try testing.expectEqual(ObjectType.other, ObjectType.fromInterface("PipeWire:Interface:Nonesuch"));
    try testing.expect(ObjectType.other.interfaceName() == null);
}
