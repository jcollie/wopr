// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Session management: seeing the graph, and changing it.
//!
//! A `Session` is the other half of what this library does. Where `Stream` puts
//! one node into the graph and feeds it, a `Session` watches the graph as a
//! whole — every node, device, port, link and metadata store the daemon will
//! show us — and asks for the changes a mixer or a control panel makes: which
//! sink is the default, how loud a node is, where a stream is routed, what is
//! linked to what.
//!
//! It is what the session manager talks to rather than a session manager
//! itself. WirePlumber (or whatever is running) still decides policy; these
//! calls are requests, and the graph settles a moment later, which is why every
//! one of them ends with a round trip and why the object you were looking at
//! may have changed by the time it returns.
//!
//! ```zig
//! const session = try pw.Session.open(gpa, .{ .name = "mixer", .environ = env });
//! defer session.close();
//!
//! var sinks = session.sinks();
//! while (sinks.next()) |sink| std.debug.print("{s}\n", .{sink.label()});
//!
//! if (try session.defaultSink()) |sink| {
//!     try session.setVolume(sink.id, 0.5);
//! }
//! ```
//!
//! # Blocking, and one thread
//!
//! Every call that reaches the daemon blocks until the daemon has answered, and
//! nothing here is safe to call from two threads at once. A `Session` has its
//! own connection, so it can be used alongside a `Stream` without either
//! knowing about the other — at the cost of a second socket.
//!
//! # What a pointer is worth
//!
//! `Object` pointers stay valid while the object does. Anything that talks to
//! the daemon — `roundTrip` and every call that changes something — may process
//! a `GlobalRemove` for an object that has gone away, and the pointer to that
//! object dies with it. Hold ids across such a call and look them up again
//! afterwards; pointers are for the stretch between.

const std = @import("std");
const spa = @import("spa.zig");
const pod = @import("pod.zig");
const conn = @import("connection.zig");
const core_mod = @import("core.zig");
const reg = @import("registry.zig");

const Core = core_mod.Core;

pub const Log = @import("log.zig").Log;
pub const Prop = core_mod.Prop;
pub const ObjectType = reg.ObjectType;
pub const Volume = reg.Volume;
pub const NodeState = reg.node.State;
pub const LinkState = reg.link.State;
pub const max_volume_channels = reg.max_volume_channels;

pub const Error = core_mod.Error || std.mem.Allocator.Error || error{
    /// No object with that id or name, or no metadata store by that name.
    NotFound,
    /// The object is there but is not of the kind this call works on.
    WrongType,
    /// The daemon completed the round trip without sending what was asked for.
    /// A parameter the node does not have, most often — a node with no volume
    /// control of its own answers an enumeration of its `Props` with nothing.
    NoReply,
    /// A metadata value was not the JSON the session manager writes.
    MalformedValue,
    /// A name did not fit the buffer it had to be formatted into.
    NameTooLong,
};

/// How the session presents itself, and where it connects.
///
/// The strings are borrowed and need to stay valid only for `Session.open`.
pub const Options = struct {
    /// Shown as this client's name in `pw-cli ls Client` and `pw-top`.
    name: []const u8 = "zig-pipewire",

    /// The process environment, if the caller has it. When given, the socket is
    /// located the way every other PipeWire client locates it:
    /// `PIPEWIRE_RUNTIME_DIR` or `XDG_RUNTIME_DIR` for the directory and
    /// `PIPEWIRE_REMOTE` for the name. Zig 0.16 hands this to `main`.
    environ: ?std.process.Environ = null,
    /// Override the directory holding the socket. Takes precedence over
    /// `environ`; without either, `/run/user/<uid>` is used.
    runtime_dir: ?[]const u8 = null,
    /// Override the socket name, or give an absolute path. Takes precedence
    /// over `environ`; the default is `pipewire-0`.
    remote: ?[]const u8 = null,

    /// Extra client properties, applied after the ones derived above.
    extra_props: []const Prop = &.{},

    log: ?Log = null,
};

// --- objects ----------------------------------------------------------------

/// One object in the daemon's graph, with the properties the registry gave for
/// it.
///
/// The properties are a copy; the daemon's own strings live only as long as the
/// message that brought them. What is here is what the registry announced,
/// which for a node is already enough to list it: its name, its description,
/// what it is (`media.class`) and which device and client it belongs to.
pub const Object = struct {
    id: u32,
    permissions: u32,
    version: u32,
    type: ObjectType,
    /// The interface name, kept verbatim so that an object of a kind this
    /// library has no name for is still legible.
    type_name: []const u8,
    props: []const Prop,

    /// The one allocation `type_name` and every property string point into.
    storage: []u8,

    pub fn prop(o: *const Object, key: []const u8) ?[]const u8 {
        for (o.props) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }

    /// The property that names an object of this kind: `node.name` for a node,
    /// `device.name` for a device, and so on.
    pub fn name(o: *const Object) ?[]const u8 {
        return switch (o.type) {
            .node => o.prop("node.name"),
            .device => o.prop("device.name"),
            .port => o.prop("port.name"),
            .factory => o.prop("factory.name"),
            .module => o.prop("module.name"),
            .metadata => o.prop(reg.metadata.key_name),
            .client => o.prop("application.name"),
            else => null,
        };
    }

    pub fn description(o: *const Object) ?[]const u8 {
        return switch (o.type) {
            .node => o.prop("node.description"),
            .device => o.prop("device.description"),
            else => null,
        };
    }

    pub fn nick(o: *const Object) ?[]const u8 {
        return o.prop("node.nick");
    }

    /// What a node is for: `Audio/Sink`, `Audio/Source`, `Stream/Output/Audio`
    /// and so on. Null for anything that is not a node.
    pub fn mediaClass(o: *const Object) ?[]const u8 {
        return o.prop("media.class");
    }

    /// The serial number, which unlike the id is never reused. This is what a
    /// metadata entry should name when it has the choice.
    pub fn serial(o: *const Object) ?u64 {
        const text = o.prop("object.serial") orelse return null;
        return std.fmt.parseInt(u64, text, 10) catch null;
    }

    /// The node a port belongs to, or the device a node belongs to.
    pub fn parentNodeId(o: *const Object) ?u32 {
        return parseId(o.prop("node.id"));
    }

    pub fn deviceId(o: *const Object) ?u32 {
        return parseId(o.prop("device.id"));
    }

    pub fn clientId(o: *const Object) ?u32 {
        return parseId(o.prop("client.id"));
    }

    /// A port's index within its node, which is what a link names rather than
    /// the port's global id.
    pub fn portIndex(o: *const Object) ?u32 {
        return parseId(o.prop("port.id"));
    }

    /// Which way a port faces. The registry spells it `in` or `out`.
    pub fn portDirection(o: *const Object) ?spa.Direction {
        const text = o.prop("port.direction") orelse return null;
        if (std.mem.eql(u8, text, "in")) return .input;
        if (std.mem.eql(u8, text, "out")) return .output;
        return null;
    }

    /// The speaker position a port carries, as `FL`, `FR`, `MONO` and so on.
    pub fn channel(o: *const Object) ?[]const u8 {
        return o.prop("audio.channel");
    }

    pub fn isSink(o: *const Object) bool {
        return matchesClass(o, "Audio/Sink");
    }

    pub fn isSource(o: *const Object) bool {
        return matchesClass(o, "Audio/Source") or matchesClass(o, "Audio/Source/Virtual");
    }

    /// An application's playback or capture stream, rather than a device.
    pub fn isStream(o: *const Object) bool {
        const class = o.mediaClass() orelse return false;
        return std.mem.startsWith(u8, class, "Stream/");
    }

    /// The best name to show a person: the description if there is one, then
    /// the nickname, then the name, and the interface itself if an object has
    /// none of those.
    pub fn label(o: *const Object) []const u8 {
        return o.description() orelse o.nick() orelse o.name() orelse o.type_name;
    }

    fn matchesClass(o: *const Object, class: []const u8) bool {
        const c = o.mediaClass() orelse return false;
        return std.mem.eql(u8, c, class);
    }

    /// Free an object's copy of what the registry said.
    ///
    /// A session does this for every object it holds; it is public for the same
    /// reason `makeObject` is.
    pub fn deinit(o: *Object, gpa: std.mem.Allocator) void {
        gpa.free(o.props);
        gpa.free(o.storage);
    }
};

