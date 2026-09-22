// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Lists the graph and changes it, the way `wpctl` does.
//!
//!     zig build run-session                            # what is in the graph
//!     zig build run-session -- volume <node-id>        # read one node's volume
//!     zig build run-session -- volume <node-id> 0.5    # and set it
//!     zig build run-session -- mute <node-id> on|off
//!     zig build run-session -- default <sink-name>
//!     zig build run-session -- move <node-id> <sink-name>
//!     zig build run-session -- link <out-node-id> <in-node-id>
//!     zig build run-session -- unlink <link-id>
//!
//! Volumes here are the linear amplitudes the protocol carries, where 1.0 is
//! unattenuated. `wpctl` and `pavucontrol` show a cubic scale, on which this
//! 0.125 reads as 0.50.

const std = @import("std");
const pw = @import("pipewire");

const Writer = std.Io.Writer;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &buf);
    const out = &file_writer.interface;
    defer out.flush() catch {};

    var args = init.minimal.args.iterate();
    _ = args.next(); // program name
    const command = args.next() orelse "status";

    const session = try pw.Session.open(gpa, .{
        .name = "zig-pipewire session",
        .environ = init.minimal.environ,
    });
    defer session.close();

    if (std.mem.eql(u8, command, "status")) {
        try status(session, out);
    } else if (std.mem.eql(u8, command, "volume")) {
        const id = try wantId(args.next());
        if (args.next()) |level| {
            try session.setVolume(id, try wantFloat(level));
        }
        const volume = try session.volume(id);
        try out.print("volume {d:.3} ({d:.2} on the cubic scale){s}\n", .{
            volume.peak(),
            pw.Volume.linearToCubic(volume.peak()),
            if (volume.mute) " [muted]" else "",
        });
    } else if (std.mem.eql(u8, command, "mute")) {
        const id = try wantId(args.next());
        const how = args.next() orelse return error.MissingArgument;
        try session.setMute(id, std.mem.eql(u8, how, "on"));
    } else if (std.mem.eql(u8, command, "default")) {
        const wanted = args.next() orelse return error.MissingArgument;
        try session.setDefaultSink(wanted);
        // The session manager grants the request by changing the graph, which
        // it does a moment after the write rather than in reply to it.
        var waited: usize = 0;
        while (waited < 20) : (waited += 1) {
            pw.sleep(100 * std.time.ns_per_ms);
            try session.roundTrip();
            const sink = (try session.defaultSink()) orelse continue;
            const name = sink.name() orelse continue;
            if (!std.mem.eql(u8, name, wanted)) continue;
            try out.print("default sink is now {s}\n", .{sink.label()});
            break;
        } else try out.print("asked for {s}; the session manager has not moved\n", .{wanted});
    } else if (std.mem.eql(u8, command, "move")) {
        const id = try wantId(args.next());
        try session.moveNode(id, args.next());
        // Same again: what was asked for is in the metadata, and whether it was
        // granted shows up as the node's links changing.
        pw.sleep(300 * std.time.ns_per_ms);
        try session.roundTrip();
    } else if (std.mem.eql(u8, command, "link")) {
        const output = try wantId(args.next());
        const input = try wantId(args.next());
        var ids: [64]u32 = undefined;
        const made = try session.linkNodes(output, input, .{}, &ids);
        try out.print("made {d} link(s):", .{made.len});
        for (made) |id| try out.print(" {d}", .{id});
        try out.writeAll("\n");
        // The links belong to this connection, so hold it open to keep them.
        try out.flush();
        pw.sleep(5 * std.time.ns_per_s);
    } else if (std.mem.eql(u8, command, "unlink")) {
        try session.destroy(try wantId(args.next()));
    } else {
        try out.print("unknown command: {s}\n", .{command});
        return error.UnknownCommand;
    }
}

fn status(session: *pw.Session, out: *Writer) !void {
    const default_sink = try session.defaultSink();
    const default_source = try session.defaultSource();

    try out.writeAll("Sinks:\n");
    var sinks = session.sinks();
    while (sinks.next()) |sink| try describe(session, out, sink, default_sink);

    try out.writeAll("\nSources:\n");
    var sources = session.sources();
    while (sources.next()) |source| try describe(session, out, source, default_source);

    try out.writeAll("\nStreams:\n");
    var streams = session.streams();
    while (streams.next()) |stream| try describe(session, out, stream, null);

    try out.writeAll("\nDevices:\n");
    var devices = session.devices();
    while (devices.next()) |device| {
        try out.print("  {d:>4}  {s}\n", .{ device.id, device.label() });
    }

    try out.writeAll("\nLinks:\n");
    var links = session.links();
    var link_ids: [256]u32 = undefined;
    var link_count: usize = 0;
    while (links.next()) |link| {
        if (link_count == link_ids.len) break;
        link_ids[link_count] = link.id;
        link_count += 1;
    }
    // Asking a link what it is doing means binding it, which can take objects
    // away, so the ids are collected before any of them are asked.
    for (link_ids[0..link_count]) |id| {
        const link = session.byId(id) orelse continue;
        const state = session.linkState(id) catch |err| switch (err) {
            error.NoReply, error.NotFound => continue,
            else => return err,
        };
        try out.print("  {d:>4}  node {s} port {s} -> node {s} port {s}  [{s}]\n", .{
            id,
            link.prop("link.output.node") orelse "?",
            link.prop("link.output.port") orelse "?",
            link.prop("link.input.node") orelse "?",
            link.prop("link.input.port") orelse "?",
            state.name(),
        });
    }

    try out.print("\n{d} objects, {d} links\n", .{ session.objects().len, link_count });
}

/// One node, with its volume if it has one.
///
/// Reading a volume costs a round trip, which can take a node away — so the id
/// is kept rather than the pointer, and the name is printed first.
fn describe(
    session: *pw.Session,
    out: *Writer,
    node: *const pw.Object,
    default: ?*const pw.Object,
) !void {
    const is_default = if (default) |d| d.id == node.id else false;
    const state = session.nodeState(node.id) catch pw.NodeState.creating;
    try out.print("{s} {d:>4}  {s} ({s})", .{
        if (is_default) "*" else " ",
        node.id,
        node.label(),
        state.name(),
    });

    const volume = session.volume(node.id) catch |err| switch (err) {
        // A node with no volume control of its own, which is most drivers.
        error.NoReply, error.NotFound, error.WrongType => {
            try out.writeAll("\n");
            return;
        },
        else => return err,
    };
    try out.print(" [{d:.2}{s}]\n", .{
        pw.Volume.linearToCubic(volume.peak()),
        if (volume.mute) " muted" else "",
    });
}

fn wantId(text: ?[]const u8) !u32 {
    const t = text orelse return error.MissingArgument;
    return std.fmt.parseInt(u32, t, 10) catch error.NotANumber;
}

fn wantFloat(text: []const u8) !f32 {
    return std.fmt.parseFloat(f32, text) catch error.NotANumber;
}
