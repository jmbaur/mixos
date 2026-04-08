{
  description = "MixOS, a Minimal Nix OS";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    inputs:
    let
      inherit (builtins) mapAttrs;
      inherit (inputs.nixpkgs.lib)
        concatMapStringsSep
        escapeShellArg
        evalModules
        genAttrs
        getExe
        optionals
        ;
    in
    {
      overlays.default = final: prev: {
        mixos = final.callPackage (
          {
            lib,
            nukeReferences,
            stdenvNoCC,
            zig_0_15,
          }:

          # TODO(jared): use zig's setup hook once https://github.com/NixOS/nixpkgs/commit/1dfa28594068cde0031ac471c48da20a18c67cd1 is in a stable release.
          stdenvNoCC.mkDerivation (
            finalAttrs:
            let
              deps = stdenvNoCC.mkDerivation {
                pname = finalAttrs.pname + "-deps";
                inherit (finalAttrs) src version;
                depsBuildBuild = [ zig_0_15 ];
                buildCommand = ''
                  export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
                  runHook unpackPhase
                  cd $sourceRoot
                  zig build --fetch
                  mv $ZIG_GLOBAL_CACHE_DIR/p $out
                '';
                outputHashAlgo = null;
                outputHashMode = "recursive";
                outputHash = "sha256-Sh3vZrYzpXkhvFTFH5RGm5nzwPO2gaSeLrp/k9bKXDs=";
              };
            in
            {
              pname = "mixos";
              version = "1.0.4";

              src = lib.fileset.toSource {
                root = ./.;
                fileset = lib.fileset.unions [
                  ./build.zig
                  ./build.zig.zon
                  ./com.jmbaur.mixos.varlink
                  ./src
                ];
              };

              __structuredAttrs = true;
              doCheck = true;
              strictDeps = true;

              nativeBuildInputs = [
                nukeReferences
                zig_0_15
              ];

              # Prevent zig (or anything else) from being in the runtime closure
              allowedReferences = [ ];

              zigBuildFlags = [
                "--color off"
                "-Doptimize=ReleaseSafe"
                "-Dcpu=baseline"
                "-Dtarget=${stdenvNoCC.hostPlatform.qemuArch}-${stdenvNoCC.hostPlatform.parsed.kernel.name}"
              ];

              configurePhase = ''
                runHook preConfigure
                export ZIG_GLOBAL_CACHE_DIR=$TMPDIR
                ln -s ${deps} $ZIG_GLOBAL_CACHE_DIR/p
                runHook postConfigure
              '';

              buildPhase = ''
                runHook preBuild
                zig build -j$NIX_BUILD_CORES ''${zigBuildFlags[@]}
                runHook postBuild
              '';

              checkPhase = ''
                runHook preCheck
                zig build test -j$NIX_BUILD_CORES ''${zigBuildFlags[@]}
                runHook postCheck
              '';

              installPhase = ''
                runHook preInstall
                zig build install -j$NIX_BUILD_CORES --prefix "$out" ''${zigBuildFlags[@]}
                runHook postInstall
              '';

              postFixup = ''
                find $out/bin $out/libexec -type f | while read i; do
                  nuke-refs -e $out $i
                done
              '';

              meta = {
                platforms = lib.platforms.linux;
                mainProgram = "mixos";
              };
            }
          )
        ) { };
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyfinal: _: {
            mixos-testing-library = builtins.warn "mixos-testing-library is a deprecated alias, use mixos instead" pyfinal.mixos;
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
            # TODO(jared): Remove when we have https://github.com/NixOS/nixpkgs/pull/502712 in a stable release
            varlink = pyfinal.callPackage (
              {
                buildPythonPackage,
                fetchFromGitHub,
                lib,
                setuptools,
                setuptools-scm,
              }:
              buildPythonPackage {
                pname = "varlink";
                version = "32.1.0";
                pyproject = true;
                build-system = [
                  setuptools
                  setuptools-scm
                ];
                src = fetchFromGitHub {
                  owner = "varlink";
                  repo = "python";
                  tag = "32.1.0";
                  hash = "sha256-cdTQ5OIhyPts3wuiyWZjEv9ItbHRlKbHd0nW0eAnj6s=";
                };
                meta.license = lib.licenses.asl20;
              }
            ) { };
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
              "vhost-vsock-pci,guest-cid=3"
              "-virtfs"
              "local,path=./,security_model=none,mount_tag=host"
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
            (python3.withPackages (p: [ (p.mixos.override { __editable = true; }) ]))
            libvarlink
            zig_0_15
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
