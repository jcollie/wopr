// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! SPA (Simple Plugin API) constants and shared-memory layouts.
//!
//! The values here are part of the PipeWire wire protocol and the layout of the
//! memory the server shares with a client, so they are fixed by the daemon we
//! talk to rather than by us. They mirror `spa/include/spa/**` and
//! `src/pipewire/private.h` from PipeWire 1.6.

const std = @import("std");

/// A sentinel meaning "no id"; appears in place of ids all over the protocol.
pub const id_invalid: u32 = 0xffffffff;

/// POD type tags, from `enum spa_type`.
pub const Type = enum(u32) {
    none = 1,
    bool = 2,
    id = 3,
    int = 4,
    long = 5,
    float = 6,
    double = 7,
    string = 8,
    bytes = 9,
    rectangle = 10,
    fraction = 11,
    bitmap = 12,
    array = 13,
    @"struct" = 14,
    object = 15,
    sequence = 16,
    pointer = 17,
    fd = 18,
    choice = 19,
    pod = 20,
    _,
};

/// Object body types, from the `SPA_TYPE_OBJECT_*` block of `enum spa_type`.
pub const object_type = struct {
    pub const prop_info: u32 = 0x40001;
    pub const props: u32 = 0x40002;
    pub const format: u32 = 0x40003;
    pub const param_buffers: u32 = 0x40004;
    pub const param_meta: u32 = 0x40005;
    pub const param_io: u32 = 0x40006;
    pub const param_port_config: u32 = 0x40008;
    pub const param_route: u32 = 0x40009;
    pub const param_latency: u32 = 0x4000b;
    pub const param_tag: u32 = 0x4000d;
};

/// `SPA_TYPE_COMMAND_Node`, the object type of the commands the server sends us.
pub const command_node: u32 = 0x30002;

/// Choice kinds, from `enum spa_choice_type`.
pub const Choice = enum(u32) {
    none = 0,
    range = 1,
    step = 2,
    @"enum" = 3,
    flags = 4,
};

/// Param ids, from `enum spa_param_type`.
pub const Param = enum(u32) {
    invalid = 0,
    prop_info = 1,
    props = 2,
    enum_format = 3,
    format = 4,
    buffers = 5,
    meta = 6,
    io = 7,
    enum_profile = 8,
    profile = 9,
    enum_port_config = 10,
    port_config = 11,
    enum_route = 12,
    route = 13,
    control = 14,
    latency = 15,
    process_latency = 16,
    tag = 17,
    _,
};

/// Flags in a `spa_param_info` entry.
pub const param_info = struct {
    pub const serial: u32 = 1 << 0;
    pub const read: u32 = 1 << 1;
    pub const write: u32 = 1 << 2;
    pub const readwrite: u32 = read | write;
};

/// Property keys of a `SPA_TYPE_OBJECT_Format` object.
pub const format = struct {
    pub const media_type: u32 = 1;
    pub const media_subtype: u32 = 2;
    pub const audio_format: u32 = 0x10001;
    pub const audio_rate: u32 = 0x10003;
    pub const audio_channels: u32 = 0x10004;
    pub const audio_position: u32 = 0x10005;
};

/// `enum spa_media_type`.
pub const media_type = struct {
    pub const audio: u32 = 1;
    pub const application: u32 = 6;
};

/// `enum spa_media_subtype`.
pub const media_subtype = struct {
    pub const raw: u32 = 1;
    pub const dsp: u32 = 2;
    pub const control: u32 = 0x60001;
};

/// `enum spa_audio_format`. Only the entries this library can produce.
pub const audio_format = struct {
    pub const f32p: u32 = 0x206;
    /// PipeWire's DSP audio format: one plane of native-endian f32 per port.
    pub const dsp_f32: u32 = f32p;
};

