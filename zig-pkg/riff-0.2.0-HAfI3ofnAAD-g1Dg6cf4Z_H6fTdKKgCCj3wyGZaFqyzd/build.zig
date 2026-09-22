// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("riff", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);

    // The API documentation, which is where the doc comments in this library
    // are meant to be read. A library is built purely to get at it: Zig emits
    // the documentation as a side effect of compiling.
    // A consumer imports the module above and never links against a compiled
    // object, so this artifact exists for two other reasons. Zig emits the API
    // documentation as a side effect of compiling, and something has to do
    // that compiling; and `zig build` with nothing installed produces an empty
    // output directory, which a Nix build rejects as a derivation that built
    // nothing.
    const library = b.addLibrary(.{ .name = "riff", .root_module = mod });
    b.installArtifact(library);
    const install_docs = b.addInstallDirectory(.{
        .source_dir = library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Build the API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    const docs_port = b.option(u16, "docs-port", "Port for `zig build docs-serve` (default 8000)") orelse 8000;
    const docs_server = b.addExecutable(.{
        .name = "docs-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/docs_server.zig"),
            // Always the machine running the build, never whatever -Dtarget
            // the library is being built for.
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_docs_server = b.addRunArtifact(docs_server);
    run_docs_server.step.dependOn(&install_docs.step);
    run_docs_server.addArg(b.getInstallPath(.prefix, "docs"));
    run_docs_server.addArg(b.fmt("{d}", .{docs_port}));
    // It runs until interrupted, so its output has to reach the terminal
    // rather than being captured by the build runner.
    run_docs_server.stdio = .inherit;
    const docs_serve_step = b.step("docs-serve", "Serve the API documentation over HTTP");
    docs_serve_step.dependOn(&run_docs_server.step);

    // The server has a test of its own, and nothing else builds it, so
    // without these two lines it could stop compiling and no test would
    // notice.
    test_step.dependOn(&b.addRunArtifact(
        b.addTest(.{ .root_module = docs_server.root_module }),
    ).step);

    const check_step = b.step("check", "Compile everything without running it");
    check_step.dependOn(&library.step);
    check_step.dependOn(&docs_server.step);
}
