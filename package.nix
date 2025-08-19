{
  lib,
  stdenvNoCC,
  zig_0_14,
}:

stdenvNoCC.mkDerivation {
  pname = "mixos";
  version = "0.1.0";

  depsBuildBuild = [ zig_0_14 ];

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./build.zig
      ./build.zig.zon
      ./src
    ];
  };

  __structuredAttrs = true;

  zigBuildFlags = [
    "--color off"
    "-Doptimize=ReleaseSmall"
    "-Dcpu=baseline"
    "-Dtarget=${stdenvNoCC.hostPlatform.qemuArch}-${stdenvNoCC.hostPlatform.parsed.kernel.name}"
  ];

  doCheck = true;

  configurePhase = ''
    runHook preConfigure
    export ZIG_GLOBAL_CACHE_DIR=$TEMPDIR
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
    zig build install --prefix $out ''${zigBuildFlags[@]}
    runHook postInstall
  '';

  meta.platforms = lib.platforms.linux;
}