fn parseId(text: ?[]const u8) ?u32 {
    const t = text orelse return null;
    return std.fmt.parseInt(u32, t, 10) catch null;
}

/// Which objects an iterator yields.
pub const Filter = struct {
    type: ?ObjectType = null,
    /// `media.class` exactly.
    media_class: ?[]const u8 = null,
    /// `media.class` by prefix, so that `Stream/Output` finds both the audio
    /// and the video streams.
    media_class_prefix: ?[]const u8 = null,
};

pub const Iterator = struct {
    items: []const *Object,
    index: usize = 0,
    filter: Filter,

    pub fn next(it: *Iterator) ?*const Object {
        while (it.index < it.items.len) {
            const object = it.items[it.index];
            it.index += 1;
            if (it.filter.type) |t| {
                if (object.type != t) continue;
            }
            if (it.filter.media_class) |class| {
                const c = object.mediaClass() orelse continue;
                if (!std.mem.eql(u8, c, class)) continue;
            }
            if (it.filter.media_class_prefix) |prefix| {
                const c = object.mediaClass() orelse continue;
                if (!std.mem.startsWith(u8, c, prefix)) continue;
            }
            return object;
        }
        return null;
    }
};

// --- bindings ---------------------------------------------------------------

/// One metadata key/value pair, copied out of the events that carry it.
const Entry = struct {
    subject: u32,
    key: []u8,
    type: []u8,
    value: []u8,

    fn deinit(e: *Entry, gpa: std.mem.Allocator) void {
        gpa.free(e.key);
        gpa.free(e.type);
        gpa.free(e.value);
    }
};

