_: {
  name = "mixos-state";

  mixos.nodes.machine = { pkgs, ... }: {
    testing.qemu.diskImage = 1024 * 1024 * 1024;

    boot.kernelModules = [ "ext4" ];

    state = {
      enable = true;
      fsType = "ext2";
      source = "/dev/vda";
      options = [ "debug" ];
      init = pkgs.writeScript "state-init.sh" ''
        #!/bin/sh
        if ! blkid | grep mixos-state; then
          mkfs.ext2 -L mixos-state /dev/vda
        fi
      '';
    };
  };

  # Only started by its own subtest, since it never finishes booting.
  mixos.nodes.stuck = { lib, pkgs, ... }: {
    boot.watchdog.enable = true;
    boot.watchdog.timeout = 10; # so the reset comes quickly
    boot.requiredKernelConfig.I6300ESB_WDT = lib.kernel.module;
    boot.kernelModules = [ "i6300esb" ];

    state = {
      enable = true;
      source = "none";
      fsType = "tmpfs";
      init = pkgs.writeScript "never-finishes.sh" ''
        #!/bin/sh
        sleep infinity
      '';
    };
  };

  testScript = ''
    import datetime

    machine.start(allow_reboot=True)
    machine.succeed("test -b /dev/vda")
    machine.succeed("mount | grep '/dev/vda on /state type ext2'")
    machine.succeed("touch /state/hi")
    machine.execute("reboot", check_output=False)
    machine.connected = False
    machine.connect()
    machine.succeed("test -e /state/hi")

    with subtest("userspace restart handles state"):
        machine.succeed("touch /state/restarted")
        machine.execute("kill -QUIT 1", check_output=False)

        machine.wait_for_console_text("executing init")
        machine.connected = False
        machine.connect()

        machine.succeed("mount | grep '/dev/vda on /state type ext2'")
        machine.succeed("test -e /state/hi")
        machine.succeed("test -e /state/restarted")
        machine.shutdown()

    with subtest("state initialization times out"):
        stuck.start()
        stuck.wait_for_console_text(
            "failed to run state initialization: error.Timeout",
            timeout=datetime.timedelta(seconds=60),
        )
        stuck.wait_for_shutdown() # the watchdog goes off once boot has failed
  '';
}
