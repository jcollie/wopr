// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! `wopr`: write the machine room hum somewhere.
//!
//! Run from a terminal it plays, through PipeWire, as a node of its own
//! that a mixer can see and move. Redirected or piped it writes a WAVE
//! stream instead, and never stops, which is the shape that goes into
//! something else:
//!
//! ```console
//! $ wopr                                          # plays
//! $ wopr --duration 30 --output hum.wav           # renders
//! $ wopr --raw | aplay -f S16_LE -r 44100 -c 2    # somebody else plays
//! ```
//!
//! Nothing here paces the output against a clock, in either mode. A graph
//! consumes frames at the rate it plays them and the ring fills up behind
//! it; a pipe does the same thing with a player on the far end. A file or
//! `/dev/null` takes them as fast as they can be made, which is what you
//! want when rendering.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const wopr = @import("wopr");
const play = @import("play");

const version = "0.0.0";

/// The synthesiser's own defaults, so that the command line has none of its
/// own to fall out of step with. The usage text below quotes them, and a
/// test at the bottom of this file checks that it still quotes them
/// correctly.
const defaults: wopr.Hum.Options = .{};

const usage =
    \\usage: wopr [options]
    \\
    \\Writes an endless WOPR machine room hum, as a WAVE stream on stdout
    \\unless told otherwise.
    \\
    \\  -p, --play            play through PipeWire; the default from a terminal
    \\      --sink NAME       play to this sink rather than the default one
    \\  -o, --output PATH     write a file here instead
    \\  -d, --duration SECS   stop after SECS seconds (default: never stop)
    \\  -r, --rate HZ         sample rate (default 44100)
    \\  -c, --channels N      1 or 2 (default 2)
    \\  -f, --format FMT      s16, s24 or f32 (default s16); written files only
    \\      --raw             headerless PCM rather than a WAVE stream
    \\  -g, --gain DB         output level in dBFS RMS (default -18)
    \\  -w, --width W         stereo spread, 0 to 1 (default 0.6)
    \\  -n, --hiss DB         add a broadband noise floor, in dB under the hum;
    \\                        off by default, because a room has one already
    \\  -b, --bursts N        pings and pongs per minute (default 70);
    \\                        "off" for a hum with nothing over it
    \\  -s, --seed N          seed the randomness (default: from the clock)
    \\  -h, --help            print this and stop
    \\  -V, --version         print the version and stop
    \\
    \\examples:
    \\  wopr
    \\  wopr --sink alsa_output.usb-audio -g -24
    \\  wopr -d 30 -o hum.wav
    \\  wopr --raw | aplay -f S16_LE -r 44100 -c 2
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var message_buffer: [512]u8 = undefined;

    // A mistake on the command line is the user's, not a crash: it goes to
    // stderr and exits 2, rather than being returned so that the runtime
    // prints `error.BadUsage` and a stack trace through the argument parser.
    var config = parse(args[1..]) catch |err| {
        var w: Io.File.Writer = .init(.stderr(), io, &message_buffer);
        w.interface.print("wopr: {s}\n\n{s}", .{ describe(err), usage }) catch {};
        w.interface.flush() catch {};
        std.process.exit(2);
    };

    // Asked for, so it is output rather than a diagnostic, and goes where
    // output goes.
    switch (config.action) {
        .help, .version => {
            var w: Io.File.Writer = .init(.stdout(), io, &message_buffer);
            defer w.interface.flush() catch {};
            switch (config.action) {
                .help => try w.interface.writeAll(usage),
                .version => try w.interface.print("wopr {s}\n", .{version}),
                .run => unreachable,
            }
            return;
        },
        .run => {},
    }

    var stderr_buffer: [512]u8 = undefined;
    var stderr_file: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file.interface;
    defer stderr.flush() catch {};

    // A seed from the clock unless one was given, so that two runs started
    // moments apart -- a pair of terminals, a script and its retry -- are not
    // the same machine humming in unison. Hashed rather than truncated,
    // because consecutive nanosecond counts differ only in their low bits and
    // a seed whose high bits never change is most of a constant.
    const seed = config.seed orelse seed: {
        const ns = Io.Timestamp.now(io, .real).nanoseconds;
        break :seed std.hash.Wyhash.hash(0, std.mem.asBytes(&ns));
    };

    const hum_options: wopr.Hum.Options = .{
        .sample_rate = config.rate,
        .channels = config.channels,
        .seed = seed,
        .level_dbfs = config.gain_db,
        .width = config.width,
        .hiss_level_db = config.hiss_db,
        .bursts = if (config.bursts_per_minute) |n|
            if (n == 0) &.{} else defaults.bursts
        else
            defaults.bursts,
        // Left alone unless asked, so that the default rate lives in one
        // place -- `bursts.Timing` -- rather than being restated here.
        .timing = if (config.bursts_per_minute) |n| .{ .per_minute = n } else .{},
    };

    // Played unless it was asked to write somewhere, or unless stdout is
    // going anywhere other than a terminal. A person who types `wopr` wants
    // to hear it; `wopr > hum.wav` and `wopr | something` still mean what
    // they always did, and nothing spills binary onto a terminal.
    const playing = config.play or
        (config.output == null and (Io.File.stdout().isTty(io) catch false));

    if (playing) {
        // Out of `main` rather than the parser: PipeWire locates its socket
        // from PIPEWIRE_RUNTIME_DIR, XDG_RUNTIME_DIR and PIPEWIRE_REMOTE,
        // the way every other client does.
        config.environ = init.minimal.environ;
        if (!play.supported) {
            try stderr.writeAll(
                \\wopr: this build cannot play audio -- PipeWire is a Linux daemon and
                \\      zig-pipewire reaches it with Linux syscalls. Write a file with
                \\      --output, or pipe the WAVE stream on stdout into a player.
                \\
            );
            try stderr.flush();
            std.process.exit(2);
        }
        try playHum(gpa, stderr, hum_options, config);
        return;
    }

    var hum: wopr.Hum = wopr.Hum.init(gpa, hum_options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The partial table is fixed and well inside any sample rate a
        // sound card offers, so this only happens if `--rate` was absurd.
        error.PartialAboveNyquist => {
            try stderr.print("wopr: a sample rate of {d} Hz is too low for the hum\n", .{config.rate});
            try stderr.flush();
            std.process.exit(2);
        },
        // All three come from tables that are compiled in, and the command
        // line cannot reach any of them.
        error.UnsupportedChannelCount, error.NoPartials, error.BadBurst, error.BadEchoDelay => unreachable,
    };
    defer hum.deinit(gpa);

    const file: Io.File = if (config.output) |path|
        try Io.Dir.cwd().createFile(io, path, .{})
    else
        .stdout();
    defer if (config.output != null) file.close(io);

    var out_buffer: [64 * 1024]u8 = undefined;
    var out_file: Io.File.Writer = if (config.output == null)
        .initStreaming(file, io, &out_buffer)
    else
        .init(file, io, &out_buffer);
    const out = &out_file.interface;

    const total_frames: ?u64 = if (config.duration_seconds) |secs|
        @intFromFloat(@round(secs * @as(f64, @floatFromInt(config.rate))))
    else
        null;

    // A player being closed, or a `head` downstream of us, is how this
    // program is normally stopped. It is not a failure. `Io.Writer` reports
    // every write problem as `WriteFailed` and leaves the real one on the
    // file writer, so that is where to look.
    stream(out, &hum, config, total_frames) catch |err| {
        if (out_file.err) |cause| if (cause == error.BrokenPipe) return;
        return err;
    };
}