/// A proxy on a global, and whatever that object has told us since.
///
/// Binding is what turns a registry listing into something that can be asked
/// questions and given orders: a node's parameters and a metadata store's
/// contents arrive only on a proxy of their own.
const Binding = struct {
    session: *Session,
    global_id: u32,
    proxy_id: u32,
    type: ObjectType,
    /// Set once a round trip has been made since binding, so that the events
    /// the daemon sends on binding have arrived.
    primed: bool = false,

    /// The last volume this object reported: a node's own `Props`, or the
    /// `Props` inside the one device route that `route_filter` names.
    volume: ?Volume = null,
    /// Which of a device's routes to watch, and the index the last matching one
    /// reported — which a write has to name, so it is kept from the read.
    route_filter: ?u32 = null,
    route_index: ?u32 = null,
    /// The last state a node or a link reported.
    state: ?NodeState = null,
    link_state: ?LinkState = null,
    /// A node's `card.profile.device`, which says which of its device's routes
    /// is its own. It is in the node's info rather than in what the registry
    /// announced, so it costs a bind to learn.
    card_device: ?u32 = null,
    /// The flags of the `Props` and `Route` parameters this object reported
    /// having, or null for one it did not mention.
    ///
    /// This is what an object's `param_info` is for, and asking it first is not
    /// an optimisation: enumerating a parameter an object does not have is an
    /// error event from the daemon rather than an empty answer, and a node with
    /// no volume of its own — this library's own playback node, for one — is an
    /// ordinary thing for a mixer to meet.
    params_props: ?u32 = null,
    params_route: ?u32 = null,
    /// A metadata store's entries.
    entries: std.ArrayList(Entry) = .empty,

    fn deinit(b: *Binding, gpa: std.mem.Allocator) void {
        for (b.entries.items) |*e| e.deinit(gpa);
        b.entries.deinit(gpa);
    }

    fn put(b: *Binding, gpa: std.mem.Allocator, p: reg.metadata.Property) !void {
        const key = p.key orelse {
            // A null key clears everything about that subject.
            var i: usize = 0;
            while (i < b.entries.items.len) {
                if (b.entries.items[i].subject == p.subject) {
                    var e = b.entries.orderedRemove(i);
                    e.deinit(gpa);
                } else i += 1;
            }
            return;
        };

        for (b.entries.items, 0..) |*e, i| {
            if (e.subject != p.subject or !std.mem.eql(u8, e.key, key)) continue;
            if (p.value) |value| {
                const type_copy = try gpa.dupe(u8, p.type orelse "");
                errdefer gpa.free(type_copy);
                const value_copy = try gpa.dupe(u8, value);
                gpa.free(e.type);
                gpa.free(e.value);
                e.type = type_copy;
                e.value = value_copy;
            } else {
                var gone = b.entries.orderedRemove(i);
                gone.deinit(gpa);
            }
            return;
        }

        const value = p.value orelse return;
        const key_copy = try gpa.dupe(u8, key);
        errdefer gpa.free(key_copy);
        const type_copy = try gpa.dupe(u8, p.type orelse "");
        errdefer gpa.free(type_copy);
        const value_copy = try gpa.dupe(u8, value);
        errdefer gpa.free(value_copy);
        try b.entries.append(gpa, .{
            .subject = p.subject,
            .key = key_copy,
            .type = type_copy,
            .value = value_copy,
        });
    }

    /// Fold one `Props` object into what is known about this object's volume.
    ///
    /// An enumeration answers with every `Props` the object has, and only some
    /// of them say anything about volume, so they are merged rather than the
    /// last one taken.
    fn mergeVolume(b: *Binding, parsed: Volume) void {
        if (!parsed.any()) return;
        if (b.volume) |*existing| existing.merge(parsed) else b.volume = parsed;
    }

    fn get(b: *const Binding, subject: u32, key: []const u8) ?[]const u8 {
        for (b.entries.items) |e| {
            if (e.subject == subject and std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }
};

// --- the session ------------------------------------------------------------

pub const Session = struct {
    gpa: std.mem.Allocator,
    log: ?Log,
    core: *Core,
    registry_id: u32 = 0,

    /// Every global the daemon has shown us, in the order it showed them.
    /// Heap-allocated so that a pointer handed out survives the map growing.
    globals: std.AutoArrayHashMapUnmanaged(u32, *Object) = .empty,
    bindings: std.AutoArrayHashMapUnmanaged(u32, *Binding) = .empty,

    /// Scratch for parameter objects, which have to be encoded before the
    /// message that carries them can be built in the Core's own builder.
    param_scratch: pod.Builder,

    // --- lifecycle ---

    pub fn open(gpa: std.mem.Allocator, opts: Options) Error!*Session {
        var path_buf: [256]u8 = undefined;
        var runtime_dir = opts.runtime_dir;
        var remote = opts.remote;
        if (opts.environ) |env| {
            if (runtime_dir == null) {
                runtime_dir = env.getPosix("PIPEWIRE_RUNTIME_DIR") orelse
                    env.getPosix("XDG_RUNTIME_DIR");
            }
            if (remote == null) remote = env.getPosix("PIPEWIRE_REMOTE");
        }
        const path = try Core.socketPath(&path_buf, runtime_dir, remote);

        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .log = opts.log,
            .core = undefined,
            .param_scratch = .init(gpa),
        };
        errdefer self.param_scratch.deinit();

        var props: std.ArrayList(Prop) = .empty;
        defer props.deinit(gpa);
        try props.append(gpa, .{ .key = "application.name", .value = opts.name });
        for (opts.extra_props) |p| try props.append(gpa, p);

        self.core = try Core.connect(gpa, path, props.items);
        errdefer self.core.deinit();

        self.registry_id = try self.core.getRegistry(reg.version.registry);
        try self.core.register(self.registry_id, .{ .ctx = self, .func = registryDispatch });

        // The daemon answers a registry request with a Global event for every
        // object it has, and nothing to say it has finished. The round trip is
        // what says so.
        try self.roundTrip();
        return self;
    }

    pub fn close(self: *Session) void {
        for (self.bindings.values()) |b| {
            b.deinit(self.gpa);
            self.gpa.destroy(b);
        }
        self.bindings.deinit(self.gpa);

        for (self.globals.values()) |object| {
            object.deinit(self.gpa);
            self.gpa.destroy(object);
        }
        self.globals.deinit(self.gpa);

        self.param_scratch.deinit();
        self.core.deinit();
        self.gpa.destroy(self);
    }

    // --- looking ---

    /// Every object the daemon has shown us, in the order it showed them.
    pub fn objects(self: *const Session) []const *Object {
        return self.globals.values();
    }

    pub fn byId(self: *const Session, id: u32) ?*const Object {
        return self.globals.get(id);
    }

    /// The first object of `type` whose own name property matches.
    pub fn byName(self: *const Session, object_type: ObjectType, wanted: []const u8) ?*const Object {
        for (self.globals.values()) |object| {
            if (object.type != object_type) continue;
            const n = object.name() orelse continue;
            if (std.mem.eql(u8, n, wanted)) return object;
        }
        return null;
    }

    pub fn iterator(self: *const Session, filter: Filter) Iterator {
        return .{ .items = self.globals.values(), .filter = filter };
    }

    pub fn nodes(self: *const Session) Iterator {
        return self.iterator(.{ .type = .node });
    }

    pub fn devices(self: *const Session) Iterator {
        return self.iterator(.{ .type = .device });
    }

    pub fn ports(self: *const Session) Iterator {
        return self.iterator(.{ .type = .port });
    }

    pub fn links(self: *const Session) Iterator {
        return self.iterator(.{ .type = .link });
    }

    pub fn sinks(self: *const Session) Iterator {
        return self.iterator(.{ .type = .node, .media_class = "Audio/Sink" });
    }

    pub fn sources(self: *const Session) Iterator {
        return self.iterator(.{ .type = .node, .media_class = "Audio/Source" });
    }

    /// The application streams: what `wpctl status` lists under Streams.
    pub fn streams(self: *const Session) Iterator {
        return self.iterator(.{ .type = .node, .media_class_prefix = "Stream/" });
    }

    // --- talking ---

    /// Send everything queued and wait for the daemon to say it has dealt with
    /// it, processing every event that arrives in the meantime.
    ///
    /// This is how the picture is kept current: nothing arrives except during a
    /// call that waits, so a program that wants to see changes calls this.
    pub fn roundTrip(self: *Session) Error!void {
        self.core.clearError();
        const seq = try self.core.sync();
        self.core.waitSync(seq) catch |err| switch (err) {
            error.RemoteError => return error.RemoteError,
            error.BrokenPipe, error.ConnectionReset => return error.Disconnected,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.logf(.err, "round trip failed: {s}", .{@errorName(err)});
                return error.ProtocolError;
            },
        };
        if (self.core.errorMessage()) |m| {
            self.logf(.err, "daemon reported: {s} ({d})", .{ m, self.core.errorCode() });
            return error.RemoteError;
        }
    }

    // --- volume ---

    /// How loud a node is.
    ///
    /// Costs a round trip, and reads from wherever that node's volume actually
    /// lives — its own `Props` for an application stream, the device's route
    /// for a sound card. A node with no volume control at all, which is what a
    /// driver node is, answers with nothing: `error.NoReply`.
    pub fn volume(self: *Session, node_id: u32) Error!Volume {
        switch (try self.volumeSite(node_id)) {
            .node => return self.nodeVolume(node_id),
            .route => |site| {
                const binding = try self.bindPrimed(site.device_id);
                if (binding.params_route == null) return self.nodeVolume(node_id);
                binding.volume = null;
                binding.route_index = null;
                binding.route_filter = site.card_device;

                const b = self.core.beginMessage();
                try reg.writeEnumParams(b, 0, .route, 0, std.math.maxInt(u32), null);
                _ = try self.core.sendMessage(binding.proxy_id, reg.device.method.enum_params, 0);
                try self.roundTrip();

                const after = self.bindings.get(site.device_id) orelse return error.NotFound;
                // A device lists only the routes its current profile has
                // active, so a node can name a route that is not among them —
                // a capture device in an output-only profile. Its own `Props`
                // are what a mixer falls back to, and what one shows.
                return after.volume orelse self.nodeVolume(node_id);
            },
        }
    }

    fn nodeVolume(self: *Session, node_id: u32) Error!Volume {
        const binding = try self.bindPrimed(node_id);
        if (binding.params_props == null) return error.NoReply;
        binding.volume = null;

        const b = self.core.beginMessage();
        try reg.writeEnumParams(b, 0, .props, 0, std.math.maxInt(u32), null);
        _ = try self.core.sendMessage(binding.proxy_id, reg.node.method.enum_params, 0);
        try self.roundTrip();

        const after = self.bindings.get(node_id) orelse return error.NotFound;
        return after.volume orelse error.NoReply;
    }

    /// Set every channel of a node to the same linear volume.
    ///
    /// The channel count comes from the node's current `Props`, so this costs
    /// two round trips; `setChannelVolumes` is the one to use when the count is
    /// already known.
    pub fn setVolume(self: *Session, node_id: u32, level: f32) Error!void {
        const current = try self.volume(node_id);
        const channels = if (current.channels == 0) 2 else current.channels;
        var levels: [max_volume_channels]f32 = @splat(level);
        try self.setChannelVolumes(node_id, levels[0..channels]);
    }

    /// Set each channel of a node separately, in the order of its negotiated
    /// layout. Volumes are linear amplitudes; `Volume.cubicToLinear` converts
    /// from the scale `wpctl` and `pavucontrol` show.
    pub fn setChannelVolumes(self: *Session, node_id: u32, levels: []const f32) Error!void {
        if (levels.len > max_volume_channels) return error.WrongType;
        try self.setProps(node_id, null, levels);
    }

    pub fn setMute(self: *Session, node_id: u32, mute: bool) Error!void {
        try self.setProps(node_id, mute, null);
    }

    fn setProps(
        self: *Session,
        node_id: u32,
        mute: ?bool,
        levels: ?[]const f32,
    ) Error!void {
        switch (try self.volumeSite(node_id)) {
            .node => try self.setNodeProps(node_id, mute, levels),
            .route => |site| {
                // A route is written by index, so the one to write has to have
                // been read: enumerate first unless that has already happened.
                const known = try self.bindPrimed(site.device_id);
                if (known.route_index == null or known.route_filter != site.card_device) {
                    _ = try self.volume(node_id);
                }
                const binding = self.bindings.get(site.device_id) orelse return error.NotFound;
                // No active route carries it, so it goes where it was read
                // from: the node itself.
                const index = binding.route_index orelse
                    return self.setNodeProps(node_id, mute, levels);

                self.param_scratch.clear();
                try reg.route.writeVolume(
                    &self.param_scratch,
                    index,
                    site.card_device,
                    mute,
                    levels,
                    true,
                );

                const b = self.core.beginMessage();
                try reg.writeSetParam(b, .route, 0, self.param_scratch.bytes());
                _ = try self.core.sendMessage(binding.proxy_id, reg.device.method.set_param, 0);
                try self.roundTrip();
            },
        }
    }

    fn setNodeProps(
        self: *Session,
        node_id: u32,
        mute: ?bool,
        levels: ?[]const f32,
    ) Error!void {
        const binding = try self.bindPrimed(node_id);
        if (binding.params_props == null) return error.NoReply;

        self.param_scratch.clear();
        try reg.writeVolumeProps(&self.param_scratch, .{ .mute = mute, .channel_volumes = levels });

        const b = self.core.beginMessage();
        try reg.writeSetParam(b, .props, 0, self.param_scratch.bytes());
        _ = try self.core.sendMessage(binding.proxy_id, reg.node.method.set_param, 0);
        try self.roundTrip();
    }

    /// Where a node keeps its volume.
    ///
    /// An application stream keeps it in its own `Props`. A node that belongs
    /// to a device keeps it in that device's route instead — the node's `Props`
    /// then sit at 1.0 whatever the volume is, so a mixer that reads them
    /// disagrees with every other mixer on the machine.
    const VolumeSite = union(enum) {
        node: u32,
        route: struct { device_id: u32, card_device: u32 },
    };

    fn volumeSite(self: *Session, node_id: u32) Error!VolumeSite {
        const object = self.globals.get(node_id) orelse return error.NotFound;
        if (object.type != .node) return error.WrongType;

        const device_id = object.deviceId() orelse return .{ .node = node_id };
        const device = self.globals.get(device_id) orelse return .{ .node = node_id };
        if (device.type != .device) return .{ .node = node_id };

        const card_device = try self.cardDevice(node_id) orelse return .{ .node = node_id };
        return .{ .route = .{ .device_id = device_id, .card_device = card_device } };
    }

    /// Which of its device's routes a node plays through.
    ///
    /// The registry does not announce it, so the node has to be bound and asked
    /// — once; what it answers is kept.
    fn cardDevice(self: *Session, node_id: u32) Error!?u32 {
        const binding = try self.bindPrimed(node_id);
        return binding.card_device;
    }

    // --- state ---

    /// What a node is doing: running, idle, suspended, or in error.
    ///
    /// The registry does not announce it, so this binds the node and waits for
    /// what it says — once; afterwards the answer is whatever the node has most
    /// recently reported, which a `roundTrip` brings up to date.
    pub fn nodeState(self: *Session, node_id: u32) Error!NodeState {
        const binding = try self.bindTyped(node_id, .node);
        const primed = try self.bindPrimed(binding.global_id);
        return primed.state orelse error.NoReply;
    }

    /// Whether a link is carrying audio, still negotiating, or broken.
    pub fn linkState(self: *Session, link_id: u32) Error!LinkState {
        const binding = try self.bindTyped(link_id, .link);
        const primed = try self.bindPrimed(binding.global_id);
        return primed.link_state orelse error.NoReply;
    }

    // --- metadata ---

    /// One value out of a metadata store, or null when it is not set.
    ///
    /// The slice belongs to the session and lives until that entry changes,
    /// which the next round trip may do.
    pub fn metadataValue(
        self: *Session,
        store: []const u8,
        subject: u32,
        key: []const u8,
    ) Error!?[]const u8 {
        const binding = try self.metadataBinding(store);
        return binding.get(subject, key);
    }

    /// Write one value into a metadata store. A null `value` clears the entry.
    ///
    /// This needs write permission on the store and, for a subject other than
    /// 0, permission to name that object — which an ordinary user client has.
    ///
    /// The value is not readable back when this returns. A metadata store
    /// belongs to the session manager rather than to the daemon, so a write
    /// goes out to it and the change comes back as an event of its own, after
    /// the daemon has finished with the round trip that carried the write. A
    /// later `roundTrip` is what collects it.
    pub fn setMetadata(
        self: *Session,
        store: []const u8,
        subject: u32,
        key: []const u8,
        value_type: ?[]const u8,
        value: ?[]const u8,
    ) Error!void {
        const binding = try self.metadataBinding(store);
        const b = self.core.beginMessage();
        try reg.metadata.writeSetProperty(b, subject, key, value_type, value);
        _ = try self.core.sendMessage(binding.proxy_id, reg.metadata.method.set_property, 0);
        try self.roundTrip();
    }

    // --- defaults ---

    /// The sink the session manager is sending everything to, if it is one this
    /// session can see.
    pub fn defaultSink(self: *Session) Error!?*const Object {
        return self.defaultNode("default.audio.sink");
    }

    pub fn defaultSource(self: *Session) Error!?*const Object {
        return self.defaultNode("default.audio.source");
    }

    /// Ask for a sink to be the default, by `node.name`. A null clears the
    /// choice, which puts the session manager back in charge of it.
    ///
    /// What this writes is the *configured* default, which is the wish; the
    /// session manager grants it by setting the default itself, and will not if
    /// the node is not there. So the change shows up in `defaultSink` a moment
    /// later, or not at all.
    pub fn setDefaultSink(self: *Session, node_name: ?[]const u8) Error!void {
        try self.setDefaultNode("default.configured.audio.sink", node_name);
    }

    pub fn setDefaultSource(self: *Session, node_name: ?[]const u8) Error!void {
        try self.setDefaultNode("default.configured.audio.source", node_name);
    }

    fn defaultNode(self: *Session, key: []const u8) Error!?*const Object {
        const value = try self.metadataValue(reg.metadata.name_default, 0, key) orelse return null;
        var scratch: [8192]u8 = undefined;
        const node_name = try jsonName(value, &scratch) orelse return null;
        return self.byName(.node, node_name);
    }

    fn setDefaultNode(self: *Session, key: []const u8, node_name: ?[]const u8) Error!void {
        const name = node_name orelse {
            return self.setMetadata(reg.metadata.name_default, 0, key, null, null);
        };
        var buf: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.writeAll("{\"name\":") catch return error.NameTooLong;
        std.json.Stringify.encodeJsonString(name, .{}, &w) catch return error.NameTooLong;
        w.writeAll("}") catch return error.NameTooLong;
        try self.setMetadata(
            reg.metadata.name_default,
            0,
            key,
            reg.metadata.type_json,
            w.buffered(),
        );
    }

    /// Ask the session manager to move a node to a particular sink or source.
    ///
    /// The target is named the way `target.object` is written everywhere else:
    /// a `node.name`, or an `object.serial` in decimal. A null clears the
    /// request, which lets the node go back to following the default.
    ///
    /// The value goes in as a plain string and with no type, which is what the
    /// session manager compares against — not as the JSON the default-device
    /// keys use. A quoted one is stored happily and then matches no node at
    /// all, which looks from the outside exactly like a move that was refused.
    pub fn moveNode(self: *Session, node_id: u32, target: ?[]const u8) Error!void {
        try self.setMetadata(
            reg.metadata.name_default,
            node_id,
            "target.object",
            null,
            target,
        );
    }

    // --- links ---

    pub const LinkRequest = struct {
        output_node: u32,
        /// The port's own global id, as the registry lists it — not its
        /// `port.id`, which is only its index within its node.
        output_port: u32,
        input_node: u32,
        input_port: u32,
        /// Whether the link outlives this session. Without it the daemon takes
        /// the link away when the connection closes, which is usually what a
        /// program making a temporary connection wants.
        linger: bool = false,
    };

    /// Link one port to another, and return the global id of the new link.
    pub fn createLink(self: *Session, req: LinkRequest) Error!u32 {
        var bufs: [4][16]u8 = undefined;
        var props: [5]Prop = undefined;
        var n: usize = 0;
        const ids = [_]struct { key: []const u8, value: u32 }{
            .{ .key = reg.link.key_output_node, .value = req.output_node },
            .{ .key = reg.link.key_output_port, .value = req.output_port },
            .{ .key = reg.link.key_input_node, .value = req.input_node },
            .{ .key = reg.link.key_input_port, .value = req.input_port },
        };
        for (ids, 0..) |entry, i| {
            const text = std.fmt.bufPrint(&bufs[i], "{d}", .{entry.value}) catch
                return error.NameTooLong;
            props[n] = .{ .key = entry.key, .value = text };
            n += 1;
        }
        if (req.linger) {
            props[n] = .{ .key = reg.link.key_linger, .value = "true" };
            n += 1;
        }

        const proxy_id = try self.core.createObject(
            reg.link.factory_name,
            reg.interface.link,
            reg.version.link,
            props[0..n],
        );
        try self.roundTrip();
        return self.core.boundId(proxy_id) orelse error.NoReply;
    }

    /// Link every output port of one node to an input port of another, the way
    /// `pw-link` does when it is given two node names.
    ///
    /// Ports are paired by speaker position where both sides say what theirs
    /// is, and in order otherwise, stopping when either side runs out. The ids
    /// of the links made are written into `out`, which must have room for as
    /// many links as the narrower of the two nodes has ports; what comes back
    /// is the part of it that was used.
    pub fn linkNodes(
        self: *Session,
        output_node: u32,
        input_node: u32,
        opts: struct { linger: bool = false },
        out: []u32,
    ) Error![]u32 {
        var outputs: [max_volume_channels]PortRef = undefined;
        var inputs: [max_volume_channels]PortRef = undefined;
        const from = self.collectPorts(output_node, .output, &outputs);
        const to = self.collectPorts(input_node, .input, &inputs);
        if (from.len == 0 or to.len == 0) return error.NotFound;

        // The whole pairing is worked out before any of it is asked for,
        // because a `PortRef` borrows its speaker position from the object it
        // came from and making a link is a round trip — which is exactly when
        // an object can go away and take that string with it.
        var pairs: [max_volume_channels][2]u32 = undefined;
        var n: usize = 0;
        for (from) |source| {
            if (n == out.len or n == pairs.len) break;
            const sink = pickPort(source, to, n) orelse continue;
            pairs[n] = .{ source.id, sink.id };
            n += 1;
        }

        for (pairs[0..n], 0..) |pair, i| {
            out[i] = try self.createLink(.{
                .output_node = output_node,
                .output_port = pair[0],
                .input_node = input_node,
                .input_port = pair[1],
                .linger = opts.linger,
            });
        }
        return out[0..n];
    }

    /// Ask for a global to be taken out of the graph — a link to be broken, or
    /// a node the session owns to go away. The daemon refuses politely, with an
    /// error event, when the client has no say over that object.
    pub fn destroy(self: *Session, global_id: u32) Error!void {
        const b = self.core.beginMessage();
        try reg.writeDestroy(b, global_id);
        _ = try self.core.sendMessage(self.registry_id, reg.method.destroy, 0);
        try self.roundTrip();
    }

    // --- binding ---

    /// Take a proxy on a global, or return the one already taken.
    ///
    /// Binding is one message and no round trip of its own: what the object has
    /// to say arrives during the next one.
    fn bind(self: *Session, global_id: u32) Error!*Binding {
        if (self.bindings.get(global_id)) |existing| return existing;

        const object = self.globals.get(global_id) orelse return error.NotFound;
        const object_type = object.type;
        const type_name = object_type.interfaceName() orelse return error.WrongType;
        const bind_version = object_type.bindVersion();

        const binding = try self.gpa.create(Binding);
        errdefer self.gpa.destroy(binding);
        const proxy_id = self.core.allocId();
        binding.* = .{
            .session = self,
            .global_id = global_id,
            .proxy_id = proxy_id,
            .type = object_type,
        };

        try self.bindings.put(self.gpa, global_id, binding);
        errdefer _ = self.bindings.orderedRemove(global_id);
        try self.core.register(proxy_id, .{ .ctx = binding, .func = bindingDispatch });
        errdefer self.core.unregister(proxy_id);

        const b = self.core.beginMessage();
        try reg.writeBind(b, global_id, type_name, bind_version, proxy_id);
        _ = try self.core.sendMessage(self.registry_id, reg.method.bind, 0);
        return binding;
    }

    fn bindTyped(self: *Session, global_id: u32, want: ObjectType) Error!*Binding {
        const object = self.globals.get(global_id) orelse return error.NotFound;
        if (object.type != want) return error.WrongType;
        return self.bind(global_id);
    }

    /// Bind a global and wait, once, for what it says on being bound: a node's
    /// and a device's info, a metadata store's whole contents.
    fn bindPrimed(self: *Session, global_id: u32) Error!*Binding {
        const binding = try self.bind(global_id);
        if (binding.primed) return binding;
        try self.roundTrip();
        const after = self.bindings.get(global_id) orelse return error.NotFound;
        after.primed = true;
        return after;
    }

    fn metadataBinding(self: *Session, store: []const u8) Error!*Binding {
        var found: ?u32 = null;
        var it = self.iterator(.{ .type = .metadata });
        while (it.next()) |object| {
            const n = object.prop(reg.metadata.key_name) orelse continue;
            if (std.mem.eql(u8, n, store)) {
                found = object.id;
                break;
            }
        }
        const id = found orelse return error.NotFound;

        // Binding a metadata store makes it send everything it holds, which
        // the round trip inside this is what waits for.
        return self.bindPrimed(id);
    }

    // --- incoming events ---

    fn registryDispatch(ctx: *anyopaque, _: *Core, msg: conn.Message) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        switch (msg.opcode) {
            reg.event.global => {
                const global = reg.parseGlobal(msg) catch |err| {
                    self.logf(.warn, "unreadable global: {s}", .{@errorName(err)});
                    return;
                };
                try self.addGlobal(global);
            },
            reg.event.global_remove => {
                const id = reg.parseGlobalRemove(msg) catch return;
                self.removeGlobal(id);
            },
            else => {},
        }
    }

    /// Events for a bound object.
    ///
    /// A message this cannot read is dropped rather than dispatched as an
    /// error: a session watches the whole graph, and one object saying
    /// something unexpected is not a reason to stop watching the rest.
    fn bindingDispatch(ctx: *anyopaque, _: *Core, msg: conn.Message) anyerror!void {
        const binding: *Binding = @ptrCast(@alignCast(ctx));
        const self = binding.session;
        switch (binding.type) {
            .node => switch (msg.opcode) {
                reg.node.event.info => {
                    const info = reg.node.parseInfo(msg) catch return;
                    if (info.change_mask & reg.node.change.state != 0) binding.state = info.state;
                    if (info.props.get("card.profile.device")) |text| {
                        binding.card_device = std.fmt.parseInt(u32, text, 10) catch null;
                    }
                    if (info.change_mask & reg.node.change.params != 0) {
                        binding.params_props = info.params.get(.props);
                    }
                },
                reg.node.event.param => {
                    const param = reg.parseParam(msg) catch return;
                    if (param.id != .props) return;
                    const value = param.param orelse return;
                    binding.mergeVolume(reg.parseVolume(value) catch return);
                },
                else => {},
            },
            .device => switch (msg.opcode) {
                reg.device.event.info => {
                    const info = reg.device.parseInfo(msg) catch return;
                    if (info.change_mask & reg.device.change.params != 0) {
                        binding.params_route = info.params.get(.route);
                    }
                },
                reg.device.event.param => {
                    const param = reg.parseParam(msg) catch return;
                    if (param.id != .route) return;
                    const value = param.param orelse return;
                    const info = reg.route.parse(value) catch return;
                    // A device enumerates every route it has; only the one the
                    // node in hand plays through is being asked about.
                    const wanted = binding.route_filter orelse return;
                    if (info.device != wanted) return;
                    binding.route_index = info.index;
                    const props = info.props orelse return;
                    binding.mergeVolume(reg.parseVolume(props) catch return);
                },
                else => {},
            },
            .link => switch (msg.opcode) {
                reg.link.event.info => {
                    const info = reg.link.parseInfo(msg) catch return;
                    if (info.change_mask & reg.link.change.state != 0) {
                        binding.link_state = info.state;
                    }
                },
                else => {},
            },
            .metadata => switch (msg.opcode) {
                reg.metadata.event.property => {
                    const property = reg.metadata.parseProperty(msg) catch return;
                    binding.put(self.gpa, property) catch |err| {
                        if (err == error.OutOfMemory) return err;
                    };
                },
                else => {},
            },
            else => {},
        }
    }

    fn addGlobal(self: *Session, global: reg.Global) Error!void {
        const object = try makeObject(self.gpa, global);
        errdefer {
            object.deinit(self.gpa);
            self.gpa.destroy(object);
        }

        const entry = try self.globals.getOrPut(self.gpa, global.id);
        if (entry.found_existing) {
            // An id the daemon has handed out again. Whatever was here is gone,
            // and so is any proxy on it.
            self.dropBinding(global.id);
            entry.value_ptr.*.deinit(self.gpa);
            self.gpa.destroy(entry.value_ptr.*);
        }
        entry.value_ptr.* = object;
    }

    fn removeGlobal(self: *Session, id: u32) void {
        self.dropBinding(id);
        if (self.globals.fetchOrderedRemove(id)) |entry| {
            entry.value.deinit(self.gpa);
            self.gpa.destroy(entry.value);
        }
    }

    fn dropBinding(self: *Session, global_id: u32) void {
        const entry = self.bindings.fetchOrderedRemove(global_id) orelse return;
        // The proxy goes with the global: the daemon has already taken the
        // resource away, so there is nothing to destroy, only to forget.
        self.core.unregister(entry.value.proxy_id);
        entry.value.deinit(self.gpa);
        self.gpa.destroy(entry.value);
    }

    // --- ports, for linking ---

    const PortRef = struct {
        /// The port's global id, which is what a link names.
        id: u32,
        /// Its index within its node, which is what puts the ports in order.
        index: u32,
        channel: ?[]const u8,
    };

    fn collectPorts(
        self: *const Session,
        node_id: u32,
        direction: spa.Direction,
        out: *[max_volume_channels]PortRef,
    ) []PortRef {
        var n: usize = 0;
        var it = self.iterator(.{ .type = .port });
        while (it.next()) |object| {
            if (n == out.len) break;
            if (object.parentNodeId() != node_id) continue;
            if (object.portDirection() != direction) continue;
            const index = object.portIndex() orelse continue;
            out[n] = .{ .id = object.id, .index = index, .channel = object.channel() };
            n += 1;
        }
        std.mem.sort(PortRef, out[0..n], {}, struct {
            fn lessThan(_: void, a: PortRef, b: PortRef) bool {
                return a.index < b.index;
            }
        }.lessThan);
        return out[0..n];
    }

    fn pickPort(source: PortRef, candidates: []const PortRef, fallback: usize) ?PortRef {
        if (source.channel) |want| {
            for (candidates) |candidate| {
                const have = candidate.channel orelse continue;
                if (std.mem.eql(u8, have, want)) return candidate;
            }
        }
        if (fallback < candidates.len) return candidates[fallback];
        return null;
    }

    fn logf(self: *Session, level: Log.Level, comptime fmt: []const u8, args: anytype) void {
        Log.printf(self.log, level, fmt, args);
    }
};

