<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-pipewire

A PipeWire client library in Zig: send audio to the graph for live playback,
and see and change the graph itself.

It speaks PipeWire's native wire protocol directly over the daemon's Unix
socket: no `libpipewire`, no libc, no C at all. The only dependency is a running
PipeWire daemon.

```zig
const pw = @import("pipewire");

const stream = try pw.Stream.open(gpa, .{
    .name = "my app",
    .channels = 2,
    .rate = 48000,
    .environ = init.minimal.environ,
});
defer stream.close();

_ = stream.waitStreaming(5000);
try stream.writeAll(interleaved_f32_samples);
stream.drain(2000);
```

```zig
const session = try pw.Session.open(gpa, .{ .name = "my mixer" });
defer session.close();

var sinks = session.sinks();
while (sinks.next()) |sink| std.debug.print("{d} {s}\n", .{ sink.id, sink.label() });

if (try session.defaultSink()) |sink| try session.setVolume(sink.id, 0.5);
```

Requires Zig 0.16 and Linux.

## Playing audio

`Stream` creates a `client-node` in the daemon's graph with one mono output port
per channel, and lets the session manager route it like any other audio stream —
it appears in `wpctl status`, `pavucontrol` and `pw-top`, and can be moved
between sinks and have its volume changed from the usual tools.

The volume is the node's `Props` parameter, and the stream applies it to the
samples on their way out: what a mixer sets is what is heard, and audio handed
to `write` or filled in by `process` is at full scale whatever the slider says.
`Stream.volume` reads back what the graph has set. A volume of exactly 1.0 is
skipped rather than multiplied through, so the usual case costs one comparison
per channel per cycle.

Audio is handed over as 32-bit float. There are two ways to supply it:

- **Push.** `write` and `writeAll` copy interleaved frames into a lock-free
  ring that the real-time thread drains. Call them from wherever is convenient.
- **Pull.** Set `Options.process` and PipeWire calls back once per graph cycle
  with one plane per channel to fill in place. The callback runs on the
  real-time thread, so it must not allocate, lock or block.

## Seeing and changing the graph

`Session` is the other half: its own connection, bound to the daemon's registry,
which announces every node, device, port, link and metadata store and keeps
announcing them as they come and go. It is what a mixer or a control panel talks
to, and it does what `wpctl` does.

```zig
const session = try pw.Session.open(gpa, .{ .name = "my mixer" });
defer session.close();

// Listing costs nothing: it is what the registry has already said.
var streams = session.streams();
while (streams.next()) |stream| {
    std.debug.print("{d} {s}\n", .{ stream.id, stream.label() });
}

// A volume, and what a node or a link is doing, are not in what the registry
// announced: each has to be asked of the object itself, which costs a round
// trip the first time.
const volume = try session.volume(node_id);
const state = try session.nodeState(node_id); // .running, .idle, .suspended

// Changing costs a round trip each, and the graph settles a moment later.
try session.setVolume(node_id, volume.peak() / 2);
try session.setMute(node_id, false);
try session.setDefaultSink("alsa_output.pci-0000_0b_00.4.iec958-stereo");
try session.moveNode(node_id, "alsa_output.usb-audio");
const link = try session.createLink(.{
    .output_node = node_id,
    .output_port = port_id,
    .input_node = sink_id,
    .input_port = sink_port_id,
});
try session.destroy(link);
```

Every call that reaches the daemon blocks until the daemon has answered, and a
`Session` is not safe to use from two threads at once. `roundTrip` is how a
program that wants to see changes asks for them; nothing arrives except during a
call that waits.

Volumes are the linear amplitudes the protocol carries, where 1.0 is
unattenuated. `wpctl` and `pavucontrol` show a cubic scale instead, so 0.5 there
is 0.125 here; `Volume.cubicToLinear` and `Volume.linearToCubic` convert.

Where a volume lives depends on what the node is. An application stream keeps it
in its own `Props`; a node belonging to a sound card keeps it in that card's
device route, and the node's own `Props` sit at 1.0 whatever the volume is. The
library follows the node to the right one, which is why `session.volume(id)`
agrees with `wpctl get-volume id` for a sink as well as for a stream.

The defaults and a stream's target are not set directly either: they are
requests written into the session manager's `default` metadata store, which
grants them by changing the graph. So a change shows up on the next round trip
after that, or not at all if the session manager declined it.

## What it does not do

Playback only — there is no capture side, and no filter or duplex node.

