// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // One module: the synthesiser and the measured tables it is built from.
    // It depends on nothing but the standard library, on purpose -- a
    // program that renders a hum into its own audio callback should not
    // acquire a WAVE writer or a PipeWire client by linking one. Both of
    // those belong to the command line below.
    const mod = b.addModule("wopr", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // The same two modules again for the host, for `zig build site`, whose
    // sampler has to run here rather than on whatever -Dtarget was asked
    // for. When they are the same target Zig reuses the compilation, so
    // this costs nothing in the usual case.
    const host_mod = b.addModule("wopr-host", .{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
    });
    const host_wav = b.dependency("wav", .{ .target = b.graph.host, .optimize = .ReleaseFast });
    const host_play = b.createModule(.{
        .root_source_file = b.path(if (b.graph.host.result.os.tag == .linux)
            "src/play.zig"
        else
            "src/play_unsupported.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "wopr", .module = host_mod }},
    });
    if (b.graph.host.result.os.tag == .linux) {
        if (b.lazyDependency("pipewire", .{ .target = b.graph.host, .optimize = .ReleaseFast })) |dep| {
            host_play.addImport("pipewire", dep.module("pipewire"));
        }
    }

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

    // Writing the files. Not lazy and not conditional: a WAVE file is the
    // same on every target.
    const wav = b.dependency("wav", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "wopr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wopr", .module = mod },
                .{ .name = "play", .module = play },
                .{ .name = "wav", .module = wav.module("wav") },
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

    // -- the published site ---------------------------------------------------
    //
    // What goes to https://jeff.jcollie.page/wopr/ : a page that plays the
    // hum, with the API documentation under `api/`. The sample is rendered
    // here rather than committed, so the recording on the page is always
    // what the commit being documented actually produces -- a synthesiser
    // whose demo is a stale file is a synthesiser nobody can check.
    const site_seconds = b.option(f64, "site-seconds", "Length of the sample on the site (default 30)") orelse 30;
    const site_seed = b.option(u64, "site-seed", "Seed for the sample on the site (default 1983)") orelse 1983;

    // Built for the machine running the build, never for whatever -Dtarget
    // the rest is being built for: this one has to run.
    const sampler = b.addExecutable(.{
        .name = "wopr-sampler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "wopr", .module = host_mod },
                .{ .name = "play", .module = host_play },
                .{ .name = "wav", .module = host_wav.module("wav") },
            },
        }),
    });

    const render_sample = b.addRunArtifact(sampler);
    render_sample.addArgs(&.{ "--duration", b.fmt("{d}", .{site_seconds}) });
    // A fixed seed, so that a docs build that changed nothing about the
    // synthesis produces the identical file and `git-pages-cli` has nothing
    // to upload. Without it every push would push five megabytes.
    render_sample.addArgs(&.{ "--seed", b.fmt("{d}", .{site_seed}) });
    render_sample.addArg("--output");
    const sample = render_sample.addOutputFileArg("hum.wav");

    const site_step = b.step("site", "Assemble the published site into zig-out/site");
    site_step.dependOn(&b.addInstallFile(b.path("site/index.html"), "site/index.html").step);
    site_step.dependOn(&b.addInstallFile(sample, "site/hum.wav").step);
    site_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "site/api",
    }).step);

    // Nothing else builds the sampler for the host when cross compiling.
    check_step.dependOn(&sampler.step);

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

    // The same server pointed at the whole site rather than just the API
    // documentation, which is what actually gets published: the page, the
    // sample it plays, and the documentation under `api/`. Worth having
    // separately from `docs-serve` because a page is a thing to look at
    // before it goes up.
    const run_site_server = b.addRunArtifact(docs_server);
    run_site_server.step.dependOn(site_step);
    run_site_server.addArg(b.getInstallPath(.prefix, "site"));
    run_site_server.addArg(b.fmt("{d}", .{docs_port}));
    run_site_server.stdio = .inherit;

    const site_serve_step = b.step("site-serve", "Serve the published site over HTTP");
    site_serve_step.dependOn(&run_site_server.step);

    // The server has tests of its own; without this they would never run.
    // And nothing else builds it, so it belongs in `check` or it could stop
    // compiling without anything noticing.
    test_step.dependOn(&b.addRunArtifact(
        b.addTest(.{ .root_module = docs_server.root_module }),
    ).step);
    check_step.dependOn(&docs_server.step);
}
