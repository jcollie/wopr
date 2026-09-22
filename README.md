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
the way an unregulated motor does, with the room's ping and pong over the
top of it.

Run from a terminal it plays, straight into PipeWire as a node of its own.
Redirected or piped it writes a WAVE stream instead.

```console
$ wopr
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

## The ping and the pong

Something in the machine room pings and pongs, in irregular little flurries —
four inside a second, then nothing for two — and both carry an echo off the
room. `src/bursts.zig` has them, measured the same way the hum was, and
`analysis/bursts.py` is how they were found.

Not with a spectrum: they sit 17 dB under the hum and last a tenth of a
second, so averaged over even one second they are gone. What finds them is
subtracting each frequency's own median over time from a spectrogram, which
turns a steady partial grey and leaves anything that *happens* standing out.
Each burst was then measured against a nearby quiet stretch, twice, against
two different quiet windows — a component whose level moves when the
reference window moves is the background, not the burst.

|  | ping | pong |
| --- | ---: | ---: |
| fundamental | 1188 Hz | 527 Hz |
| other partials | 2376 Hz, −24 dB | 822, 978, 1120, 1405 Hz |
| level under the hum | 19 dB | 17 dB |
| attack / hold / release | 3 / 72 / 12 ms | 4 / 86 / 28 ms |

The interesting one is the pong. Its partials land at 1.56, 1.86, 2.12 and
2.66 times its fundamental — nowhere near whole numbers — which is what a
struck metal object sounds like and is the whole reason it reads as a *pong*
rather than as a low beep. The ping is very nearly a pure tone: one partial
24 dB down at twice the fundamental, and nothing else.

Neither is struck-and-decaying, which is the other thing worth knowing
before changing them. Both are flat-topped: the ping reaches full level
within 5 ms, holds within 3 dB for 70 ms, and is gone 10 ms later. The
envelope is a raised cosine at each end rather than a corner, because at
this level a click would be the only part anybody heard.

**The echo** is one delay line per channel with a little feedback — 205 ms on
the left, 232 ms on the right, different because a room is not symmetric and
two equal delays put the repeat in the middle of the head where the dry
burst already is. The repeats are damped at 2.6 kHz, as they would be off
real surfaces. The hum does not go through it: a continuous sound convolved
with its own echo is the same continuous sound very slightly thicker.

`EchoShape.level_db` sets how *loud* the repeat is and `feedback` sets how
*many* there are, and confusing the two is worth avoiding. The first version
had 0.42 of feedback, which put a third and fourth repeat 14 and 21 dB down.
In the recording those are under the noise floor; here, where by default
there is no floor, they are audible — and the whole thing sounded like it
was running fast when the burst rate was right.

Rate is `--bursts N`, in bursts a minute, or `off`. The default of 70 is not
quite a measurement and it is worth saying so: `analysis/bursts.py` counts
112 a minute in the recording, but it cannot tell a burst from that burst's
echo 205 ms later, and several of the gaps it reports are about 205 ms.
Reading those as repeats puts the real figure somewhere between 56 and 90,
and 70 is where it was left after listening.

## How close it gets

Left is the reference recording over its steady stretch, 6.0 s to 12.0 s.
Then twenty seconds of `wopr -s 42`, at the default and with the optional
noise floor turned on. All measured by `analysis/measure.py`.

| | recording | `wopr` | `wopr --hiss -16` |
| --- | ---: | ---: | ---: |
| strongest partial | 125.16 Hz | 125.16 Hz | 125.16 Hz |
| energy in 80–160 Hz | 98.08% | 99.65% | 98.11% |
| 20–40 Hz | −46.31 dB | −51.67 dB | −46.08 dB |
| 40–80 Hz | −29.78 dB | −45.51 dB | −33.10 dB |
| 160–315 Hz | −19.24 dB | −24.87 dB | −19.02 dB |
| 315–630 Hz | −24.23 dB | −58.93 dB | −23.02 dB |
| 630–1250 Hz | −29.08 dB | −74.59 dB | −32.49 dB |
| 1250–2500 Hz | −33.58 dB | −83.32 dB | −52.70 dB |
| noise floor, A-weighted | −24.98 dB | −66.59 dB | −28.08 dB |
| channel correlation | 0.971 | 0.971 | 0.963 |
| crest factor | 11.28 dB | 10.55 dB | 10.90 dB |
| level drift, ½ s to ½ s | 1.20 dB sd | 0.91 dB sd | 0.91 dB sd |
| throb depth | 0.542 | 0.461 | 0.455 |

The tonal part — which is to say the hum — matches closely and is the same
in both `wopr` columns. What the middle one leaves out is the recording's
broadband floor, which is off by default; the next section is why.

Of the rest, three differences are deliberate.

* **Level.** The recording is normalised to full scale, peaking at −0.08 dBFS.
  `wopr` defaults to −18 dBFS RMS, which peaks around −7 and leaves room for
  whatever it is mixed under. `--gain` moves it.
* **Above 2.5 kHz.** The recording has a bump at 3 kHz and a cliff above
  4 kHz, which is what a lossy encoder leaves behind rather than anything the
  machine room did. Nothing here reproduces it.
* **Channel balance.** The recording's left channel is 1.6 dB above its
  right, which is why its side channel measures 16.4 dB under its mid where
  `wopr` measures 18.3 at the same correlation. That is a property of how the
  recording was made; reproducing it would mean shipping a lopsided mix.

The throb comes out a little shallower than the recording's. The beating is
there and at the right rate — that is what `tests/acoustics.zig` pins — but
the recording's six second window also carries a slow swell that a twenty
second render averages away.

## The noise floor, and why it is off

The recording has a broadband floor under the hum, `wopr` can reproduce it
to within 2 dB from 50 Hz to 800 Hz, and it does not do so unless asked. Two
rounds of listening got it there, and both are worth writing down, because
each is a way of being wrong that the measurements happily called right.

**A cascade of one-pole lowpasses has no stopband.** Its response flattens
out towards Nyquist at `(1-a)/(1+a)`, about 30 dB down per pole, and a band
narrow enough to shape a floor like this then needs 20 dB of make-up gain to
reach the level asked for. The first version was shaped that way: it matched
every octave band below 1 kHz to within 2 dB and hissed audibly at 4–8 kHz,
where the ear is at its most sensitive and where a band total, dominated by
the octave beneath it, shows nothing at all. Two Butterworth biquads have a
double zero at Nyquist and keep falling, which fixed it.

**A smooth, steady floor is heard as hiss whatever its level.** With the
stopband sorted there was still a quieter one, and the reason is character
rather than energy. Measured in third-octaves, the recording's content above
1 kHz has a spectral flatness of 0.11 to 0.33 at its peaks and swings 27 dB
from frame to frame: it is discrete and intermittent, not a floor at all.
Synthetic noise is flatness 0.98 and holds within 1 dB. Matching the
recording's energy up there with smooth noise matches the measurement and
not the sound, so the fit is now against 50 Hz to 800 Hz — where the
recording really does have a floor — and constrained to stay well under it
above 1 kHz.

**And then off entirely.** What settled it is not acoustics. A room already
has a floor — fans, traffic, the building — and something that runs for
hours as a background bed is heard *in* that room rather than instead of it.
A second floor on top of the listener's own is the one thing here that
people notice and dislike, and the partials do not need it to sound like a
machine. `--hiss -28` is present without being audible as hiss; `--hiss -16`
is the recording's own floor, for a dry mix that has none of its own.

`analysis/measure.py` reports the floor A-weighted as well as by octave,
because loudness is the question a hiss complaint asks and energy is not:
the ear is roughly 20 dB more sensitive at 3 kHz than at 125 Hz.

## Using it

Build it with Nix, or with Zig from the devshell:

```console
$ nix build            # the binary lands at result/bin/wopr
$ nix run . -- --duration 30 --output hum.wav
$ nix develop -c zig build -Doptimize=ReleaseFast
```

The Zig dependency is vendored for Nix by
[zon2nix](https://git.jcollie.dev/jeff/zon2nix) into `build.zig.zon.nix`,
which is committed. Adding, removing or updating one is the whole of
regenerating it:

```console
$ nix develop -c zon2nix --16 --nix=build.zig.zon.nix build.zig.zon
```

Run from a terminal, `wopr` plays. Redirected or piped it writes a WAVE
stream to stdout instead and never stops, which is the shape that goes into
something else.

```console
$ wopr                                          # plays
$ wopr --sink alsa_output.usb-audio -g -24      # plays somewhere particular
$ wopr -d 30 -o hum.wav                         # renders thirty seconds
$ wopr --raw | aplay -f S16_LE -r 44100 -c 2    # somebody else plays
$ wopr | ffmpeg -i - -c:a flac hum.flac         # somebody else encodes
```

Deciding by whether stdout is a terminal keeps every pipeline working and
stops a bare `wopr` from spilling binary across a terminal. `--play` and
`--output` force it either way, and giving both is refused rather than
guessed at.

Nothing paces the output against a clock in either mode. The graph consumes
frames at the rate it plays them and the ring fills up behind it; a pipe does
the same thing with a player on the far end. A file or `/dev/null` takes them
as fast as they can be made, which is what you want when rendering.

| option | |
| --- | --- |
| `-p, --play` | play through PipeWire; the default from a terminal |
| `--sink NAME` | play to this sink rather than the default one |
| `-o, --output PATH` | write a file here instead |
| `-d, --duration SECS` | stop after this long; the default is never |
| `-r, --rate HZ` | sample rate, 8000 to 768000 (default 44100) |
| `-c, --channels N` | 1 or 2 (default 2) |
| `-f, --format FMT` | `s16`, `s24` or `f32` (default `s16`); written files only |
| `--raw` | headerless PCM rather than a WAVE stream |
| `-g, --gain DB` | output level in dBFS RMS (default −18) |
| `-w, --width W` | stereo spread, 0 to 1 (default 0.6) |
| `-n, --hiss DB` | add a broadband noise floor, in dB under the hum; off by default |
| `-b, --bursts N` | pings and pongs a minute (default 70), or `off` |
| `-s, --seed N` | seed the randomness; the default comes from the clock |

An endless WAVE stream declares its length as `0xFFFFFFFF`, which is the
convention for one: a player reads until the pipe closes rather than stopping
at a length that was a guess. Give `--duration` and the header carries the
real length, because then there is one.

### Playing

Playback goes through [zig-pipewire](https://git.jcollie.dev/jeff/zig-pipewire),
which speaks PipeWire's wire protocol over the daemon's socket directly — no
`libpipewire`, no C. `wopr | pw-play -` worked and still does, but it makes
the hum a file that something else happens to be reading: it shows up in
`wpctl status` as `pw-play`, the volume belongs to `pw-play`, and the WAVE
header has to claim a length it does not have. Opening the graph directly
makes it a node called `wopr`, which a mixer can see, move to another sink
and turn down like anything else.

```console
$ wopr &
$ wpctl status | grep wopr
  112. wopr
