// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A playback stream: a node in the PipeWire graph with one mono output port per
//! channel, driven by the daemon once per graph cycle.
//!
//! ## How playback works here
//!
//! PipeWire's audio graph is planar: every audio port carries one channel of
//! native-endian `f32`, and the sink in front of the hardware does any mixing,
//! resampling and format conversion. So a stereo stream is a node with two
//! output ports, `output_FL` and `output_FR`, and the session manager links them
//! to the default sink.
//!
//! The daemon owns the clock. Once per cycle it writes an eventfd; this library
//! wakes on it, asks the shared position area how many frames the cycle wants,
//! writes exactly that many into the shared buffer each port was given, and
//! marks each port's io area as holding data. It then decrements the barrier of
//! every peer node it feeds and wakes those in turn, which is how the graph
//! walks from source to sink within one cycle.
//!
//! ## Threads
//!
//! Two threads run behind this API. The *data* thread does nothing but wait on
//! the eventfd and run the cycle above. The *protocol* thread reads the socket
//! and applies whatever the daemon says: a negotiated format, a new set of
//! buffers, a peer appearing or going away. The two share `rt_lock`, which the
//! data thread holds for the length of a cycle and the protocol thread holds
//! only while swapping that state — that is, during linking and unlinking, not
//! during steady playback.
//!
//! Audio reaches the data thread either through `write`, which feeds a lock-free
//! ring, or through a `process` callback the caller supplies, which then runs on
//! the data thread and must not block.

const std = @import("std");
const spa = @import("spa.zig");
const pod = @import("pod.zig");
const sys = @import("sys.zig");
const conn = @import("connection.zig");
const core_mod = @import("core.zig");
const cn = @import("client_node.zig");
const reg = @import("registry.zig");
const ring_mod = @import("ring.zig");

const Core = core_mod.Core;
const Prop = core_mod.Prop;

/// What this node's `Props` parameter says about its volume — the same type a
/// `Session` reads off any other node, because this is the same parameter.
pub const Volume = reg.Volume;

pub const Error = core_mod.Error || std.mem.Allocator.Error || error{
    TooManyBuffers,
    TooManyChannels,
    ChannelMapMismatch,
    ThreadSpawnFailed,
    NotConnected,
};

pub const max_channels = 64;

/// Frames of scratch to keep per port before the daemon says how big a cycle
/// is. PipeWire's own `clock.quantum-limit` default is the same number.
const default_scratch_frames = 8192;

comptime {
    // `channelMapFor` writes one channel per channel the decoder reports, so
    // the decoder's own cap has to be the smaller of the two.
    std.debug.assert(cn.max_layout_channels <= max_channels);
}

/// A speaker position, used both for the port name the graph shows and for the
/// `audio.channel` property the session manager routes on.
pub const Channel = enum {
    mono,
    fl,
    fr,
    fc,
    lfe,
    rl,
    rr,
    sl,
    sr,
    flc,
    frc,
    rc,

    /// The `enum spa_audio_channel` id, for a format's `position` array.
    pub fn position(c: Channel) u32 {
        return switch (c) {
            .mono => spa.audio_channel.mono,
            .fl => spa.audio_channel.fl,
            .fr => spa.audio_channel.fr,
            .fc => spa.audio_channel.fc,
            .lfe => spa.audio_channel.lfe,
            .rl => spa.audio_channel.rl,
            .rr => spa.audio_channel.rr,
            .sl => spa.audio_channel.sl,
            .sr => spa.audio_channel.sr,
            .flc => spa.audio_channel.flc,
            .frc => spa.audio_channel.frc,
            .rc => spa.audio_channel.rc,
        };
    }

    pub fn name(c: Channel) []const u8 {
        return switch (c) {
            .mono => "MONO",
            .fl => "FL",
            .fr => "FR",
            .fc => "FC",
            .lfe => "LFE",
            .rl => "RL",
            .rr => "RR",
            .sl => "SL",
            .sr => "SR",
            .flc => "FLC",
            .frc => "FRC",
            .rc => "RC",
        };
    }
};

/// The conventional channel order for a given channel count, matching what the
/// rest of the PipeWire stack assumes when no map is given.
pub fn defaultChannelMap(channels: u32) []const Channel {
    const stereo = [_]Channel{ .fl, .fr };
    const quad = [_]Channel{ .fl, .fr, .rl, .rr };
    const five_one = [_]Channel{ .fl, .fr, .fc, .lfe, .rl, .rr };
    const seven_one = [_]Channel{ .fl, .fr, .fc, .lfe, .rl, .rr, .sl, .sr };
    return switch (channels) {
        1 => &[_]Channel{.mono},
        2 => &stereo,
        4 => &quad,
        6 => &five_one,
        8 => &seven_one,
        else => &.{},
    };
}

/// `media.role`, which the session manager uses to pick a sink and apply policy.
pub const Role = enum {
    movie,
    music,
    camera,
    screen,
    communication,
    game,
    notification,
    dsp,
    production,
    accessibility,
    @"test",

    pub fn name(r: Role) []const u8 {
        return switch (r) {
            .movie => "Movie",
            .music => "Music",
            .camera => "Camera",
            .screen => "Screen",
            .communication => "Communication",
            .game => "Game",
            .notification => "Notification",
            .dsp => "DSP",
            .production => "Production",
            .accessibility => "Accessibility",
            .@"test" => "Test",
        };
    }
};

/// Pull-mode audio source. `planes` has one entry per channel, each `frames`
/// samples long, and must be filled completely. Runs on the data thread: no
/// allocation, no locks, no I/O.
pub const Process = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, planes: []const []f32, frames: u32) void,
};

/// Optional diagnostics. Called from whichever thread hit the event, so it must
/// be safe to call concurrently.
pub const Log = @import("log.zig").Log;

/// One metric's spread over the cycles since the last reset.
///
/// Kept as min, mean and max rather than a histogram because the number that
/// decides whether a stream is safe is the worst cycle, not the typical one:
/// audio has a deadline, and one late cycle is a dropout.
pub const Summary = struct {
    min_ns: u64,
    mean_ns: u64,
    max_ns: u64,

    /// This metric as a fraction of the cycle period, which is the form
    /// `pw-top` reports and the one that says whether there is headroom.
    pub fn fractionOfPeriod(sm: Summary, period_ns: u64) f64 {
        if (period_ns == 0) return 0;
        return @as(f64, @floatFromInt(sm.max_ns)) / @as(f64, @floatFromInt(period_ns));
    }
};

/// What the graph cycles have cost, measured the way PipeWire's own `pw-top`
/// measures them so the two can be compared.
pub const Stats = struct {
    /// Cycles processed since the last reset.
    cycles: u64,
    /// Between the graph marking this node ready and the data thread waking:
    /// `pw-top` calls this WAIT.
    wake: Summary,
    /// Spent inside the cycle producing audio: `pw-top` calls this BUSY.
    process: Summary,
    /// How long a cycle lasts at the current rate and quantum. Both figures
    /// above have to fit inside this, together with every other node's.
    period_ns: u64,
    /// Wakeups the data thread missed, as counted from the eventfd: the graph
    /// ran a cycle this node was not there for.
    missed_cycles: u64,
    /// Frames the graph asked for that the ring could not supply.
    underrun_frames: u32,
};

/// One metric, accumulated by the data thread and read from anywhere.
///
/// There is exactly one writer, so the updates need no compare-and-swap; the
/// atomics are here so a reader on another thread sees them at all.
const Timing = struct {
    count: std.atomic.Value(u64) = .init(0),
    sum: std.atomic.Value(u64) = .init(0),
    min: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
    max: std.atomic.Value(u64) = .init(0),

    fn record(t: *Timing, ns: u64) void {
        t.count.store(t.count.load(.monotonic) + 1, .monotonic);
        t.sum.store(t.sum.load(.monotonic) +% ns, .monotonic);
        if (ns < t.min.load(.monotonic)) t.min.store(ns, .monotonic);
        if (ns > t.max.load(.monotonic)) t.max.store(ns, .monotonic);
    }

    fn summary(t: *const Timing) Summary {
        const n = t.count.load(.monotonic);
        if (n == 0) return .{ .min_ns = 0, .mean_ns = 0, .max_ns = 0 };
        return .{
            .min_ns = t.min.load(.monotonic),
            .mean_ns = t.sum.load(.monotonic) / n,
            .max_ns = t.max.load(.monotonic),
        };
    }

    fn reset(t: *Timing) void {
        t.count.store(0, .monotonic);
        t.sum.store(0, .monotonic);
        t.min.store(std.math.maxInt(u64), .monotonic);
        t.max.store(0, .monotonic);
    }
};

pub const State = enum(u8) {
    /// Connected to the daemon but not yet linked into the graph.
    idle,
    /// Linked and being driven; audio written now is heard.
    streaming,
    /// The daemon reported a fatal error, or the connection dropped.
    failed,
};

