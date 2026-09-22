# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

"""Measure an audio file the way the synthesiser is specified.

Prints the handful of numbers `tests/acoustics.zig` asserts on, so that the
reference recording and a rendering of `wopr` can be held up next to each
other and read off the same way.

    python3 analysis/measure.py reference/wopr-computer-humming.flac --from 6 --to 12
    python3 analysis/measure.py /tmp/rendered.wav

Anything ffmpeg can decode will do; it is resampled to 44.1 kHz stereo first.
"""

import argparse
import pathlib
import subprocess
import sys
import tempfile

import numpy as np
from scipy.io import wavfile
from scipy.signal import welch


def a_weighting(f):
    """IEC 61672 A-weighting, in dB, for an array of frequencies.

    Here because loudness is the question a hiss complaint asks and energy is
    not: the ear is roughly 20 dB more sensitive at 3 kHz than at 125 Hz, so
    a floor that measures 30 dB below the hum can still be the first thing
    anybody hears.
    """
    f = np.maximum(f, 1.0)
    f2 = f * f
    ra = ((12194.0**2 * f2**2)
          / ((f2 + 20.6**2)
             * np.sqrt((f2 + 107.7**2) * (f2 + 737.9**2))
             * (f2 + 12194.0**2)))
    return 20 * np.log10(ra) + 2.0

RATE = 44100


def load(path, start, end):
    """Decode `path` to 44.1 kHz stereo float and return (left, right)."""
    with tempfile.TemporaryDirectory() as tmp:
        wav = pathlib.Path(tmp) / "decoded.wav"
        subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
             "-i", str(path), "-ac", "2", "-ar", str(RATE),
             "-c:a", "pcm_s16le", str(wav)],
            check=True,
        )
        rate, data = wavfile.read(wav)
    x = data.astype(np.float64) / 32768.0
    a = int(start * rate)
    b = len(x) if end is None else min(len(x), int(end * rate))
    if b - a < rate:
        sys.exit(f"{path}: need at least a second between --from and --to")
    return x[a:b, 0], x[a:b, 1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path", type=pathlib.Path)
    ap.add_argument("--from", dest="start", type=float, default=0.0,
                    help="skip this many seconds (the reference fades in)")
    ap.add_argument("--to", dest="end", type=float, default=None)
    args = ap.parse_args()

    left, right = load(args.path, args.start, args.end)
    mono = (left + right) / 2

    rms = np.sqrt((mono**2).mean())
    peak = np.abs(np.concatenate([left, right])).max()
    print(f"level          {20 * np.log10(rms):7.2f} dBFS RMS")
    print(f"peak           {20 * np.log10(peak + 1e-30):7.2f} dBFS")
    print(f"crest factor   {20 * np.log10(peak / rms):7.2f} dB")

    # Channel geometry. The reference measures 0.971 and -16.4 dB.
    corr = np.corrcoef(left, right)[0, 1]
    mid, side = (left + right) / 2, (left - right) / 2
    ratio = 20 * np.log10(np.sqrt((side**2).mean()) / np.sqrt((mid**2).mean()))
    print(f"L/R corr       {corr:7.3f}")
    print(f"side vs mid    {ratio:7.2f} dB")

    # Where the energy is. The reference puts 97.8% in the 80-160 Hz octave.
    f, p = welch(mono, RATE, nperseg=1 << 15)
    total = np.trapezoid(p, f)
    print("octave bands (share of total energy)")
    edges = [20, 40, 80, 160, 315, 630, 1250, 2500, 5000, 10000, 20000]
    for lo, hi in zip(edges[:-1], edges[1:]):
        m = (f >= lo) & (f < hi)
        e = np.trapezoid(p[m], f[m])
        print(f"  {lo:6d}-{hi:<6d} {10 * np.log10(e / total + 1e-20):7.2f} dB  {100 * e / total:6.2f}%")

    # How loud the part above the hum is, A-weighted. This is the number a
    # "there is a hiss" report is about, and the one an octave band table
    # does not show: it weights 2-6 kHz roughly 20 dB above the hum's own
    # octave, which is what the ear does.
    above = f >= 400
    aw = 10 ** (a_weighting(f) / 10)
    hiss = np.trapezoid(p[above] * aw[above], f[above])
    print(f"hiss, A-wtd    {10 * np.log10(hiss / total):7.2f} dB  (>=400 Hz, relative to total energy)")

    # The strongest partial. The reference peaks at 124.94 Hz.
    band = (f > 80) & (f < 160)
    print(f"peak partial   {f[band][np.argmax(p[band])]:7.2f} Hz")

    # The throb: the reference's envelope spectrum peaks at 3.70 Hz.
    env = np.convolve(np.abs(mono), np.ones(441) / 441, mode="same")
    env = env - env.mean()
    fe, pe = welch(env, RATE, nperseg=1 << 16)
    m = (fe > 1.0) & (fe < 30)
    print(f"throb          {fe[m][np.argmax(pe[m])]:7.2f} Hz")
    print(f"throb depth    {np.sqrt((env**2).mean()) / np.abs(mono).mean():7.3f}")

    # How steady the level is over seconds. The reference's loud stretch
    # varies by about 0.75 dB standard deviation from half-second to
    # half-second; a synthesiser whose partials wander too deeply in level
    # gives itself away here long before anything else measures differently.
    block = RATE // 2
    blocks = [mono[i:i + block] for i in range(0, len(mono) - block + 1, block)]
    levels = np.array([20 * np.log10(np.sqrt((b**2).mean()) + 1e-30) for b in blocks])
    print(f"level drift    {levels.std():7.2f} dB sd, {np.ptp(levels):.2f} dB range"
          f" over {len(levels)} half-seconds")


if __name__ == "__main__":
    main()
