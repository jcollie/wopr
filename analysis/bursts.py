# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

"""Find and measure the tone bursts in `src/bursts.zig` from the recording.

    python3 analysis/bursts.py reference/wopr-computer-humming.flac
    python3 analysis/bursts.py rendered.wav --plot /tmp/spec.png

Prints, for each of the two bands, when the bursts happen and how long they
last; then, for each one that has quiet on either side of it, what it is made
of. Point it at a rendering of `wopr` to check the synthesiser against the
same measurement.

Why it is not a spectrum. The bursts sit about 17 dB under the hum and last
a tenth of a second, so averaged over even one second they are gone. What
finds them is subtracting each frequency's own median over time from a
spectrogram: a steady partial goes to zero and anything that *happens*
stands out. `--plot` writes that picture, which is how the two bands were
found in the first place.

Why each burst is measured against a quiet stretch. The hum's own partials
reach past 290 Hz and its floor reaches further, so the spectrum of a burst
is mostly the spectrum of whatever was already there. Subtracting a nearby
quiet window leaves what the burst *added*. Doing it against two different
quiet windows is the check that matters: a component whose level moves when
the reference window moves is the background, not the burst.
"""

import argparse
import pathlib
import subprocess
import sys
import tempfile

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, hilbert, sosfiltfilt, stft

RATE = 44100

#: The two bands, wide enough to hold a fundamental that wanders half a
#: percent and narrow enough to exclude the other burst.
#:
#: The ping band starts at 1150 rather than 1120 on purpose. The pong has a
#: partial of its own at 1120 Hz, only 14 dB under its fundamental, so a band
#: that reaches down to it counts every pong as a ping as well -- which
#: inflated the rate by a third before anybody noticed.
BANDS = {"ping": (1150, 1250), "pong": (480, 580)}


def load(path):
    with tempfile.TemporaryDirectory() as tmp:
        wav = pathlib.Path(tmp) / "decoded.wav"
        subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
             "-i", str(path), "-ac", "1", "-ar", str(RATE),
             "-c:a", "pcm_s16le", str(wav)],
            check=True,
        )
        rate, data = wavfile.read(wav)
    return data.astype(np.float64) / 32768.0


def envelope(x, lo, hi):
    """The amplitude envelope of `x` between `lo` and `hi` hertz."""
    sos = butter(4, [lo, hi], "bandpass", fs=RATE, output="sos")
    env = np.abs(hilbert(sosfiltfilt(sos, x)))
    smooth = int(RATE * 0.004)
    return np.convolve(env, np.ones(smooth) / smooth, mode="same")


def find(x, lo, hi, rise_db, min_ms):
    """Stretches where the band sits `rise_db` above its own baseline."""
    db = 20 * np.log10(envelope(x, lo, hi) + 1e-12)
    base = np.percentile(db, 60)
    loud = db > base + rise_db
    out, i = [], 0
    while i < len(loud):
        if not loud[i]:
            i += 1
            continue
        j = i
        while j < len(loud) and loud[j]:
            j += 1
        if (j - i) / RATE * 1000 >= min_ms:
            out.append((i / RATE, (j - i) / RATE, db[i:j].max()))
        i = j
    return base, out


def components(x, t0, dur, quiet, limit_db=-28):
    """What the burst at `t0` adds over the quiet window starting at `quiet`."""
    n = int(dur * RATE)
    window = np.hanning(n)
    a = x[int(t0 * RATE):int(t0 * RATE) + n] * window
    b = x[int(quiet * RATE):int(quiet * RATE) + n] * window
    if len(a) < n or len(b) < n:
        return []
    size = 1 << 18
    power = (np.abs(np.fft.rfft(a, n=size)) ** 2
             - np.abs(np.fft.rfft(b, n=size)) ** 2)
    freqs = np.fft.rfftfreq(size, 1 / RATE)
    db = 10 * np.log10(np.maximum(power, 1e-30))
    keep = (freqs > 300) & (freqs < 8000)
    f, d = freqs[keep], db[keep] - db[keep].max()

    found = []
    for i in np.argsort(-d):
        if d[i] < limit_db:
            break
        if any(abs(f[i] - g) < 30 for g, _ in found):
            continue
        found.append((f[i], d[i]))
        if len(found) >= 8:
            break
    return found


