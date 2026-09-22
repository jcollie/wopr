# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

"""Extract the partial table in `src/partials.zig` from the reference recording.

    python3 analysis/partials.py reference/wopr-computer-humming.flac

Prints Zig, ready to paste over the body of `partials.wopr`. Running it again
on the same file gives the same numbers, which is the point: the table is a
measurement with a method behind it rather than a set of values somebody
liked the sound of.

The method, and why each part of it is there:

  * The window is 6.0 s to 12.0 s. The recording fades in over the first two
    seconds and out over the last three, and a taper is amplitude modulation:
    it smears every partial into a skirt and moves the peaks. What is left is
    six seconds steady to within a decibel.

  * A Hann window, because the partials are 1-3 Hz apart and within 26 dB of
    each other. A rectangular window's sidelobes are 13 dB down, so the
    strongest partial alone would bury its neighbours in leakage.

  * Zero-padded to 2^21. Padding does not add resolution -- six seconds of
    signal resolves what six seconds resolves -- but it does interpolate the
    spectrum finely enough for the next step to work on.

  * Each peak's frequency and height come from fitting a parabola through
    the peak bin and its two neighbours, in decibels, which is where the
    hundredths of a hertz come from.

  * Peaks within 0.8 Hz of a louder one are dropped as the same partial seen
    twice, and the table stops 34 dB below the strongest. Below that the
    spectrum stops being peaks on a floor and becomes the floor, which the
    synthesiser reproduces as filtered noise instead.
"""

import argparse
import pathlib
import subprocess
import sys
import tempfile

import numpy as np
from scipy.io import wavfile

RATE = 44100
PAD = 1 << 21
#: Peaks quieter than this, relative to the strongest, are floor rather than
#: partial.
FLOOR_DB = -34.0
#: Two peaks closer together than this are one partial found twice.
MIN_SPACING_HZ = 0.8
#: Outside this band there is nothing above the floor.
BAND_HZ = (70.0, 320.0)


def load(path, start, end):
    with tempfile.TemporaryDirectory() as tmp:
        wav = pathlib.Path(tmp) / "decoded.wav"
        subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
             "-i", str(path), "-ac", "1", "-ar", str(RATE),
             "-c:a", "pcm_s16le", str(wav)],
            check=True,
        )
        rate, data = wavfile.read(wav)
    x = data.astype(np.float64) / 32768.0
    a, b = int(start * rate), int(end * rate)
    if b > len(x):
        sys.exit(f"{path}: only {len(x) / rate:.2f} s long, need {end} s")
    return x[a:b]


def peaks(x):
    """Every spectral peak in the band, as (hz, db) with db relative to the loudest."""
    spectrum = np.abs(np.fft.rfft(x * np.hanning(len(x)), n=PAD))
    freqs = np.fft.rfftfreq(PAD, 1 / RATE)
    band = (freqs >= BAND_HZ[0]) & (freqs <= BAND_HZ[1])
    f, mag = freqs[band], 20 * np.log10(spectrum[band] + 1e-30)
    step = f[1] - f[0]

    found = []
    for i in range(1, len(mag) - 1):
        if not (mag[i] > mag[i - 1] and mag[i] >= mag[i + 1]):
            continue
        # Parabolic interpolation through three points in decibels: the
        # vertex is the partial's true frequency and height.
        a, b, c = mag[i - 1], mag[i], mag[i + 1]
        denom = a - 2 * b + c
        shift = 0.5 * (a - c) / denom if denom else 0.0
        found.append((f[i] + shift * step, b - 0.25 * (a - c) * shift))
    return found


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", type=pathlib.Path)
    ap.add_argument("--from", dest="start", type=float, default=6.0)
    ap.add_argument("--to", dest="end", type=float, default=12.0)
    args = ap.parse_args()

    found = sorted(peaks(load(args.path, args.start, args.end)), key=lambda p: -p[1])
    loudest = found[0][1]

    kept = []
    for hz, db in found:
        rel = db - loudest
        if rel < FLOOR_DB:
            break
        if any(abs(hz - other) < MIN_SPACING_HZ for other, _ in kept):
            continue
        kept.append((hz, rel))
    kept.sort()

    print(f"// {len(kept)} partials from {args.path.name}, "
          f"{args.start:g}-{args.end:g} s, down to {FLOOR_DB:g} dB")
    for hz, rel in kept:
        print(f"    .{{ .freq = {hz:.3f}, .amp = {10 ** (rel / 20):.5f} }}, "
              f"// {rel:6.2f} dB")


if __name__ == "__main__":
    main()