// --- helpers ----------------------------------------------------------------

/// Copy a global and its properties out of the message they arrived in.
///
/// Two passes: one to measure, one to fill, so that every string a caller sees
/// lives in one allocation freed with the object. A dictionary that runs out
/// mid-way is taken as ending there rather than failing the whole object —
/// having a node's id and no properties is more use than not knowing it exists.
///
/// Public because it is the one allocating step between the daemon's bytes and
/// what a session holds, which the fuzz targets drive directly.
pub fn makeObject(gpa: std.mem.Allocator, global: reg.Global) Error!*Object {
    var count: usize = 0;
    var bytes: usize = global.type_name.len;
    var measure = global.props;
    while (measure.next() catch null) |p| {
        count += 1;
        bytes += p.key.len + p.value.len;
    }

    const storage = try gpa.alloc(u8, bytes);
    errdefer gpa.free(storage);
    const props = try gpa.alloc(Prop, count);
    errdefer gpa.free(props);

    @memcpy(storage[0..global.type_name.len], global.type_name);
    var used: usize = global.type_name.len;
    var filled: usize = 0;
    var fill = global.props;
    while (fill.next() catch null) |p| {
        if (filled == count) break;
        const key = storage[used..][0..p.key.len];
        @memcpy(key, p.key);
        used += p.key.len;
        const value = storage[used..][0..p.value.len];
        @memcpy(value, p.value);
        used += p.value.len;
        props[filled] = .{ .key = key, .value = value };
        filled += 1;
    }

    const object = try gpa.create(Object);
    object.* = .{
        .id = global.id,
        .permissions = global.permissions,
        .version = global.version,
        .type = global.type,
        .type_name = storage[0..global.type_name.len],
        .props = props[0..filled],
        .storage = storage,
    };
    return object;
}