/// How the stream presents itself and where it connects.
///
/// The strings here are borrowed, not copied: they need to stay valid only for
/// the duration of `Stream.open`.
pub const Options = struct {
    /// Shown in `pw-top`, `wpctl status` and volume mixers.
    name: []const u8 = "zig-pipewire",
    /// What is playing, if that differs from the application name.
    media_name: ?[]const u8 = null,
    application_name: ?[]const u8 = null,

    channels: u32 = 2,
    /// One entry per channel. Defaults to the conventional layout for the count,
    /// which exists for 1, 2, 4, 6 and 8 channels; any other count needs a map.
    channel_map: ?[]const Channel = null,

    /// The rate to ask the graph to run at. PipeWire may run at another rate; the
    /// sink resamples. Read `rate()` after connecting for the real one.
    rate: u32 = 48000,
    /// Preferred cycle length in frames, expressed to the daemon as
    /// `node.latency`. Null leaves it to the graph.
    latency_frames: ?u32 = null,

    role: Role = .music,
    /// `node.target` / `target.object`: a sink name or id to link to instead of
    /// the default.
    target: ?[]const u8 = null,
    /// Let the session manager link this stream automatically.
    autoconnect: bool = true,

    /// Capacity of the internal ring, in frames, used by `write`. Ignored when
    /// `process` is set.
    ring_frames: u32 = 16384,
    /// Supply audio by callback instead of through `write`.
    process: ?Process = null,

    /// The process environment, if the caller has it. When given, the socket is
    /// located the way every other PipeWire client locates it:
    /// `PIPEWIRE_RUNTIME_DIR` or `XDG_RUNTIME_DIR` for the directory and
    /// `PIPEWIRE_REMOTE` for the name. Zig 0.16 hands this to `main`.
    environ: ?std.process.Environ = null,
    /// Override the directory holding the socket. Takes precedence over
    /// `environ`; without either, `/run/user/<uid>` is used.
    runtime_dir: ?[]const u8 = null,
    /// Override the socket name, or give an absolute path. Takes precedence over
    /// `environ`; the default is `pipewire-0`.
    remote: ?[]const u8 = null,

    /// Extra node properties, applied after the ones derived above.
    extra_props: []const Prop = &.{},

    log: ?Log = null,
};

// --- internal state --------------------------------------------------------

const Buffer = struct {
    id: u32,
    map: sys.Mapping,
    /// The sample area as f32, `maxsize / 4` long.
    data: []f32,
    chunk: *spa.Chunk,
    /// False while the buffer is out with the peer.
    free: bool,
};

/// One link's worth of state on a port. The daemon also gives every port a
/// "global" mix whose id is `spa.id_invalid`, which is where it attaches the
/// buffers shared by all of that port's links.
const Mix = struct {
    id: u32,
    peer_id: u32 = spa.id_invalid,
    io_map: ?sys.Mapping = null,
    /// Indexed by cycle parity. For a synchronous link both entries are the same
    /// area; for an async link they are the two halves of an AsyncBuffers.
    io: [2]?*spa.IoBuffers = .{ null, null },
    buffers: [cn.max_buffers]Buffer = undefined,
    n_buffers: u32 = 0,

    fn clearBuffers(m: *Mix) void {
        for (m.buffers[0..m.n_buffers]) |b| b.map.unmap();
        m.n_buffers = 0;
    }

    fn clearIo(m: *Mix) void {
        if (m.io_map) |map| map.unmap();
        m.io_map = null;
        m.io = .{ null, null };
    }
};

const Port = struct {
    id: u32,
    channel: Channel,
    name_buf: [32]u8 = undefined,
    name_len: usize = 0,
    mixes: std.ArrayList(Mix) = .empty,
    /// Written when no buffer is available, so the producer always has somewhere
    /// to put its samples.
    scratch: []f32 = &.{},

    fn name(p: *const Port) []const u8 {
        return p.name_buf[0..p.name_len];
    }

    fn findMix(p: *Port, id: u32) ?*Mix {
        for (p.mixes.items) |*m| {
            if (m.id == id) return m;
        }
        return null;
    }

    /// The mix the daemon attached buffers to, if any.
    fn bufferMix(p: *Port) ?*Mix {
        // The global mix is where buffers normally live; fall back to any mix
        // that has them, since which one the daemon uses depends on whether the
        // port or the link did the allocation.
        if (p.findMix(spa.id_invalid)) |m| {
            if (m.n_buffers > 0) return m;
        }
        for (p.mixes.items) |*m| {
            if (m.n_buffers > 0) return m;
        }
        return null;
    }
};

/// Where one graph port's samples come from.
const Route = union(enum) {
    /// Copy the caller's channel at this index.
    copy: u32,
    /// The average of all the caller's channels.
    downmix,
    /// Nothing the caller supplies belongs at this position.
    silence,
};

/// A node we feed. After finishing a cycle we decrement its barrier and, if we
/// were the last one it was waiting on, wake it.
const Peer = struct {
    node_id: u32,
    signal_fd: i32,
    map: sys.Mapping,
    activation: *spa.Activation,
};