def plot(x, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    f, t, z = stft(x, RATE, nperseg=2048, noverlap=2048 - 128)
    db = 20 * np.log10(np.abs(z) + 1e-12)
    keep = (f >= 150) & (f <= 2600)
    # Each frequency minus its own median over time: steady partials go grey,
    # and anything that happens stands out.
    d = db[keep] - np.median(db[keep], axis=1, keepdims=True)
    plt.figure(figsize=(16, 5))
    plt.pcolormesh(t, f[keep], d, vmin=2, vmax=20, cmap="inferno", shading="auto")
    plt.yscale("log")
    plt.ylabel("Hz")
    plt.xlabel("seconds")
    plt.title("each frequency minus its own median over time")
    plt.tight_layout()
    plt.savefig(path, dpi=90)
    print(f"wrote {path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", type=pathlib.Path)
    ap.add_argument("--from", dest="start", type=float, default=0.0)
    ap.add_argument("--to", dest="end", type=float, default=None)
    ap.add_argument("--rise", type=float, default=9.0,
                    help="dB above the band's baseline that counts as a burst")
    ap.add_argument("--min-ms", type=float, default=40.0)
    ap.add_argument("--plot", type=pathlib.Path)
    args = ap.parse_args()

    x = load(args.path)
    if args.end is not None:
        x = x[:int(args.end * RATE)]
    x = x[int(args.start * RATE):]
    span = len(x) / RATE
    if span < 1:
        sys.exit("need at least a second of audio")
    print(f"{args.path.name}: {span:.2f} s")

    if args.plot:
        plot(x, args.plot)

    everything = []
    for name, (lo, hi) in BANDS.items():
        base, found = find(x, lo, hi, args.rise, args.min_ms)
        rate_per_min = len(found) / span * 60
        print(f"\n### {name}: {lo}-{hi} Hz, baseline {base:.1f} dBFS")
        print(f"    {len(found)} bursts in {span:.1f} s = {rate_per_min:.0f} a minute")
        print(f"{'onset':>8} {'dur ms':>7} {'peak dBFS':>10} {'gap s':>7}")
        previous = None
        for t0, dur, peak in found:
            gap = "" if previous is None else f"{t0 - previous:7.3f}"
            print(f"{t0:8.3f} {dur * 1000:7.0f} {peak:10.1f} {gap}")
            previous = t0
        everything += [(t0, name, dur) for t0, dur, _ in found]

    everything.sort()
    if len(everything) > 1:
        gaps = np.diff([t for t, _, _ in everything])
        print(f"\nall bursts: {len(everything)} in {span:.1f} s "
              f"= {len(everything) / span * 60:.0f} a minute")
        print(f"  gaps: median {np.median(gaps):.3f} s, "
              f"{(gaps < 0.5).sum()} under 0.5 s, {(gaps >= 0.5).sum()} over")
        print("  NB: a count is not a firing rate. This cannot tell a burst")
        print("  from that burst's echo about 205 ms later, and it merges")
        print("  bursts that overlap -- so the count rises and falls with")
        print("  the echo settings and stops tracking the rate once the")
        print("  flurries get dense. It is for finding and measuring the")
        print("  bursts, which it does well; for rate, trust your ears.")

    # What each isolated burst is made of. A burst needs half a second of
    # nothing before it to have a quiet window to be measured against.
    print("\n### components of the bursts that stand alone")
    for i, (t0, name, dur) in enumerate(everything):
        before = t0 - (everything[i - 1][0] if i else 0.0)
        if i and before < 0.5:
            continue
        quiet = t0 - 0.45
        if quiet < 0:
            continue
        found = components(x, t0, dur, quiet)
        if not found:
            continue
        print(f"\n  {name} at {t0:.3f} s, against {quiet:.3f} s")
        for freq, level in found:
            print(f"     {freq:8.1f} Hz  {level:6.1f} dB")


if __name__ == "__main__":
    main()