/// The node name out of a metadata value.
///
/// The session manager writes `{"name":"<node name>"}` for a default device and
/// a bare JSON string for a target, so both are read here. `scratch` backs the
/// parse, and the name may point into it.
fn jsonName(value: []const u8, scratch: []u8) Error!?[]const u8 {
    var fba: std.heap.FixedBufferAllocator = .init(scratch);
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        fba.allocator(),
        value,
        .{},
    ) catch return error.MalformedValue;
    return switch (parsed) {
        .string => |s| s,
        .object => |o| switch (o.get("name") orelse return null) {
            .string => |s| s,
            .null => null,
            else => error.MalformedValue,
        },
        .null => null,
        else => error.MalformedValue,
    };
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;

/// A registry Global event, encoded the way the daemon sends one.
fn testGlobal(
    b: *pod.Builder,
    id: u32,
    type_name: []const u8,
    props: []const Prop,
) !reg.Global {
    b.clear();
    const f = try b.pushStruct();
    try b.addInt(@bitCast(id));
    try b.addInt(@bitCast(reg.perm.rwx));
    try b.addString(type_name);
    try b.addInt(3);
    try core_mod.writeDict(b, props);
    try b.pop(f);
    return reg.parseGlobal(.{
        .id = 2,
        .opcode = reg.event.global,
        .seq = 0,
        .data = b.bytes(),
        .fds = &.{},
    });
}

