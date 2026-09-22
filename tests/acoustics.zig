// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What the synthesiser has to *sound* like.
//!
//! The unit tests next to the code check that it does what it says. These
//! check that what it says is still the sound that was measured: that the
//! spectrum peaks where the recording peaks, that the energy is in the same
//! octave, that the channels are as wide as the recording's and no wider,
//! that the throb is still around 3.7 Hz, and that none of it clips.
//!
//! Every one of these is a claim taken from `analysis/` and from the table
//! in `partials.zig`, written down where a change to the model will break it
//! rather than quietly move the sound somewhere else. The tolerances are
//! deliberately loose: they are there to catch a *different sound*, not to
//! pin the output bit for bit.

const std = @import("std");
const testing = std.testing;

const wopr = @import("wopr");

const rate = 44_100;
/// 2^17 frames, just under three seconds at 44.1 kHz. A power of two because
/// the FFT below is radix-2, and this long because a 0.34 Hz bin is what it
/// takes to say the peak is at 124.9 Hz rather than at 125.
const n = 1 << 17;

/// Render `frames` frames into a freshly allocated buffer.
fn render(gpa: std.mem.Allocator, frames: usize, options: wopr.Hum.Options) ![]f32 {
    var hum: wopr.Hum = try .init(gpa, options);
    defer hum.deinit(gpa);

    const out = try gpa.alloc(f32, frames * options.channels);
    errdefer gpa.free(out);
    // In pieces, so that the tests exercise the same block-boundary handling
    // that a real caller with a 256 frame audio callback would.
    var i: usize = 0;
    while (i < out.len) {
        const take = @min(out.len - i, 1000 * @as(usize, options.channels));
        hum.render(out[i..][0..take]);
        i += take;
    }
    return out;
}

test "the same seed renders the same audio" {
    const a = try render(testing.allocator, 4096, .{ .seed = 1981 });
    defer testing.allocator.free(a);
    const b = try render(testing.allocator, 4096, .{ .seed = 1981 });
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(f32, a, b);
}

test "a different seed is a different machine" {
    // Two seconds, because the hum beats at about 3.7 Hz and a window
    // shorter than several of those periods measures where in the throb it
    // happened to start rather than how loud it is.
    const a = try render(testing.allocator, rate * 2, .{ .seed = 1 });
    defer testing.allocator.free(a);
    const b = try render(testing.allocator, rate * 2, .{ .seed = 2 });
    defer testing.allocator.free(b);
    try testing.expect(!std.mem.eql(f32, a, b));
    // Different, but the same sound.
    try testing.expectApproxEqAbs(dbfs(rms(a)), dbfs(rms(b)), 1.5);
}

test "the block size a caller happens to use does not change the audio" {
    // The oscillators are retuned every 64 frames regardless of how the
    // caller asks for them, so a 1000 frame call and a 7 frame call have to
    // produce the same stream. If they ever differ, the control-rate
    // bookkeeping in `render` has a seam in it.
    const whole = try render(testing.allocator, 4096, .{ .seed = 7, .channels = 1 });
    defer testing.allocator.free(whole);

    var hum: wopr.Hum = try .init(testing.allocator, .{ .seed = 7, .channels = 1 });
    defer hum.deinit(testing.allocator);
    const piecemeal = try testing.allocator.alloc(f32, 4096);
    defer testing.allocator.free(piecemeal);
    var i: usize = 0;
    var take: usize = 1;
    while (i < piecemeal.len) {
        const m = @min(take, piecemeal.len - i);
        hum.render(piecemeal[i..][0..m]);
        i += m;
        take = take % 97 + 1;
    }
    try testing.expectEqualSlices(f32, whole, piecemeal);
}

test "the spectrum peaks where the recording peaks" {
    const x = try render(testing.allocator, n, .{ .channels = 1, .seed = 3 });
    defer testing.allocator.free(x);

    const mag = try spectrum(testing.allocator, x);
    defer testing.allocator.free(mag);

    var best: usize = 0;
    for (mag, 0..) |m, i| if (m > mag[best]) {
        best = i;
    };
    const peak_hz = @as(f64, @floatFromInt(best)) * rate / n;
    // 124.942 Hz is the strongest partial of the recording.
    try testing.expectApproxEqAbs(@as(f64, 124.942), peak_hz, 1.0);
}