/// Open the graph and render into it until told to stop.
fn playHum(
    gpa: Allocator,
    stderr: *Io.Writer,
    hum_options: wopr.Hum.Options,
    config: Config,
) !void {
    var player: play.Player = play.Player.open(gpa, hum_options, .{
        .target = config.sink,
        .environ = config.environ,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PartialAboveNyquist => {
            // The graph chose its own rate, so this is not something the
            // command line asked for and the message has to say so.
            try stderr.print("wopr: the graph is running too slowly for the hum\n", .{});
            try stderr.flush();
            std.process.exit(1);
        },
        else => {
            try stderr.print("wopr: cannot reach PipeWire: {t}\n", .{err});
            try stderr.flush();
            std.process.exit(1);
        },
    };
    defer player.close();

    try stderr.print("wopr: playing at {d} Hz into {d} channel(s); ^C to stop\n", .{
        player.rate(),
        player.graphChannels(),
    });
    try stderr.flush();

    try player.run(config.duration_seconds);
}

fn stream(out: *Io.Writer, hum: *wopr.Hum, config: Config, total_frames: ?u64) !void {
    if (!config.raw) try wopr.wav.writeHeader(out, .{
        .sample_rate = config.rate,
        .channels = config.channels,
        .format = config.format,
        .frames = total_frames,
    });

    // 4096 frames is about 90 ms at 44.1 kHz: long enough that the per-block
    // work disappears, short enough that a player's buffer is fed smoothly
    // and that `--duration` lands within a block of where it was asked to.
    var block: [4096 * 2]f32 = undefined;
    var rendered: u64 = 0;
    while (true) {
        var frames: usize = block.len / config.channels;
        if (total_frames) |limit| {
            if (rendered >= limit) break;
            frames = @intCast(@min(frames, limit - rendered));
        }
        const samples = block[0 .. frames * config.channels];
        hum.render(samples);
        try wopr.wav.writeSamples(out, config.format, samples);
        rendered += frames;
    }
    try out.flush();
}

const Config = struct {
    pub const Action = enum { run, help, version };

    action: Action = .run,
    /// Set by `--play` or `--sink`. Kept separate from `output` rather than
    /// collapsed into one "destination" field, because collapsing it makes
    /// the check below depend on which flag came last -- and `--play -o x`
    /// then quietly wrote a file instead of being refused.
    play: bool = false,
    sink: ?[]const u8 = null,
    /// Filled in by `main`, not by the parser: PipeWire finds its socket the
    /// way every other client does, out of the environment.
    environ: ?std.process.Environ = null,
    output: ?[]const u8 = null,
    duration_seconds: ?f64 = null,
    rate: u32 = defaults.sample_rate,
    channels: u8 = defaults.channels,
    format: wopr.wav.Format = .s16,
    raw: bool = false,
    gain_db: f64 = defaults.level_dbfs,
    width: f64 = defaults.width,
    hiss_db: ?f64 = defaults.hiss_level_db,
    /// `null` means the measured rate; 0 means none at all.
    bursts_per_minute: ?f64 = null,
    seed: ?u64 = null,
};

const ParseError = error{
    UnknownOption,
    UnexpectedArgument,
    MissingValue,
    BadNumber,
    BadFormat,
    BadChannelCount,
    BadRate,
    BadDuration,
    BadWidth,
    BadGain,
    BadHiss,
    BadBurstRate,
    /// `--play` and `--output` in the same command line.
    PlayAndWrite,
};

fn describe(err: ParseError) []const u8 {
    return switch (err) {
        error.UnknownOption => "unknown option",
        error.UnexpectedArgument => "unexpected argument; wopr takes options only",
        error.MissingValue => "an option is missing its value",
        error.BadNumber => "that is not a number",
        error.BadFormat => "format must be s16, s24 or f32",
        error.BadChannelCount => "channels must be 1 or 2",
        error.BadRate => "rate must be between 8000 and 768000 Hz",
        error.BadDuration => "duration must be a positive number of seconds",
        error.BadWidth => "width must be between 0 and 1",
        error.BadGain => "gain must be between -120 and 0 dBFS",
        error.BadHiss => "hiss must be between -120 and 0 dB, or \"off\"",
        error.BadBurstRate => "bursts must be between 0 and 3600 a minute, or \"off\"",
        error.PlayAndWrite => "--play writes nowhere and --output plays nothing; pick one",
    };
}

/// The whole of the command line.
///
/// Long options take their value either as the next argument or after an
/// `=`; short ones take the next argument. Nothing is positional, so a bare
/// word is a mistake rather than a filename — `-o` is not optional, because
/// a program whose default is to write to a terminal should not also be one
/// that silently creates files.
fn parse(args: []const []const u8) ParseError!Config {
    var config: Config = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) return error.UnexpectedArgument;

        // Split `--name=value` so that the rest of this only has to think
        // about a name and a way of asking for its value.
        var name = arg;
        var inline_value: ?[]const u8 = null;
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.findScalar(u8, arg, '=')) |eq| {
                name = arg[0..eq];
                inline_value = arg[eq + 1 ..];
            }
        }

        const Value = struct {
            fn next(v: ?[]const u8, args_: []const []const u8, i_: *usize) ParseError![]const u8 {
                if (v) |x| return x;
                if (i_.* + 1 >= args_.len) return error.MissingValue;
                i_.* += 1;
                return args_[i_.*];
            }
        };

        if (is(name, "-h", "--help")) {
            config.action = .help;
            return config;
        } else if (is(name, "-V", "--version")) {
            config.action = .version;
            return config;
        } else if (std.mem.eql(u8, name, "--raw")) {
            if (inline_value != null) return error.UnexpectedArgument;
            config.raw = true;
        } else if (is(name, "-p", "--play")) {
            if (inline_value != null) return error.UnexpectedArgument;
            config.play = true;
        } else if (std.mem.eql(u8, name, "--sink")) {
            config.sink = try Value.next(inline_value, args, &i);
            config.play = true;
        } else if (is(name, "-o", "--output")) {
            config.output = try Value.next(inline_value, args, &i);
        } else if (is(name, "-d", "--duration")) {
            const v = try Value.next(inline_value, args, &i);
            const secs = std.fmt.parseFloat(f64, v) catch return error.BadNumber;
            if (!(secs > 0) or !std.math.isFinite(secs)) return error.BadDuration;
            config.duration_seconds = secs;
        } else if (is(name, "-r", "--rate")) {
            const v = try Value.next(inline_value, args, &i);
            const rate = std.fmt.parseInt(u32, v, 10) catch return error.BadNumber;
            if (rate < 8_000 or rate > 768_000) return error.BadRate;
            config.rate = rate;
        } else if (is(name, "-c", "--channels")) {
            const v = try Value.next(inline_value, args, &i);
            const n = std.fmt.parseInt(u8, v, 10) catch return error.BadNumber;
            if (n != 1 and n != 2) return error.BadChannelCount;
            config.channels = n;
        } else if (is(name, "-f", "--format")) {
            const v = try Value.next(inline_value, args, &i);
            config.format = std.meta.stringToEnum(wopr.wav.Format, v) orelse return error.BadFormat;
        } else if (is(name, "-g", "--gain")) {
            const v = try Value.next(inline_value, args, &i);
            const db = std.fmt.parseFloat(f64, v) catch return error.BadNumber;
            if (!(db >= -120 and db <= 0)) return error.BadGain;
            config.gain_db = db;
        } else if (is(name, "-w", "--width")) {
            const v = try Value.next(inline_value, args, &i);
            const w = std.fmt.parseFloat(f64, v) catch return error.BadNumber;
            if (!(w >= 0 and w <= 1)) return error.BadWidth;
            config.width = w;
        } else if (is(name, "-n", "--hiss")) {
            const v = try Value.next(inline_value, args, &i);
            if (std.mem.eql(u8, v, "off")) {
                config.hiss_db = null;
            } else {
                const db = std.fmt.parseFloat(f64, v) catch return error.BadNumber;
                if (!(db >= -120 and db <= 0)) return error.BadHiss;
                config.hiss_db = db;
            }
        } else if (is(name, "-b", "--bursts")) {
            const v = try Value.next(inline_value, args, &i);
            if (std.mem.eql(u8, v, "off")) {
                config.bursts_per_minute = 0;
            } else {
                const n = std.fmt.parseFloat(f64, v) catch return error.BadNumber;
                if (!(n >= 0 and n <= 3600)) return error.BadBurstRate;
                config.bursts_per_minute = n;
            }
        } else if (is(name, "-s", "--seed")) {
            const v = try Value.next(inline_value, args, &i);
            config.seed = std.fmt.parseInt(u64, v, 0) catch return error.BadNumber;
        } else {
            return error.UnknownOption;
        }
    }
    if (config.play and config.output != null) return error.PlayAndWrite;
    return config;
}