test "an object keeps a copy of what the registry said about it" {
    var b = pod.Builder.init(testing.allocator);
    defer b.deinit();

    const global = try testGlobal(&b, 39, reg.interface.node, &.{
        .{ .key = "node.name", .value = "alsa_output.pci" },
        .{ .key = "node.description", .value = "Built-in Audio" },
        .{ .key = "media.class", .value = "Audio/Sink" },
        .{ .key = "object.serial", .value = "64" },
        .{ .key = "device.id", .value = "56" },
    });
    const object = try makeObject(testing.allocator, global);
    defer {
        object.deinit(testing.allocator);
        testing.allocator.destroy(object);
    }

    // The message the properties came in is about to be reused, so what the
    // object holds must not point into it.
    b.clear();
    try b.addString("something else entirely");

    try testing.expectEqual(@as(u32, 39), object.id);
    try testing.expectEqual(ObjectType.node, object.type);
    try testing.expectEqualStrings("alsa_output.pci", object.name().?);
    try testing.expectEqualStrings("Built-in Audio", object.label());
    try testing.expectEqual(@as(u64, 64), object.serial().?);
    try testing.expectEqual(@as(u32, 56), object.deviceId().?);
    try testing.expect(object.isSink());
    try testing.expect(!object.isStream());
    try testing.expect(object.prop("node.nick") == null);
}

