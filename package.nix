# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  lib,
  stdenv,
  callPackage,
  zig_0_16,
}:

let
  # Generated from build.zig.zon by zon2nix; regenerate with
  #   nix develop -c zon2nix --16 --nix=build.zig.zon.nix build.zig.zon
  zigDeps = callPackage ./build.zig.zon.nix { };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "wopr";
  version = "0.0.0";

  # Named rather than filtered, so that editing something outside this list --
  # the flake, the analysis scripts, a scratch file -- does not rebuild the
  # package.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./build.zig
      ./build.zig.zon
      ./site
      ./src
      ./tests
      ./tools
      ./LICENSES
      ./README.md
      ./REUSE.toml
    ];
  };

  nativeBuildInputs = [ zig_0_16.hook ];

  # `--system` does not merely offer the directory, it forbids fetching: a
  # dependency missing from it is a build error naming the package rather
  # than a silent attempt to reach a network the sandbox does not have.
  zigBuildFlags = [
    "--system"
    "${zigDeps}"
  ];
  # The check phase assembles its own flags rather than reusing the build's,
  # so without this `zig build test` runs without --system, tries to fetch,
  # and fails.
  zigCheckFlags = finalAttrs.zigBuildFlags;

  # The tests are pure: they render into a buffer and measure it. Nothing
  # here opens a file or a socket, so the build sandbox is enough -- the
  # PipeWire path is compiled but never run, since there is no daemon.
  doCheck = true;

  meta = {
    description = "A synthesiser for the WOPR machine-room hum from WarGames";
    homepage = "https://git.jcollie.dev/jeff/wopr";
    license = lib.licenses.mit;
    mainProgram = "wopr";
    platforms = lib.platforms.unix;
  };
})
