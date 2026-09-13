{
  lib,
  nukeReferences,
  stdenvNoCC,
  zig_0_16,
  buildTools ? false,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = lib.concatStringsSep "-" ([ "mixos" ] ++ lib.optional buildTools "buildtools");
  version = "1.11.0";

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
    zig_0_16
  ];

  # Prevent zig (or anything else) from being in the runtime closure
  allowedReferences = [ ];

  dontSetZigDefaultFlags = true;

  zigBuildFlags = [
    "-Doptimize=ReleaseSmall"
    "-Dcpu=baseline"
    "-Dbuildtools=${lib.boolToString buildTools}"
    "-Dtarget=${
      {
        "armv7l-linux" = "arm-linux";
      }
      .${stdenvNoCC.hostPlatform.system} or stdenvNoCC.hostPlatform.system
    }"
  ];

  zigCheckFlags = finalAttrs.zigBuildFlags;

  postConfigure = ''
    ln -s ${finalAttrs.passthru.deps} "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  postFixup = ''
    nuke-refs -e $out $out/bin/*
  '';

  passthru.deps = zig_0_16.fetchDeps {
    pname = "mixos";
    inherit (finalAttrs) src version;
    hash = "sha256-AibAg0fTfKpT4RHMLliocerMt932J+vJpKrIYtWsS4Q=";
  };

  meta = {
    platforms = lib.platforms.linux;
    mainProgram = "mixos";
  };
})
