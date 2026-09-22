<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# wopr

A synthesiser for the low humming of the WOPR machine room in *WarGames*
(1983) — the bed of sound under Crystal Palace, which the film leaves running
in almost every scene it cuts to.

It renders indefinitely and never repeats. There is no sample and no loop
point: the hum is built back up out of the fifty-six sine partials that a
recording of it measures, each one wandering slightly in frequency and level
the way an unregulated motor does, over a floor of shaped noise.

```console
$ wopr | pw-play -
```

API documentation, generated from the doc comments, is published at
<https://jeff.jcollie.page/wopr/>. The doc comments carry most of the
explanation of *why* the synthesiser is shaped the way it is, so they are
worth reading before the source.

## Where this lives

The repository has three homes, all carrying the same `main`.

```console
$ git clone https://git.jcollie.dev/jeff/wopr.git
$ rad clone rad:z2hpahcXcgvnjmbvU2gDmNSJQRWBB
```

* Forgejo, at <https://git.jcollie.dev/jeff/wopr>, which is where the CI runs
  and where the issues are.
* Tangled, at <https://tangled.org/jcollie.dev/wopr>.
* Radicle, as `rad:z2hpahcXcgvnjmbvU2gDmNSJQRWBB`. A Radicle repository is
  findable only by its ID, so that string is the whole of what somebody needs
  to seed or clone it.

## What the recording says

