{
  description = "MixOS, a Minimal Nix OS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    pyproject-nix.url = "github:pyproject-nix/pyproject.nix";
    pyproject-nix.inputs.nixpkgs.follows = "nixpkgs";
    flake-compat = {
      url = "github:NixOS/flake-compat";
      flake = false;
    };
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs.lib.attrsets) unionOfDisjoint;
      inherit (inputs.nixpkgs.lib)
        const
        evalModules
        flip
        genAttrs
        listToAttrs
        mapAttrs
        mapAttrs'
        nameValuePair
        readDir
        removeSuffix
        fileset
        ;

      pythonProject = inputs.pyproject-nix.lib.project.loadPyproject {
        projectRoot = fileset.toSource {
          root = ./.;
          fileset = fileset.unions [
            ./pyproject.toml
            ./mixos
          ];
        };
      };
    in
    {
      overlays.default = final: prev: {
        mixos = final.callPackage ./package.nix { };
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyfinal: _: {
            mixos = pyfinal.callPackage (
              { buildPythonPackage }:
              buildPythonPackage (pythonProject.renderers.buildPythonPackage { inherit (pyfinal) python; })
            ) { };
          })
        ];
      };

      hydraJobs =
        let
          pkgs = inputs.self.legacyPackages.x86_64-linux;
        in
        unionOfDisjoint
          (mapAttrs' (flip (
            const (
              test:
              nameValuePair "test-${removeSuffix ".nix" test}" {
                x86_64-linux = pkgs.testers.runNixOSTest {
                  imports = [
                    inputs.self.lib.nixosTestModule
                    ./testing/tests/${test}
                  ];
                };
              }
            )
          )) (readDir ./testing/tests))
          (
            listToAttrs (
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
            )
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

      devShells = mapAttrs (const (
        pkgs:
        let
          python = pkgs.python3.override {
            self = python;
            packageOverrides = pyfinal: _: {
              mixos = pyfinal.callPackage (
                { mkPythonEditablePackage }:
                mkPythonEditablePackage (
                  {
                    root = "$REPO_ROOT";
                  }
                  // pythonProject.renderers.mkPythonEditablePackage { inherit (pyfinal) python; }
                )
              ) { };
            };
          };
        in
        {
          default = pkgs.mkShell {
            packages = [
              (python.withPackages (p: [ p.mixos ]))
              pkgs.zig_0_16
            ];
            shellHook = ''
              unset ZIG_GLOBAL_CACHE_DIR
              export REPO_ROOT=$(git rev-parse --show-toplevel)
            '';
          };
        }
      )) inputs.self.legacyPackages;

      formatter = mapAttrs (const (
        pkgs:
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
      )) inputs.self.legacyPackages;
    };
}