test "an object of an interface this library has no name for is still listed" {
    var b = pod.Builder.init(testing.allocator);
    defer b.deinit();

    const global = try testGlobal(&b, 5, "PipeWire:Interface:Nonesuch", &.{});
    const object = try makeObject(testing.allocator, global);
    defer {
        object.deinit(testing.allocator);
        testing.allocator.destroy(object);
    }

    try testing.expectEqual(ObjectType.other, object.type);
    try testing.expectEqualStrings("PipeWire:Interface:Nonesuch", object.type_name);
    try testing.expectEqualStrings("PipeWire:Interface:Nonesuch", object.label());
}

test "a truncated dictionary costs the properties, not the object" {
    var b = pod.Builder.init(testing.allocator);
    defer b.deinit();

    // A global promising three properties and carrying one.
    const f = try b.pushStruct();
    try b.addInt(11);
    try b.addInt(@bitCast(reg.perm.rwx));
    try b.addString(reg.interface.node);
    try b.addInt(3);
    const dict = try b.pushStruct();
    try b.addInt(3);
    try b.addString("node.name");
    try b.addString("half-a-dictionary");
    try b.pop(dict);
    try b.pop(f);

    const global = try reg.parseGlobal(.{
        .id = 2,
        .opcode = reg.event.global,
        .seq = 0,
        .data = b.bytes(),
        .fds = &.{},
    });
    const object = try makeObject(testing.allocator, global);
    defer {
        object.deinit(testing.allocator);
        testing.allocator.destroy(object);
    }

    try testing.expectEqual(@as(usize, 1), object.props.len);
    try testing.expectEqualStrings("half-a-dictionary", object.name().?);
}

