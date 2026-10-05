{
  bintools,
  buildPackages,
  callPackage,
  lib,
  nukeReferences,
  stdenvNoCC,
  zig_0_17,

  revision ? "main", # just for docs
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "mixos";
  version = import ./version.nix;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./build.zig
      ./build.zig.zon
      ./com.jmbaur.mixos.varlink
      ./src
    ];
  };

  outputs = [
    "out"
    "buildtools"
  ];

  __structuredAttrs = true;
  doCheck = true;
  strictDeps = true;
  separateDebugInfo = true;
  nativeBuildInputs = [
    bintools # needed for strip hook
    nukeReferences
    zig_0_17
  ];

  # Prevent zig (or anything else) from being in the runtime closure (debug output is excluded).
  allowedReferences = [ ];

  dontSetZigDefaultFlags = true;

  zigBuildFlags = [
    "-Doptimize=safe"
    "-Dcpu=baseline"
    "--build-id=sha1" # used by separateDebugInfo
    "-Dtarget=${
      {
        "armv7l-linux" = "arm-linux";
        "i686-linux" = "x86-linux";
      }
      .${stdenvNoCC.hostPlatform.system} or stdenvNoCC.hostPlatform.system
    }"
  ];

  zigCheckFlags = finalAttrs.zigBuildFlags;

  postConfigure = ''
    ln -s ${finalAttrs.passthru.deps} "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  postInstall = ''
    mkdir -p $buildtools/bin
    mv $out/buildtools/* $buildtools/bin/
    rmdir $out/buildtools
  '';

  postFixup = ''
    nuke-refs -e $out $out/bin/*
    nuke-refs -e $buildtools $buildtools/bin/*
  '';

  passthru = {
    deps = buildPackages.zig_0_17.fetchDeps {
      pname = "mixos";
      inherit (finalAttrs) src version;
      hash = "sha256-E0J8FsSmUDD6oc/1A7OUXd6nZMbLqi+zKMwbDdDHqBM=";
    };

    manual = callPackage ./doc {
      inherit revision;
      inherit (finalAttrs) version;
    };
  };

  meta = {
    platforms = lib.platforms.linux;
    mainProgram = "mixos";
  };
})
