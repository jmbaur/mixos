{
  description = "MixOS, a Minimal Nix OS";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs.lib)
        concatMapStringsSep
        escapeShellArg
        evalModules
        genAttrs
        getExe
        mapAttrs
        optionals
        ;
    in
    {
      overlays.default = final: prev: {
        mixos = final.callPackage ./package.nix { };
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyfinal: _: {
            mixos-testing-library = pyfinal.callPackage ./mixos-testing-library/package.nix { };
          })
        ];
      };

      hydraJobs.mixos.x86_64-linux = inputs.self.legacyPackages.x86_64-linux.mixos;

      legacyPackages = genAttrs [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ] (
        system:
        import inputs.nixpkgs {
          inherit system;
          overlays = [ inputs.self.overlays.default ];
        }
      );

      lib.mixosSystem =
        { modules }:
        evalModules {
          modules = [
            ./module.nix
            { nixpkgs.overlays = [ inputs.self.overlays.default ]; }
          ]
          ++ modules;
        };

      apps = mapAttrs (
        system: pkgs:
        let
          mixosConfig = inputs.self.lib.mixosSystem {
            modules = [
              ./test/mixos-configuration.nix
              {
                nixpkgs.nixpkgs = inputs.nixpkgs;
                nixpkgs.buildPlatform = system;
                nixpkgs.hostPlatform = builtins.replaceStrings [ "darwin" ] [ "linux" ] system;
              }
            ];
          };
          mixosPkgs = mixosConfig._module.args.pkgs;
          qemuOpts =
            (
              {
                x86_64 = [
                  "-machine"
                  "q35"
                ];
                arm64 = [
                  "-machine"
                  "virt"
                  "-cpu"
                  "cortex-a53"
                ];
              }
              .${mixosPkgs.stdenv.hostPlatform.linuxArch} or [ ]
            )
            ++ [
              "-m"
              "2G"
              "-nographic"
              "-device"
              "e1000,netdev=net0"
              "-netdev"
              "user,id=net0,hostfwd=tcp::8000-:8000"
              "-kernel"
              "${mixosConfig.config.system.build.all}/kernel"
              "-initrd"
              "test.initrd"
              "-append"
              "${toString (
                [ "debug" ] ++ optionals mixosPkgs.stdenv.hostPlatform.isx86_64 [ "console=ttyS0,115200" ]
              )}"
            ];
        in
        {
          default = {
            type = "app";
            meta.description = "Launch MixOS in a VM";
            program = getExe (
              pkgs.writeShellApplication {
                name = "mixos-test";
                runtimeInputs = [
                  pkgs.qemu
                  pkgs.cpio
                ];
                text = ''
                  tmp=$(mktemp -d)
                  trap 'rm -rf $tmp; rm -f {passthru,test}.initrd' EXIT
                  mkdir "$tmp/passthru"
                  echo hello >"$tmp/passthru/hello"
                  (cd "$tmp"; find . -print0 | cpio --quiet -o -H newc -R +0:+0 --null >"$OLDPWD/passthru.initrd")
                  cat ${mixosConfig.config.system.build.all}/initrd passthru.initrd >test.initrd

                  qemu-img create -f qcow2 mixos.qcow2 1G
                  qemu_opts+=("-drive" "file=mixos.qcow2,if=virtio")

                  declare -a qemu_opts
                  if [[ -c /dev/kvm ]]; then
                    qemu_opts+=("-enable-kvm")
                  fi

                  qemu_opts+=(${concatMapStringsSep " " escapeShellArg qemuOpts})
                  qemu-system-${mixosPkgs.stdenv.hostPlatform.qemuArch} "''${qemu_opts[@]}"
                '';
              }
            );
          };
        }
      ) inputs.self.legacyPackages;

      devShells = mapAttrs (_: pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            (python3.withPackages (p: [ p.mixos-testing-library ]))
            zig_0_15
          ];
        };
      }) inputs.self.legacyPackages;

      formatter = mapAttrs (
        _: pkgs:
        pkgs.treefmt.withConfig {
          runtimeInputs = [
            pkgs.nixfmt
            pkgs.ruff
            pkgs.zig_0_15
          ];

          settings = {
            on-unmatched = "info";

            formatter.nixfmt = {
              command = "nixfmt";
              includes = [ "*.nix" ];
            };

            formatter.ruff = {
              command = "ruff";
              options = [ "format" ];
              includes = [ "*.py" ];
            };

            formatter.zig = {
              command = "zig";
              options = [ "fmt" ];
              includes = [ "*.zig" ];
            };
          };
        }
      ) inputs.self.legacyPackages;
    };
}
