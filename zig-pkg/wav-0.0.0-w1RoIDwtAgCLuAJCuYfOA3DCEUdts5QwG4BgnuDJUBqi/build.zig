// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // RIFF itself: the twelve byte header, the chunk walk, the pad byte that
    // an odd-length chunk carries and does not count, and the nesting. WAVE is
    // one of the forms built on that container, and the container is somebody
    // else's problem -- a solved one, in a library of its own.
    const riff = b.dependency("riff", .{
        .target = target,
        .optimize = optimize,
    });

    // One module. The reader, the writer and the sample conversion between
    // them are one vocabulary and a few hundred lines; splitting them would
    // only make the vocabulary a fourth module that all three import. Zig
    // analyses what is referenced, so a program that only reads never
    // compiles the writer.
    const mod = b.addModule("wav", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "riff", .module = riff.module("riff") }},
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);

    // -- fuzzing -------------------------------------------------------------
    //
    // The fuzz targets: what the reader and the sample conversion must do with
    // input nobody wrote. They are ordinary tests as well as fuzz targets, so
    // `zig build test` exercises the same properties on the seeds checked in
    // beside them.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wav", .module = mod }},
    });
    // Zig's fuzzer takes one test at a time and keeps a coverage file per
    // test, so naming a target is what you want when a finding is being
    // chased: `zig build fuzz --fuzz -Dfuzz-filter=reader`.
    const fuzz_filter = b.option(
        []const u8,
        "fuzz-filter",
        "Fuzz or test only the targets whose name contains this",
    );
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
        .filters = if (fuzz_filter) |f| &.{f} else &.{},
    });
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // A step of its own for `zig build fuzz --fuzz`, holding nothing else: the
    // fuzzer takes over the terminal and runs until it is stopped, so it must
    // not be reachable from `zig build test`.
    const fuzz_step = b.step("fuzz", "The fuzz targets: add --fuzz to fuzz them");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // The loop that drives those same targets without Zig's fuzzer, which this
    // toolchain cannot usefully run: `tools/fuzz.zig` says why, and the short
    // version is that the coverage table comes back empty. Optimised, because
    // a fuzzer's whole job is how many inputs it gets through, and ReleaseSafe
    // keeps every check that makes a failure a failure.
    const fuzz_run = b.addExecutable(.{
        .name = "wav-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzz.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "fuzz_targets", .module = fuzz_mod }},
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz_run);
    run_fuzz.stdio = .inherit;
    if (b.args) |a| run_fuzz.addArgs(a);
    const fuzz_run_step = b.step("fuzz-run", "Fuzz the targets with a loop of our own");
    fuzz_run_step.dependOn(&run_fuzz.step);

    const check_step = b.step("check", "Compile everything without running it");
    // Nothing else builds the standalone fuzz driver, so without this it could
    // stop compiling and `zig build test` would not notice.
    check_step.dependOn(&fuzz_run.step);

    // -- the cross-check against another implementation ----------------------
    //
    // Everything else here compares this library against itself, which cannot
    // catch the two of them agreeing on something the format does not say.
    // `tools/crosscheck.sh` has ffmpeg write a file at each width, round-trips
    // it through `tools/crosscheck.zig`, and has ffmpeg decode both and
    // compare; the script says what that reaches that the unit tests do not.
    const crosscheck_tool = b.addExecutable(.{
        .name = "wav-crosscheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/crosscheck.zig"),
            // The machine running the build, since the script runs what it
            // builds rather than shipping it anywhere.
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "wav", .module = mod }},
        }),
    });

    const run_crosscheck = b.addSystemCommand(&.{"sh"});
    run_crosscheck.addFileArg(b.path("tools/crosscheck.sh"));
    run_crosscheck.addArtifactArg(crosscheck_tool);
    run_crosscheck.setName("crosscheck");
    // It needs ffmpeg, which is in the devshell and nowhere else, so its
    // complaint about not finding one has to reach the terminal.
    run_crosscheck.stdio = .inherit;

    const crosscheck_step = b.step("crosscheck", "Round-trip ffmpeg's WAVE files through this library");
    crosscheck_step.dependOn(&run_crosscheck.step);

    // It is not in `test`, because it needs a program this project does not
    // build and cannot assume; `check` builds it so that it cannot rot.
    check_step.dependOn(&crosscheck_tool.step);

    // -- documentation -------------------------------------------------------
    //
    // Zig emits the API documentation as a side effect of compiling, so the
    // module is built as a library purely to get at it. What comes out is not
    // a page but a program: a WebAssembly viewer, its javascript, and a tar of
    // the sources it reads from.
    const library = b.addLibrary(.{ .name = "wav", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Build the API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // That viewer fetches `sources.tar` and `main.wasm` at runtime, which a
    // browser refuses to do from a `file://` page, so reading the docs
    // locally means serving them. It is the same reason `zig std` runs a
    // server rather than opening a file.
    const docs_port = b.option(u16, "docs-port", "Port for `zig build docs-serve` (default 8000)") orelse 8000;

    const docs_server = b.addExecutable(.{
        .name = "docs-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/docs_server.zig"),
            // Always built for the machine running the build, never for
            // whatever -Dtarget the library is being built for.
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_docs_server = b.addRunArtifact(docs_server);
    run_docs_server.step.dependOn(&install_docs.step);
    run_docs_server.addArg(b.getInstallPath(.prefix, "docs"));
    run_docs_server.addArg(b.fmt("{d}", .{docs_port}));
    // The server runs until interrupted, so its output has to reach the
    // terminal rather than being captured by the build runner.
    run_docs_server.stdio = .inherit;

    const docs_serve_step = b.step("docs-serve", "Serve the API documentation over HTTP");
    docs_serve_step.dependOn(&run_docs_server.step);

    // The server has tests of its own; without this they would never run. And
    // nothing else builds it, so it belongs in `check` as well or it could
    // stop compiling without anything noticing.
    test_step.dependOn(&b.addRunArtifact(
        b.addTest(.{ .root_module = docs_server.root_module }),
    ).step);
    check_step.dependOn(&docs_server.step);

    // A library installs nothing, so without this `zig build` would compile
    // nothing and say it had succeeded.
    b.getInstallStep().dependOn(&library.step);
}
