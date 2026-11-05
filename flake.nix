{
  inputs = {
    # Zig 0.17.1 is on master but not yet on nixos-unstable; return to
    # nixos-unstable once the channel has it.
    nixpkgs.url = "github:nixos/nixpkgs/master";
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
        zig."0.17"
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
              # golang.org/x/perf, which supplies benchstat, util-linux
              # supplies taskset, which pins every run to one core, and GNU
              # time reports each run's peak RSS.
              goperf
              util-linux
              time
              # Profiling the interpreter: `perf record` and `perf annotate`
              # on a ReleaseFast build.
              perf
              # `just capi-test`: lua-cjson's tests generate their UTF-8
              # data with Perl. The C compiler is mkShell's.
              perl
            ];

            # `just capi-test` builds these real C modules against
            # include/ and runs their own tests on the C-API lua: the
            # sources nixpkgs pins for its Lua 5.5 packages.
            LPEG_SRC = pkgs.lua5_5.pkgs.lpeg.src;
            LUA_CJSON_SRC = pkgs.lua5_5.pkgs.lua-cjson.src;
            LFS_SRC = pkgs.lua5_5.pkgs.luafilesystem.src;
            LUAPOSIX_SRC = pkgs.lua5_5.pkgs.luaposix.src;
          };
        };
    };
}