Everything in `src/partials.zig` was measured rather than chosen, from a
fifteen second recording of the hum (see [References cited](#references-cited)).
The measurement is reproducible: `analysis/partials.py` prints that table.

Three facts out of it decided the whole design.

**It is not a harmonic series.** There is no fundamental the rest are
multiples of. It is a dense cluster of unrelated partials between 91 Hz and
160 Hz — a room full of independent motors, transformers and fans, not one
vibrating thing. Nothing subtractive reaches that spectrum, so a filtered
sawtooth was never going to be the right sound however carefully it was
voiced. Hence additive synthesis, and hence a table of frequencies with no
pattern in it.

**97.8% of the energy is in the 80–160 Hz octave.** Everything above it is
more than 19 dB down. This is a *low* hum in a way most synthetic hums are
not, and getting the octave balance right matters more than anything in the
top four octaves.

**The throb is free.** The strongest partials sit about 3.7 Hz apart —
121.20, 124.94, 128.65 and 136.32, 140.05 — so summing them beats at 3.7 Hz
without any modulator. The synthesiser has no tremolo in it, deliberately:
adding one would be modulating something that already pulses, and it sounds
like it.

## How close it gets

Left is the reference recording over its steady stretch, 6.0 s to 12.0 s.
Right is twenty seconds of `wopr -s 42`. Both measured by
`analysis/measure.py`.

| | recording | `wopr` |
| --- | ---: | ---: |
| strongest partial | 125.16 Hz | 125.16 Hz |
| energy in 80–160 Hz | 98.08% | 98.48% |
| 160–315 Hz | −19.24 dB | −20.50 dB |
| 315–630 Hz | −24.23 dB | −24.80 dB |
| 630–1250 Hz | −29.08 dB | −29.84 dB |
| 1250–2500 Hz | −33.58 dB | −37.14 dB |
| channel correlation | 0.971 | 0.972 |
| crest factor | 11.28 dB | 10.73 dB |
| level drift, ½ s to ½ s | 1.20 dB sd | 0.78 dB sd |
| throb depth | 0.542 | 0.418 |

Three of those are deliberately not matched, and it is worth saying which.

* **Level.** The recording is normalised to full scale, peaking at −0.08 dBFS.
  `wopr` defaults to −18 dBFS RMS, which peaks around −7 and leaves room for
  whatever it is mixed under. `--gain` moves it.
* **Above 2.5 kHz.** The recording has a bump at 2.5–5 kHz and a cliff above
  it, which is what a lossy encoder leaves behind rather than anything the
  machine room did. `wopr` is 12 dB quieter there and nothing is missing.
* **Channel balance.** The recording's left channel is 1.6 dB above its
  right, which is why its side channel measures 16.4 dB under its mid where
  `wopr` measures 18.5 at the same correlation. That is a property of how the
  recording was made; reproducing it would mean shipping a lopsided mix.

The throb comes out a little shallower than the recording's. The beating is
there and at the right rate — that is what `tests/acoustics.zig` pins — but
the recording's six second window also carries a slow swell that a twenty
second render averages away.

## Using it

Build it with Nix, or with Zig from the devshell:

```console
$ nix build            # the binary lands at result/bin/wopr
$ nix run . -- --duration 30 --output hum.wav
$ nix develop -c zig build -Doptimize=ReleaseFast
```

By default it writes a WAVE stream to stdout and never stops, which is the
shape that pipes into a player. Nothing paces the output against a clock: a
player consumes samples at the rate it plays them and the pipe fills up
behind it, so the backpressure does the pacing for free, while a file takes
them as fast as they can be made.

```console
$ wopr | pw-play -                              # PipeWire
$ wopr --raw | aplay -f S16_LE -r 44100 -c 2    # ALSA
$ wopr -d 30 -o hum.wav                         # thirty seconds to a file
$ wopr -c 1 -f f32 --raw | ...                  # mono float, no header
```

| option | |
| --- | --- |
| `-o, --output PATH` | write here instead of stdout |
| `-d, --duration SECS` | stop after this long; the default is never |
| `-r, --rate HZ` | sample rate, 8000 to 768000 (default 44100) |
| `-c, --channels N` | 1 or 2 (default 2) |
| `-f, --format FMT` | `s16`, `s24` or `f32` (default `s16`) |
| `--raw` | headerless PCM rather than a WAVE stream |
| `-g, --gain DB` | output level in dBFS RMS (default −18) |
| `-w, --width W` | stereo spread, 0 to 1 (default 0.6) |
| `-s, --seed N` | seed the randomness; the default comes from the clock |

An endless WAVE stream declares its length as `0xFFFFFFFF`, which is the
convention for one: a player reads until the pipe closes rather than stopping
at a length that was a guess. Give `--duration` and the header carries the
real length, because then there is one.

Fifty-six oscillators in stereo is about 3.7% of one core at 44.1 kHz in a
`ReleaseFast` build — twenty-seven times faster than real time — so leaving
it running costs nothing, and rendering an hour to a file takes a couple of
minutes.

## Using it as a library

`Hum` allocates once, renders into a caller's buffer of `f32`, and cannot
fail after `init` — so it can be driven from an audio callback as readily as
written to a file.

```zig
const wopr = @import("wopr");

var hum: wopr.Hum = try .init(gpa, .{ .sample_rate = 48_000 });
defer hum.deinit(gpa);

var frames: [2048]f32 = undefined; // interleaved, 1024 stereo frames
hum.render(&frames);
```

`Hum.Options` exposes every number the model has: the partial table itself,
the drift and shimmer depths and their time constants, the two noise bands,
the output level and the microphone spacing that sets the stereo width. Each
one is documented with what it was measured at and why.

The same seed and options give byte-identical output, which is what makes
`tests/acoustics.zig` possible; the block size the caller happens to use does
not change the stream, which that file also checks.

## The analysis

Two scripts, both needing only the devshell:

```console
$ nix develop -c python3 analysis/partials.py reference/wopr-computer-humming.flac
$ nix develop -c python3 analysis/measure.py  reference/wopr-computer-humming.flac --from 6 --to 12
$ nix develop -c python3 analysis/measure.py  hum.wav
```

`partials.py` prints `src/partials.zig`'s table, and its docstring gives the
method and the reason for each step of it. `measure.py` prints the numbers in
the comparison above, for the recording or for a rendering, so the two can be
held up next to each other and read off the same way.

The recording itself is **not** in this repository. It is a clip of a
commercial film's soundtrack, and `reference/` is gitignored; the References
cited section says what it is and where it came from, and the Zotero entry
holds a copy. Nothing in the build or the test suite needs it — what the
scripts establish is asserted instead by `tests/acoustics.zig`, which renders
its own audio and measures that.

## Development

```console
$ nix develop
$ zig build test --summary all   # unit tests and the acoustic ones
$ zig build check                # compile what the tests do not
$ zig build docs-serve           # read the API docs at localhost:8000
$ zig fmt --check .
$ reuse lint
```

`tests/acoustics.zig` is where a claim about the *sound* gets written down: it
renders seconds of audio and measures the spectrum, the octave balance, the
channel correlation, the throb rate, the crest factor and the absence of a
click at a control-block boundary. The tolerances are loose on purpose — they
are there to catch a *different sound*, not to pin the output bit for bit.

## Licence

MIT. The project follows the [REUSE](https://reuse.software/) standard and
`reuse lint` passes.

## References cited

* Harris, F. J. (1978). On the use of windows for harmonic analysis with the
  discrete Fourier transform. *Proceedings of the IEEE*, 66(1), 51–83.
  <https://doi.org/10.1109/PROC.1978.11455> — why the partial extraction uses
  a Hann window: the partials are 1–3 Hz apart and up to 34 dB unequal, and a
  rectangular window's first sidelobe is 13 dB down, so the strongest partial
  alone would bury its neighbours in leakage.

* Microsoft Corporation & IBM Corporation. (1991). *Multimedia Programming
  Interface and Data Specifications 1.0*.
  <https://www.tactilemedia.com/info/MCI_Control_Info.html> — the RIFF
  container and the `WAVE` form: the canonical 44 byte header `src/wav.zig`
  writes, the `wFormatTag` values for integer and float PCM, and the field
  widths that make a length of more than 4 GiB unrepresentable.

* Smith, J. O., & Serra, X. (1987). PARSHL: An analysis/synthesis program for
  non-harmonic sounds based on a sinusoidal representation. In *Proceedings of
  the 1987 International Computer Music Conference* (pp. 290–297).
  <https://ccrma.stanford.edu/~jos/parshl/> — the parabolic interpolation of a
  spectral peak, which is where `analysis/partials.py` gets frequencies to the
  hundredth of a hertz out of a six second window.

* Welch, P. (1967). The use of fast Fourier transform for the estimation of
  power spectra: A method based on time averaging over short, modified
  periodograms. *IEEE Transactions on Audio and Electroacoustics*, 15(2),
  70–73. <https://doi.org/10.1109/TAU.1967.1161901> — the averaged
  periodogram that `analysis/measure.py` reads the octave band energies off,
  through `scipy.signal.welch`.

* *WOPR computer humming* [Audio recording]. 101soundboards.com. — the
  reference recording, `wopr-computer-humming.flac`: fifteen seconds of
  machine room hum lifted from the film, FLAC, 44.1 kHz, 24 bit, stereo. It
  fades in over the first two seconds and out over the last three, so the
  measurement window is the steady stretch from 6.0 s to 12.0 s. Not
  redistributed here; the Zotero entry holds a copy.

* Badham, J. (Director). (1983). *WarGames* [Film]. Metro-Goldwyn-Mayer /
  United Artists. — the source of the sound.