pub const Stream = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    log: ?Log,

    core: *Core,
    node_id: u32 = 0,

    /// Channels the caller supplies, as asked for at open time.
    channels: u32,
    channel_map: [max_channels]Channel = undefined,
    ports: []Port = &.{},

    /// How each graph port is fed from the caller's channels.
    routes: [max_channels]Route = @splat(.silence),
    /// True when the graph wants exactly the caller's channels in order, so the
    /// samples can be written straight into the shared buffers.
    identity_routing: bool = true,
    /// Holds the caller's channels while they are being routed, when the layout
    /// the graph asked for is not the one the caller supplies.
    mix_scratch: []f32 = &.{},

    ring: ?ring_mod.Ring = null,
    process: ?Process,

    // --- shared with the daemon ---
    activation_map: ?sys.Mapping = null,
    activation: ?*spa.Activation = null,
    position_map: ?sys.Mapping = null,
    /// The driver's position for the current cycle. Points into the position
    /// area when the daemon sends one, otherwise into our own activation record.
    position: ?*spa.IoPosition = null,
    read_fd: i32 = -1,
    write_fd: i32 = -1,
    /// Transport descriptors replaced by a later transport event. The data
    /// thread may still be polling one, so they are closed only at teardown.
    retired_fds: std.ArrayList(i32) = .empty,
    peers: std.ArrayList(Peer) = .empty,

    // --- threads ---
    /// Held by the data thread for a whole cycle, and by the protocol thread
    /// while it swaps buffers, io areas or peers.
    rt_lock: sys.Mutex = .{},
    running: std.atomic.Value(bool) = .init(false),
    /// Written to wake either thread out of `poll` at shutdown.
    quit_fd: i32 = -1,
    /// Written to pull the data thread out of `poll` when the transport it is
    /// waiting on has been replaced.
    wake_fd: i32 = -1,
    data_thread: ?std.Thread = null,
    proto_thread: ?std.Thread = null,

    state: std.atomic.Value(State) = .init(.idle),
    /// True once the daemon has sent a Start command.
    started: std.atomic.Value(bool) = .init(false),
    /// Set once the eventfd is being watched, so the activation record has been
    /// moved out of INACTIVE.
    prepared: bool = false,

    /// The volume the graph has set on this node, and the volume applied to the
    /// samples on their way out. Guarded by `rt_lock`, which the data thread
    /// holds for a whole cycle and the protocol thread takes to change it.
    volume_props: Volume = .{},
    /// Flipped on every node update, so that the `Props` parameter's flags
    /// differ from the ones sent last time.
    ///
    /// This is the whole of what `SPA_PARAM_INFO_SERIAL` is for. The daemon
    /// caches a readable parameter's value and drops that cache only when the
    /// flags it is told about differ from the flags it holds — so a node that
    /// reports the same flags with a new value is a node whose new value
    /// nobody ever reads.
    props_serial: bool = false,

    graph_rate: std.atomic.Value(u32) = .init(0),
    graph_quantum: std.atomic.Value(u32) = .init(0),
    graph_channels: std.atomic.Value(u32) = .init(0),

    // --- what the cycles cost, written by the data thread ---
    wake_timing: Timing = .{},
    process_timing: Timing = .{},
    missed_cycles: std.atomic.Value(u64) = .init(0),

    // Storage for the property strings we derive at connect time.
    props_arena: std.heap.ArenaAllocator,

    // --- lifecycle ---

    pub fn open(gpa: std.mem.Allocator, opts: Options) Error!*Stream {
        if (opts.channels == 0 or opts.channels > max_channels) return error.TooManyChannels;
        const map = opts.channel_map orelse defaultChannelMap(opts.channels);
        if (map.len != opts.channels) return error.ChannelMapMismatch;

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

        const self = try gpa.create(Stream);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .opts = opts,
            .log = opts.log,
            .core = undefined,
            .channels = opts.channels,
            .process = opts.process,
            .props_arena = .init(gpa),
        };
        @memcpy(self.channel_map[0..map.len], map);
        // One volume per channel asked for, until the graph settles on a layout
        // of its own and `configurePorts` resizes this to match.
        self.volume_props.channels = opts.channels;
        errdefer self.props_arena.deinit();

        if (opts.process == null) {
            self.ring = try ring_mod.Ring.init(gpa, opts.channels, opts.ring_frames);
        }
        errdefer if (self.ring) |*r| r.deinit(gpa);

        const props = try self.buildNodeProps();
        self.core = try Core.connect(gpa, path, props);
        errdefer self.core.deinit();

        self.quit_fd = try sys.eventfd(0, 0);
        errdefer sys.close(self.quit_fd);
        self.wake_fd = try sys.eventfd(0, 0);
        errdefer sys.close(self.wake_fd);
        errdefer self.releaseGraphState();

        try self.createNode(props);

        // One round-trip so the node exists and its transport has arrived before
        // we let the threads touch it.
        const seq = try self.core.sync();
        // Dispatch runs handlers through a type-erased function pointer, so its
        // error set is open; narrow it back to this library's.
        self.core.waitSync(seq) catch |err| switch (err) {
            error.RemoteError => return error.RemoteError,
            error.BrokenPipe, error.ConnectionReset => return error.Disconnected,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.logf(.err, "handshake failed: {s}", .{@errorName(err)});
                return error.ProtocolError;
            },
        };
        if (self.core.errorMessage()) |m| {
            self.logf(.err, "daemon rejected the node: {s} ({d})", .{ m, self.core.errorCode() });
            return error.RemoteError;
        }

        try self.setActive(true);
        try self.core.flush();

        self.running.store(true, .release);
        // If the second thread fails to start, the first is already touching
        // this struct and has to be stopped before anything is freed.
        errdefer self.stopThreads();
        self.data_thread = std.Thread.spawn(.{}, dataThreadMain, .{self}) catch
            return error.ThreadSpawnFailed;
        self.proto_thread = std.Thread.spawn(.{}, protoThreadMain, .{self}) catch
            return error.ThreadSpawnFailed;

        return self;
    }

    pub fn close(self: *Stream) void {
        self.stopThreads();
        self.releaseGraphState();
        // Both threads have been joined, so the connection is ours again: leave
        // the daemon's graph tidily before dropping it.
        self.setActive(false) catch {};
        self.core.destroyObject(self.node_id) catch {};
        self.core.flush() catch {};

        if (self.ring) |*r| r.deinit(self.gpa);
        sys.close(self.quit_fd);
        sys.close(self.wake_fd);
        self.core.deinit();
        self.props_arena.deinit();
        self.gpa.destroy(self);
    }

    fn stopThreads(self: *Stream) void {
        if (self.running.swap(false, .acq_rel)) {
            sys.eventfdWrite(self.quit_fd, 1) catch {};
        }
        if (self.data_thread) |t| t.join();
        if (self.proto_thread) |t| t.join();
        self.data_thread = null;
        self.proto_thread = null;
    }

    /// Drop everything the daemon handed us: mapped buffers, io areas, peers and
    /// the transport. Safe to call before any of it exists.
    fn releaseGraphState(self: *Stream) void {
        self.rt_lock.lock();
        defer self.rt_lock.unlock();

        // Leave the graph cleanly, so nothing is left waiting on this node.
        self.unprepare();

        for (self.ports) |*p| {
            for (p.mixes.items) |*m| {
                m.clearBuffers();
                m.clearIo();
            }
            p.mixes.deinit(self.gpa);
            if (p.scratch.len > 0) self.gpa.free(p.scratch);
        }
        if (self.ports.len > 0) self.gpa.free(self.ports);
        self.ports = &.{};
        if (self.mix_scratch.len > 0) self.gpa.free(self.mix_scratch);
        self.mix_scratch = &.{};

        for (self.peers.items) |*peer| {
            peer.map.unmap();
            sys.close(peer.signal_fd);
        }
        self.peers.deinit(self.gpa);
        self.peers = .empty;

        if (self.position_map) |m| m.unmap();
        self.position_map = null;
        self.position = null;
        if (self.activation_map) |m| m.unmap();
        self.activation_map = null;
        self.activation = null;
        sys.close(self.read_fd);
        sys.close(self.write_fd);
        self.read_fd = -1;
        self.write_fd = -1;
        for (self.retired_fds.items) |fd| sys.close(fd);
        self.retired_fds.deinit(self.gpa);
        self.retired_fds = .empty;
    }

    // --- application-facing API ---

    /// Queue interleaved frames for playback. Returns how many whole frames were
    /// accepted, which is fewer than offered when the ring is full. Never blocks.
    ///
    /// Only valid when the stream was opened without a `process` callback.
    pub fn write(self: *Stream, interleaved: []const f32) usize {
        if (self.ring) |*r| return r.write(interleaved);
        return 0;
    }

    /// Queue every frame, sleeping until there is room.
    ///
    /// Returns `error.NotConnected` if the stream fails while waiting, or if it
    /// was opened with a `process` callback and so has no queue to write into.
    pub fn writeAll(self: *Stream, interleaved: []const f32) Error!void {
        if (self.ring == null) return error.NotConnected;
        const ch = self.channels;
        var rest = interleaved;
        while (rest.len >= ch) {
            const n = self.write(rest);
            if (n == 0) {
                if (self.state.load(.acquire) == .failed) return error.NotConnected;
                // Wait about a third of a cycle before trying again.
                const frames = @max(self.quantum(), 256);
                const hz = @max(self.rate(), 8000);
                sys.sleep(@as(u64, frames) * std.time.ns_per_s / hz / 3);
                continue;
            }
            rest = rest[n * ch ..];
        }
    }

    /// Frames that `write` would accept right now.
    pub fn writable(self: *Stream) u32 {
        if (self.ring) |*r| return r.writable();
        return 0;
    }

    /// Frames queued but not yet played.
    pub fn queued(self: *Stream) u32 {
        if (self.ring) |*r| return r.filled();
        return 0;
    }

    /// Frames the graph asked for that the ring could not supply, counted from
    /// the first `write`. A count that climbs during playback means the producer
    /// is not keeping up.
    ///
    /// Once you stop writing, the graph keeps asking: expect this to pick up
    /// roughly a quantum's worth of silence between the last frame written and
    /// `close`.
    pub fn underruns(self: *Stream) u32 {
        if (self.ring) |*r| return r.underruns.load(.monotonic);
        return 0;
    }

    /// The graph's sample rate, or 0 before the first cycle.
    pub fn rate(self: *Stream) u32 {
        return self.graph_rate.load(.acquire);
    }

    /// Frames per cycle, or 0 before the first cycle.
    pub fn quantum(self: *Stream) u32 {
        return self.graph_quantum.load(.acquire);
    }

    /// How many channels the graph settled on, or 0 before it has said.
    ///
    /// This is the sink's layout, not necessarily the one asked for at open
    /// time; `write` still takes the requested channel count and is mapped onto
    /// this one. See `Options.channels`.
    pub fn graphChannels(self: *Stream) u32 {
        return self.graph_channels.load(.acquire);
    }

    /// The volume the graph has set on this stream, as any mixer sees it.
    ///
    /// Volumes are linear amplitudes, one per graph channel, and they are
    /// applied to the samples on their way out — so audio handed to `write` or
    /// filled in by `process` is at full scale whatever this says. Setting it
    /// is the graph's business rather than the stream's: a `Session`, `wpctl`
    /// or a volume slider writes it, and an application that wants its own
    /// gain applies that to its own samples.
    ///
    /// Takes the lock the data thread holds for a whole cycle, so it is for the
    /// application's own thread and not for the `process` callback — which is
    /// inside that cycle and would wait on itself.
    pub fn volume(self: *Stream) Volume {
        self.rt_lock.lock();
        defer self.rt_lock.unlock();
        return self.volume_props;
    }

    pub fn getState(self: *Stream) State {
        return self.state.load(.acquire);
    }

    /// What the cycles since the last `resetStats` have cost.
    ///
    /// `wake` and `process` are what `pw-top` shows as WAIT and BUSY for this
    /// node, taken from the same clock and the same two timestamps, so the two
    /// should agree.
    pub fn stats(self: *Stream) Stats {
        const hz = self.rate();
        const frames = self.quantum();
        return .{
            .cycles = self.process_timing.count.load(.monotonic),
            .wake = self.wake_timing.summary(),
            .process = self.process_timing.summary(),
            .period_ns = if (hz == 0)
                0
            else
                @as(u64, frames) * std.time.ns_per_s / hz,
            .missed_cycles = self.missed_cycles.load(.monotonic),
            .underrun_frames = self.underruns(),
        };
    }

    /// Start the measurement window again, so a benchmark can time a stretch
    /// that excludes the cycles spent linking up.
    pub fn resetStats(self: *Stream) void {
        self.wake_timing.reset();
        self.process_timing.reset();
        self.missed_cycles.store(0, .monotonic);
    }

    /// Block until the stream is linked and running, or `timeout_ms` elapses.
    /// Returns false on timeout.
    pub fn waitStreaming(self: *Stream, timeout_ms: u64) bool {
        const deadline = sys.nowNsec() + timeout_ms * std.time.ns_per_ms;
        while (true) {
            switch (self.getState()) {
                .streaming => return true,
                .failed => return false,
                .idle => {},
            }
            if (sys.nowNsec() >= deadline) return false;
            sys.sleep(2 * std.time.ns_per_ms);
        }
    }

    /// Wait until every queued frame has been consumed, or `timeout_ms` elapses,
    /// then let the last of them play out.
    ///
    /// Call this before `close` so the tail of the audio is heard rather than
    /// cut off.
    pub fn drain(self: *Stream, timeout_ms: u64) void {
        const deadline = sys.nowNsec() + timeout_ms * std.time.ns_per_ms;
        while (self.queued() > 0 and self.getState() == .streaming) {
            if (sys.nowNsec() >= deadline) return;
            sys.sleep(2 * std.time.ns_per_ms);
        }
        // The last frames handed over still have a cycle to play out.
        sys.sleep(20 * std.time.ns_per_ms);
    }

    // --- connection setup ---

    fn buildNodeProps(self: *Stream) Error![]const Prop {
        const a = self.props_arena.allocator();
        var list: std.ArrayList(Prop) = .empty;

        try list.append(a, .{ .key = "media.type", .value = "Audio" });
        try list.append(a, .{ .key = "media.category", .value = "Playback" });
        try list.append(a, .{ .key = "media.class", .value = "Stream/Output/Audio" });
        try list.append(a, .{ .key = "media.role", .value = self.opts.role.name() });
        try list.append(a, .{ .key = "node.name", .value = self.opts.name });
        try list.append(a, .{ .key = "node.description", .value = self.opts.name });
        try list.append(a, .{
            .key = "application.name",
            .value = self.opts.application_name orelse self.opts.name,
        });
        try list.append(a, .{
            .key = "media.name",
            .value = self.opts.media_name orelse self.opts.name,
        });
        try list.append(a, .{
            .key = "node.autoconnect",
            .value = if (self.opts.autoconnect) "true" else "false",
        });
        // Without this the node is never grouped with a driver, so nothing ever
        // wakes it.
        try list.append(a, .{ .key = "node.want-driver", .value = "true" });
        try list.append(a, .{
            .key = "audio.channels",
            .value = try std.fmt.allocPrint(a, "{d}", .{self.channels}),
        });
        try list.append(a, .{
            .key = "node.rate",
            .value = try std.fmt.allocPrint(a, "1/{d}", .{self.opts.rate}),
        });
        if (self.opts.latency_frames) |frames| {
            try list.append(a, .{
                .key = "node.latency",
                .value = try std.fmt.allocPrint(a, "{d}/{d}", .{ frames, self.opts.rate }),
            });
        }
        if (self.opts.target) |t| {
            try list.append(a, .{ .key = "target.object", .value = t });
        }
        for (self.opts.extra_props) |p| try list.append(a, p);

        return list.items;
    }

    fn createNode(self: *Stream, props: []const Prop) Error!void {
        self.node_id = try self.core.createObject(
            "client-node",
            core_mod.interface_client_node,
            cn.version,
            props,
        );
        try self.core.register(self.node_id, .{ .ctx = self, .func = dispatchNodeEvent });
        try self.sendNodeUpdate(props);
    }

    /// Send the node's parameters and info, replacing what the daemon holds.
    ///
    /// The parameter list is sent whole every time, because that is how the
    /// daemon takes it: a client node's parameters are the ones the client last
    /// sent, and what it sends replaces the lot. `props` is the property
    /// dictionary, which is given once at creation and left alone afterwards —
    /// an empty one means "not this time" rather than "no properties".
    fn sendNodeUpdate(self: *Stream, props: []const Prop) Error!void {
        var params = pod.Builder.init(self.gpa);
        defer params.deinit();
        var bounds: [3][2]usize = undefined;
        bounds[0] = try self.buildNodeFormat(&params);
        bounds[1] = try buildEnumPortConfig(&params);
        bounds[2] = try self.buildProps(&params);
        var node_params: [3][]const u8 = undefined;
        for (bounds, &node_params) |bound, *slice| {
            slice.* = params.bytes()[bound[0]..bound[1]];
        }

        var change_mask = spa.node_change.flags | spa.node_change.params;
        if (props.len > 0) change_mask |= spa.node_change.props;

        self.props_serial = !self.props_serial;
        const props_flags = spa.param_info.readwrite |
            @as(u32, if (self.props_serial) spa.param_info.serial else 0);

        const b = self.core.beginMessage();
        try cn.writeUpdate(b, cn.update_mask.params | cn.update_mask.info, &node_params, .{
            .max_input_ports = 0,
            .max_output_ports = max_channels,
            .change_mask = change_mask,
            .flags = spa.node_flag.rt,
            .props = props,
            .params = &.{
                .{ .id = .enum_format, .flags = spa.param_info.read },
                .{ .id = .enum_port_config, .flags = spa.param_info.read },
                .{ .id = .port_config, .flags = spa.param_info.write },
                .{ .id = .props, .flags = props_flags },
            },
        });
        _ = try self.core.sendMessage(self.node_id, cn.method.update, 0);
    }

    /// This node's volume, in the `Props` object every mixer reads.
    ///
    /// Unlike the port format, this one is genuinely readable: the value goes
    /// up with the parameter list, so a mixer that enumerates `Props` gets what
    /// is written here. Without it a stream has no volume at all — `wpctl`
    /// shows one of these nodes at 0.00 and setting it does nothing, because
    /// there is no parameter for the setting to land in.
    fn buildProps(self: *Stream, b: *pod.Builder) Error![2]usize {
        const start = b.bytes().len;
        const n = @min(self.volume_props.channels, max_channels);

        var positions: [max_channels]u32 = undefined;
        for (0..n) |i| positions[i] = self.channelAt(i).position();

        try reg.writeVolumeProps(b, .{
            .volume = self.volume_props.volume,
            .mute = self.volume_props.mute,
            .channel_volumes = self.volume_props.channel_volumes[0..n],
            .channel_map = positions[0..n],
        });
        return .{ start, b.bytes().len };
    }

    /// Which speaker the `index`th volume belongs to: the graph's layout once
    /// there is one, and the layout asked for until then.
    fn channelAt(self: *const Stream, index: usize) Channel {
        if (index < self.ports.len) return self.ports[index].channel;
        if (index < self.channels) return self.channel_map[index];
        return .mono;
    }

    /// The node-level `EnumFormat` the session manager reads to decide how to
    /// route this stream.
    ///
    /// It has to be there, and it has to carry a `position` array. WirePlumber
    /// refuses to make a linkable out of an audio node with no usable format,
    /// and for a *positioned* stream that it is autoconnecting it then skips
    /// configuring the node's ports altogether — which is what lets this plain
    /// client-node, whose DSP ports are already exactly what the graph wants,
    /// be linked as it stands.
    fn buildNodeFormat(self: *Stream, b: *pod.Builder) Error![2]usize {
        const start = b.bytes().len;
        const f = try b.pushObject(
            spa.object_type.format,
            @intFromEnum(spa.Param.enum_format),
        );
        try b.objectPropId(spa.format.media_type, spa.media_type.audio);
        try b.objectPropId(spa.format.media_subtype, spa.media_subtype.raw);
        try b.objectPropId(spa.format.audio_format, spa.audio_format.f32p);
        try b.objectPropInt(spa.format.audio_rate, @intCast(self.opts.rate));
        try b.objectPropInt(spa.format.audio_channels, @intCast(self.channels));
        try b.prop(spa.format.audio_position, 0);
        const arr = try b.pushArray(4, .id);
        for (self.channel_map[0..self.channels]) |c| {
            try b.addRaw(std.mem.asBytes(&c.position()));
        }
        try b.pop(arr);
        try b.pop(f);
        return .{ start, b.bytes().len };
    }

    /// The single port configuration this node supports: DSP output ports.
    fn buildEnumPortConfig(b: *pod.Builder) Error![2]usize {
        const start = b.bytes().len;
        const f = try b.pushObject(
            spa.object_type.param_port_config,
            @intFromEnum(spa.Param.enum_port_config),
        );
        try b.objectPropId(spa.param_port_config.direction, @intFromEnum(spa.Direction.output));
        try b.objectPropId(spa.param_port_config.mode, @intFromEnum(spa.PortConfigMode.dsp));
        try b.pop(f);
        return .{ start, b.bytes().len };
    }

    /// Build the node's ports for a negotiated channel layout, replacing
    /// whatever was there before.
    ///
    /// Removing and re-adding rather than updating in place is deliberate: the
    /// session manager waits for the node's port list to change as its signal
    /// that a `PortConfig` was applied, so an in-place update would leave it
    /// waiting forever.
    fn configurePorts(self: *Stream, map: []const Channel) Error!void {
        self.rt_lock.lock();
        defer self.rt_lock.unlock();

        // The routing must be replaced in the same critical section: a cycle
        // that saw the new ports with the old routing would hand the producer
        // the wrong number of planes.
        self.buildChannelRouting(map);

        for (self.ports) |*p| {
            try self.sendPortRemove(p.id);
            for (p.mixes.items) |*m| {
                m.clearBuffers();
                m.clearIo();
            }
            p.mixes.deinit(self.gpa);
            if (p.scratch.len > 0) self.gpa.free(p.scratch);
        }
        if (self.ports.len > 0) self.gpa.free(self.ports);
        self.ports = &.{};

        self.ports = try self.gpa.alloc(Port, map.len);
        for (self.ports, map, 0..) |*p, channel, i| {
            p.* = .{ .id = @intCast(i), .channel = channel };
            const written = std.fmt.bufPrint(&p.name_buf, "output_{s}", .{channel.name()}) catch
                return error.OutOfMemory;
            p.name_len = written.len;
            // Somewhere to write when this port has no shared buffer yet.
            p.scratch = try self.gpa.alloc(f32, default_scratch_frames);
            try self.sendPortUpdate(p, null);
        }
        try self.growMixScratch(default_scratch_frames);
        self.graph_channels.store(@intCast(map.len), .release);

        // The volume is one per graph channel, so a layout with more channels
        // than the last one leaves the new ones unattenuated rather than at
        // whatever was in the array.
        const was = self.volume_props.channels;
        for (was..map.len) |i| self.volume_props.channel_volumes[i] = 1.0;
        self.volume_props.channels = @intCast(map.len);
        try self.sendNodeUpdate(&.{});

        try self.core.flush();
    }

    /// An empty change mask is how the protocol spells "remove this port".
    fn sendPortRemove(self: *Stream, port_id: u32) Error!void {
        const b = self.core.beginMessage();
        try cn.writePortUpdate(b, .output, port_id, 0, &.{}, null);
        _ = try self.core.sendMessage(self.node_id, cn.method.port_update, 0);
    }

    /// Send a port's parameters and info, replacing what the daemon holds.
    ///
    /// `format` is the negotiated `Format` object, once there is one. It has to
    /// go back: a client node's parameters are whatever the client last sent,
    /// so a port that never returns its format is a port the daemon has no
    /// format for — which is not noticed while the session manager is making
    /// the links, because a link being negotiated is what sets the format in
    /// the first place, and is then refused with `error get output format` for
    /// anything linking that port afterwards.
    fn sendPortUpdate(self: *Stream, p: *Port, format: ?[]const u8) Error!void {
        // The parameter objects have to outlive the message they go into, so
        // build them in a scratch buffer separate from the message builder.
        // Record where each one lands rather than slicing as we go: the builder
        // reallocates, so a slice taken before the next append would dangle.
        var params = pod.Builder.init(self.gpa);
        defer params.deinit();

        var bounds: [4][2]usize = undefined;
        bounds[0] = try buildDspFormat(&params, .enum_format);
        bounds[1] = try buildBuffersParam(&params);
        bounds[2] = try buildIoParam(&params, .buffers);
        bounds[3] = try buildIoParam(&params, .async_buffers);

        var param_slices: [5][]const u8 = undefined;
        for (bounds, param_slices[0..4]) |bound, *slice| {
            slice.* = params.bytes()[bound[0]..bound[1]];
        }
        // The daemon's own bytes, echoed: what it set is exactly what this port
        // has, and re-encoding it could only differ from it.
        if (format) |encoded| param_slices[4] = encoded;
        const n_params: usize = if (format == null) 4 else 5;

        const b = self.core.beginMessage();
        try cn.writePortUpdate(
            b,
            .output,
            p.id,
            cn.update_mask.params | cn.update_mask.info,
            param_slices[0..n_params],
            .{
                .change_mask = spa.port_change.flags | spa.port_change.props |
                    spa.port_change.params,
                .flags = spa.port_flag.no_ref,
                .props = &.{
                    .{ .key = "format.dsp", .value = "32 bit float mono audio" },
                    .{ .key = "port.name", .value = p.name() },
                    .{ .key = "audio.channel", .value = p.channel.name() },
                    .{ .key = "port.group", .value = "stream.0" },
                },
                .params = &.{
                    .{ .id = .enum_format, .flags = spa.param_info.read },
                    // Write only, as every DSP client node reports it: the
                    // daemon sets the format, and what comes back is the value
                    // in `params` rather than a claim to enumerate one.
                    .{ .id = .format, .flags = spa.param_info.write },
                    .{ .id = .buffers, .flags = spa.param_info.read },
                    .{ .id = .io, .flags = spa.param_info.read },
                },
            },
        );
        _ = try self.core.sendMessage(self.node_id, cn.method.port_update, 0);
    }

    /// The one format a DSP audio port speaks: mono planar `f32`.
    fn buildDspFormat(b: *pod.Builder, id: spa.Param) Error![2]usize {
        const start = b.bytes().len;
        const f = try b.pushObject(spa.object_type.format, @intFromEnum(id));
        try b.objectPropId(spa.format.media_type, spa.media_type.audio);
        try b.objectPropId(spa.format.media_subtype, spa.media_subtype.dsp);
        try b.objectPropId(spa.format.audio_format, spa.audio_format.dsp_f32);
        try b.pop(f);
        return .{ start, b.bytes().len };
    }

    fn buildBuffersParam(b: *pod.Builder) Error![2]usize {
        const start = b.bytes().len;
        const sample = @sizeOf(f32);
        const f = try b.pushObject(spa.object_type.param_buffers, @intFromEnum(spa.Param.buffers));
        try b.objectPropRangeInt(spa.param_buffers.buffers, 2, 1, cn.max_buffers);
        try b.objectPropInt(spa.param_buffers.blocks, 1);
        // Any whole number of samples; the daemon picks a size for the quantum.
        try b.objectPropStepInt(
            spa.param_buffers.size,
            8192 * sample,
            sample,
            std.math.maxInt(i32),
            sample,
        );
        try b.objectPropInt(spa.param_buffers.stride, sample);
        try b.pop(f);
        return .{ start, b.bytes().len };
    }

    fn buildIoParam(b: *pod.Builder, io: spa.IoType) Error![2]usize {
        const start = b.bytes().len;
        const size: i32 = switch (io) {
            .async_buffers => @sizeOf(spa.IoAsyncBuffers),
            else => @sizeOf(spa.IoBuffers),
        };
        const f = try b.pushObject(spa.object_type.param_io, @intFromEnum(spa.Param.io));
        try b.objectPropId(spa.param_io.id, @intFromEnum(io));
        try b.objectPropInt(spa.param_io.size, size);
        try b.pop(f);
        return .{ start, b.bytes().len };
    }

    fn setActive(self: *Stream, active: bool) Error!void {
        const b = self.core.beginMessage();
        try cn.writeSetActive(b, active);
        _ = try self.core.sendMessage(self.node_id, cn.method.set_active, 0);
    }

    // --- protocol thread ---

    /// The connection belongs to this thread for as long as it runs: nothing
    /// else touches `core` between the spawn in `open` and the join in `close`.
    fn protoThreadMain(self: *Stream) void {
        var fds = [_]sys.PollFd{
            .{ .fd = self.core.c.fd, .events = sys.POLL.IN, .revents = 0 },
            .{ .fd = self.quit_fd, .events = sys.POLL.IN, .revents = 0 },
        };

        while (self.running.load(.acquire)) {
            _ = sys.poll(&fds, -1) catch |err| switch (err) {
                error.Interrupted => continue,
                else => {
                    self.fail("poll on the daemon socket failed");
                    return;
                },
            };
            if (fds[1].revents != 0) return;
            if (fds[0].revents & (sys.POLL.ERR | sys.POLL.HUP) != 0) {
                self.fail("the daemon closed the connection");
                return;
            }
            if (fds[0].revents & sys.POLL.IN == 0) continue;

            self.core.dispatchBlocking() catch |err| {
                self.logf(.err, "protocol error: {s}", .{@errorName(err)});
                self.fail("lost the connection to the daemon");
                return;
            };
        }
    }

    fn dispatchNodeEvent(ctx: *anyopaque, core: *Core, msg: conn.Message) anyerror!void {
        const self: *Stream = @ptrCast(@alignCast(ctx));
        _ = core;
        switch (msg.opcode) {
            cn.event.transport => try self.onTransport(msg),
            cn.event.set_param => try self.onSetParam(msg),
            cn.event.set_io => try self.onSetIo(msg),
            cn.event.command => try self.onCommand(msg),
            cn.event.port_set_param => try self.onPortSetParam(msg),
            cn.event.port_use_buffers => try self.onUseBuffers(msg),
            cn.event.port_set_io => try self.onPortSetIo(msg),
            cn.event.set_activation => try self.onSetActivation(msg),
            cn.event.port_set_mix_info => try self.onPortSetMixInfo(msg),
            cn.event.add_port, cn.event.remove_port => {
                // We declare a fixed set of ports up front and advertise no
                // dynamic-port flags, so the daemon should never ask for these.
                self.logf(.warn, "ignoring unsupported dynamic port change", .{});
            },
            else => {},
        }
    }

    fn onTransport(self: *Stream, msg: conn.Message) !void {
        const t = try cn.parseTransport(msg);

        self.rt_lock.lock();
        defer self.rt_lock.unlock();

        self.unprepare();
        if (self.activation_map) |m| m.unmap();
        self.activation_map = null;
        self.activation = null;
        // The data thread may be blocked in poll() on the old descriptor, so it
        // is retired rather than closed; the wake below makes it look again.
        if (self.read_fd >= 0) try self.retired_fds.append(self.gpa, self.read_fd);
        sys.close(self.write_fd);
        self.read_fd = -1;
        self.write_fd = -1;

        const map = self.core.mapMem(t.mem_id, t.offset, t.size) catch |err| {
            sys.close(t.read_fd);
            sys.close(t.write_fd);
            return err;
        };
        self.activation_map = map;
        const activation: *spa.Activation = @ptrCast(@alignCast(map.slice.ptr));
        self.activation = activation;
        // Tell the daemon which activation protocol we implement, so it knows we
        // handle the INACTIVE -> FINISHED transition ourselves.
        @atomicStore(u32, &activation.client_version, spa.activation_version, .seq_cst);

        self.read_fd = t.read_fd;
        self.write_fd = t.write_fd;
        // Until a driver hands us a position area, use the one in our own record.
        if (self.position == null) self.position = &activation.position;

        sys.eventfdWrite(self.wake_fd, 1) catch {};
        self.logf(.debug, "transport ready: read fd {d}, activation {d} bytes", .{ t.read_fd, t.size });
    }

    fn onSetParam(self: *Stream, msg: conn.Message) !void {
        const sp = try cn.parseSetParam(msg);
        switch (sp.id) {
            .port_config => try self.onPortConfig(sp),
            .props => try self.onProps(sp),
            else => {},
        }
    }

    /// A mixer, or the session manager restoring what a mixer did last time,
    /// setting this node's volume.
    ///
    /// What comes in says only what it changes, so it is merged rather than
    /// taken whole, and what comes out is the new state sent straight back —
    /// the daemon answers everyone else's enumeration out of the parameters
    /// this client last sent, so a change nobody echoes is a change nobody
    /// else can see.
    fn onProps(self: *Stream, sp: cn.SetParam) !void {
        const param = sp.param orelse return;
        const incoming = reg.parseVolume(param) catch |err| {
            self.logf(.warn, "unreadable Props: {s}", .{@errorName(err)});
            return;
        };
        if (!incoming.any()) return;

        {
            self.rt_lock.lock();
            defer self.rt_lock.unlock();
            self.volume_props.merge(incoming);
        }

        try self.sendNodeUpdate(&.{});
        try self.core.flush();
        self.logf(.debug, "volume {d:.3}{s}", .{
            self.volume_props.peak(),
            if (self.volume_props.mute) " (muted)" else "",
        });
    }

    /// The session manager configures this node's ports by writing a
    /// `PortConfig` param, exactly as it would to a real audio adapter. The
    /// channel layout it asks for is the one the sink is running, so that is the
    /// layout the ports are built for, whatever was requested at open time.
    fn onPortConfig(self: *Stream, sp: cn.SetParam) !void {
        const param = sp.param orelse return;

        var mode: spa.PortConfigMode = .none;
        var direction: spa.Direction = .output;
        var layout: ?cn.AudioLayout = null;

        var obj = try param.objectBody();
        while (try obj.next()) |prop| {
            switch (prop.key) {
                spa.param_port_config.direction => direction = @enumFromInt(try prop.value.asIntOrId()),
                spa.param_port_config.mode => mode = @enumFromInt(try prop.value.asIntOrId()),
                spa.param_port_config.format => layout = try cn.parseAudioLayout(prop.value),
                else => {},
            }
        }

        if (direction != .output) return;
        if (mode != .dsp) {
            self.logf(.warn, "port config mode {t} is not supported", .{mode});
            return;
        }

        var map_buf: [max_channels]Channel = undefined;
        // No usable layout came with the config; keep what was asked for.
        const n_channels = channelMapFor(layout, &map_buf) orelse blk: {
            @memcpy(map_buf[0..self.channels], self.channel_map[0..self.channels]);
            break :blk self.channels;
        };

        self.logf(.info, "graph configured {d} port(s)", .{n_channels});
        try self.configurePorts(map_buf[0..n_channels]);
    }

    fn onSetIo(self: *Stream, msg: conn.Message) !void {
        const io = try cn.parseSetIo(msg);
        if (io.id != .position) return;

        self.rt_lock.lock();
        defer self.rt_lock.unlock();

        if (self.position_map) |m| m.unmap();
        self.position_map = null;

        if (io.mem_id == spa.id_invalid) {
            self.position = if (self.activation) |a| &a.position else null;
            return;
        }

        const map = try self.core.mapMem(io.mem_id, io.offset, io.size);
        self.position_map = map;
        const position: *spa.IoPosition = @ptrCast(@alignCast(map.slice.ptr));
        self.position = position;

        // The driver only schedules nodes whose activation agrees with it about
        // which driver is in charge. Without this the node is silently skipped.
        if (self.activation) |a| {
            @atomicStore(u32, &a.active_driver_id, position.clock.id, .seq_cst);
        }
        self.publishTiming(position);
        self.logf(.debug, "driver clock {d} at {d} Hz", .{ position.clock.id, position.clock.rate.denom });
    }

    fn onCommand(self: *Stream, msg: conn.Message) !void {
        const command = try cn.parseCommand(msg);
        switch (command) {
            .start => {
                if (self.started.load(.acquire)) return;
                self.rt_lock.lock();
                self.prepare();
                self.rt_lock.unlock();
                self.started.store(true, .release);
                self.state.store(.streaming, .release);
                self.logf(.info, "streaming", .{});
            },
            .pause, .@"suspend" => {
                if (!self.started.load(.acquire)) return;
                self.rt_lock.lock();
                self.unprepare();
                self.rt_lock.unlock();
                self.started.store(false, .release);
                if (self.state.load(.acquire) == .streaming) self.state.store(.idle, .release);
                self.logf(.info, "paused", .{});
            },
            else => {},
        }
    }

    fn onPortSetParam(self: *Stream, msg: conn.Message) !void {
        const sp = try cn.parsePortSetParam(msg);
        if (sp.direction != .output) return;
        if (sp.id != .format) return;

        // Clearing the format invalidates the buffers that went with it.
        if (sp.param == null) {
            self.rt_lock.lock();
            defer self.rt_lock.unlock();
            if (sp.port_id < self.ports.len) {
                for (self.ports[sp.port_id].mixes.items) |*m| m.clearBuffers();
            }
        }
        self.logf(.debug, "port {d} format {s}", .{
            sp.port_id,
            if (sp.param == null) "cleared" else "set",
        });

        // And say so, which is what puts the format on the daemon's copy of
        // this port. The parameter borrows the message being handled, which
        // outlives the call that sends it on.
        if (sp.port_id >= self.ports.len) return;
        const format: ?[]const u8 = if (sp.param) |param| param.encoded else null;
        try self.sendPortUpdate(&self.ports[sp.port_id], format);
        try self.core.flush();
    }

    fn onUseBuffers(self: *Stream, msg: conn.Message) !void {
        var ub: cn.UseBuffers = undefined;
        try cn.parseUseBuffers(msg, &ub);
        if (ub.direction != .output) return;

        self.rt_lock.lock();
        defer self.rt_lock.unlock();

        if (ub.port_id >= self.ports.len) return;
        const port = &self.ports[ub.port_id];
        const mix = try self.mixFor(port, ub.mix_id);
        mix.clearBuffers();

        for (ub.slice(), 0..) |desc, i| {
            const map = self.core.mapMem(desc.mem_id, desc.offset, desc.size) catch |err| {
                self.logf(.warn, "could not map buffer {d}: {s}", .{ i, @errorName(err) });
                continue;
            };

            if (self.adoptBuffer(mix, desc, map, i)) {
                mix.n_buffers += 1;
            } else {
                map.unmap();
            }
        }

        // Keep the scratch planes at least as large as the buffers, so a cycle
        // where no buffer can be dequeued still has room for its samples.
        var largest: usize = 0;
        for (mix.buffers[0..mix.n_buffers]) |b| largest = @max(largest, b.data.len);
        if (largest > port.scratch.len) {
            if (port.scratch.len > 0) self.gpa.free(port.scratch);
            port.scratch = try self.gpa.alloc(f32, largest);
        }
        try self.growMixScratch(largest);

        self.logf(.debug, "port {d} mix {d}: {d} buffers", .{ ub.port_id, ub.mix_id, mix.n_buffers });
    }

    /// Take on one mapped buffer, or say why it cannot be used.
    ///
    /// All the arithmetic on the daemon's numbers is in `cn.bufferLayout`; what
    /// is left here is turning the offsets it vouched for into pointers.
    fn adoptBuffer(
        self: *Stream,
        mix: *Mix,
        desc: cn.BufferDesc,
        map: sys.Mapping,
        index: usize,
    ) bool {
        const layout = cn.bufferLayout(desc, map.slice.len, @intFromPtr(map.slice.ptr)) catch |err| {
            self.logf(.warn, "unusable buffer {d}: {s}", .{ index, @errorName(err) });
            return false;
        };

        mix.buffers[mix.n_buffers] = .{
            .id = @intCast(index),
            .map = map,
            .data = std.mem.bytesAsSlice(f32, @as(
                []align(@alignOf(f32)) u8,
                @alignCast(map.slice[layout.data_offset..][0..layout.data_len]),
            )),
            .chunk = @ptrCast(@alignCast(map.slice[layout.chunk_offset..].ptr)),
            .free = true,
        };
        return true;
    }

    fn onPortSetIo(self: *Stream, msg: conn.Message) !void {
        const si = try cn.parsePortSetIo(msg);
        if (si.direction != .output) return;
        if (si.id != .buffers and si.id != .async_buffers) return;

        self.rt_lock.lock();
        defer self.rt_lock.unlock();

        if (si.port_id >= self.ports.len) return;
        const port = &self.ports[si.port_id];
        const mix = try self.mixFor(port, si.mix_id);
        mix.clearIo();

        if (si.mem_id == spa.id_invalid) return;

        const map = try self.core.mapMem(si.mem_id, si.offset, si.size);
        mix.io_map = map;

        if (si.size >= @sizeOf(spa.IoAsyncBuffers)) {
            // An async link alternates halves by cycle, and the two peers index
            // them in opposite order so that a writer never touches the half a
            // reader is on.
            const ab: *spa.IoAsyncBuffers = @ptrCast(@alignCast(map.slice.ptr));
            mix.io[0] = &ab.buffers[1];
            mix.io[1] = &ab.buffers[0];
        } else if (si.size >= @sizeOf(spa.IoBuffers)) {
            const io: *spa.IoBuffers = @ptrCast(@alignCast(map.slice.ptr));
            mix.io[0] = io;
            mix.io[1] = io;
        }
    }

    fn onSetActivation(self: *Stream, msg: conn.Message) !void {
        const sa = try cn.parseSetActivation(msg);

        self.rt_lock.lock();
        defer self.rt_lock.unlock();

        if (sa.mem_id == spa.id_invalid) {
            sys.close(sa.signal_fd);
            for (self.peers.items, 0..) |*peer, i| {
                if (peer.node_id == sa.node_id) {
                    peer.map.unmap();
                    sys.close(peer.signal_fd);
                    _ = self.peers.swapRemove(i);
                    self.logf(.debug, "peer node {d} removed", .{sa.node_id});
                    return;
                }
            }
            return;
        }

        const map = self.core.mapMem(sa.mem_id, sa.offset, sa.size) catch |err| {
            sys.close(sa.signal_fd);
            return err;
        };
        try self.peers.append(self.gpa, .{
            .node_id = sa.node_id,
            .signal_fd = sa.signal_fd,
            .map = map,
            .activation = @ptrCast(@alignCast(map.slice.ptr)),
        });
        self.logf(.debug, "peer node {d} added", .{sa.node_id});
    }

    fn onPortSetMixInfo(self: *Stream, msg: conn.Message) !void {
        const mi = try cn.parsePortSetMixInfo(msg);
        if (mi.direction != .output) return;

        self.rt_lock.lock();
        defer self.rt_lock.unlock();

        if (mi.port_id >= self.ports.len) return;
        const port = &self.ports[mi.port_id];
        if (mi.peer_id == spa.id_invalid) {
            for (port.mixes.items, 0..) |*m, i| {
                if (m.id == mi.mix_id) {
                    m.clearBuffers();
                    m.clearIo();
                    _ = port.mixes.swapRemove(i);
                    return;
                }
            }
            return;
        }
        const mix = try self.mixFor(port, mi.mix_id);
        mix.peer_id = mi.peer_id;
    }

    /// Work out how to feed the graph's channel layout from the caller's.
    ///
    /// The rules are deliberately simple and predictable:
    ///
    /// * a graph channel whose position the caller also supplies is copied;
    /// * otherwise, if the caller supplies a single channel, that channel feeds
    ///   every graph channel;
    /// * otherwise, if the graph wants a single channel, it gets the average of
    ///   the caller's;
    /// * otherwise the graph channel is silent, and the caller's channel at that
    ///   position is dropped.
    ///
    /// So mono plays through a stereo sink, stereo folds down to a mono sink,
    /// and a 5.1 source into a stereo sink keeps its front pair and loses the
    /// rest. Anything more careful than that is the caller's to do before
    /// handing samples over.
    /// Caller must hold `rt_lock`.
    fn buildChannelRouting(self: *Stream, graph_map: []const Channel) void {
        const in = self.channel_map[0..self.channels];
        var identity = graph_map.len == in.len;
        var dropped = false;

        for (graph_map, 0..) |want, i| {
            var mapping: Route = .silence;
            for (in, 0..) |have, j| {
                if (have == want) {
                    mapping = .{ .copy = @intCast(j) };
                    break;
                }
            }
            if (mapping == .silence) {
                if (in.len == 1) {
                    mapping = .{ .copy = 0 };
                } else if (graph_map.len == 1) {
                    mapping = .downmix;
                } else {
                    dropped = true;
                }
            }
            self.routes[i] = mapping;
            if (identity and !(mapping == .copy and mapping.copy == i)) identity = false;
        }

        self.identity_routing = identity;
        if (!identity) {
            self.logf(.info, "routing {d} channel(s) onto the graph's {d}", .{
                in.len,
                graph_map.len,
            });
            if (dropped) {
                self.logf(.warn, "some channels have no place in the graph layout", .{});
            }
        }
    }

    /// Make sure the routing scratch can hold one cycle of the caller's
    /// channels. Growing it here keeps the data thread free of allocation.
    fn growMixScratch(self: *Stream, frames: usize) !void {
        const want = frames * self.channels;
        if (self.mix_scratch.len >= want) return;
        if (self.mix_scratch.len > 0) self.gpa.free(self.mix_scratch);
        self.mix_scratch = try self.gpa.alloc(f32, want);
    }

    fn mixFor(self: *Stream, port: *Port, id: u32) !*Mix {
        if (port.findMix(id)) |m| return m;
        try port.mixes.append(self.gpa, .{ .id = id });
        return &port.mixes.items[port.mixes.items.len - 1];
    }

    // --- data thread ---

    fn prepare(self: *Stream) void {
        const a = self.activation orelse return;
        if (self.prepared) return;
        // INACTIVE -> FINISHED tells the driver this node is watching its
        // eventfd and may be scheduled from the next cycle on.
        @atomicStore(u32, &a.status, spa.activation_status.finished, .seq_cst);
        self.prepared = true;
    }

    fn unprepare(self: *Stream) void {
        const a = self.activation orelse return;
        if (!self.prepared) return;
        const old = @atomicRmw(u32, &a.status, .Xchg, spa.activation_status.inactive, .seq_cst);
        self.prepared = false;
        // If we were mid-cycle, the peers waiting on us would hang. Release them.
        if (old != spa.activation_status.finished) self.triggerPeers(sys.nowNsec());
    }

    fn dataThreadMain(self: *Stream) void {
        while (self.running.load(.acquire)) {
            self.rt_lock.lock();
            const read_fd = self.read_fd;
            self.rt_lock.unlock();

            var fds = [_]sys.PollFd{
                .{ .fd = self.quit_fd, .events = sys.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_fd, .events = sys.POLL.IN, .revents = 0 },
                .{ .fd = read_fd, .events = sys.POLL.IN, .revents = 0 },
            };
            // Before the transport arrives there is nothing to wait on but the
            // quit and wake descriptors.
            const armed = read_fd >= 0;
            const slice = if (armed) fds[0..3] else fds[0..2];

            _ = sys.poll(slice, -1) catch |err| switch (err) {
                error.Interrupted => continue,
                else => return,
            };
            if (fds[0].revents != 0) return;
            if (fds[1].revents != 0) {
                // The transport was replaced; drop through and pick up the new
                // descriptor on the next pass.
                _ = sys.eventfdRead(self.wake_fd) catch {};
                continue;
            }
            if (armed and fds[2].revents & sys.POLL.IN != 0) self.cycle(read_fd);
        }
    }

    /// One graph cycle: wake, produce `duration` frames, hand them on, and
    /// release whatever was waiting on us.
    fn cycle(self: *Stream, fd: i32) void {
        self.rt_lock.lock();
        defer self.rt_lock.unlock();

        // A retired transport can still be readable; only the live one is ours
        // to consume, and reading any other would block this thread for good.
        if (fd != self.read_fd) return;
        const missed = sys.eventfdRead(fd) catch return;

        const a = self.activation orelse return;

        // The driver marks us TRIGGERED before writing the eventfd. A wakeup we
        // did not expect (a stale write, or a cycle already handled) stops here.
        if (@cmpxchgStrong(
            u32,
            &a.status,
            spa.activation_status.triggered,
            spa.activation_status.awake,
            .seq_cst,
            .seq_cst,
        ) != null) return;

        const now = sys.nowNsec();
        a.awake_time = now;
        if (missed > 1) {
            a.xrun_count +%= @intCast(missed - 1);
            a.xrun_time = now / std.time.ns_per_us;
            _ = self.missed_cycles.fetchAdd(missed - 1, .monotonic);
        }
        // The driver stamps `signal_time` when it marks this node ready, so the
        // difference is how long the wakeup took to arrive. Saturating, because
        // the two stamps are written by different threads and a stale one would
        // otherwise wrap.
        self.wake_timing.record(now -| a.signal_time);

        const position = self.position orelse &a.position;
        const frames: u32 = @intCast(@min(position.clock.duration, std.math.maxInt(u32)));
        const parity: u1 = @intCast(position.clock.cycle & 1);
        self.publishTiming(position);

        if (frames > 0) self.produce(frames, parity);

        a.state[0].status = spa.status.have_data;

        const finished = sys.nowNsec();
        const old = @atomicRmw(u32, &a.status, .Xchg, spa.activation_status.finished, .seq_cst);
        a.finish_time = finished;
        self.process_timing.record(finished -| now);

        // Only the thread that actually did the work wakes the peers; if the
        // driver had already moved us on, it will have handled them.
        if (old == spa.activation_status.awake) self.triggerPeers(finished);
    }

    fn publishTiming(self: *Stream, position: *const spa.IoPosition) void {
        if (position.clock.rate.denom != 0) {
            self.graph_rate.store(position.clock.rate.denom, .release);
        }
        self.graph_quantum.store(@intCast(position.clock.duration), .release);
    }

    /// Fill each port's current buffer with `frames` samples and publish it.
    fn produce(self: *Stream, frames: u32, parity: u1) void {
        var planes: [max_channels][]f32 = undefined;
        var chosen: [max_channels]?*Buffer = @splat(null);

        var limit = frames;
        for (self.ports, 0..) |*port, i| {
            const mix = port.bufferMix();
            const buffer: ?*Buffer = if (mix) |m| dequeue(m, parity) else null;
            chosen[i] = buffer;
            // A port with no buffer still needs somewhere to put its samples, so
            // that one unlinked port does not stall the others.
            const plane = if (buffer) |b| b.data else port.scratch;
            // A buffer shorter than the cycle would be a daemon bug, but clamp
            // rather than write past the end of shared memory.
            limit = @min(limit, @as(u32, @intCast(plane.len)));
            planes[i] = plane;
        }
        if (limit == 0 or self.ports.len == 0) return;

        const out = planes[0..self.ports.len];
        for (out) |*p| p.* = p.*[0..limit];

        if (self.identity_routing) {
            self.fill(out, limit);
        } else {
            self.route(out, limit);
        }
        // Whatever the samples came from, the graph's volume is applied to them
        // here: one gain per graph channel, on the planes about to be published.
        applyVolume(out, &self.volume_props);

        const bytes = limit * @sizeOf(f32);
        for (self.ports, 0..) |*port, i| {
            const buffer = chosen[i] orelse continue;
            buffer.chunk.offset = 0;
            buffer.chunk.size = bytes;
            buffer.chunk.stride = @sizeOf(f32);
            buffer.chunk.flags = 0;
            // Publish to every link on this port. The write of `status` is what
            // makes the buffer visible, so it goes last.
            for (port.mixes.items) |*m| {
                const io = m.io[parity] orelse continue;
                @atomicStore(u32, &io.buffer_id, buffer.id, .monotonic);
                @atomicStore(i32, &io.status, spa.status.have_data, .release);
            }
        }
    }

    /// Fill the caller's channels into scratch, then spread them across the
    /// graph's ports according to `routes`.
    fn route(self: *Stream, out: []const []f32, frames: u32) void {
        const n_in = self.channels;
        if (self.mix_scratch.len < n_in * frames) {
            for (out) |plane| @memset(plane, 0);
            return;
        }

        var in: [max_channels][]f32 = undefined;
        for (0..n_in) |c| in[c] = self.mix_scratch[c * frames ..][0..frames];
        self.fill(in[0..n_in], frames);

        for (out, self.routes[0..out.len]) |plane, r| switch (r) {
            .copy => |c| @memcpy(plane, in[c]),
            .downmix => {
                const scale = 1.0 / @as(f32, @floatFromInt(n_in));
                for (plane, 0..) |*sample, i| {
                    var sum: f32 = 0;
                    for (in[0..n_in]) |src| sum += src[i];
                    sample.* = sum * scale;
                }
            },
            .silence => @memset(plane, 0),
        };
    }

    /// Get `frames` of audio from the caller, into one plane per caller channel.
    fn fill(self: *Stream, planes: []const []f32, frames: u32) void {
        if (self.process) |p| {
            p.func(p.ctx, planes, frames);
        } else if (self.ring) |*r| {
            _ = r.readPlanar(planes, frames);
        } else {
            for (planes) |plane| @memset(plane, 0);
        }
    }

    /// Pick the buffer to write this cycle, recycling the one the peer has
    /// finished with.
    fn dequeue(m: *Mix, parity: u1) ?*Buffer {
        if (m.n_buffers == 0) return null;
        if (m.n_buffers == 1) return &m.buffers[0];

        // A buffer the peer has consumed shows up as no longer HAVE_DATA.
        if (m.io[parity]) |io| {
            if (@atomicLoad(i32, &io.status, .acquire) != spa.status.have_data) {
                const id = @atomicLoad(u32, &io.buffer_id, .monotonic);
                if (id < m.n_buffers) m.buffers[id].free = true;
            }
        }
        for (m.buffers[0..m.n_buffers]) |*b| {
            if (b.free) {
                b.free = false;
                return b;
            }
        }
        // Everything is still out with the peer; reuse the most recent buffer
        // rather than dropping the cycle.
        return &m.buffers[0];
    }

    /// Decrement each peer's barrier and wake the ones we were the last
    /// dependency of.
    fn triggerPeers(self: *Stream, nsec: u64) void {
        for (self.peers.items) |*peer| {
            const a = peer.activation;
            const remaining = @atomicRmw(i32, &a.state[0].pending, .Sub, 1, .seq_cst) - 1;
            if (remaining != 0) continue;

            if (a.server_version >= 1) {
                // Only wake a peer that is between cycles; anything else means
                // the driver has already moved it along.
                if (@cmpxchgStrong(
                    u32,
                    &a.status,
                    spa.activation_status.not_triggered,
                    spa.activation_status.triggered,
                    .seq_cst,
                    .seq_cst,
                ) != null) continue;
            } else {
                @atomicStore(u32, &a.status, spa.activation_status.triggered, .seq_cst);
            }
            a.signal_time = nsec;
            sys.eventfdWrite(peer.signal_fd, 1) catch {};
        }
    }

    // --- diagnostics ---

    fn fail(self: *Stream, msg: []const u8) void {
        self.state.store(.failed, .release);
        self.logf(.err, "{s}", .{msg});
    }

    fn logf(self: *Stream, level: Log.Level, comptime fmt: []const u8, args: anytype) void {
        Log.printf(self.log, level, fmt, args);
    }
};

