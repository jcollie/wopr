// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! An endless WOPR machine room hum.
//!
//! The model is additive and deliberately small: one sine oscillator per
//! measured partial (see `partials`), two noise generators for the floor
//! beneath them, and a slow random wander applied to the frequency and
//! amplitude of each oscillator so that the sound never settles into a loop.
//! There is no filter bank, no reverb and no tremolo, because the recording
//! does not call for any:
//!
//! * The throb is not a tremolo. The loudest partials sit about 3.7 Hz apart,
//!   so summing them beats at 3.7 Hz on its own. Modulating the sum as well
//!   would be doing the same job twice, audibly.
//! * The hum is not a filtered sawtooth, or anything else with a fundamental.
//!   Its partials are not harmonically related, so nothing subtractive
//!   reaches the same spectrum. `partials.zig` says more about why.
//!
//! What the wander buys is the absence of a period. Twenty-eight fixed sines
//! repeat exactly whenever their frequencies happen to share one, and the ear
//! finds that quickly and stops hearing a machine. Letting the whole bank
//! drift together by a fraction of a percent — the way an unregulated motor
//! does, and the way the recording does, whose strongest partial wanders
//! between 123.6 Hz and 125.2 Hz across twelve seconds — removes the period
//! without moving the pitch anywhere the ear can follow.
//!
//! ```zig
//! var hum: Hum = try .init(gpa, .{});
//! defer hum.deinit(gpa);
//!
//! var frames: [2048]f32 = undefined; // interleaved, 1024 stereo frames
//! while (true) {
//!     hum.render(&frames);
//!     try out.writeAll(std.mem.sliceAsBytes(&frames));
//! }
//! ```
//!
//! `render` is the only thing that runs per sample, it allocates nothing and
//! it never fails, so it is safe to call from an audio callback. `init` is
//! the only part that allocates, and it allocates once.

const Hum = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const partials = @import("partials.zig");

/// The block size at which the drift and shimmer are recomputed, in frames.
///
/// Wandering by a fraction of a percent every 1.5 ms is indistinguishable
/// from wandering every sample, and costs 1/64th as much; amplitudes are
/// ramped across the block rather than stepped, so nothing zippers.
const control_period = 64;

