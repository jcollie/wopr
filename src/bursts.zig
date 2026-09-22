// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The two tone bursts heard over the hum, measured the same way the hum was.
//!
//! Something in the machine room pings and pongs. In the reference recording
//! (see the README) they arrive in irregular little flurries — four inside a
//! second, then nothing for two — and both carry an echo off the room.
//!
//! Finding them took a spectrogram rather than a spectrum, because neither
//! is loud: they sit about 17 dB under the hum, and averaged over even a
//! second they vanish into it. `analysis/bursts.py` does what was done by
//! hand: subtract each frequency's own median over time, which turns a
//! steady partial grey and leaves anything that *happens* standing out, then
//! band-pass around what is left and look at the envelope.
//!
//! Each burst below was measured from several occurrences, with a nearby
//! quiet stretch subtracted from each so that the hum's own partials do not
//! get counted as part of it. Only components that appear in *every*
//! occurrence are kept: the recording is dense, and a partial that shows up
//! once is the background moving.
//!
//! The interesting result is the pong. Its partials are at 1.56, 1.86, 2.12
//! and 2.66 times its fundamental — nowhere near whole numbers — which is
//! what a struck metal object sounds like and is the whole reason it reads
//! as a *pong* rather than as a low beep. The ping, by contrast, is very
//! nearly a pure tone: one partial 24 dB down at twice the fundamental, and
//! nothing else.

const std = @import("std");

const partials = @import("partials.zig");

/// One component of a burst. Amplitudes are relative to the first partial.
pub const Partial = partials.Partial;

/// A tone burst: what it is made of, how loud it is, and how it starts and
/// stops.
///
/// The envelope is a flat-topped one — a raised-cosine attack, a hold at
/// full level, a raised-cosine release — because that is what the recording
/// shows. These are not struck-and-decaying sounds: the ping reaches full
/// level within 5 ms, holds within 3 dB for 70 ms, and is gone 10 ms later.
pub const Burst = struct {
    /// At most `max_partials` of them.
    partials: []const Partial,

    /// Peak level, in dB relative to the hum's RMS.
    level_db: f64,

    /// Raised-cosine attack, in seconds. Short enough to have a transient in
    /// it and long enough not to click.
    attack_s: f64,

    /// How long it holds at full level, in seconds.
    hold_s: f64,

    /// Raised-cosine release, in seconds.
    release_s: f64,

    /// How much `hold_s` varies from one occurrence to the next, as a
    /// fraction either side. The recording's are between 42 ms and 264 ms,
    /// so this is not a detail: bursts of identical length sound like a
    /// sample being retriggered, which is the thing this project exists to
    /// avoid.
    hold_spread: f64,

    /// Relative chance of a flurry being made of these.
    weight: f64,
};

/// No burst may have more partials than this, so that a voice can hold their
/// phases without allocating.
pub const max_partials = 8;

/// The higher one. Very nearly a pure tone at 1188 Hz.
///
/// Measured across five occurrences, whose fundamentals came out at 1182.8,
/// 1185.2, 1187.2, 1189.5 and 1190.6 Hz — so 1188 Hz with a little spread,
/// rather than anything exact. The only other component that survives
/// background subtraction is at 2339 Hz, 24 dB down, which is near enough
/// twice the fundamental to be its second harmonic.
pub const ping: Burst = .{
    .partials = &.{
        .{ .freq = 1188.0, .amp = 1.0 },
        .{ .freq = 2376.0, .amp = 0.063 }, // -24 dB
    },
    .level_db = -19.0,
    .attack_s = 0.003,
    .hold_s = 0.072,
    .release_s = 0.012,
    .hold_spread = 0.45,
    .weight = 2.0,
};

/// The lower one. Inharmonic, and struck-metal for it.
///
/// Measured across three occurrences at 524.2, 524.9 and 528.9 Hz. The four
/// partials above it land at 1.56, 1.86, 2.12 and 2.66 times that, which is
/// not a harmonic series and is not close to one.
pub const pong: Burst = .{
    .partials = &.{
        .{ .freq = 527.0, .amp = 1.0 },
        .{ .freq = 822.0, .amp = 0.200 }, // -14 dB, 1.56x
        .{ .freq = 978.0, .amp = 0.158 }, // -16 dB, 1.86x
        .{ .freq = 1120.0, .amp = 0.200 }, // -14 dB, 2.12x
        .{ .freq = 1405.0, .amp = 0.141 }, // -17 dB, 2.66x
    },
    .level_db = -17.0,
    .attack_s = 0.004,
    .hold_s = 0.086,
    .release_s = 0.028,
    .hold_spread = 0.35,
    .weight = 1.0,
};

/// Both of them, which is what `Hum` uses unless told otherwise.
pub const wopr: []const Burst = &.{ ping, pong };

