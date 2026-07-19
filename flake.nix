{
  description = "MixOS, a Minimal Nix OS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-compat = {
      url = "github:NixOS/flake-compat";
      flake = false;
    };
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs.lib)
        evalModules
        genAttrs
        listToAttrs
        mapAttrs
        ;
    in
    {
      overlays.default = final: prev: {
        mixos = final.callPackage ./package.nix { };
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyfinal: _: {
            mixos = pyfinal.callPackage (
              {
                __editable ? false,
                buildPythonPackage,
                lib,
                mkPythonEditablePackage,
                setuptools,
                varlink,
              }:

              let
                pname = pyproject.project.name;
                inherit (pyproject.project) version;
                pyproject = lib.importTOML ./pyproject.toml;
                build-system = [ setuptools ];
                dependencies = [ varlink ];
              in
              if __editable then
                mkPythonEditablePackage {
                  inherit
                    pname
                    version
                    build-system
                    dependencies
                    ;

                  root = "$REPO_ROOT";
                }
              else
                buildPythonPackage {
                  inherit
                    pname
                    version
                    build-system
                    dependencies
                    ;

                  pyproject = true;

                  src = lib.fileset.toSource {
                    root = ./.;
                    fileset = lib.fileset.unions [
                      ./pyproject.toml
                      ./mixos
                    ];
                  };

                  meta.mainProgram = "mixos";
                }
            ) { };
          })
        ];
      };

      hydraJobs =
        let
          pkgs = inputs.self.legacyPackages.x86_64-linux;
        in
        {
          test.x86_64-linux = pkgs.testers.runNixOSTest (
            { config, ... }:
            {
              imports = [ inputs.self.lib.nixosTestModule ];
              name = "mixos-example-test";
              mixos.nodes.machine =
                { pkgs, ... }:
                {
                  imports = [ ./testing/example.nix ];
                  packages = [ pkgs.hello ];
                };
              testScript = ''
                import mixos

                mixos_machines = mixos.create_machines("${config.mixos.driverConfiguration}", create_machine)
                machine = mixos_machines.get("machine")
                machine.succeed("hello")
                machine.fail("helloo")
                machine.shutdown()
                machine.wait_for_shutdown()
                machine.release()
              '';
            }
          );

        }
        // listToAttrs (
          map
            (pkgs: {
              name =
                "mixos-"
                + (
                  if (pkgs.stdenv.hostPlatform != pkgs.stdenv.buildPlatform) then
                    "cross-${pkgs.stdenv.hostPlatform.system}"
                  else
                    "native"
                );
              value = {
                x86_64-linux = pkgs.mixos;
              };
            })
            [
              pkgs
              pkgs.pkgsCross.aarch64-multiplatform
              pkgs.pkgsCross.armv7l-hf-multiplatform
              pkgs.pkgsCross.riscv64
              pkgs.pkgsCross.riscv32
              pkgs.pkgsCross.ppc64
              pkgs.pkgsCross.mips64el-linux-gnuabi64
            ]
        );

      legacyPackages = genAttrs [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (
        system:
        import inputs.nixpkgs {
          inherit system;
          overlays = [ inputs.self.overlays.default ];
        }
      );

      # Used to construct a new MixOS configuration
      lib.mixosSystem =
        {
          modules,
          baseModules ? [ ],
        }:
        let
          baseModules' = [ ./module.nix ] ++ baseModules;
          noUserModulesModule = {
            _module.args.noUserModules = evalModules { modules = baseModules'; };
          };
        in
        evalModules {
          modules = baseModules' ++ [ noUserModulesModule ] ++ modules;
        };

      # Used with the NixOS VM testing framework
      lib.nixosTestModule.imports = [ (import ./testing/module.nix inputs.self.lib.mixosSystem) ];

      devShells = mapAttrs (_: pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            (python3.withPackages (p: [ (p.mixos.override { __editable = true; }) ]))
            zig_0_16
          ];
          shellHook = ''
            unset ZIG_GLOBAL_CACHE_DIR
            export REPO_ROOT=$(git rev-parse --show-toplevel)
          '';
        };
      }) inputs.self.legacyPackages;

      formatter = mapAttrs (
        _: pkgs:
        pkgs.treefmt.withConfig {
          runtimeInputs = [
            pkgs.nixfmt
            pkgs.ruff
            pkgs.zig_0_16
            pkgs.statix
            pkgs.zigimports
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

            formatter.statix = {
              command = pkgs.writeShellScript "statix-fix" ''
                for file in "$@"; do
                  statix fix "$file"
                done
              '';
              includes = [ "*.nix" ];
            };

            formatter.zig = {
              command = "zig";
              options = [ "fmt" ];
              includes = [ "*.zig" ];
            };

            formatter.zigimports = {
              command = "zigimports";
              options = [ "--fix" ];
              includes = [ "*.zig" ];
            };
          };
        }
      ) inputs.self.legacyPackages;
    };
}