pub const Options = struct {
    /// Frames per second.
    sample_rate: u32 = 44_100,

    /// 1 for mono, 2 for stereo. Anything else is `error.UnsupportedChannelCount`.
    channels: u8 = 2,

    /// Chooses the random phases, pans and wander. The same seed and options
    /// give byte-identical output, which is what makes the tests possible;
    /// different seeds give a different instance of the same machine.
    seed: u64 = 0,

    /// The partials to sum. Defaults to the ones measured off the recording.
    partials: []const Partial = partials.wopr,

    /// Output level, in dBFS RMS. The default leaves about 8 dB of headroom
    /// above the peaks of a signal whose crest factor is around 10 dB; the
    /// reference recording sits at roughly -11 dBFS RMS at its loudest, which
    /// is louder than anything should be asked to render into a fixed-point
    /// format without a limiter in the way.
    level_dbfs: f64 = -18.0,

    /// The broadband floor under the hum, in dB relative to the tonal part.
    /// Measured at about -17 dB over the recording's noise bands.
    hiss_level_db: f64 = -18.0,

    /// The band the hiss occupies, in hertz: a one-pole highpass at the
    /// first and a two-pole lowpass at the second.
    ///
    /// The recording's floor is flat through a few hundred hertz and then
    /// falls at about 12 dB an octave, which is the two lowpass poles. The
    /// highpass is there because the floor also stops below the hum rather
    /// than continuing down: white noise taken straight to DC puts 17 dB
    /// more into the 20-40 Hz octave than the recording has in it.
    hiss_band_hz: [2]f64 = .{ 110.0, 220.0 },

    /// Rumble, in dB relative to the tonal part: the room and the air
    /// handling under everything else.
    ///
    /// Quiet, and deliberately so. The recording has almost nothing below
    /// 80 Hz -- its 20-40 Hz octave is 46 dB under the hum, which is to say
    /// absent -- so a synthesiser with a generous bottom end would be a
    /// different and less convincing sound however good it felt on a
    /// subwoofer.
    rumble_level_db: f64 = -34.0,

    /// The band the rumble occupies, in hertz: a one-pole highpass at the
    /// first and a two-pole lowpass at the second. It is a band rather than
    /// everything below a cutoff because that is the shape the recording
    /// has, falling away below 40 Hz as steeply as it does above 80.
    rumble_band_hz: [2]f64 = .{ 42.0, 78.0 },

    /// How far the whole bank drifts in frequency, as an RMS fraction. All
    /// the partials move together by this much, because they are one machine
    /// changing speed. 0.004 is ±0.4%, which matches the wander measured in
    /// the recording.
    drift: f64 = 0.004,

    /// How long the bank takes to wander, in seconds. Longer is slower and
    /// less noticeable.
    drift_seconds: f64 = 3.0,

    /// How far each partial drifts independently of the others, as an RMS
    /// fraction. Small, but it is what stops the beat pattern from repeating:
    /// the partials' spacing changes, so the 3.7 Hz throb breathes.
    voice_drift: f64 = 0.0008,

    /// How far each partial's level wanders, in dB RMS.
    shimmer_db: f64 = 2.0,

    /// How long a partial takes to wander in level, in seconds.
    shimmer_seconds: f64 = 4.0,

    /// Stereo spread, 0 to 1. Ignored when `channels` is 1.
    ///
    /// 0 puts the same signal in both channels. 1 is a pair of microphones
    /// `spacing_seconds` apart in a room; the default reproduces the
    /// reference recording's channel correlation of 0.97, which is a wide
    /// but overwhelmingly centred image.
    ///
    /// Correlation rather than the recording's side-to-mid ratio, which is
    /// 1.6 dB of plain level imbalance between its two channels on top of
    /// the image width. That is a property of how the recording was made,
    /// not of the room, and matching it would mean shipping a lopsided mix.
    width: f64 = 0.6,

    /// How far apart the two microphones are, expressed as the time it takes
    /// sound to travel between them. Scaled by `width`.
    ///
    /// This is the whole of the decorrelation that matters, and it is a
    /// delay rather than a random phase per partial for a reason worth
    /// recording: a random phase makes the channel correlation depend on
    /// where the *strongest* partial's draw happened to land, and one
    /// partial here is 8 dB above every other, so the image came out
    /// anywhere between 0.95 and 0.997 depending on the seed. A delay gives
    /// every partial a phase difference of `2*pi*f*tau`, which is what a
    /// spaced pair actually does, and makes the width a property of the
    /// options rather than of the seed.
    ///
    /// 450 microseconds is about 15 cm of air.
    spacing_seconds: f64 = 450e-6,
};

pub const Partial = partials.Partial;

pub const InitError = error{
    UnsupportedChannelCount,
    NoPartials,
    /// A partial at or above half the sample rate has nowhere to be.
    PartialAboveNyquist,
} || Allocator.Error;

voices: []Voice,
noise: [2]NoiseFloor,
drift: Wander,
rng: std.Random.DefaultPrng,
sample_rate: f64,
channels: u8,
/// Applied to the whole mix, folding in the RMS normalisation and `level_dbfs`.
gain: f64,
hiss_gain: f64,
rumble_gain: f64,
/// How much of each channel's noise is its own rather than shared.
noise_spread: f64,
/// Frames left before the control values are recomputed.
countdown: u32 = 0,

