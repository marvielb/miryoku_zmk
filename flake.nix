# Local build environment for miryoku_zmk on ZMK 0.3.
#
# Reproduces the toolchain inside the zmkfirmware/zmk-build-arm:stable container
# used by .github/workflows/main.yml: GNU Arm Embedded GCC 12 (that image's
# Zephyr SDK 0.16.x is GCC 12.3), CMake 3.2x and Python 3.11.
#
# nixpkgs is pinned to nixos-23.11 on purpose. Current nixpkgs ships CMake 4 and
# gcc-arm-embedded 15, both too new for Zephyr 3.5.
#
# Targets are defined in scripts/zmk-build.sh; the wrappers below only set up the
# toolchain and forward there.
#
# Usage:
#   nix run .#cygnus-dongle                  # build one target, artifacts in ./artifacts
#   nix run .#                               # build every target
#   nix develop -c ./scripts/zmk-build.sh cygnus-dongle   # same, through a shell

{
  description = "Local build environment for miryoku_zmk (ZMK 0.3)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];

      # Keep in sync with the targets in scripts/zmk-build.sh.
      targetNames = [
        "cygnus-left"
        "cygnus-right"
        "cygnus-dongle"
        "settings-reset"
      ];

      mkOutputs = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Zephyr 3.5 does not install its Python requirements itself; the
          # zmk-build-arm image pre-installs scripts/requirements-base.txt, so
          # the packages have to be supplied up front.
          pythonEnv = pkgs.python3.withPackages (ps: with ps; [
            west          # the manifest/build tool, plus Zephyr's west commands
            pyelftools    # gen_defines.py, linker scripts
            pyyaml        # devicetree bindings, kconfig
            pykwalify     # zephyr_module.py
            canopen       # west-commands
            packaging
            progress
            psutil
            pylink-square
            pyserial
            requests
            setuptools    # pkg_resources, required by nanopb's generator
            protobuf      # python protobuf, needed by the nanopb generator
            grpcio-tools  # python protoc, preferred by nanopb over a binary
            anytree       # ram/rom reports
            intelhex      # mergehex.py
          ]);

          # GNU Arm Embedded 12.3.rel1. Zephyr 3.5's gnuarmemb toolchain variant
          # expects <path>/bin/arm-none-eabi-* plus <path>/arm-none-eabi/ as the
          # sysroot, which is exactly this package's layout.
          armToolchain = pkgs.gcc-arm-embedded;

          # nixpkgs' west is a python-package wrapper that prepends its own
          # python interpreter to PATH. Every subprocess west then starts
          # inherits that, which breaks anything invoked by shebang -- most
          # notably nanopb's protoc, which runs via #!/usr/bin/env python3 and
          # then cannot import pkg_resources. Wrap west against pythonEnv
          # instead so PATH stays untouched.
          westBin = pkgs.writeShellScriptBin "west" ''
            exec ${pythonEnv}/bin/python3 ${pkgs.python3Packages.west}/bin/.west-wrapped "$@"
          '';

          toolchain = [
            westBin
            pythonEnv
            armToolchain
            pkgs.protobuf   # protoc binary, fallback when grpcio-tools is absent
            pkgs.bash
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.gnused
            pkgs.cmake
            pkgs.ninja
            pkgs.dtc
            pkgs.gperf
            pkgs.git
            pkgs.rsync
          ];

          # The wrapper resolves the checkout at runtime so it keeps working
          # even though the flake itself lives in the Nix store.
          runScript = targets:
            ''
              export PATH=${lib.makeBinPath toolchain}:$PATH
              export ZEPHYR_TOOLCHAIN_VARIANT=gnuarmemb
              export GNUARMEMB_TOOLCHAIN_PATH=${armToolchain}
              root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
              exec ${pkgs.bash}/bin/bash "$root/scripts/zmk-build.sh" ${targets} "$@"
            '';

          packages =
            lib.genAttrs targetNames (name: pkgs.writeShellScriptBin name (runScript name)) // {
              default = pkgs.writeShellScriptBin "build-all"
                (runScript (lib.escapeShellArgs targetNames));
            };
        in
        {
          devShells.default = pkgs.mkShell {
            name = "miryoku-zmk-0.3";
            packages = toolchain;
            ZEPHYR_TOOLCHAIN_VARIANT = "gnuarmemb";
            GNUARMEMB_TOOLCHAIN_PATH = "${armToolchain}";
          };

          inherit packages;

          apps = builtins.mapAttrs
            (name: drv: { type = "app"; program = "${drv}/bin/${drv.name}"; })
            packages;
        };
    in
    {
      devShells = lib.genAttrs systems (system: (mkOutputs system).devShells);
      packages = lib.genAttrs systems (system: (mkOutputs system).packages);
      apps = lib.genAttrs systems (system: (mkOutputs system).apps);
    };
}