fn is(arg: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long);
}

const testing = std.testing;

test "the defaults are a stereo 16 bit WAVE stream that never ends" {
    const config = try parse(&.{});
    try testing.expectEqual(@as(?[]const u8, null), config.output);
    try testing.expectEqual(@as(?f64, null), config.duration_seconds);
    try testing.expectEqual(@as(u32, 44_100), config.rate);
    try testing.expectEqual(@as(u8, 2), config.channels);
    try testing.expectEqual(wopr.wav.Format.s16, config.format);
    try testing.expect(!config.raw);
}

test "the usage text quotes the defaults it claims to" {
    // A help message that has drifted from the program is worse than none,
    // and these are the four numbers in it that can drift.
    const config = try parse(&.{});
    var buf: [64]u8 = undefined;
    inline for (.{ config.rate, config.channels, config.gain_db, config.width }) |value| {
        const quoted = try std.fmt.bufPrint(&buf, "(default {d})", .{value});
        if (std.mem.indexOf(u8, usage, quoted) == null) {
            std.debug.print("usage does not mention \"{s}\"\n", .{quoted});
            return error.UsageOutOfDate;
        }
    }
}

test "long options take their value either way round" {
    const spaced = try parse(&.{ "--rate", "48000", "--format", "f32" });
    const joined = try parse(&.{ "--rate=48000", "--format=f32" });
    try testing.expectEqual(@as(u32, 48_000), spaced.rate);
    try testing.expectEqual(@as(u32, 48_000), joined.rate);
    try testing.expectEqual(wopr.wav.Format.f32, spaced.format);
    try testing.expectEqual(wopr.wav.Format.f32, joined.format);
}