/// `enum spa_audio_channel`: speaker positions, used in a format's `position`
/// array. Only the entries this library's `Channel` maps to.
pub const audio_channel = struct {
    pub const unknown: u32 = 0;
    pub const na: u32 = 1;
    pub const mono: u32 = 2;
    pub const fl: u32 = 3;
    pub const fr: u32 = 4;
    pub const fc: u32 = 5;
    pub const lfe: u32 = 6;
    pub const sl: u32 = 7;
    pub const sr: u32 = 8;
    pub const flc: u32 = 9;
    pub const frc: u32 = 10;
    pub const rc: u32 = 11;
    pub const rl: u32 = 12;
    pub const rr: u32 = 13;
};

/// Property keys of a `SPA_TYPE_OBJECT_Props` object, from `enum spa_prop`.
///
/// Only the audio block, which is what a session manager sets on a node: a
/// volume is a linear amplitude where 1.0 is unattenuated, and `channel_volumes`
/// carries one per channel of the node's negotiated layout.
pub const prop = struct {
    pub const volume: u32 = 0x10003;
    pub const mute: u32 = 0x10004;
    pub const channel_volumes: u32 = 0x10008;
    pub const volume_base: u32 = 0x10009;
    pub const volume_step: u32 = 0x1000a;
    pub const channel_map: u32 = 0x1000b;
    pub const monitor_mute: u32 = 0x1000c;
    pub const monitor_volumes: u32 = 0x1000d;
    pub const soft_mute: u32 = 0x1000f;
    pub const soft_volumes: u32 = 0x10010;
};

/// Property keys of a `SPA_TYPE_OBJECT_ParamBuffers` object.
pub const param_buffers = struct {
    pub const buffers: u32 = 1;
    pub const blocks: u32 = 2;
    pub const size: u32 = 3;
    pub const stride: u32 = 4;
    pub const @"align": u32 = 5;
    pub const data_type: u32 = 6;
    pub const meta_type: u32 = 7;
};

/// Property keys of a `SPA_TYPE_OBJECT_ParamPortConfig` object.
pub const param_port_config = struct {
    pub const direction: u32 = 1;
    pub const mode: u32 = 2;
    pub const monitor: u32 = 3;
    pub const control: u32 = 4;
    pub const format: u32 = 5;
};

/// `enum spa_param_port_config_mode`.
pub const PortConfigMode = enum(u32) {
    none = 0,
    passthrough = 1,
    convert = 2,
    /// One mono port per channel, in PipeWire's planar f32 DSP format.
    dsp = 3,
    _,
};

/// Property keys of a `SPA_TYPE_OBJECT_ParamRoute` object.
///
/// A route is one way in or out of a device — a headphone jack, a speaker pair
/// — and it is where a sound card's volume actually lives: the node in the
/// graph carries none of it, so a mixer that sets the node's `Props` moves a
/// slider nothing is listening to.
pub const param_route = struct {
    pub const index: u32 = 1;
    pub const direction: u32 = 2;
    /// Which of the card's devices this route belongs to, matching a node's
    /// `card.profile.device` property.
    pub const device: u32 = 3;
    pub const name: u32 = 4;
    pub const description: u32 = 5;
    pub const priority: u32 = 6;
    pub const available: u32 = 7;
    pub const info: u32 = 8;
    pub const profiles: u32 = 9;
    /// A `SPA_TYPE_OBJECT_Props` object: the volume and mute of this route.
    pub const props: u32 = 10;
    pub const devices: u32 = 11;
    pub const profile: u32 = 12;
    /// Whether the session manager should remember the change.
    pub const save: u32 = 13;
};

/// Property keys of a `SPA_TYPE_OBJECT_ParamIO` object.
pub const param_io = struct {
    pub const id: u32 = 1;
    pub const size: u32 = 2;
};

/// `enum spa_io_type`: the kinds of shared area the server can hand a node.
pub const IoType = enum(u32) {
    invalid = 0,
    buffers = 1,
    range = 2,
    clock = 3,
    latency = 4,
    control = 5,
    notify = 6,
    position = 7,
    rate_match = 8,
    memory = 9,
    async_buffers = 10,
    _,
};

