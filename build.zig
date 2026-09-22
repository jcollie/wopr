// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // One module: the synthesiser, the partial table it is built from, and
    // the little bit of RIFF/WAVE needed to hand samples to a player. They
    // are one module because they are one idea and total a few hundred
    // lines; Zig only analyses what is referenced, so a program that renders
    // into its own audio callback never compiles the WAVE header writer.
    const mod = b.addModule("wopr", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Playing the hum into PipeWire, which is a Linux daemon reached with
    // Linux syscalls -- so off Linux the stand-in is compiled instead and
    // `--play` becomes a message rather than a build failure. The library
    // module above deliberately does not depend on any of this: a program
    // that renders into its own audio callback should not acquire a
    // PipeWire dependency by linking a hum.
    const linux = target.result.os.tag == .linux;
    const play = b.createModule(.{
        .root_source_file = b.path(if (linux) "src/play.zig" else "src/play_unsupported.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wopr", .module = mod }},
    });
    if (linux) {
        // Lazy in `build.zig.zon`, so this is also what fetches it.
        if (b.lazyDependency("pipewire", .{ .target = target, .optimize = optimize })) |dep| {
            play.addImport("pipewire", dep.module("pipewire"));
        }
    }

    const exe = b.addExecutable(.{
        .name = "wopr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wopr", .module = mod },
                .{ .name = "play", .module = play },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // It writes audio to stdout and runs until it is stopped, so the build
    // runner must not be holding either end of that.
    run_cmd.stdio = .inherit;
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Play the hum: `zig build run -- --duration 10`");
    run_step.dependOn(&run_cmd.step);

    // A test executable covers one module, so each needs its own. Missing
    // one out would not fail: its tests would simply never run.
    const test_step = b.step("test", "Run tests");
    for ([_]*std.Build.Module{ mod, exe.root_module }) |m| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }

    // What the synthesiser is measured against: the spectrum, the channel
    // correlation, the crest factor. They are a module of their own because
    // they render seconds of audio and analyse it, which is slower than a
    // unit test should be allowed to make the rest of the suite, and because
    // they are the place where a claim about the *sound* gets written down.
    const acoustics = b.createModule(.{
        .root_source_file = b.path("tests/acoustics.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wopr", .module = mod }},
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = acoustics })).step);

    const check_step = b.step("check", "Compile everything without running it");
    check_step.dependOn(&exe.step);

    // The stand-in is never built by anything above on Linux, which is
    // where this is developed, so without this it could stop compiling and
    // only a cross build would find out.
    const play_stub = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/play_unsupported.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "wopr", .module = mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(play_stub).step);

    // -- documentation -------------------------------------------------------
    //
    // Zig emits the API documentation as a side effect of compiling, so the
    // module is built as a library purely to get at it. What comes out is not
    // a page but a program: a WebAssembly viewer, its javascript, and a tar
    // of the sources it reads from.
    const library = b.addLibrary(.{ .name = "wopr", .root_module = mod });
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

    // The server has tests of its own; without this they would never run.
    // And nothing else builds it, so it belongs in `check` or it could stop
    // compiling without anything noticing.
    test_step.dependOn(&b.addRunArtifact(
        b.addTest(.{ .root_module = docs_server.root_module }),
    ).step);
    check_step.dependOn(&docs_server.step);
}