test "a filter picks out one kind of object" {
    var b = pod.Builder.init(testing.allocator);
    defer b.deinit();

    var made: [4]*Object = undefined;
    const table = [_]struct { id: u32, type_name: []const u8, class: []const u8 }{
        .{ .id = 1, .type_name = reg.interface.node, .class = "Audio/Sink" },
        .{ .id = 2, .type_name = reg.interface.node, .class = "Stream/Output/Audio" },
        .{ .id = 3, .type_name = reg.interface.node, .class = "Stream/Input/Audio" },
        .{ .id = 4, .type_name = reg.interface.device, .class = "Audio/Device" },
    };
    for (table, &made) |entry, *slot| {
        const global = try testGlobal(&b, entry.id, entry.type_name, &.{
            .{ .key = "media.class", .value = entry.class },
        });
        slot.* = try makeObject(testing.allocator, global);
    }
    defer for (made) |object| {
        object.deinit(testing.allocator);
        testing.allocator.destroy(object);
    };

    var sinks: Iterator = .{ .items = &made, .filter = .{ .type = .node, .media_class = "Audio/Sink" } };
    try testing.expectEqual(@as(u32, 1), sinks.next().?.id);
    try testing.expect(sinks.next() == null);

    var streams: Iterator = .{ .items = &made, .filter = .{ .type = .node, .media_class_prefix = "Stream/" } };
    try testing.expectEqual(@as(u32, 2), streams.next().?.id);
    try testing.expectEqual(@as(u32, 3), streams.next().?.id);
    try testing.expect(streams.next() == null);

    var devices: Iterator = .{ .items = &made, .filter = .{ .type = .device } };
    try testing.expectEqual(@as(u32, 4), devices.next().?.id);
    try testing.expect(devices.next() == null);
}

test "a default device is read out of the JSON the session manager writes" {
    var scratch: [4096]u8 = undefined;
    try testing.expectEqualStrings(
        "alsa_output.pci",
        (try jsonName("{\"name\":\"alsa_output.pci\"}", &scratch)).?,
    );
    // A target is written as a bare string rather than an object.
    try testing.expectEqualStrings("sink-name", (try jsonName("\"sink-name\"", &scratch)).?);
    // An escape has to survive, which is the whole reason this is JSON.
    try testing.expectEqualStrings(
        "odd\"name",
        (try jsonName("{\"name\":\"odd\\\"name\"}", &scratch)).?,
    );
    try testing.expect(try jsonName("{\"other\":1}", &scratch) == null);
    try testing.expect(try jsonName("null", &scratch) == null);
    try testing.expectError(error.MalformedValue, jsonName("{not json", &scratch));
    try testing.expectError(error.MalformedValue, jsonName("{\"name\":17}", &scratch));
}

test "ports pair up by speaker position, and by order when they cannot" {
    const PortRef = Session.PortRef;
    const inputs = [_]PortRef{
        .{ .id = 66, .index = 1, .channel = "FR" },
        .{ .id = 65, .index = 0, .channel = "FL" },
    };
    const left: PortRef = .{ .id = 93, .index = 0, .channel = "FL" };
    try testing.expectEqual(@as(u32, 65), Session.pickPort(left, &inputs, 0).?.id);

    // No position on either side: take them in the order they were collected.
    const plain = [_]PortRef{
        .{ .id = 10, .index = 0, .channel = null },
        .{ .id = 11, .index = 1, .channel = null },
    };
    const anonymous: PortRef = .{ .id = 1, .index = 0, .channel = null };
    try testing.expectEqual(@as(u32, 11), Session.pickPort(anonymous, &plain, 1).?.id);
    try testing.expect(Session.pickPort(anonymous, &plain, 2) == null);

    // A position with nothing to match falls back to order as well, which is
    // the order the candidates were collected in rather than their ids.
    const centre: PortRef = .{ .id = 2, .index = 0, .channel = "FC" };
    try testing.expectEqual(@as(u32, 66), Session.pickPort(centre, &inputs, 0).?.id);
}