pub fn init(gpa: Allocator, options: Options) InitError!Hum {
    if (options.channels != 1 and options.channels != 2) return error.UnsupportedChannelCount;
    if (options.partials.len == 0) return error.NoPartials;

    const rate: f64 = @floatFromInt(options.sample_rate);
    const nyquist = rate / 2;
    // Checked against the drifted extreme rather than the nominal frequency,
    // so that a partial cannot alias only sometimes, minutes into a run.
    const headroom = 1 + 4 * (options.drift + options.voice_drift);
    for (options.partials) |p| {
        if (p.freq <= 0 or p.freq * headroom >= nyquist) return error.PartialAboveNyquist;
    }

    var prng: std.Random.DefaultPrng = .init(options.seed);
    const rng = prng.random();

    const control_rate = rate / control_period;
    const width = std.math.clamp(options.width, 0, 1);

    const voices = try gpa.alloc(Voice, options.partials.len);
    errdefer gpa.free(voices);

    var power: f64 = 0;
    for (voices, options.partials) |*v, p| {
        power += p.amp * p.amp;

        // A pan angle either side of centre, for texture, and the phase
        // difference the microphone spacing gives this partial, which is
        // what actually sets the width.
        const pan = std.math.pi / 4.0 + width * 0.12 * rng.floatNorm(f64);
        const skew = p.freq * width * options.spacing_seconds;

        v.* = .{
            .freq = p.freq,
            .amp = p.amp,
            .phase = .{ rng.float(f64), 0 },
            .gain = .{ @cos(pan) * std.math.sqrt2, @sin(pan) * std.math.sqrt2 },
            .freq_wander = .init(options.drift_seconds, control_rate, options.voice_drift),
            .amp_wander = .init(options.shimmer_seconds, control_rate, options.shimmer_db),
            .inc = 0,
            .level = p.amp,
            .level_step = 0,
        };
        v.phase[1] = wrap(v.phase[0] + skew);
    }

    // The bank is normalised to unit RMS before the output level is applied,
    // so that changing the partial table -- or handing in a different one --
    // changes the timbre and not the loudness. Sines contribute half their
    // squared amplitude to the mean square.
    // The pans are random, so nothing makes the two channels come out at the
    // same level on their own -- and with one partial 8 dB above the rest,
    // where that one happens to sit decides the balance of the whole mix.
    // Measured over a dozen seeds it strays past a decibel, which is an
    // audibly lopsided image and one that changes every run. Equalising the
    // two sides here keeps the width the pans bought and throws the
    // imbalance away.
    var side_power: [2]f64 = .{ 0, 0 };
    for (voices) |v| for (0..2) |ch| {
        side_power[ch] += v.amp * v.amp * v.gain[ch] * v.gain[ch];
    };
    const balanced = (side_power[0] + side_power[1]) / 2;
    for (voices) |*v| for (0..2) |ch| {
        if (side_power[ch] > 0) v.gain[ch] *= @sqrt(balanced / side_power[ch]);
    };

    const tonal_rms = @sqrt(power / 2);
    const level = std.math.pow(f64, 10, options.level_dbfs / 20);

    // The shimmer is symmetric in decibels, which is not symmetric in power:
    // a partial spends as long 3.5 dB up as 3.5 dB down, and 3.5 dB up is the
    // larger change. Left alone that makes the output louder than
    // `level_dbfs` asked for, by e^(2 c^2 sigma^2) in power for c = ln(10)/20,
    // so it is taken back out here rather than left as a surprise that grows
    // with the shimmer setting.
    const c = @log(@as(f64, 10)) / 20;
    const shimmer_bias = @exp(-c * c * options.shimmer_db * options.shimmer_db);

    return .{
        .voices = voices,
        .noise = .{
            .init(rng.int(u64), options, rate),
            .init(rng.int(u64), options, rate),
        },
        .drift = .init(options.drift_seconds, control_rate, options.drift),
        .rng = prng,
        .sample_rate = rate,
        .channels = options.channels,
        .gain = level * shimmer_bias / tonal_rms,
        .hiss_gain = tonal_rms * std.math.pow(f64, 10, options.hiss_level_db / 20),
        .rumble_gain = tonal_rms * std.math.pow(f64, 10, options.rumble_level_db / 20),
        .noise_spread = if (options.channels == 1) 0 else width,
    };
}

pub fn deinit(hum: *Hum, gpa: Allocator) void {
    gpa.free(hum.voices);
    hum.* = undefined;
}

/// Fill `out` with the next samples, interleaved by channel.
///
/// `out.len` must be a multiple of the channel count. Nothing here allocates,
/// blocks or can fail, so this is safe to call from an audio callback.
pub fn render(hum: *Hum, out: []f32) void {
    std.debug.assert(out.len % hum.channels == 0);
    const rng = hum.rng.random();

    var i: usize = 0;
    while (i < out.len) {
        if (hum.countdown == 0) {
            hum.retune(rng);
            hum.countdown = control_period;
        }
        const frames_left = (out.len - i) / hum.channels;
        const run = @min(hum.countdown, frames_left);
        hum.countdown -= @intCast(run);

        if (hum.channels == 1) hum.renderMono(out[i..][0..run]) else hum.renderStereo(out[i..][0 .. run * 2]);
        i += run * hum.channels;
    }
}

