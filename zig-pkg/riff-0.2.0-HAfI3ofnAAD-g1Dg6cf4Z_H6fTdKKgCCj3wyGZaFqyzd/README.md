<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-riff

A sans-I/O reader and writer for **RIFF**, the container underneath WAV, AVI,
WebP, DLS, RMID and a good deal else.

RIFF is a container and not a format. A file is twelve bytes of header —
`RIFF`, a length, and a four-character *form type* saying what kind of file
this is — and then a sequence of chunks, each a four-character identifier, a
length, and that many bytes. Everything that makes a WAV a WAV is in the
chunks; everything in this library is the walk between them.

The [API documentation](https://jeff.jcollie.page/zig-riff/) is generated from
the doc comments in the source, which is where the reasoning lives.

## Using it

```zig
var reader: riff.Reader = try .init(&stream);
if (!reader.form.is("WEBP")) return error.NotWebp;

while (try reader.next()) |chunk| {
    if (chunk.is("VP8L")) {
        var buf: [64]u8 = undefined;
        try decodeLossless(reader.payload(&buf));
    }
    // Anything left unread is stepped over by the next `next`.
}
```

Sans-I/O: everything reads through a caller-supplied `std.Io.Reader` and
writes through a `std.Io.Writer`. Nothing here opens a file, so a walk over a
network stream is the same code as one over memory, and the whole library is
testable without touching a disk.

Add it with:

```console
zig fetch --save git+https://git.jcollie.dev/jeff/zig-riff.git
```

and depend on the module named `riff`.

## What it handles, and why each is worth saying

### The pad byte

**A chunk is padded to an even length, and the pad byte is not counted in the
chunk's length.** This is the single most common way to write a RIFF parser
that works on most files and desynchronises on some, because a file whose
chunks all happen to have even lengths never exercises it. Every length here
goes through `Chunk.padded`, and the walk steps over the pad byte without the
caller having to know it is there.

### Nesting

A `LIST` chunk holds a four-character list type and then more chunks, which is
how AVI stores almost everything. `enter` descends into one, and `next` climbs
back out when it runs out — so a caller writes one loop rather than a
recursive walk:

```zig
while (try reader.next()) |chunk| {
    if (chunk.is("LIST")) {
        const kind = try reader.enter();
        if (kind.is("movi")) { ... }
        continue;
    }
}
```

Bytes consumed come out of every open level at once, since the levels nest,
and a chunk claiming more than the container holding it has left is refused
rather than believed.

### Both byte orders

Almost every RIFF file is little-endian and begins `RIFF`. The big-endian
variant begins `RIFX`, is rare and real, and costs one branch. The
*identifiers* are characters and are never byte-swapped — which is the thing
most likely to be got wrong when adding the second order to a parser that only
had the first.

### Truncation

A file that stops on a chunk boundary is read up to where it stops rather than
refused: a recorder killed mid-write leaves a header promising more than
arrived, and what did arrive is still worth having. A length that runs past
its container is a different thing and is an error.

### Lengths that were never filled in

A writer whose output is a pipe cannot seek back to fill in the file's length,
or the length of the chunk it is still writing. The convention is to write
`0xffffffff` and let the end of the stream say where things stop — which is
what ffmpeg does, byte for byte, when you ask it for `-f wav -` — and several
encoders leave the file's length at zero instead.

Both are read here as "not known" rather than believed: the walk is then
bounded by the stream, and a chunk whose length was never filled in runs to
the end of whatever holds it. `riff.unknown_length` is that value and
`Chunk.isUnknownLength` is how a caller tells such a chunk from one that
really does claim four gigabytes — which matters, because for a WAVE file
that chunk is the audio and "how much of it is there" is the caller's next
question.

A file that says nothing about its length is therefore readable, and a file
that says something impossible is still refused.

### RF64, by name

RF64 is the WAV extension for files past four gigabytes: it replaces the
`RIFF` tag, writes `0xffffffff` where the length goes, and puts the real
64-bit sizes in a `ds64` chunk. It is **not** handled, and it is recognised
and refused as `error.Rf64` rather than read as a corrupt RIFF, because a
caller that meets one should be told what it is.

## Writing

```zig
var writer: riff.Writer = .init("WAVE");
defer writer.deinit(gpa);

try writer.chunk(gpa, "fmt ", header_bytes);
try writer.openList(gpa, "INFO");
try writer.chunk(gpa, "INAM", "a name");
try writer.close();
try writer.chunk(gpa, "data", samples);

try writer.finish(w);
```

Everything is held until `finish`, and it has to be: the header carries the
length of everything after it and a `LIST` carries the length of everything
inside it, and neither is known until the thing is complete. A forward-only
writer either buffers or seeks backwards, and this one is sans-I/O and cannot
seek.

## Where this lives

```console
git clone https://git.jcollie.dev/jeff/zig-riff.git
```

- <https://git.jcollie.dev/jeff/zig-riff>
- <https://tangled.org/jcollie.dev/zig-riff>

It is on [Radicle](https://radicle.xyz/) as
`rad:z3QNJRPpssgFMdfjV8Pgsopix3qE4`, which is the only thing a peer needs to
find it — a Radicle repository is discoverable by its identifier and by
nothing else:

```console
rad clone rad:z3QNJRPpssgFMdfjV8Pgsopix3qE4
```

## Testing

```console
nix develop -c zig build test --summary all
nix develop -c zig fmt --check .
nix develop -c reuse lint
```

The tests are the awkward cases rather than the happy path: a chunk of odd
length followed by one a parser that forgot the pad byte would read a byte
early, a `LIST` walked by the same loop as its siblings, a big-endian file
whose identifiers must *not* be swapped, a chunk longer than the file holding
it, and a truncated recording. There is also a property test over arbitrary
bytes — that the walk terminates, stays inside the input, and never reports
more content than arrived — which is the claim that matters for a parser whose
every length is chosen by whoever wrote the file.

## References cited

- Microsoft Corporation, & IBM Corporation. (1991, August). *Multimedia
  Programming Interface and Data Specifications 1.0*.
  <https://www.tactilemedia.com/info/MCI_Control_Info.html>
- Microsoft Corporation. *Resource Interchange File Format Services*. Win32
  API documentation, Microsoft Learn.
  <https://learn.microsoft.com/en-us/windows/win32/multimedia/resource-interchange-file-format-services>
- European Broadcasting Union. (2009, September). *Specification of the
  Broadcast Wave Format: A format for audio data files — MBWF/RF64: An
  extended File Format for Audio* (EBU Tech 3306).
  <https://tech.ebu.ch/docs/tech/tech3306.pdf>

## Licence

MIT, and [REUSE](https://reuse.software/) compliant: every file carries its
own copyright and licence, or is covered by `REUSE.toml`.
