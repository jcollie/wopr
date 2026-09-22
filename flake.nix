# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "wopr";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    };
    zon2nix = {
      url = "github:jcollie/zon2nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs =
    {
      nixpkgs,
      zon2nix,
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
          # The Zig dependencies on their own, so that a workflow job can
          # run `zig build` for something other than the package -- the
          # documentation -- without a network.
          zig-deps = pkgs.callPackage ./build.zig.zon.nix { };
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

              # Regenerating `build.zig.zon.nix` shells out to `zig env`, so
              # the one it finds has to be the one this project builds with
              # rather than whatever happens to be on PATH.
              (pkgs.symlinkJoin {
                name = "zon2nix";
                paths = [ zon2nix.packages.${pkgs.stdenv.hostPlatform.system}.zon2nix ];
                nativeBuildInputs = [ pkgs.makeWrapper ];
                postBuild = ''
                  wrapProgram $out/bin/zon2nix \
                    --prefix PATH : ${lib.makeBinPath [ pkgs.zig_0_16 ]}
                '';
              })
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
