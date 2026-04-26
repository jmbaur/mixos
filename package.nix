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
    version = "1.3.0";

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
      "-Doptimize=ReleaseSmall"
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
      nuke-refs -e $out $out/bin/mixos
    '';

    meta = {
      platforms = lib.platforms.linux;
      mainProgram = "mixos";
    };
  }
)