/// Scale one cycle's planes by the node's volume.
///
/// A gain of exactly one is left alone rather than multiplied through, which is
/// the usual case and the whole of the cost when nothing has touched the volume.
/// A channel the volume array does not reach — a graph layout wider than the
/// mixer's idea of it — is unattenuated for the same reason.
fn applyVolume(planes: []const []f32, volume: *const Volume) void {
    if (volume.mute) {
        for (planes) |plane| @memset(plane, 0);
        return;
    }
    for (planes, 0..) |plane, i| {
        const per_channel = if (i < volume.channels) volume.channel_volumes[i] else 1.0;
        const gain = volume.volume * per_channel;
        if (gain == 1.0) continue;
        for (plane) |*sample| sample.* *= gain;
    }
}

/// Turn a negotiated audio layout into channels this library knows, writing
/// them into `out`. Returns null when there is no layout, or when it names a
/// position or a channel count this library has no name for.
fn channelMapFor(layout: ?cn.AudioLayout, out: *[max_channels]Channel) ?u32 {
    const l = layout orelse return null;
    if (l.channels == 0 or l.channels > max_channels) return null;

    if (l.positioned) {
        for (0..l.channels) |i| {
            out[i] = channelFromPosition(l.positions[i]) orelse break;
        } else return l.channels;
    }

    // Either unpositioned, or a position this library has no name for: fall
    // back on the conventional layout for the count, if there is one.
    const conventional = defaultChannelMap(l.channels);
    if (conventional.len != l.channels) return null;
    @memcpy(out[0..l.channels], conventional);
    return l.channels;
}

