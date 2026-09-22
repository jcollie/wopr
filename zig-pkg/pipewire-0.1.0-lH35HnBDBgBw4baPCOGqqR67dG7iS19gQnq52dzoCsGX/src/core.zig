// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The Core object and the connection bookkeeping around it.
//!
//! `Core` owns the socket, hands out object ids, and understands the handful of
//! Core events every client needs: `Done` (the reply to `Sync`), `Error`, and
//! the `AddMem`/`RemoveMem` pair that populates the memory pool. Everything else
//! is dispatched to whichever object the message is addressed to.

const std = @import("std");
const sys = @import("sys.zig");
const pod = @import("pod.zig");
const conn = @import("connection.zig");

pub const Error = conn.Error || pod.Error || error{
    /// The daemon replied to one of our requests with a Core.Error event.
    RemoteError,
    /// The daemon closed the connection.
    Disconnected,
    /// No PipeWire socket could be located.
    NoSocket,
};

/// Well-known object ids. The Core is always 0 and the Client always 1, because
/// a client creates those two proxies in that order before anything else.
pub const id_core: u32 = 0;
pub const id_client: u32 = 1;

pub const version_core: u32 = 4;
pub const version_client: u32 = 3;

pub const interface_client_node = "PipeWire:Interface:ClientNode";

const core_method = struct {
    const hello: u8 = 1;
    const sync: u8 = 2;
    const pong: u8 = 3;
    const err: u8 = 4;
    const get_registry: u8 = 5;
    const create_object: u8 = 6;
    const destroy: u8 = 7;
};

const core_event = struct {
    const info: u8 = 0;
    const done: u8 = 1;
    const ping: u8 = 2;
    const err: u8 = 3;
    const remove_id: u8 = 4;
    const bound_id: u8 = 5;
    const add_mem: u8 = 6;
    const remove_mem: u8 = 7;
    const bound_props: u8 = 8;
};

const client_method = struct {
    const err: u8 = 1;
    const update_properties: u8 = 2;
};

/// A key/value pair as it appears in a properties dictionary.
pub const Prop = struct { key: []const u8, value: []const u8 };

/// One entry of the memory pool: a descriptor the daemon shared with us,
/// referred to elsewhere in the protocol by its id.
pub const MemBlock = struct {
    id: u32,
    type: u32,
    fd: i32,
    flags: u32,
};

/// Where an object's messages go. Returning an error aborts the message pump.
pub const Dispatch = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, core: *Core, msg: conn.Message) anyerror!void,
};