Format conversion is left to the graph. The stream produces planar `f32` at the
graph's own rate, which is what PipeWire's sinks consume; ask for the rate you
want with `Options.rate` and read back what you got with `Stream.rate`.

Channel layout is negotiated rather than dictated: the session manager
configures the node for the layout the sink is running, which may not be the one
you asked for. `Stream.write` still takes the channel count you asked for and
maps it onto the graph's:

- a graph channel whose position you also supply is copied;
- otherwise, if you supply a single channel, it feeds every graph channel;
- otherwise, if the graph wants a single channel, it gets the average of yours;
- otherwise that graph channel is silent, and yours at that position is dropped.

So mono plays through a stereo sink, stereo folds down to a mono sink, and 5.1
into a stereo sink keeps its front pair and loses the rest. `Stream.graphChannels`
reports what the graph settled on. Anything more careful than the above is
yours to do before handing samples over.

## Examples

```
zig build run-tone  -- [seconds] [hz] [channels]   # push API
zig build run-chord -- [seconds]                   # pull API
zig build run-session                              # what is in the graph
zig build run-session -- volume <node-id> [level]
zig build run-session -- mute <node-id> on|off
zig build run-session -- default <sink-name>
zig build run-session -- move <node-id> <sink-name>
zig build run-session -- link <out-node-id> <in-node-id>
zig build run-session -- unlink <link-id>
```

`run-session` prints what `wpctl status` prints, out of the same graph — every
sink, source, stream and device with its state and its volume, and every link
with the two ports it joins and whether it is carrying audio. Which makes it the
quickest way to see whether the two agree.

## Using it

```
zig fetch --save git+https://git.jcollie.dev/jeff/zig-pipewire.git#main
```

```zig
const pipewire = b.dependency("pipewire", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pipewire", pipewire.module("pipewire"));
```

`#main` follows the branch; name a tag or a commit there instead to pin to one.
The repository is at <https://git.jcollie.dev/jeff/zig-pipewire>, mirrored on
Tangled at <https://tangled.org/jcollie.dev/zig-pipewire>.

## Layout

| file | what it holds |
| --- | --- |
| `src/stream.zig` | the playback API, negotiation and the real-time cycle |
| `src/session.zig` | the session API: the graph, and the changes made to it |
| `src/client_node.zig` | encoding and decoding for the `client-node` interface |
| `src/registry.zig` | encoding and decoding for the registry and its objects |
| `src/core.zig` | the Core object, object ids, the memory pool |
| `src/connection.zig` | message framing and descriptor passing |
| `src/pod.zig` | SPA POD serialization |
| `src/spa.zig` | SPA constants and shared-memory layouts |
| `src/ring.zig` | the lock-free ring behind `write` |
| `src/log.zig` | the optional diagnostics callback |
| `src/sys.zig` | the Linux syscalls the library makes |
| `tools/bench.zig` | the benchmarks |
| `tests/fuzz.zig` | the fuzz targets |

`Stream` is the whole of the playback API and `Session` the whole of the session
one; the lower layers are exported for callers who need to reach past them.

## Tests

```
zig build test
```

The unit tests cover POD encoding and decoding, message framing over a
socketpair (descriptor passing included), the ring, and the registry and session
decoders — what a global, a node's info, a metadata property and a volume are
made of, and what a session keeps of them. They need no daemon.
The layouts of the structures shared with the daemon are checked at compile
time against the sizes PipeWire hard-codes.

## Benchmarks

```
zig build bench                    # both halves
zig build bench -- micro
zig build bench -- live --seconds 30 --channels 6
```

An audio graph has a deadline rather than a throughput target: PipeWire wakes
the node once per quantum and everything downstream waits on it, so the question
is whether a cycle finishes in time *every* time. `live` plays a tone and reports
what the cycles cost, taken from the two timestamps the node writes into the
activation record it shares with the daemon — the same two `pw-top` reads as WAIT
and BUSY, so the two can be checked against each other. `micro` times the
routines a cycle is made of, with no daemon involved.

On a Ryzen 7 5800X, stereo at 48 kHz with a quantum of 1024 (a period of
21.3 ms), over 1876 cycles:

| | min | mean | max | worst as % of period |
| --- | ---: | ---: | ---: | ---: |
| wake (WAIT) | 5.9 us | 9.6 us | 55.4 us | 0.26% |
| process (BUSY) | 2.2 us | 3.2 us | 25.8 us | 0.12% |