/// `enum spa_node_command`.
pub const NodeCommand = enum(u32) {
    @"suspend" = 0,
    pause = 1,
    start = 2,
    enable = 3,
    disable = 4,
    flush = 5,
    drain = 6,
    marker = 7,
    param_begin = 8,
    param_end = 9,
    request_process = 10,
    user = 11,
    _,
};

/// `enum spa_data_type`: how the bytes behind a `Data` block are reached.
pub const DataType = enum(u32) {
    invalid = 0,
    mem_ptr = 1,
    mem_fd = 2,
    dma_buf = 3,
    mem_id = 4,
    sync_obj = 5,
    _,
};

/// Status bits shared through an `IoBuffers` area, from `spa_io_buffers`.
pub const status = struct {
    pub const ok: i32 = 0;
    pub const need_data: i32 = 1 << 0;
    pub const have_data: i32 = 1 << 1;
    pub const stopped: i32 = 1 << 2;
    pub const drained: i32 = 1 << 3;
};

/// `struct spa_node_info` flags.
pub const node_flag = struct {
    pub const rt: u64 = 1 << 0;
};

/// `struct spa_node_info` change mask bits.
pub const node_change = struct {
    pub const flags: u64 = 1 << 0;
    pub const props: u64 = 1 << 1;
    pub const params: u64 = 1 << 2;
};

/// `struct spa_port_info` flags.
pub const port_flag = struct {
    pub const no_ref: u64 = 1 << 4;
};

/// `struct spa_port_info` change mask bits.
pub const port_change = struct {
    pub const flags: u64 = 1 << 0;
    pub const rate: u64 = 1 << 1;
    pub const props: u64 = 1 << 2;
    pub const params: u64 = 1 << 3;
};

/// Which way data flows through a port.
///
/// Non-exhaustive, like every other enum in this file that is decoded from the
/// wire: the value arrives as a `u32` from another process, and `@enumFromInt`
/// into an exhaustive enum is illegal behaviour for anything outside its range
/// rather than a value that can be checked and rejected.
pub const Direction = enum(u32) {
    input = 0,
    output = 1,
    _,
};

pub const Rectangle = extern struct { width: u32, height: u32 };
pub const Fraction = extern struct { num: u32, denom: u32 };

// --- Shared memory layouts -------------------------------------------------
//
// Everything below is mapped from a file descriptor the server sends us, so the
// field order and size must match PipeWire exactly. The `comptime` block at the
// bottom of this file asserts the sizes that PipeWire itself hard-codes.

/// `struct spa_io_buffers`: the handshake slot for one link.
pub const IoBuffers = extern struct {
    status: i32,
    buffer_id: u32,
};

/// `struct spa_io_async_buffers`: a pair of `IoBuffers` selected by cycle parity.
pub const IoAsyncBuffers = extern struct {
    buffers: [2]IoBuffers,
};

/// `struct spa_io_clock`: the driver's notion of time for the current cycle.
pub const IoClock = extern struct {
    flags: u32,
    id: u32,
    name: [64]u8,
    nsec: u64,
    rate: Fraction,
    position: u64,
    duration: u64,
    delay: i64,
    rate_diff: f64,
    next_nsec: u64,
    target_rate: Fraction,
    target_duration: u64,
    target_seq: u32,
    cycle: u32,
    xrun: u64,
};

pub const IoVideoSize = extern struct {
    flags: u32,
    stride: u32,
    size: Rectangle,
    framerate: Fraction,
    padding: [4]u32,
};

pub const IoSegmentBar = extern struct {
    flags: u32,
    offset: u32,
    signature_num: f32,
    signature_denom: f32,
    bpm: f64,
    beat: f64,
    bar_start_tick: f64,
    ticks_per_beat: f64,
    padding: [4]u32,
};

pub const IoSegmentVideo = extern struct {
    flags: u32,
    offset: u32,
    framerate: Fraction,
    hours: u32,
    minutes: u32,
    seconds: u32,
    frames: u32,
    field_count: u32,
    padding: [11]u32,
};

