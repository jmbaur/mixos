{
  lib,
  stdenvNoCC,
  zig_0_15,
}:

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
      outputHash = "sha256-H0VzWTP00Pg9zPa6rCgGCcf8/NgTa0ng1aZh5tjt4ZU=";
    };
  in
  {
    pname = "mixos";
    version = "0.1.0";

    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./build.zig
        ./build.zig.zon
        ./src
      ];
    };

    __structuredAttrs = true;
    doCheck = true;
    dontPatchELF = true;
    dontStrip = true;
    strictDeps = true;

    zigBuildFlags = [
      "--color off"
      "-Doptimize=ReleaseSafe"
      "-Dcpu=baseline"
      "-Dtarget=${stdenvNoCC.hostPlatform.qemuArch}-${stdenvNoCC.hostPlatform.parsed.kernel.name}"
    ];

    nativeBuildInputs = [ zig_0_15 ];

    preHook = ''
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR
      ln -s ${deps} $ZIG_GLOBAL_CACHE_DIR/p
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

    meta = {
      platforms = lib.platforms.linux;
      mainProgram = "mixos";
    };
  }
)
