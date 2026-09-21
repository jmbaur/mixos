let
  banner = "GRAPHICS WORKS";
  westonLog = "/run/weston.log";
  waylandSocket = "wayland-0";
  runtimeDir = "/run/user/0";
in
{
  name = "mixos-graphics";

  enableOCR = true;

  mixos.nodes.machine =
    { lib, pkgs, ... }:
    let
      # TODO(jared): this probably belongs in module.nix under
      # hardware.graphics.enable rather than in a test.
      fontconfigEtc = pkgs.runCommand "mixos-fontconfig-etc" { } ''
        mkdir -p $out
        ln -s ${pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; }} $out/fonts.conf
        ln -s ${pkgs.fontconfig.out}/etc/fonts/conf.d $out/conf.d
      '';

      terminalShell = pkgs.writeScript "weston-terminal-shell" ''
        #!/bin/sh
        echo "${banner}"
        exec /bin/sh
      '';
    in
    {
      hardware.graphics.enable = true;

      packages = [ pkgs.weston ];

      etc."fonts".source = fontconfigEtc;

      # mesa is large
      testing.qemu.memory = 4 * 1024 * 1024 * 1024;

      boot.requiredKernelConfig.DRM_BOCHS = lib.kernel.module;

      services.weston.run = pkgs.writeScript "weston-run" ''
        #!/bin/sh

        exec >>${westonLog} 2>&1

        export XDG_RUNTIME_DIR=${runtimeDir}
        mkdir -p "$XDG_RUNTIME_DIR"
        chmod 0700 "$XDG_RUNTIME_DIR"

        # Required for libinput to work.
        # TODO(jared): This is not very well fleshed out.
        export LD_LIBRARY_PATH=${pkgs.libudev-zero}/lib

        exec weston \
          --backend=drm \
          --drm-device=card0 \
          --socket=${waylandSocket} \
          --no-config \
          --idle-time=0 \
          -- weston-terminal --font-size=32 --shell=${terminalShell}
      '';
    };

  testScript = ''
    import datetime

    with subtest("mesa is installed"):
        machine.succeed("test -L /run/opengl-driver")
        machine.succeed("test -e /run/opengl-driver/lib/libEGL_mesa.so")

    with subtest("the kernel gives us a DRM device"):
        machine.wait_until_succeeds(
            "test -c /dev/dri/card0", timeout=datetime.timedelta(seconds=30)
        )

    with subtest("weston comes up on it"):
        machine.wait_until_succeeds(
            "test -S ${runtimeDir}/${waylandSocket}",
            timeout=datetime.timedelta(seconds=60),
        )

    with subtest("weston-terminal renders to the screen"):
        machine.wait_for_text("${banner}", timeout=datetime.timedelta(seconds=60))
        machine.screenshot("weston-terminal")
  '';
}