/// Recompute the per-partial frequency and level. Called once per
/// `control_period` frames.
fn retune(hum: *Hum, rng: std.Random) void {
    const speed = 1 + hum.drift.next(rng);
    const inv_rate = 1 / hum.sample_rate;
    const inv_period: f64 = 1.0 / @as(f64, control_period);
    for (hum.voices) |*v| {
        v.inc = v.freq * speed * (1 + v.freq_wander.next(rng)) * inv_rate;
        const target = v.amp * std.math.pow(f64, 10, v.amp_wander.next(rng) / 20);
        v.level_step = (target - v.level) * inv_period;
    }
}

fn renderMono(hum: *Hum, out: []f32) void {
    @memset(out, 0);
    for (hum.voices) |*v| {
        var level = v.level;
        var phase = v.phase[0];
        for (out) |*s| {
            s.* += @floatCast(level * sine(phase));
            phase = wrap(phase + v.inc);
            level += v.level_step;
        }
        v.phase[0] = phase;
        v.level = level;
    }
    const floor = &hum.noise[0];
    for (out) |*s| {
        const n = floor.next(hum.hiss_gain, hum.rumble_gain);
        s.* = @floatCast((s.* + n) * hum.gain);
    }
}

fn renderStereo(hum: *Hum, out: []f32) void {
    @memset(out, 0);
    for (hum.voices) |*v| {
        for (0..2) |ch| {
            var level = v.level;
            var phase = v.phase[ch];
            const g = v.gain[ch];
            var k: usize = ch;
            while (k < out.len) : (k += 2) {
                out[k] += @floatCast(g * level * sine(phase));
                phase = wrap(phase + v.inc);
                level += v.level_step;
            }
            v.phase[ch] = phase;
            // Both channels walked the same ramp; keep the one they agree on.
            if (ch == 1) v.level = level;
        }
    }

    // A shared noise source plus a private one per channel. `noise_spread`
    // decides how much of each channel is its own, which is what keeps the
    // floor from either collapsing to the centre or throwing the channel
    // correlation away entirely.
    const common = @sqrt(1 - hum.noise_spread * hum.noise_spread);
    var k: usize = 0;
    while (k < out.len) : (k += 2) {
        const shared = hum.noise[0].next(hum.hiss_gain, hum.rumble_gain);
        const l = hum.noise[1].next(hum.hiss_gain, hum.rumble_gain);
        const r = hum.noise[1].next(hum.hiss_gain, hum.rumble_gain);
        out[k] = @floatCast((out[k] + common * shared + hum.noise_spread * l) * hum.gain);
        out[k + 1] = @floatCast((out[k + 1] + common * shared + hum.noise_spread * r) * hum.gain);
    }
}

/// One partial.
const Voice = struct {
    freq: f64,
    amp: f64,
    /// Turns, one per channel. Stereo gives the two channels different
    /// phases; mono uses only the first.
    phase: [2]f64,
    gain: [2]f64,
    freq_wander: Wander,
    amp_wander: Wander,
    /// Phase increment per frame, in turns. Set by `retune`.
    inc: f64,
    /// Current amplitude, ramped towards the wander's target across a block.
    level: f64,
    level_step: f64,
};

/// A bounded random walk: white noise through a one-pole lowpass, scaled so
/// that it settles at a known RMS.
///
/// A plain random walk is unbounded and would eventually take a partial
/// anywhere; a sine LFO is periodic, which is the thing being avoided. This
/// is neither: it wanders, and it stays.
const Wander = struct {
    state: f64 = 0,
    pole: f64,
    gain: f64,

    fn init(tau_seconds: f64, rate: f64, rms: f64) Wander {
        const a = @exp(-1 / (tau_seconds * rate));
        // y = a*y + g*x with x of unit variance settles at var(y) =
        // g^2/(1-a^2), so this is the g that makes var(y) come out at rms^2.
        return .{ .pole = a, .gain = rms * @sqrt(1 - a * a) };
    }

    fn next(w: *Wander, rng: std.Random) f64 {
        w.state = w.state * w.pole + rng.floatNorm(f64) * w.gain;
        return w.state;
    }
};