test "short options and their long spellings agree" {
    const short = try parse(&.{ "-c", "1", "-g", "-24", "-w", "0", "-s", "7", "-d", "1.5", "-o", "x.wav" });
    const long = try parse(&.{ "--channels", "1", "--gain", "-24", "--width", "0", "--seed", "7", "--duration", "1.5", "--output", "x.wav" });
    try testing.expectEqualDeep(short, long);
    try testing.expectEqual(@as(?u64, 7), short.seed);
    try testing.expectEqual(@as(f64, -24), short.gain_db);
}

test "the noise floor is off unless a level is given" {
    try testing.expectEqual(@as(?f64, null), (try parse(&.{})).hiss_db);
    try testing.expectEqual(@as(?f64, -24), (try parse(&.{ "--hiss", "-24" })).hiss_db);
    try testing.expectEqual(@as(?f64, -24), (try parse(&.{ "-n", "-24" })).hiss_db);
    // "off" spells the default out, for a script that wants to be explicit.
    try testing.expectEqual(@as(?f64, null), (try parse(&.{ "--hiss", "off" })).hiss_db);
    try testing.expectError(error.BadHiss, parse(&.{ "--hiss", "6" }));
    try testing.expectError(error.BadNumber, parse(&.{ "--hiss", "quiet" }));
}

