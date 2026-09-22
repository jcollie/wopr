# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  lib,
  stdenv,
  zig_0_16,
}:

stdenv.mkDerivation {
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
      ./src
      ./tests
      ./tools
      ./LICENSES
      ./README.md
      ./REUSE.toml
    ];
  };

  nativeBuildInputs = [ zig_0_16.hook ];

  # The tests are pure: they render into a buffer and measure it. Nothing
  # here opens a file or a socket, so the build sandbox is enough.
  doCheck = true;

  meta = {
    description = "A synthesiser for the WOPR machine-room hum from WarGames";
    homepage = "https://git.jcollie.dev/jeff/wopr";
    license = lib.licenses.mit;
    mainProgram = "wopr";
    platforms = lib.platforms.unix;
  };
}
