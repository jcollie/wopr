// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A synthesiser for the low humming of the WOPR machine room in *WarGames*.
//!
//! `Hum` is the whole of it. It renders indefinitely into a buffer of `f32`,
//! allocating once at `init` and nothing afterwards, so it can be driven from
//! an audio callback as readily as written to a file. `partials` and `bursts`
//! are the measured description of the sound it is reproducing — the numbers,
//! and how they were arrived at.
//!
//! This module depends on nothing but the standard library. Putting the
//! samples somewhere is somebody else's job: the `wopr` program writes WAVE
//! files with [zig-wav](https://git.jcollie.dev/jeff/zig-wav) and plays them
//! with [zig-pipewire](https://git.jcollie.dev/jeff/zig-pipewire), and
//! neither is reachable from here.
//!
//! ```zig
//! const wopr = @import("wopr");
//!
//! var hum: wopr.Hum = try .init(gpa, .{ .sample_rate = 48_000 });
//! defer hum.deinit(gpa);
//!
//! var frames: [4096]f32 = undefined;
//! hum.render(&frames);
//! ```

/// The synthesiser.
pub const Hum = @import("Hum.zig");

/// The measured partials of the reference recording, and what they mean.
pub const partials = @import("partials.zig");

/// The two tone bursts heard over the hum -- the ping and the pong -- and
/// how often they arrive.
pub const bursts = @import("bursts.zig");

test {
    // Reaches the three namespaces above so that `zig build test` compiles
    // and runs every test in the module, not just the ones in this file.
    @import("std").testing.refAllDecls(@This());
}
