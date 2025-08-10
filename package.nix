{
  lib,
  stdenvNoCC,
  zig_0_14,
}:

stdenvNoCC.mkDerivation {
  pname = "mixos-rdinit";
  version = "0.1.0";

  depsBuildBuild = [ zig_0_14 ];

  # TODO(jared): Allow for stack traces with ReleaseSmall. See
  # https://github.com/ziglang/zig/issues/18520
  buildCommand = ''
    mkdir -p $out

    export ZIG_GLOBAL_CACHE_DIR=$TEMPDIR

    zig_args=("-j$NIX_BUILD_CORES" "--color" "off")
    zig_build_exe_args=(
      "''${zig_args[@]}"
      "-femit-bin=$out/init"
      "-mcpu" "baseline"
      "-ofmt=elf"
      "-fstrip"
      "-O" "ReleaseSmall"
      "-target" "${stdenvNoCC.hostPlatform.qemuArch}-linux"
    )

    zig test ''${zig_args[@]} ${./mixos-rdinit.zig}
    zig build-exe ''${zig_build_exe_args[@]} ${./mixos-rdinit.zig}
    rm -f $out/*.o
  '';

  meta.platforms = lib.platforms.linux;
}