/// How often the bursts arrive, and in what pattern.
///
/// They do not arrive at a steady rate. `analysis/bursts.py` counts fifteen
/// of them in the recording's usable eight seconds, and the fourteen gaps
/// between them are plainly bimodal: eleven from 0.08 s to 0.47 s, and
/// three of 1.21 s, 1.48 s and 2.45 s. So they come in flurries — of four,
/// two, five and four — with a long wait in between, and that is what this
/// describes.
pub const Timing = struct {
    /// Seconds between bursts within a flurry, drawn uniformly. The
    /// recording's eleven short gaps run from 0.08 s to 0.47 s.
    gap_s: [2]f64 = .{ 0.08, 0.42 },

    /// Seconds between flurries, drawn uniformly. Its three long ones are
    /// 1.21 s, 1.48 s and 2.45 s.
    rest_s: [2]f64 = .{ 1.0, 2.4 },

    /// Mean number of bursts in a flurry. The count is geometric, so short
    /// flurries are common and long ones happen; the recording's four are
    /// of 4, 2, 5 and 4.
    flurry: f64 = 3.75,

    /// Chance that a burst inside a flurry is the *other* kind. The
    /// recording's flurries are nearly all one kind, but at 7.34 s a ping
    /// and a pong land together.
    stray: f64 = 0.12,

    /// Everything above scaled so that bursts arrive this often, or `null`
    /// to use those figures as they stand.
    ///
    /// The three fields above describe the *pattern* -- flurries of about
    /// four, a second or two apart -- and this sets the *rate*, which is
    /// the thing anybody actually wants to change.
    ///
    /// The default is not quite a measurement, and it is worth being honest
    /// about why. `analysis/bursts.py` counts 112 a minute in the
    /// recording's usable stretch, but it cannot tell a burst from that
    /// burst's echo 205 ms later, and several of the gaps it reports are
    /// about 205 ms. Reading those as repeats puts the real rate somewhere
    /// between 56 and 90. 70 sits in that range and is where it was left
    /// after listening; the first attempt shipped 112 and was audibly too
    /// busy.
    per_minute: ?f64 = 70.0,

    /// The mean seconds between bursts that `gap_s`, `rest_s` and `flurry`
    /// describe, before `per_minute` is applied.
    pub fn meanInterval(t: Timing) f64 {
        const gap = (t.gap_s[0] + t.gap_s[1]) / 2;
        const rest = (t.rest_s[0] + t.rest_s[1]) / 2;
        // A flurry of n bursts costs (n-1) gaps and one rest.
        return ((t.flurry - 1) * gap + rest) / t.flurry;
    }

    /// What to multiply every interval by to hit `per_minute`.
    pub fn scale(t: Timing) f64 {
        const want = t.per_minute orelse return 1;
        if (!(want > 0)) return 1;
        return (60.0 / want) / t.meanInterval();
    }
};

test "the tables are within what a voice can hold" {
    for (wopr) |b| {
        try std.testing.expect(b.partials.len > 0);
        try std.testing.expect(b.partials.len <= max_partials);
        try std.testing.expectEqual(@as(f64, 1.0), b.partials[0].amp);
        for (b.partials[1..]) |p| try std.testing.expect(p.amp > 0 and p.amp < 1);
        try std.testing.expect(b.weight > 0);
        try std.testing.expect(b.hold_spread >= 0 and b.hold_spread < 1);
    }
}

test "the pong is inharmonic and the ping is not" {
    // The claim the timbre rests on. If an edit ever rounds the pong's
    // partials onto a harmonic series it stops being a struck object and
    // starts being an organ pipe, and this is where that gets caught.
    const f0 = pong.partials[0].freq;
    for (pong.partials[1..]) |p| {
        const ratio = p.freq / f0;
        const nearest = @round(ratio);
        try std.testing.expect(@abs(ratio - nearest) > 0.1);
    }

    const ping_f0 = ping.partials[0].freq;
    for (ping.partials[1..]) |p| {
        const ratio = p.freq / ping_f0;
        try std.testing.expectApproxEqAbs(@round(ratio), ratio, 0.02);
    }
}

test "the default rate is inside what the recording supports" {
    // `analysis/bursts.py` counts 112 a minute but cannot separate a burst
    // from its echo, which puts the real figure between 56 and 90. Outside
    // that range this is no longer the recording's rate, whatever it sounds
    // like.
    const t: Timing = .{};
    const per_minute = 60.0 / (t.scale() * t.meanInterval());
    try std.testing.expect(per_minute >= 56 and per_minute <= 90);
}

test "the pattern on its own is in the right neighbourhood" {
    // `per_minute` scales the intervals, so a pattern that was wildly off
    // would still hit the rate -- by stretching the flurries into
    // something that no longer sounds like flurries. This is the guard.
    const raw: Timing = .{ .per_minute = null };
    const per_minute = 60.0 / raw.meanInterval();
    try std.testing.expect(per_minute > 70 and per_minute < 160);
    try std.testing.expectEqual(@as(f64, 1.0), raw.scale());
}

test "per_minute scales the intervals to match" {
    for ([_]f64{ 6, 30, 112, 600 }) |want| {
        const t: Timing = .{ .per_minute = want };
        try std.testing.expectApproxEqRel(60.0 / want, t.scale() * t.meanInterval(), 1e-9);
    }
}
