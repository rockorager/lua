{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.follows = "baskingspot/flake-parts";
    baskingspot = {
      url = "github:baskingspot/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # imports and inputsFrom below mirror each other, except the toolchain
      # version: pick that once, in the import.
      imports = with inputs.baskingspot.flakeModules; [
        base
        zig."0.16"
      ];

      perSystem =
        { pkgs, config, ... }:
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = with config.devShells; [
              base
              zig
            ];

            packages = with pkgs; [
              # Reference C Lua, the same release as the vendored test
              # suite: the oracle for differential tests and the baseline
              # for benchmarks.
              lua5_5
              # `just bench-compare` (bench/README.md): nixpkgs' goperf is
              # golang.org/x/perf, which supplies benchstat, and util-linux
              # supplies taskset, which pins every run to one core.
              goperf
              util-linux
            ];
          };
        };
    };
}
