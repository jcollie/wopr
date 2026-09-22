// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A PipeWire client: playback into the graph, and management of the graph.
//!
//! The library speaks PipeWire's native wire protocol over the daemon's Unix
//! socket directly; it links neither libpipewire nor libc. `Stream` is the whole
//! of the playback API and `Session` the whole of the session one, and the lower
//! layers are exported for callers who need to reach past them.
//!
//! ```zig
//! const stream = try pw.Stream.open(gpa, .{ .name = "my app", .channels = 2 });
//! defer stream.close();
//! _ = stream.waitStreaming(5000);
//! try stream.writeAll(interleaved_f32_samples);
//! stream.drain(2000);
//! ```
//!
//! ```zig
//! const session = try pw.Session.open(gpa, .{ .name = "my mixer" });
//! defer session.close();
//! var sinks = session.sinks();
//! while (sinks.next()) |sink| std.debug.print("{s}\n", .{sink.label()});
//! if (try session.defaultSink()) |sink| try session.setVolume(sink.id, 0.5);
//! ```

const stream_mod = @import("stream.zig");
const session_mod = @import("session.zig");

/// A playback stream: one node in the graph with a mono port per channel.
pub const Stream = stream_mod.Stream;
pub const Channel = stream_mod.Channel;
pub const Role = stream_mod.Role;
pub const State = stream_mod.State;
pub const Stats = stream_mod.Stats;
pub const Summary = stream_mod.Summary;
pub const Options = stream_mod.Options;
pub const Process = stream_mod.Process;
pub const Log = @import("log.zig").Log;
pub const LogLevel = Log.Level;
pub const defaultChannelMap = stream_mod.defaultChannelMap;
pub const max_channels = stream_mod.max_channels;

/// The graph as a whole: what is in it, and the changes a mixer makes to it.
pub const Session = session_mod.Session;
pub const Object = session_mod.Object;
pub const ObjectType = session_mod.ObjectType;
pub const Filter = session_mod.Filter;
pub const Volume = session_mod.Volume;
pub const NodeState = session_mod.NodeState;
pub const LinkState = session_mod.LinkState;
pub const SessionOptions = session_mod.Options;

/// Sleep for `ns` nanoseconds.
///
/// A convenience, since this library reaches the kernel directly and so has a
/// sleep to hand; Zig 0.16's own sleep lives behind the `Io` interface.
pub const sleep = @import("sys.zig").sleep;

/// Lower layers, for clients that need to go past `Stream`.
pub const spa = @import("spa.zig");
pub const pod = @import("pod.zig");
pub const sys = @import("sys.zig");
pub const connection = @import("connection.zig");
pub const core = @import("core.zig");
pub const client_node = @import("client_node.zig");
pub const registry = @import("registry.zig");
pub const ring = @import("ring.zig");
pub const stream = stream_mod;
pub const session = session_mod;

test {
    @import("std").testing.refAllDecls(@This());
}