test "almost all the energy is in the 80-160 Hz octave" {
    // The recording measures 97.8%. The synthesiser adds a noise floor that
    // the recording also has, so the figure here is a little lower; what
    // matters is that this stays a low hum and does not drift into being a
    // buzz.
    const x = try render(testing.allocator, n, .{ .channels = 1, .seed = 4 });
    defer testing.allocator.free(x);

    const mag = try spectrum(testing.allocator, x);
    defer testing.allocator.free(mag);

    var total: f64 = 0;
    var octave: f64 = 0;
    for (mag, 0..) |m, i| {
        const hz = @as(f64, @floatFromInt(i)) * rate / n;
        const e = m * m;
        total += e;
        if (hz >= 80 and hz < 160) octave += e;
    }
    try testing.expect(octave / total > 0.95);
}

test "the sample rate does not move the pitch" {
    for ([_]u32{ 22_050, 48_000, 96_000 }) |sr| {
        const x = try render(testing.allocator, n, .{ .channels = 1, .seed = 5, .sample_rate = sr });
        defer testing.allocator.free(x);
        const mag = try spectrum(testing.allocator, x);
        defer testing.allocator.free(mag);

        var best: usize = 0;
        for (mag, 0..) |m, i| if (m > mag[best]) {
            best = i;
        };
        const peak_hz = @as(f64, @floatFromInt(best)) * @as(f64, @floatFromInt(sr)) / n;
        try testing.expectApproxEqAbs(@as(f64, 124.942), peak_hz, 1.5);
    }
}

test "it comes out at the level it was asked for, with room to spare" {
    for ([_]f64{ -30, -18, -12 }) |want| {
        const x = try render(testing.allocator, rate * 2, .{ .level_dbfs = want, .seed = 6 });
        defer testing.allocator.free(x);

        // Within 1.5 dB: the shimmer's bias is compensated exactly, but any
        // one realisation of it still lands a little either side.
        try testing.expectApproxEqAbs(want, dbfs(rms(x)), 1.5);

        // The crest factor of a sum of unrelated sines is around 10 dB, and
        // the default level leaves 18. Anything that clips at -12 dBFS RMS
        // would clip a lot louder than that in a listener's player.
        var peak: f64 = 0;
        for (x) |s| peak = @max(peak, @abs(@as(f64, s)));
        try testing.expect(peak < 1.0);
        try testing.expect(dbfs(peak) - dbfs(rms(x)) < 14.0);
    }
}

test "nothing clicks at a control-block boundary" {
    // The oscillators are retuned every 64 frames and the new amplitude is
    // ramped in across the block. If it were stepped instead, there would be
    // a discontinuity every 64 samples; at these frequencies the real signal
    // moves very little between adjacent samples, so a step stands out by
    // orders of magnitude.
    const x = try render(testing.allocator, rate, .{ .channels = 1, .seed = 8 });
    defer testing.allocator.free(x);

    var worst: f64 = 0;
    var worst_at_boundary: f64 = 0;
    for (x[1..], 1..) |s, i| {
        const d = @abs(@as(f64, s) - @as(f64, x[i - 1]));
        worst = @max(worst, d);
        if (i % 64 == 0) worst_at_boundary = @max(worst_at_boundary, d);
    }
    // The boundaries must not be where the biggest jumps are.
    try testing.expect(worst_at_boundary <= worst);
    // And the biggest jump anywhere is what a 150 Hz sine does in one
    // sample, give or take the noise floor: 2*pi*150/44100 of the peak.
    var peak: f64 = 0;
    for (x) |s| peak = @max(peak, @abs(@as(f64, s)));
    try testing.expect(worst < peak * 0.1);
}

