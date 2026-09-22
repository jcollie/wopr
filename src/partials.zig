// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What the WOPR hum is made of, measured rather than invented.
//!
//! The numbers below come from a fifteen second recording of the machine
//! room hum (see the README's references), analysed in `analysis/partials.py`.
//! The recording fades in and settles, so the measurement window is the six
//! seconds from 6.0 s to 12.0 s, where the level is steady to within a
//! decibel. That window is windowed with a Hann taper, transformed at 2^21
//! points — about 0.02 Hz a bin, far finer than the spacing being resolved —
//! and each peak's true frequency and height recovered by fitting a parabola
//! to the three bins around it, which is what buys frequencies to the
//! hundredth of a hertz from a six second sample.
//!
//! The shape that comes out is worth saying plainly, because it decides the
//! whole design of the synthesiser:
//!
//! * **It is not a harmonic series.** There is no fundamental that the rest
//!   are multiples of. It is a dense cluster of unrelated partials between
//!   91 Hz and 160 Hz, which is what a room full of independent motors,
//!   transformers and fans sounds like rather than what one vibrating thing
//!   sounds like. A synthesiser built on harmonics of 124 Hz would be the
//!   wrong sound however carefully it was voiced.
//!
//! * **97.8% of the energy is in the 80–160 Hz octave.** Everything above it
//!   is more than 19 dB down. This is a *low* hum in a sense most synthetic
//!   hums are not.
//!
//! * **The beating is free.** The strongest partials sit about 3.7 Hz apart
//!   — 121.20, 124.94, 128.65, and 136.32, 140.05 — so summing them produces
//!   the slow throb heard in the recording, whose envelope spectrum peaks at
//!   3.70 Hz with a harmonic at 15.1 Hz, without any modulator being applied.
//!   `Hum` therefore has no tremolo in it: adding one would be modulating
//!   something that already pulses.
//!
//! Amplitudes are linear and relative to the strongest partial, which is
//! defined as 1.0; the decibel figure in each comment is the same number and
//! is the one that was actually read off the spectrum.

/// One component of the hum: a frequency in hertz and a linear amplitude
/// relative to the loudest partial in the set.
pub const Partial = struct {
    freq: f64,
    amp: f64,
};

