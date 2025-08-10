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

    zig_build_exe_args=(
      "-j$NIX_BUILD_CORES"
      "--color" "off"
      "-femit-bin=$out/init"
      "-mcpu" "baseline"
      "-ofmt=elf"
      "-fstrip"
      "-O" "ReleaseSmall"
      "-target" "${stdenvNoCC.hostPlatform.qemuArch}-linux"
      "${./mixos-rdinit.zig}"
    )

    HOME=$TMPDIR zig build-exe ''${zig_build_exe_args[@]}
  '';

  meta.platforms = lib.platforms.linux;
}
