# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "wopr";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    };
  };

  outputs =
    {
      nixpkgs,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      makePackages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        rec {
          wopr = pkgs.callPackage ./package.nix { };
          default = wopr;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        {
          default = pkgs.mkShell {
            name = "wopr";
            nativeBuildInputs = [
              # Plain nixpkgs Zig. The other Zig projects here wrap it to
              # patch one line of `compiler/test_runner.zig`, without which
              # `zig build --fuzz` cannot compile; there is no fuzz target in
              # this repository to need it. The only thing here that parses
              # anything somebody else wrote is the command line, and that is
              # covered by ordinary tests.
              pkgs.zig_0_16
              pkgs.git-pages-cli
              pkgs.pinact
              pkgs.reuse

              # What the scripts in `analysis/` need: ffmpeg to decode
              # whatever they are pointed at, and matplotlib for the
              # spectrogram in `bursts.py` -- which is not decoration, it is
              # how the ping and the pong were found.
              pkgs.ffmpeg
              (pkgs.python3.withPackages (
                python-pkgs: with python-pkgs; [
                  matplotlib
                  numpy
                  scipy
                ]
              ))
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              # `zig build run | pw-play --raw ...` is how the hum gets heard.
              pkgs.pipewire
            ];
          };
        }
      );
    };
}