/// The measured WOPR machine room hum. Twenty-eight partials, ordered by
/// frequency, spanning 98.8 Hz to 289.6 Hz.
///
/// The cut is at 34 dB below the peak. Below that the spectrum stops being
/// peaks on a floor and becomes the floor, which `Hum` reproduces as filtered
/// noise instead — see `Hum.Options.hiss_level`.
pub const wopr: []const Partial = &.{
    .{ .freq = 91.111, .amp = 0.04345 }, // -27.24 dB
    .{ .freq = 95.163, .amp = 0.02134 }, // -33.42 dB
    .{ .freq = 98.826, .amp = 0.05324 }, // -25.48 dB
    .{ .freq = 101.700, .amp = 0.02202 }, // -33.14 dB
    .{ .freq = 102.505, .amp = 0.04382 }, // -27.17 dB
    .{ .freq = 105.359, .amp = 0.06022 }, // -24.40 dB
    .{ .freq = 106.238, .amp = 0.18901 }, // -14.47 dB
    .{ .freq = 107.730, .amp = 0.02466 }, // -32.16 dB
    .{ .freq = 108.754, .amp = 0.08807 }, // -21.10 dB
    .{ .freq = 109.784, .amp = 0.26347 }, // -11.59 dB
    .{ .freq = 110.587, .amp = 0.09812 }, // -20.17 dB
    .{ .freq = 111.651, .amp = 0.02172 }, // -33.26 dB
    .{ .freq = 112.573, .amp = 0.05501 }, // -25.19 dB
    .{ .freq = 113.487, .amp = 0.25532 }, // -11.86 dB
    .{ .freq = 114.313, .amp = 0.11226 }, // -19.00 dB
    .{ .freq = 116.352, .amp = 0.04797 }, // -26.38 dB
    .{ .freq = 117.987, .amp = 0.06450 }, // -23.81 dB
    .{ .freq = 119.136, .amp = 0.03158 }, // -30.01 dB
    .{ .freq = 120.124, .amp = 0.13828 }, // -17.18 dB
    .{ .freq = 121.202, .amp = 0.39796 }, //  -8.00 dB
    .{ .freq = 123.006, .amp = 0.11076 }, // -19.11 dB
    .{ .freq = 123.955, .amp = 0.29061 }, // -10.73 dB
    .{ .freq = 124.942, .amp = 1.00000 }, //   0.00 dB
    .{ .freq = 126.069, .amp = 0.12325 }, // -18.18 dB
    .{ .freq = 127.755, .amp = 0.06757 }, // -23.40 dB
    .{ .freq = 128.647, .amp = 0.17748 }, // -15.02 dB
    .{ .freq = 130.563, .amp = 0.05039 }, // -25.95 dB
    .{ .freq = 131.523, .amp = 0.05820 }, // -24.70 dB
    .{ .freq = 132.399, .amp = 0.17472 }, // -15.15 dB
    .{ .freq = 133.430, .amp = 0.04511 }, // -26.91 dB
    .{ .freq = 134.643, .amp = 0.04588 }, // -26.77 dB
    .{ .freq = 136.318, .amp = 0.12313 }, // -18.19 dB
    .{ .freq = 137.284, .amp = 0.03363 }, // -29.46 dB
    .{ .freq = 138.097, .amp = 0.07552 }, // -22.44 dB
    .{ .freq = 139.196, .amp = 0.17944 }, // -14.92 dB
    .{ .freq = 140.046, .amp = 0.41584 }, //  -7.62 dB
    .{ .freq = 141.254, .amp = 0.03297 }, // -29.64 dB
    .{ .freq = 142.172, .amp = 0.05055 }, // -25.92 dB
    .{ .freq = 143.791, .amp = 0.13018 }, // -17.71 dB
    .{ .freq = 145.884, .amp = 0.03514 }, // -29.08 dB
    .{ .freq = 147.720, .amp = 0.08830 }, // -21.08 dB
    .{ .freq = 148.619, .amp = 0.02144 }, // -33.37 dB
    .{ .freq = 151.468, .amp = 0.03335 }, // -29.54 dB
    .{ .freq = 152.641, .amp = 0.03831 }, // -28.33 dB
    .{ .freq = 153.484, .amp = 0.03398 }, // -29.37 dB
    .{ .freq = 154.291, .amp = 0.02675 }, // -31.45 dB
    .{ .freq = 155.214, .amp = 0.03411 }, // -29.34 dB
    .{ .freq = 158.990, .amp = 0.02249 }, // -32.96 dB
    .{ .freq = 166.446, .amp = 0.02223 }, // -33.06 dB
    .{ .freq = 173.946, .amp = 0.02027 }, // -33.86 dB
    .{ .freq = 181.634, .amp = 0.02317 }, // -32.70 dB
    .{ .freq = 185.353, .amp = 0.02091 }, // -33.59 dB
    .{ .freq = 222.022, .amp = 0.02013 }, // -33.92 dB
    .{ .freq = 222.936, .amp = 0.04079 }, // -27.79 dB
    .{ .freq = 225.688, .amp = 0.02505 }, // -32.02 dB
    .{ .freq = 289.639, .amp = 0.05524 }, // -25.16 dB
};

const std = @import("std");

test "the table is ordered by frequency and normalised to its peak" {
    var peak: f64 = 0;
    for (wopr, 0..) |p, i| {
        if (i > 0) try std.testing.expect(p.freq > wopr[i - 1].freq);
        try std.testing.expect(p.amp > 0 and p.amp <= 1.0);
        peak = @max(peak, p.amp);
    }
    try std.testing.expectEqual(@as(f64, 1.0), peak);
}

test "the energy is where the measurement said it was" {
    // 97.8% of the recording's energy is in the 80-160 Hz octave. The table
    // is only the tonal part, so it should agree at least this closely: if
    // an edit ever moves the weight out of that octave, the result is no
    // longer the sound that was measured.
    var total: f64 = 0;
    var octave: f64 = 0;
    for (wopr) |p| {
        total += p.amp * p.amp;
        if (p.freq >= 80 and p.freq < 160) octave += p.amp * p.amp;
    }
    try std.testing.expect(octave / total > 0.99);
}