fn channelFromPosition(position: u32) ?Channel {
    return switch (position) {
        spa.audio_channel.mono => .mono,
        spa.audio_channel.fl => .fl,
        spa.audio_channel.fr => .fr,
        spa.audio_channel.fc => .fc,
        spa.audio_channel.lfe => .lfe,
        spa.audio_channel.rl => .rl,
        spa.audio_channel.rr => .rr,
        spa.audio_channel.sl => .sl,
        spa.audio_channel.sr => .sr,
        spa.audio_channel.flc => .flc,
        spa.audio_channel.frc => .frc,
        spa.audio_channel.rc => .rc,
        else => null,
    };
}

// --- Tests ------------------------------------------------------------------

test "the graph's volume is applied to the samples, and unity costs nothing" {
    var left = [_]f32{ 1.0, -1.0, 0.5, 0.25 };
    var right = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    const planes = [_][]f32{ left[0..], right[0..] };

    // Unity everywhere: the samples come through untouched.
    var volume: Volume = .{ .channels = 2 };
    applyVolume(&planes, &volume);
    try std.testing.expectEqual(@as(f32, 1.0), left[0]);
    try std.testing.expectEqual(@as(f32, 1.0), right[0]);

    // One channel at a time, which is what a balance control is.
    volume.channel_volumes[0] = 0.5;
    applyVolume(&planes, &volume);
    try std.testing.expectEqual(@as(f32, 0.5), left[0]);
    try std.testing.expectEqual(@as(f32, -0.5), left[1]);
    try std.testing.expectEqual(@as(f32, 1.0), right[0]);

    // The master gain multiplies on top of the per-channel ones.
    volume.volume = 0.5;
    applyVolume(&planes, &volume);
    try std.testing.expectEqual(@as(f32, 0.125), left[0]);
    try std.testing.expectEqual(@as(f32, 0.5), right[0]);

    // And mute is silence whatever the rest of it says.
    volume.mute = true;
    applyVolume(&planes, &volume);
    try std.testing.expectEqual(@as(f32, 0), left[0]);
    try std.testing.expectEqual(@as(f32, 0), right[0]);
}

test "a channel the volume does not reach is left alone" {
    var only = [_]f32{2.0};
    const planes = [_][]f32{only[0..]};
    // A mixer that knows about fewer channels than the graph settled on must
    // not silence the ones it did not mention.
    const volume: Volume = .{ .channels = 0 };
    applyVolume(&planes, &volume);
    try std.testing.expectEqual(@as(f32, 2.0), only[0]);
}