test "the bursts can be thinned out or switched off" {
    try testing.expectEqual(@as(?f64, null), (try parse(&.{})).bursts_per_minute);
    try testing.expectEqual(@as(?f64, 20), (try parse(&.{ "--bursts", "20" })).bursts_per_minute);
    try testing.expectEqual(@as(?f64, 20), (try parse(&.{ "-b", "20" })).bursts_per_minute);
    // Zero rather than null, so that "off" is distinguishable from "as
    // measured" and can empty the burst table rather than dividing by it.
    try testing.expectEqual(@as(?f64, 0), (try parse(&.{ "--bursts", "off" })).bursts_per_minute);
    try testing.expectError(error.BadBurstRate, parse(&.{ "--bursts", "-4" }));
    try testing.expectError(error.BadNumber, parse(&.{ "--bursts", "lots" }));
}

test "a seed may be given in hexadecimal" {
    const config = try parse(&.{ "--seed", "0xdeadbeef" });
    try testing.expectEqual(@as(?u64, 0xdeadbeef), config.seed);
}

test "playing and writing a file are refused together, in either order" {
    try testing.expectError(error.PlayAndWrite, parse(&.{ "--play", "-o", "x.wav" }));
    try testing.expectError(error.PlayAndWrite, parse(&.{ "-o", "x.wav", "--play" }));
    try testing.expectError(error.PlayAndWrite, parse(&.{ "--sink", "a", "-o", "x.wav" }));
    try testing.expectError(error.PlayAndWrite, parse(&.{ "-o", "x.wav", "--sink", "a" }));
}