$ wpctl set-volume 112 0.3
```

The graph has one sample rate and everything in it lives with that rate, so
`--rate` is a request. The stream is opened first and the synthesiser built
afterwards at whatever the graph settled on, which is printed when it starts
— asking an additive synthesiser for a different rate costs nothing, where
resampling it would put a resampler in the way. `--sink` is a request too:
it is written into the session manager's metadata, which may decline it and
link to the default instead.

PipeWire is a Linux daemon reached with Linux syscalls, so the dependency is
`lazy` in `build.zig.zon` and is not fetched at all for any other target;
`src/play_unsupported.zig` is compiled in its place and `--play` becomes a
message rather than a build failure. The library module deliberately does
not depend on any of it — a program that renders into its own audio callback
should not acquire a PipeWire dependency by linking a hum.

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
the drift and shimmer depths and their time constants, the shape and level
of each noise band, the burst table and how often it fires, the echo, the
output level and the microphone spacing that sets the stereo width. Each one
is documented with what it was measured at and why.

The same seed and options give byte-identical output, which is what makes
`tests/acoustics.zig` possible; the block size the caller happens to use does
not change the stream, which that file also checks.

## The analysis

Two scripts, both needing only the devshell:

```console
$ nix develop -c python3 analysis/partials.py reference/wopr-computer-humming.flac
$ nix develop -c python3 analysis/measure.py  reference/wopr-computer-humming.flac --from 6 --to 12
$ nix develop -c python3 analysis/measure.py  hum.wav
$ nix develop -c python3 analysis/bursts.py   reference/wopr-computer-humming.flac --plot /tmp/spec.png
```

`partials.py` prints `src/partials.zig`'s table, and its docstring gives the
method and the reason for each step of it. `measure.py` prints the numbers in
the comparison above, for the recording or for a rendering, so the two can be
held up next to each other and read off the same way. `bursts.py` finds the
ping and the pong, times them and says what they are made of; `--plot`
writes the median-subtracted spectrogram that found them in the first place.

One caveat on `bursts.py`, in its output as well as here: a count is not a
firing rate. It cannot tell a burst from that burst's echo, and it merges
bursts that overlap, so its count moves with the echo settings and stops
tracking the rate once the flurries get dense. For finding and measuring the
bursts it is the right tool; for how often they should arrive, ears.

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

`zig build run` plays it, since the build runner inherits the terminal:
`zig build run -- --duration 10 --bursts off`, and anything else after the
`--`.

`tests/acoustics.zig` is where a claim about the *sound* gets written down: it
renders seconds of audio and measures the spectrum, the octave balance, the
channel correlation, the throb rate, the crest factor, the frequencies of the
ping and the pong, the echo's delay, and the absence of a click at a
control-block boundary. The tolerances are loose on purpose — they
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