pub const IoSegment = extern struct {
    version: u32,
    flags: u32,
    start: u64,
    duration: u64,
    rate: f64,
    position: u64,
    bar: IoSegmentBar,
    video: IoSegmentVideo,
};

/// `struct spa_io_position`: clock plus transport state for the current cycle.
pub const IoPosition = extern struct {
    clock: IoClock,
    video: IoVideoSize,
    offset: i64,
    state: u32,
    n_segments: u32,
    segments: [8]IoSegment,
};

/// `struct pw_node_activation_state`: the barrier one node waits on.
pub const ActivationState = extern struct {
    status: i32,
    required: i32,
    pending: i32,
};

/// The `status` field of an `Activation`, from the `PW_NODE_ACTIVATION_*` defines.
///
/// A node starts INACTIVE. Once it is watching its eventfd it stores FINISHED,
/// which tells the driver it may be scheduled. Per cycle the driver moves it to
/// NOT_TRIGGERED, a peer moves it to TRIGGERED and writes the eventfd, the node
/// moves it to AWAKE when it wakes, and back to FINISHED when it is done.
pub const activation_status = struct {
    pub const not_triggered: u32 = 0;
    pub const triggered: u32 = 1;
    pub const awake: u32 = 2;
    pub const finished: u32 = 3;
    pub const inactive: u32 = 4;
};

/// The activation-record version this library implements. Version 1 means the
/// `status` transitions use compare-and-swap rather than plain stores.
pub const activation_version: u32 = 1;

/// `struct pw_node_activation`: one per node, shared between the daemon and
/// every peer that has to wake this node up.
pub const Activation = extern struct {
    status: u32,
    /// Bitfield in C: `version:1`, `pending_sync:1`, `pending_new_pos:1`.
    bits: u32,
    state: [2]ActivationState,
    signal_time: u64,
    awake_time: u64,
    finish_time: u64,
    prev_signal_time: u64,
    reposition: IoSegment,
    segment: IoSegment,
    segment_owner: [16]u32,
    prev_awake_time: u64,
    prev_finish_time: u64,
    padding: [7]u32,
    client_version: u32,
    server_version: u32,
    active_driver_id: u32,
    driver_id: u32,
    flags: u32,
    position: IoPosition,
    sync_timeout: u64,
    sync_left: u64,
    cpu_load: [3]f32,
    xrun_count: u32,
    xrun_time: u64,
    xrun_delay: u64,
    max_delay: u64,
    command: u32,
    reposition_owner: u32,
};

/// `struct spa_chunk`: which part of a data block actually holds samples.
pub const Chunk = extern struct {
    offset: u32,
    size: u32,
    stride: i32,
    flags: i32,
};

comptime {
    // PipeWire hard-codes these sizes when it allocates the shared areas, so a
    // mismatch here would silently corrupt the graph rather than fail to build.
    // The numbers come from compiling the daemon's own headers.
    std.debug.assert(@sizeOf(IoBuffers) == 8);
    std.debug.assert(@sizeOf(IoAsyncBuffers) == 16);
    std.debug.assert(@sizeOf(IoClock) == 160);
    std.debug.assert(@sizeOf(IoVideoSize) == 40);
    std.debug.assert(@sizeOf(IoSegmentBar) == 64);
    std.debug.assert(@sizeOf(IoSegmentVideo) == 80);
    std.debug.assert(@sizeOf(IoSegment) == 184);
    std.debug.assert(@sizeOf(IoPosition) == 1688);
    std.debug.assert(@offsetOf(IoPosition, "segments") == 216);
    std.debug.assert(@sizeOf(Chunk) == 16);
    std.debug.assert(@sizeOf(ActivationState) == 12);
    std.debug.assert(@offsetOf(Activation, "segment_owner") == 432);
    std.debug.assert(@offsetOf(Activation, "client_version") == 540);
    std.debug.assert(@offsetOf(Activation, "position") == 560);
    std.debug.assert(@offsetOf(Activation, "command") == 2304);
    std.debug.assert(@sizeOf(Activation) == 2312);
}