with no missed cycles and no underruns. Six channels routed down to a stereo
sink roughly doubles the process time, to a mean of 6.4 us. `pw-top` sampling the
same run agreed on both means to the figure it prints; its maxima are lower
because it snapshots once a second while `Stream.stats` sees every cycle, and for
a deadline the worst cycle is the one that matters.

The hot paths, per frame:

| | 1 ch | 2 ch | 6 ch |
| --- | ---: | ---: | ---: |
| `Ring.write` (producer thread) | 0.05 ns | 0.10 ns | 0.45 ns |
| `Ring.readPlanar` (graph cycle) | 1.21 ns | 1.38 ns | 2.79 ns |

The write is a pair of `memcpy`s and the read de-interleaves a sample at a time,
which is where the twenty-fold gap comes from. It has not been worth closing: a
1024-frame quantum costs about 1.4 us to de-interleave against a 21.3 ms
deadline.

For scale, `pw-cat` playing a stereo file at the same rate and quantum measured
6.5 us mean and 10.3 us peak BUSY against this library's 3.2 and 5.0 over the
same number of `pw-top` samples. That is not a like-for-like comparison — `pw-cat`
decodes S16LE and converts it through the adapter, where this library hands the
graph planar `f32` directly — so read it as the cost of each doing its own whole
job, not as the same work done twice.

Both numbers are from one desktop with other things running on it. Measure your
own.

## Fuzzing

Every byte this library parses arrives over a socket from another process, and
a PipeWire client trusts the daemon a long way: it maps memory the daemon names
and turns integers the daemon sends into pointers into that memory. So the
parsers are fuzzed as properties rather than examples — `tests/fuzz.zig` says
what has to hold for every input there is, and its header explains each one.

```
zig build test                              # the checked-in corpus
zig build fuzz-run -- --seconds 60          # the loop in tools/fuzz.zig
zig build fuzz-run -- --target pod --seconds 300
zig build fuzz --fuzz                       # Zig's own fuzzer
```

`zig build fuzz --fuzz` needs the devshell's Zig, which patches one line of the
0.16.0 standard library; without it no project with a fuzz test in it can build
a test executable at all. Even with the patch that release populates no table of
program counters, so its fuzzer runs without coverage feedback — which is why
`tools/fuzz.zig` exists. Both find things; neither is guided.

A failing input is written to `fuzz-findings/` and can be run again with
`zig build fuzz-run -- --input <file>`. A shape worth keeping belongs in the
corpus at the bottom of `tests/fuzz.zig`, where `zig build test` will run it
every time.

The registry decoders are fuzzed the same way, with one addition: a session
copies the daemon's strings out of a buffer that is about to be reused, so the
target checks both that nothing decoded points outside the message and that
nothing kept points back into it.

This turned up one real bug: `spa.Direction` was an exhaustive two-valued enum
that five event decoders cast a daemon-supplied `u32` into, so a malformed
message crashed the client. Every enum decoded from the wire is now
non-exhaustive. Each target has also been checked against a deliberately broken
copy of the code it watches, so that a run which finds nothing means something;
the header of `tests/fuzz.zig` lists what was broken and what caught it.

## Continuous integration

`.forgejo/workflows/test.yml` runs on every push: REUSE compliance, `zig fmt
--check`, a build of the examples, and the test suite, each through `nix develop`
so the toolchain is the one this flake pins. The build step is there because
`zig build test` compiles only the library and the fuzz targets, so a broken
example would otherwise go unnoticed.

## References cited

PipeWire's own documentation is the normative description of what goes over the
socket; this library was written against it rather than against `libpipewire`.

- PipeWire Project. 2025. "Native Protocol." In *PipeWire 1.6.8 Documentation*.
  <https://docs.pipewire.org/page_native_protocol.html>. The message header, the
  handshake, and the methods and events of every interface: Core, Registry,
  Client, Device, Factory, Link, Module, Node, Port, ClientNode, Metadata and
  Profiler.
- PipeWire Project. 2025. *PipeWire 1.6.8 API Reference*.
  <https://docs.pipewire.org/>. The constants the protocol is made of, taken
  from the headers it documents: `spa/param/param.h` for parameter ids,
  `spa/param/props.h` for the volume and mute properties, `spa/param/route.h`
  for a device route, `spa/utils/type.h` for object types, and
  `pipewire/node.h`, `pipewire/link.h` and `pipewire/extensions/metadata.h` for
  the interface versions and the states an object reports.

## Licence

MIT.
