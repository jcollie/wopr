<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-wav

A RIFF/WAVE reader and writer for Zig, written against the 1991 Microsoft and
IBM specification of the container (see [References cited](#references-cited)).
It is sans-IO: it reads from a `std.Io.Reader`, writes to a `std.Io.Writer`,
and allocates nothing unless asked to, so a file, a socket, a pipe and a slice
of memory are all the same thing to it.

The container is [zig-riff](https://git.jcollie.dev/jeff/zig-riff)'s and not
this library's. RIFF is what a WAVE file *is* — twelve bytes of header, then
chunks with their lengths and their pad bytes — and WAVE is one of the forms
built on it, alongside AVI and WebP. So the chunk walk lives there, and what
is here is only what makes a WAVE a WAVE: the `fmt ` chunk, the samples in
`data`, and the conversion between those samples and numbers.

```zig
const wav = @import("wav");

var input: std.Io.Reader = .fixed(bytes);
var file: wav.Reader = try .init(&input);

const samples = try file.readAlloc(gpa, f32, 48_000 * 60);
defer gpa.free(samples);
```

API documentation, generated from the doc comments, is published at
<https://jeff.jcollie.page/zig-wav/>. The doc comments carry most of the
explanation of *why* each piece is shaped the way it is, so they are worth
reading before the source.

## Where this lives

The repository has three homes, all carrying the same `main`.

```console
$ git clone https://git.jcollie.dev/jeff/zig-wav.git
$ rad clone rad:z3MwHMYtCZcDk1dSj4ncfJi2f6tSw
```

* Forgejo, at <https://git.jcollie.dev/jeff/zig-wav>, which is where the CI
  runs and where the issues are.
* Tangled, at <https://tangled.org/jcollie.dev/zig-wav>.
* Radicle, as `rad:z3MwHMYtCZcDk1dSj4ncfJi2f6tSw`. A Radicle repository is
  findable only by its ID, so that string is the whole of what somebody needs
  to seed or clone it.

## What it does

**Reading** walks the chunks as far as the samples and stops there. Integer
PCM at 8, 16, 24 and 32 bits and IEEE float at 32 and 64 are decoded, in a
plain `WAVE_FORMAT_PCM` or `WAVE_FORMAT_IEEE_FLOAT` header or in a
`WAVE_FORMAT_EXTENSIBLE` one carrying either of those as its sub-format GUID.
Chunks that are neither `fmt ` nor `data` — `LIST`, `fact`, `JUNK`, whatever a
recorder felt like adding — are stepped over, along with the pad byte an
odd-length chunk carries and does not count. A `data` chunk whose length was
never filled in, which is what a file written to a pipe looks like, is read to
the end of the stream.

**Writing** produces the canonical 44 byte header and one `data` chunk, at any
of those same six widths. Nothing has to be known in advance: a length that
was not known when the header went out can be filled in afterwards by a caller
that can seek, and a length that will never be known is written as
`0xFFFFFFFF`, which is the convention for a WAVE stream of indefinite length —
a player reads until the pipe closes rather than stopping at a length that was
a guess.

**Not implemented**: the compressed payloads, which is to say A-law, µ-law,
ADPCM and the rest of the tag registry; the big-endian `RIFX` container, whose
lengths are the other way round while a WAVE's own fields are little-endian by
definition; and RF64 and BW64, which is how a file longer than four gigabytes
says so. Each is refused by name — `error.UnsupportedFormat`, `error.Rifx`,
`error.Rf64` — rather than misread. The channel mask of an extensible header
is read past rather than kept, since what this library writes has nowhere to
put it.

## Using it

```console
$ zig fetch --save git+https://git.jcollie.dev/jeff/zig-wav.git
```

```zig
const wav = b.dependency("wav", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("wav", wav.module("wav"));
```

That brings `zig-riff` with it, which is the only thing either of them
depends on beyond the standard library.

### Reading

`Reader.init` reads as far as the first sample and leaves the header in
`header`. `read` then fills a buffer with interleaved samples and returns how
many it wrote, which is always a whole number of frames and is short only at
the end of the audio.

```zig
var input: std.Io.Reader = .fixed(bytes);
var file: wav.Reader = try .init(&input);

std.debug.print("{d} Hz, {d} channels, {t}\n", .{
    file.header.sample_rate,
    file.header.channels,
    file.header.format,
});

var samples: [4096]f32 = undefined;
while (true) {
    const n = try file.read(f32, &samples);
    if (n == 0) break;
    consume(samples[0..n]);
}
```

`readAlloc` does the whole thing in one allocation instead, and takes a limit
in frames. The limit is not a formality: a `data` chunk may declare four
gigabytes and deliver nothing, so the declared length is a hint for the first
allocation and never a promise. A caller that needs to know whether the file
had more than it accepted asks for one frame more than it will keep.

```zig
const samples = try file.readAlloc(gpa, f32, 48_000 * 60);
defer gpa.free(samples);
```

### Writing

```zig
var out: wav.Writer = try .init(sink, .{
    .sample_rate = 48_000,
    .channels = 2,
    .format = .s16,
    .frames = samples.len / 2,
});
try out.write(f32, samples);
try out.finish();
```

`finish` writes the pad byte that a `data` chunk of odd length needs — the one
place in a WAVE file where the file's length and the chunk's are not a fixed
distance apart, since the pad is counted in the first and not in the second.
Only eight bit audio, and 24 bit mono with an odd number of frames, can land
on an odd length at all, which is exactly what makes it worth having a call
for: a bug that appears in one file in a thousand is worse than one that
appears in all of them. It is safe to call whatever was written, and safe to
call twice.

Leaving `frames` out says the length is not known, which is what a stream
going to a pipe looks like. A caller that can seek puts it right afterwards,
from `sizes`, which reports what the two length fields should say for what was
actually written:

```zig
var out: wav.Writer = try .init(sink, .{ .sample_rate = 48_000, .channels = 2, .format = .s16 });
try out.write(f32, samples);
if (out.sizes()) |s| {
    try file.seekTo(wav.riff_size_offset);
    try file.writer().writeInt(u32, s.riff, .little);
    try file.seekTo(wav.data_size_offset);
    try file.writer().writeInt(u32, s.data, .little);
}
```

`writeHeader` and `writeSamples` are the same two jobs without a `Writer` in
between, for a caller managing the container itself. `render` writes the 44
bytes into a buffer and touches no stream at all.

### Samples

Samples come out and go in as `f32`, `f64` or `i32`, whatever the file holds.
The choice is the caller's and the conversion is done on the way past.

The float types are **normalized**: full scale is ±1 whatever the file's width,
which is what a signal processing path wants. `i32` is the sample **exactly as
the file holds it** — an `.s16` file hands back values in [-32768, 32767] —
which is what a lossless path wants, since nothing is scaled and nothing is
rounded. A float *file* read as `i32`, or written from one, is scaled as
though it were `.s32`, there being no narrower width in the file to take the
scale from.

Two conventions are worth knowing about, because they are the ones that turn a
loud passage into a click if they are got wrong:

* Full scale is the **negative** extreme, `-(2^(n-1))`, because that is the
  value an integer of *n* bits actually has. So −1.0 maps exactly and +1.0
  maps one step short of the positive extreme rather than one step past it.
* A sample outside the format's range is **clipped, not wrapped**. Wrapping a
  sample that went a hair over full scale turns a moment of loudness into a
  full-scale discontinuity; a clipped sample is inaudible where a wrapped one
  is the only thing anybody would hear. A sample that is not a number becomes
  silence, which is the only honest answer and is also the one that does not
  invoke undefined behaviour on the way to an integer.

`encode` and `decode` are that conversion on its own, slice to slice, for code
that has the bytes already and only wants them as numbers.

## How it is tested

`zig build test` runs everything: the unit tests beside each piece, and the
fuzz targets in `tests/fuzz.zig` over their seed corpus and over every prefix
of it, which is the cheapest way to reach every "the file ends here" branch
there is.

What the fuzz targets assert is three properties.

* **Return, do not crash.** An error is a fine answer and so is a file full of
  samples; a panic, an out-of-bounds index, a leak, or an allocation the size
  of a declared length is a failure in whatever embedded this library rather
  than in the file that caused it. A WAVE file is very often something a
  stranger sent, and its two length fields, its channel count and its chunk
  sizes are all numbers that this library divides by, multiplies and allocates
  from.
* **What was read, written back and read again is the same samples.** A reader
  and a writer drift apart easily, because nothing else compares them, and a
  width read one way and written another is invisible until somebody's
  recording comes back quiet, inverted or an octave out.
* **Decoding what was encoded is a fixed point**, for every format, on bytes
  that were never a sample of anything.

`zig build crosscheck` is the check that does not compare this library
against itself: ffmpeg writes a WAVE file at each width and channel count,
the library reads it and writes a copy, and ffmpeg decodes both and compares.
It is the only way to catch a reader and a writer agreeing on something the
format does not say, and what it reaches beyond the six widths is the shape of
a file nobody writes by hand — a `LIST INFO` chunk after the format chunk, an
18 byte format chunk with an empty extension, a `fact` chunk beside it, and an
extensible header with a channel mask on anything past two channels.

```console
$ zig build fuzz-run                        # until interrupted
$ zig build fuzz-run -- --iterations 500000
$ zig build fuzz-run -- --seconds 600 --target roundtrip
```

That loop is ours rather than Zig's, for the reason `tools/fuzz.zig` sets out
at length: Zig 0.16.0 cannot build a test executable in fuzz mode without a
one line patch to its own standard library, which the devshell applies, and
even then nothing populates the table of program counters, so there is no
coverage feedback to be had. What this has instead is a corpus of files that
are already valid and a mutator that knows where a WAVE file keeps its
lengths, which for a format that is mostly lengths agreeing with each other is
most of the way there. It found a real defect within the first few hundred
inputs: a batch size computed with `@min` against a literal, which narrows its
result type, so the multiplication that followed was done in sixteen bits and
overflowed at a few hundred channels.

The cross-check has earned its place too. Moving the container walk to
`zig-riff` turned up a file this library had been writing wrongly all along:
a `data` chunk of odd length needs a pad byte, that byte is counted in the
file's length and not in the chunk's, and neither the byte nor the count was
there. Nothing in the round trip noticed, because the reader was as wrong as
the writer; ffmpeg's files were what said otherwise.

## Building

```console
$ nix develop
$ zig build test          # the whole suite
$ zig build               # compile the library
$ zig build check         # compile what the suite does not, without running it
$ zig build crosscheck    # round-trip ffmpeg's WAVE files through the library
$ zig build docs          # API documentation into zig-out/docs
$ zig build docs-serve    # and read it at http://127.0.0.1:8000/
```

The documentation has to be served rather than opened: the viewer Zig emits
fetches `sources.tar` and `main.wasm` at runtime, and a browser refuses either
from a `file://` page.

## What is where

| | |
| --- | --- |
| `src/root.zig` | the module: what is public, and what it all means together |
| `src/format.zig` | the six sample formats, and the conversion to and from numbers |
| `src/header.zig` | what a file says about its samples, and the 44 bytes that say it |
| `src/Reader.zig` | the walk to the samples, and reading them out of `data` |
| `src/Writer.zig` | the header, the samples, and the length fields afterwards |
| `tests/fuzz.zig` | the fuzz targets and their corpus, which are ordinary tests too |
| `tools/fuzz.zig` | the loop that drives them, and why it is not Zig's |
| `tools/crosscheck.zig` | reads a file and writes it back: the shortest complete example |
| `tools/crosscheck.sh` | what asks ffmpeg whether the two agree |
| `tools/docs_server.zig` | what `zig build docs-serve` runs |

## Licence

MIT, and the project follows the [REUSE](https://reuse.software/)
specification: every file says what it is licensed under, and `reuse lint`
checks that they all do.

## References cited

* European Broadcasting Union. (2009). *Specification of the Broadcast Wave
  Format: MBWF/RF64, an extended file format for audio* (EBU Tech 3306).
  <https://tech.ebu.ch/docs/tech/tech3306.pdf> — how a WAVE file longer than
  four gigabytes says so: the `RIFF` tag becomes `RF64`, the 32 bit lengths
  are left at `0xFFFFFFFF`, and the real 64 bit ones go in a `ds64` chunk.
  Cited for what this library deliberately does not do — it refuses such a
  file by name rather than reading it as a WAVE one whose lengths happen to
  say "unknown".

* Fleischman, E. (1998). *WAVE and AVI codec registries* (RFC 2361). Internet
  Engineering Task Force. <https://www.rfc-editor.org/info/rfc2361> — the
  registry of `wFormatTag` values: `WAVE_FORMAT_PCM` (1),
  `WAVE_FORMAT_IEEE_FLOAT` (3), and the compressed ones such as A-law (6) and
  µ-law (7) that this library refuses with `error.UnsupportedFormat` rather
  than decoding.

* Microsoft Corporation. (2020). *Extensible wave-format descriptors*.
  Microsoft Learn.
  <https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/extensible-wave-format-descriptors>
  — `WAVE_FORMAT_EXTENSIBLE`: the 22 byte extension, the valid bits per
  sample, the channel mask, and the sub-format GUIDs whose first two bytes are
  the format tag and whose remaining fourteen
  (`00000000-0010-8000-00aa00389b71`) every subtype the specification defines
  shares. `src/Reader.zig` checks those fourteen before believing the tag.

* Microsoft Corporation & IBM Corporation. (1991). *Multimedia Programming
  Interface and Data Specifications 1.0*.
  <https://www.tactilemedia.com/info/MCI_Control_Info.html> — the RIFF
  container and the `WAVE` form: chunk headers and the pad byte that an odd
  length chunk carries and does not count, the `fmt ` chunk's fields, the
  `data` chunk, the canonical 44 byte header this library writes, and the
  field widths that make a length of more than four gigabytes unrepresentable.
  Also that 8 bit samples are unsigned and every wider one is signed, which is
  the single most surprising thing about the format.