pub const Core = struct {
    gpa: std.mem.Allocator,
    c: conn.Connection,

    /// Scratch builder reused for every outgoing message.
    scratch: pod.Builder,

    /// The next object id to hand out. 0 and 1 are the Core and Client.
    next_id: u32 = 2,

    objects: std.AutoHashMapUnmanaged(u32, Dispatch) = .empty,
    mem: std.AutoHashMapUnmanaged(u32, MemBlock) = .empty,
    /// Proxy id to global id, as reported by the BoundProps event. This is how
    /// the caller of `createObject` learns the registry id of what it made.
    bound: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    /// Set when the daemon sends a Core.Error. Owned by this struct.
    last_error: ?[]u8 = null,
    last_error_res: i32 = 0,

    /// The sequence number of the most recent Done event, which is how
    /// `waitSync` knows the round trip it asked for has come back.
    done_seq: i32 = -1,

    // --- lifecycle ---

    /// Resolve the daemon socket path into `buf`.
    ///
    /// `runtime_dir` and `remote` come from the environment when the caller has
    /// it (`PIPEWIRE_RUNTIME_DIR` or `XDG_RUNTIME_DIR`, and `PIPEWIRE_REMOTE`).
    /// With neither, this falls back to `/run/user/<uid>/pipewire-0`, which is
    /// where a logged-in session puts it.
    pub fn socketPath(
        buf: []u8,
        runtime_dir: ?[]const u8,
        remote: ?[]const u8,
    ) Error![]const u8 {
        const name = if (remote) |r| (if (r.len > 0) r else "pipewire-0") else "pipewire-0";
        if (name.len > 0 and (name[0] == '/' or name[0] == '@')) {
            return std.fmt.bufPrint(buf, "{s}", .{name}) catch return error.NoSocket;
        }
        if (runtime_dir) |dir| {
            if (dir.len > 0) {
                return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch return error.NoSocket;
            }
        }
        return std.fmt.bufPrint(buf, "/run/user/{d}/{s}", .{ sys.getuid(), name }) catch
            return error.NoSocket;
    }

    /// Connect to the daemon and complete the opening handshake: Hello on the
    /// Core, then our properties on the Client.
    pub fn connect(
        gpa: std.mem.Allocator,
        path: []const u8,
        props: []const Prop,
    ) Error!*Core {
        const fd = sys.connectUnix(path) catch |err| switch (err) {
            error.NotFound, error.ConnectionRefused => return error.NoSocket,
            else => |e| return e,
        };

        const self = try gpa.create(Core);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .c = conn.Connection.init(gpa, fd),
            .scratch = pod.Builder.init(gpa),
        };
        errdefer self.deinit();

        try self.hello();
        try self.updateClientProperties(props);
        try self.c.flush();
        return self;
    }

    pub fn deinit(self: *Core) void {
        var it = self.mem.valueIterator();
        while (it.next()) |m| sys.close(m.fd);
        self.mem.deinit(self.gpa);
        self.objects.deinit(self.gpa);
        self.bound.deinit(self.gpa);
        if (self.last_error) |e| self.gpa.free(e);
        self.scratch.deinit();
        self.c.deinit();
        self.gpa.destroy(self);
    }

    // --- object registry ---

    pub fn allocId(self: *Core) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn register(self: *Core, id: u32, d: Dispatch) Error!void {
        try self.objects.put(self.gpa, id, d);
    }

    pub fn unregister(self: *Core, id: u32) void {
        _ = self.objects.remove(id);
        _ = self.bound.remove(id);
    }

    /// The global id the daemon bound a proxy of ours to, once it has said so.
    pub fn boundId(self: *const Core, proxy_id: u32) ?u32 {
        return self.bound.get(proxy_id);
    }

    // --- outgoing methods ---

    fn begin(self: *Core) *pod.Builder {
        self.scratch.clear();
        return &self.scratch;
    }

    fn finish(self: *Core, id: u32, opcode: u8, n_fds: u32) Error!u32 {
        return self.c.send(id, opcode, self.scratch.bytes(), n_fds);
    }

    fn hello(self: *Core) Error!void {
        const b = self.begin();
        const f = try b.pushStruct();
        try b.addInt(@intCast(version_core));
        try b.pop(f);
        _ = try self.finish(id_core, core_method.hello, 0);
    }

    pub fn updateClientProperties(self: *Core, props: []const Prop) Error!void {
        const b = self.begin();
        const f = try b.pushStruct();
        try writeDict(b, props);
        try b.pop(f);
        _ = try self.finish(id_client, client_method.update_properties, 0);
    }

    /// Bind the registry and return the id of the new proxy. From here on the
    /// daemon sends a Global event for every object it already has, and for
    /// every one that appears afterwards.
    pub fn getRegistry(self: *Core, registry_version: u32) Error!u32 {
        const new_id = self.allocId();
        const b = self.begin();
        const f = try b.pushStruct();
        try b.addInt(@bitCast(registry_version));
        try b.addInt(@bitCast(new_id));
        try b.pop(f);
        _ = try self.finish(id_core, core_method.get_registry, 0);
        return new_id;
    }

    /// Ask the daemon to echo a Done event once everything sent so far has been
    /// handled. Returns the sequence number to wait for.
    pub fn sync(self: *Core) Error!i32 {
        const b = self.begin();
        const f = try b.pushStruct();
        try b.addInt(@intCast(id_core));
        // PipeWire tags the seq as an async result, which is what comes back in
        // the Done event.
        const seq = self.c.seq;
        try b.addInt(@bitCast(asyncSeq(seq)));
        try b.pop(f);
        _ = try self.finish(id_core, core_method.sync, 0);
        return @bitCast(asyncSeq(seq));
    }

    fn pong(self: *Core, id: u32, seq: i32) Error!void {
        const b = self.begin();
        const f = try b.pushStruct();
        try b.addInt(@bitCast(id));
        try b.addInt(seq);
        try b.pop(f);
        _ = try self.finish(id_core, core_method.pong, 0);
    }

    /// Create an object from one of the daemon's factories and return the id of
    /// the new proxy.
    pub fn createObject(
        self: *Core,
        factory: []const u8,
        interface: []const u8,
        version: u32,
        props: []const Prop,
    ) Error!u32 {
        const new_id = self.allocId();
        const b = self.begin();
        const f = try b.pushStruct();
        try b.addString(factory);
        try b.addString(interface);
        try b.addInt(@bitCast(version));
        try writeDict(b, props);
        try b.addInt(@bitCast(new_id));
        try b.pop(f);
        _ = try self.finish(id_core, core_method.create_object, 0);
        return new_id;
    }

    /// Ask the daemon to drop the object behind a proxy id.
    pub fn destroyObject(self: *Core, id: u32) Error!void {
        const b = self.begin();
        const f = try b.pushStruct();
        try b.addInt(@bitCast(id));
        try b.pop(f);
        _ = try self.finish(id_core, core_method.destroy, 0);
        self.unregister(id);
    }

    /// Send a raw method on some other object, using the scratch builder that
    /// `beginMessage` returned.
    pub fn beginMessage(self: *Core) *pod.Builder {
        return self.begin();
    }

    pub fn sendMessage(self: *Core, id: u32, opcode: u8, n_fds: u32) Error!u32 {
        return self.finish(id, opcode, n_fds);
    }

    pub fn flush(self: *Core) Error!void {
        try self.c.flush();
    }

    // --- memory pool ---

    pub fn findMem(self: *Core, id: u32) ?MemBlock {
        return self.mem.get(id);
    }

    /// Map a region of a pooled block. The caller unmaps it.
    pub fn mapMem(self: *Core, id: u32, offset: u32, size: u32) Error!sys.Mapping {
        const block = self.findMem(id) orelse return error.ProtocolError;
        return sys.mmapShared(block.fd, offset, size);
    }

    // --- incoming messages ---

    /// Block until at least one message has been read, then dispatch every
    /// message that is complete in the buffer.
    pub fn dispatchBlocking(self: *Core) !void {
        try self.c.fill(false);
        try self.dispatchBuffered();
    }

    /// Dispatch whatever is already buffered without touching the socket.
    pub fn dispatchBuffered(self: *Core) !void {
        while (try self.c.next()) |msg| {
            defer self.c.release(msg);
            try self.handle(msg);
        }
        try self.c.flush();
    }

    /// Read and dispatch until the Done for `seq` arrives.
    pub fn waitSync(self: *Core, seq: i32) !void {
        try self.c.flush();
        while (self.done_seq != seq) {
            if (self.last_error != null) return error.RemoteError;
            try self.dispatchBlocking();
        }
    }

    fn handle(self: *Core, msg: conn.Message) !void {
        if (msg.id == id_core) return self.handleCoreEvent(msg);
        if (self.objects.get(msg.id)) |d| return d.func(d.ctx, self, msg);
        // Events for objects we never created, or already dropped, are ignored;
        // the daemon may still have messages in flight for them.
    }

    fn handleCoreEvent(self: *Core, msg: conn.Message) !void {
        var p = msg.parser();
        switch (msg.opcode) {
            core_event.done => {
                var s = try p.nextStruct();
                _ = try s.nextInt(); // id
                self.done_seq = try s.nextInt();
            },
            core_event.ping => {
                var s = try p.nextStruct();
                const id = try s.nextInt();
                const seq = try s.nextInt();
                try self.pong(@bitCast(id), seq);
            },
            core_event.err => {
                var s = try p.nextStruct();
                _ = try s.nextInt(); // id of the failing object
                _ = try s.nextInt(); // seq
                const res = try s.nextInt();
                const message = try s.nextString();
                if (self.last_error) |e| self.gpa.free(e);
                self.last_error = try self.gpa.dupe(u8, message);
                self.last_error_res = res;
            },
            core_event.add_mem => {
                var s = try p.nextStruct();
                const id: u32 = @bitCast(try s.nextInt());
                const mem_type = try s.nextId();
                const fd = msg.takeFd(try s.nextFd());
                const flags: u32 = @bitCast(try s.nextInt());
                if (fd < 0) return;
                if (try self.mem.fetchPut(self.gpa, id, .{
                    .id = id,
                    .type = mem_type,
                    .fd = fd,
                    .flags = flags,
                })) |old| sys.close(old.value.fd);
            },
            core_event.remove_mem => {
                var s = try p.nextStruct();
                const id: u32 = @bitCast(try s.nextInt());
                if (self.mem.fetchRemove(id)) |old| sys.close(old.value.fd);
            },
            // BoundId is deprecated in favour of BoundProps, but a daemon may
            // send either, and only the two ids are wanted from both.
            core_event.bound_id, core_event.bound_props => {
                var s = try p.nextStruct();
                const id: u32 = @bitCast(try s.nextInt());
                const global_id: u32 = @bitCast(try s.nextInt());
                try self.bound.put(self.gpa, id, global_id);
            },
            // Info and RemoveId carry nothing this library acts on: a node's
            // global id arrives again in its own events.
            else => {},
        }
    }

    /// Forget the last error, so that the next round trip reports only its own.
    pub fn clearError(self: *Core) void {
        if (self.last_error) |e| self.gpa.free(e);
        self.last_error = null;
        self.last_error_res = 0;
    }

    /// The error text the daemon last reported, if any.
    pub fn errorMessage(self: *const Core) ?[]const u8 {
        return self.last_error;
    }

    /// The negative errno the daemon sent with `errorMessage`.
    pub fn errorCode(self: *const Core) i32 {
        return self.last_error_res;
    }
};