test "the throb is still around 3.7 Hz" {
    // Not a modulator: the strongest partials are spaced about 3.7 Hz apart,
    // so the sum beats at that rate on its own. This test is what catches
    // somebody "improving" the partial table into something that no longer
    // pulses.
    const frames = n + 512;
    const x = try render(testing.allocator, frames, .{ .channels = 1, .seed = 9 });
    defer testing.allocator.free(x);

    // The envelope, smoothed over 10 ms and decimated by 64 so that a
    // manageable FFT covers a few seconds of it at fine resolution.
    const smooth = 441;
    const decim = 64;
    const env_len = 1 << 11;
    std.debug.assert((env_len - 1) * decim + smooth <= frames);
    const env = try testing.allocator.alloc(f32, env_len);
    defer testing.allocator.free(env);
    for (env, 0..) |*e, i| {
        var sum: f64 = 0;
        const start = i * decim;
        for (x[start..][0..smooth]) |s| sum += @abs(@as(f64, s));
        e.* = @floatCast(sum / smooth);
    }
    var mean: f64 = 0;
    for (env) |e| mean += e;
    mean /= env_len;
    for (env) |*e| e.* -= @floatCast(mean);

    const mag = try spectrum(testing.allocator, env);
    defer testing.allocator.free(mag);

    // Looked for between 2 Hz and 10 Hz. Below 2 Hz is the drift -- the
    // whole bank changing speed over seconds, which moves the level a little
    // as the partials slide past each other and which the recording has too;
    // it is not the throb, and it is bigger. Above 10 Hz are the throb's own
    // harmonics, which the beating of a dozen partials is rich in.
    const env_rate = @as(f64, rate) / decim;
    const bin_hz = env_rate / env_len;
    const first: usize = @intFromFloat(@ceil(2.0 / bin_hz));
    const last: usize = @intFromFloat(@floor(10.0 / bin_hz));
    var best = first;
    for (mag[first..last], first..) |m, i| if (m > mag[best]) {
        best = i;
    };
    const throb_hz = @as(f64, @floatFromInt(best)) * bin_hz;
    try testing.expect(throb_hz > 2.5 and throb_hz < 5.0);
}

test "the image is wide but overwhelmingly centred" {
    const x = try render(testing.allocator, rate * 2, .{ .seed = 10 });
    defer testing.allocator.free(x);

    var ll: f64 = 0;
    var rr: f64 = 0;
    var lr: f64 = 0;
    var i: usize = 0;
    while (i < x.len) : (i += 2) {
        const l: f64 = x[i];
        const r: f64 = x[i + 1];
        ll += l * l;
        rr += r * r;
        lr += l * r;
    }
    // Both channels are zero-mean, so this is the correlation coefficient.
    // The reference recording measures 0.971, and the microphone spacing is
    // set to land on that. The window is tight because the spacing makes
    // this a property of the options rather than of the seed: a random
    // phase per partial would have put it anywhere in 0.95 to 0.997
    // depending on which way the strongest partial's draw went.
    const corr = lr / @sqrt(ll * rr);
    try testing.expect(corr > 0.96 and corr < 0.98);

    // The channels are balanced, which the recording's are not: its left is
    // 1.6 dB above its right, so its side channel measures 16.4 dB under its
    // mid where this measures about 18. That imbalance is an artefact of how
    // the recording was made, and reproducing it would mean shipping a
    // lopsided mix.
    try testing.expectApproxEqAbs(10 * @log10(ll), 10 * @log10(rr), 0.5);
}

test "width 0 is mono, and mono is what one channel of it sounds like" {
    const x = try render(testing.allocator, 8192, .{ .seed = 11, .width = 0 });
    defer testing.allocator.free(x);
    var i: usize = 0;
    while (i < x.len) : (i += 2) try testing.expectEqual(x[i], x[i + 1]);
}

