// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("pipewire", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const examples = [_]struct { name: []const u8, path: []const u8, desc: []const u8 }{
        .{ .name = "tone", .path = "examples/tone.zig", .desc = "Play a test tone (push API)" },
        .{ .name = "chord", .path = "examples/callback.zig", .desc = "Play a chord (pull API)" },
        .{ .name = "session", .path = "examples/session.zig", .desc = "List and change the graph" },
    };

    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = b.fmt("pw-{s}", .{example.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "pipewire", .module = mod },
                },
            }),
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
        const run_step = b.step(b.fmt("run-{s}", .{example.name}), example.desc);
        run_step.dependOn(&run_cmd.step);
    }

    const test_step = b.step("test", "Run tests");

    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    // The fuzz targets, which are properties rather than examples: what the
    // library must do with bytes nobody wrote. They are ordinary tests as well
    // as fuzz tests — without `--fuzz` each one runs the corpus checked in
    // beside it, so `zig build test` exercises them every time.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pipewire", .module = mod },
        },
    });

    // Zig's fuzzer takes one test at a time, so a run that is chasing a
    // particular target wants to build only that one:
    // `zig build fuzz --fuzz -Dfuzz-filter=pod`.
    const fuzz_filter = b.option(
        []const u8,
        "fuzz-filter",
        "Run only the fuzz target whose name matches",
    );
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
        .filters = if (fuzz_filter) |f| &.{f} else &.{},
    });
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // And a step of their own, for `zig build fuzz --fuzz`, which needs a run
    // step holding nothing else: the fuzzer takes over the terminal.
    const fuzz_step = b.step("fuzz", "The fuzz targets: add --fuzz to fuzz them");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // The loop that drives those same targets without Zig's fuzzer, which the
    // pinned toolchain can only build with a patched standard library;
    // `tools/fuzz.zig` says why. Optimised, because a fuzzer's whole job is how
    // many inputs it gets through.
    const fuzz_run = b.addExecutable(.{
        .name = "pw-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzz.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "fuzz_targets", .module = fuzz_mod },
            },
        }),
    });
    const fuzz_run_cmd = b.addRunArtifact(fuzz_run);
    if (b.args) |args| fuzz_run_cmd.addArgs(args);
    const fuzz_run_step = b.step("fuzz-run", "Drive the fuzz targets without Zig's fuzzer");
    fuzz_run_step.dependOn(&fuzz_run_cmd.step);

    // Benchmarks, always optimised: timing a Debug build measures the safety
    // checks rather than the code.
    const bench = b.addExecutable(.{
        .name = "pw-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "pipewire", .module = mod },
            },
        }),
    });
    const bench_cmd = b.addRunArtifact(bench);
    if (b.args) |args| bench_cmd.addArgs(args);
    const bench_step = b.step("bench", "Measure the hot paths and the graph cycle");
    bench_step.dependOn(&bench_cmd.step);
}