/// PipeWire marks an asynchronous sequence number with `SPA_ASYNC_BIT`, and the
/// Done event echoes the marked value back.
fn asyncSeq(seq: u32) u32 {
    return async_bit | (seq & conn.seq_mask);
}

const async_bit: u32 = 1 << 30;

/// Write a properties dictionary: a Struct of the item count followed by that
/// many key/value string pairs.
pub fn writeDict(b: *pod.Builder, props: []const Prop) !void {
    const f = try b.pushStruct();
    try b.addInt(@intCast(props.len));
    for (props) |p| {
        try b.addString(p.key);
        try b.addString(p.value);
    }
    try b.pop(f);
}

/// Skip over a properties dictionary in a message being parsed.
pub fn skipDict(p: *pod.Parser) !void {
    var s = try p.nextStruct();
    const n = try s.nextInt();
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        _ = try s.nextString();
        _ = try s.nextString();
    }
}

test "async sequence numbers stay inside the mask" {
    try std.testing.expectEqual(@as(u32, 0x40000000), asyncSeq(0));
    try std.testing.expectEqual(@as(u32, 0x40000005), asyncSeq(5));
    try std.testing.expectEqual(@as(u32, 0x40000000), asyncSeq(1 << 30));
}

test "socket path falls back to the per-user runtime directory" {
    var buf: [128]u8 = undefined;
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "/run/user/{d}/pipewire-0",
        .{sys.getuid()},
    );
    try std.testing.expectEqualStrings(expected, try Core.socketPath(&buf, null, null));
    try std.testing.expectEqualStrings(
        "/run/x/pipewire-0",
        try Core.socketPath(&buf, "/run/x", null),
    );
    try std.testing.expectEqualStrings(
        "/run/x/pipewire-1",
        try Core.socketPath(&buf, "/run/x", "pipewire-1"),
    );
    try std.testing.expectEqualStrings(
        "/tmp/custom.sock",
        try Core.socketPath(&buf, "/run/x", "/tmp/custom.sock"),
    );
}