test "a mono render is the same level as a stereo one" {
    const s = try render(testing.allocator, rate, .{ .seed = 12, .channels = 2 });
    defer testing.allocator.free(s);
    const m = try render(testing.allocator, rate, .{ .seed = 12, .channels = 1 });
    defer testing.allocator.free(m);
    try testing.expectApproxEqAbs(dbfs(rms(s)), dbfs(rms(m)), 1.0);
}

test "a sample rate with nowhere to put the partials is refused" {
    try testing.expectError(error.PartialAboveNyquist, wopr.Hum.init(testing.allocator, .{ .sample_rate = 500 }));
    try testing.expectError(error.UnsupportedChannelCount, wopr.Hum.init(testing.allocator, .{ .channels = 6 }));
    try testing.expectError(error.NoPartials, wopr.Hum.init(testing.allocator, .{ .partials = &.{} }));
}

// -- measurement ------------------------------------------------------------

fn rms(x: []const f32) f64 {
    var sum: f64 = 0;
    for (x) |s| sum += @as(f64, s) * @as(f64, s);
    return @sqrt(sum / @as(f64, @floatFromInt(x.len)));
}

fn dbfs(v: f64) f64 {
    return 20 * @log10(v + 1e-30);
}

/// The magnitude spectrum of `x`, Hann-windowed. `x.len` must be a power of
/// two. Returns `x.len / 2 + 1` bins, which the caller frees.
fn spectrum(gpa: std.mem.Allocator, x: []const f32) ![]f64 {
    const len = x.len;
    std.debug.assert(std.math.isPowerOfTwo(len));

    const re = try gpa.alloc(f64, len);
    defer gpa.free(re);
    const im = try gpa.alloc(f64, len);
    defer gpa.free(im);

    for (x, 0..) |s, i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(len));
        re[i] = @as(f64, s) * 0.5 * (1 - @cos(2 * std.math.pi * t));
        im[i] = 0;
    }
    fft(re, im);

    const out = try gpa.alloc(f64, len / 2 + 1);
    for (out, 0..) |*m, i| m.* = @sqrt(re[i] * re[i] + im[i] * im[i]);
    return out;
}

/// An in-place iterative radix-2 FFT. Here rather than borrowed because the
/// tests need exactly this and nothing else, and because a test that depends
/// on a library to say what the code under test sounds like has moved the
/// question somewhere harder to read.
fn fft(re: []f64, im: []f64) void {
    const len = re.len;
    std.debug.assert(im.len == len);
    if (len <= 1) return;

    // Bit-reversal permutation.
    var j: usize = 0;
    for (1..len) |i| {
        var bit = len >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j |= bit;
        if (i < j) {
            std.mem.swap(f64, &re[i], &re[j]);
            std.mem.swap(f64, &im[i], &im[j]);
        }
    }

    var size: usize = 2;
    while (size <= len) : (size <<= 1) {
        const ang = -2 * std.math.pi / @as(f64, @floatFromInt(size));
        const wr = @cos(ang);
        const wi = @sin(ang);
        var start: usize = 0;
        while (start < len) : (start += size) {
            var cr: f64 = 1;
            var ci: f64 = 0;
            for (0..size / 2) |k| {
                const a = start + k;
                const b = a + size / 2;
                const tr = re[b] * cr - im[b] * ci;
                const ti = re[b] * ci + im[b] * cr;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
                const nr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = nr;
            }
        }
    }
}

test "the FFT finds a tone where it was put" {
    const len = 1 << 12;
    const re = try testing.allocator.alloc(f64, len);
    defer testing.allocator.free(re);
    const im = try testing.allocator.alloc(f64, len);
    defer testing.allocator.free(im);
    for (re, 0..) |*v, i| v.* = @sin(2 * std.math.pi * 64 * @as(f64, @floatFromInt(i)) / len);
    @memset(im, 0);
    fft(re, im);

    var best: usize = 0;
    var best_mag: f64 = 0;
    for (0..len / 2) |i| {
        const m = re[i] * re[i] + im[i] * im[i];
        if (m > best_mag) {
            best_mag = m;
            best = i;
        }
    }
    try testing.expectEqual(@as(usize, 64), best);
}