test "naming a sink is asking to play" {
    const config = try parse(&.{ "--sink", "alsa_output.usb-audio" });
    try testing.expect(config.play);
    try testing.expectEqualStrings("alsa_output.usb-audio", config.sink.?);
    try testing.expect((try parse(&.{"--play"})).play);
    try testing.expect((try parse(&.{"-p"})).play);
    // Neither, and `main` asks the terminal.
    try testing.expect(!(try parse(&.{})).play);
}

test "--help and --version stop reading, even mid-line" {
    try testing.expectEqual(Config.Action.help, (try parse(&.{ "--rate", "48000", "--help", "--nonsense" })).action);
    try testing.expectEqual(Config.Action.version, (try parse(&.{"-V"})).action);
}

test "bad input is refused rather than rounded into range" {
    try testing.expectError(error.UnknownOption, parse(&.{"--loudness"}));
    try testing.expectError(error.UnexpectedArgument, parse(&.{"hum.wav"}));
    try testing.expectError(error.UnexpectedArgument, parse(&.{"-"}));
    try testing.expectError(error.MissingValue, parse(&.{"--rate"}));
    try testing.expectError(error.BadNumber, parse(&.{ "--rate", "fast" }));
    try testing.expectError(error.BadRate, parse(&.{ "--rate", "4000" }));
    try testing.expectError(error.BadChannelCount, parse(&.{ "--channels", "6" }));
    try testing.expectError(error.BadFormat, parse(&.{ "--format", "mp3" }));
    try testing.expectError(error.BadDuration, parse(&.{ "--duration", "0" }));
    try testing.expectError(error.BadDuration, parse(&.{ "--duration", "-3" }));
    try testing.expectError(error.BadDuration, parse(&.{ "--duration", "nan" }));
    try testing.expectError(error.BadWidth, parse(&.{ "--width", "2" }));
    try testing.expectError(error.BadGain, parse(&.{ "--gain", "6" }));
}

test "every parse error has something to say" {
    inline for (@typeInfo(ParseError).error_set.?) |e| {
        try testing.expect(describe(@field(ParseError, e.name)).len > 0);
    }
}