/// The broadband floor: hiss and rumble, each a band of shaped white noise.
///
/// Two lowpass poles on the hiss rather than one, because the recording's
/// floor falls at about 12 dB an octave above a few hundred hertz and one
/// pole falls at 6.
const NoiseFloor = struct {
    rng: std.Random.DefaultPrng,
    hiss: Band,
    rumble: Band,

    fn init(seed: u64, options: Options, rate: f64) NoiseFloor {
        return .{
            .rng = .init(seed),
            .hiss = .init(options.hiss_band_hz[0], options.hiss_band_hz[1], rate),
            .rumble = .init(options.rumble_band_hz[0], options.rumble_band_hz[1], rate),
        };
    }

    fn next(f: *NoiseFloor, hiss_gain: f64, rumble_gain: f64) f64 {
        // Its own generator rather than the caller's: the noise floor is then
        // independent of how many partials there are, so adding one does not
        // change the hiss.
        const rng = f.rng.random();
        return f.hiss.next(rng) * hiss_gain + f.rumble.next(rng) * rumble_gain;
    }
};

/// White noise through an optional one-pole highpass and two one-pole
/// lowpasses, scaled back to unit RMS.
///
/// The scaling is what lets the cutoffs be moved without also having to
/// re-tune the level: a `_level_db` option means the same loudness whatever
/// band it is spread across.
const Band = struct {
    high: ?OnePole,
    low: [2]OnePole,
    scale: f64,

    fn init(high_hz: ?f64, low_hz: f64, rate: f64) Band {
        const high: ?OnePole = if (high_hz) |hz| .init(hz, rate) else null;
        const low: OnePole = .init(low_hz, rate);
        return .{
            .high = high,
            .low = .{ low, low },
            .scale = 1 / responseRms(high, low),
        };
    }

    fn next(b: *Band, rng: std.Random) f64 {
        var v = rng.floatNorm(f64) * b.scale;
        // A one-pole highpass is what the matching lowpass does not pass.
        if (b.high) |*p| v -= p.step(v);
        for (&b.low) |*p| v = p.step(v);
        return v;
    }

    /// The RMS this chain produces from unit-variance white noise.
    ///
    /// Integrated over the spectrum rather than composed from each stage's
    /// own figure, because the second lowpass is not being fed white noise
    /// and so does not attenuate it by the same factor the first one did.
    fn responseRms(high: ?OnePole, low: OnePole) f64 {
        const steps = 4096;
        var sum: f64 = 0;
        for (0..steps) |i| {
            const w = std.math.pi * (@as(f64, @floatFromInt(i)) + 0.5) / steps;
            const cos_w = @cos(w);
            var power: f64 = 1;
            if (high) |p| {
                // y = x - lp(x), so H = a(1 - e^-jw) / (1 - a e^-jw).
                const a = p.pole;
                power *= a * a * (2 - 2 * cos_w) / (1 - 2 * a * cos_w + a * a);
            }
            {
                // y = (1-a)x + a*y[-1], twice.
                const a = low.pole;
                const one = (1 - a) * (1 - a) / (1 - 2 * a * cos_w + a * a);
                power *= one * one;
            }
            sum += power;
        }
        return @sqrt(sum / steps);
    }
};

const OnePole = struct {
    state: f64 = 0,
    pole: f64,

    fn init(cutoff_hz: f64, rate: f64) OnePole {
        return .{ .pole = @exp(-2 * std.math.pi * cutoff_hz / rate) };
    }

    fn step(p: *OnePole, in: f64) f64 {
        p.state = in * (1 - p.pole) + p.state * p.pole;
        return p.state;
    }
};

inline fn sine(turns: f64) f64 {
    return @sin(turns * 2 * std.math.pi);
}

inline fn wrap(turns: f64) f64 {
    return turns - @floor(turns);
}
