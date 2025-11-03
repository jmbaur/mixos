{
  lib,
  stdenvNoCC,
  zig_0_15,
}:

stdenvNoCC.mkDerivation {
  pname = "mixos";
  version = "0.1.0";

  depsBuildBuild = [ zig_0_15 ];

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./build.zig
      ./build.zig.zon
      ./src
    ];
  };

  __structuredAttrs = true;
  strictDeps = true;

  zigBuildFlags = [
    "--color off"
    "-Doptimize=ReleaseSafe"
    "-Dcpu=baseline"
    "-Dtarget=${stdenvNoCC.hostPlatform.qemuArch}-${stdenvNoCC.hostPlatform.parsed.kernel.name}"
  ];

  doCheck = true;

  # We produce statically built executables, no need for these.
  dontStrip = true;
  dontPatchELF = true;

  preHook = ''
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR
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
    for symlink in modprobe insmod; do
      ln -sf "$out/bin/mixos" "$out/bin/$symlink"
    done
    unset -v symlink
    runHook postInstall
  '';

  meta = {
    platforms = lib.platforms.linux;
    mainProgram = "mixos";
  };
}
