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

  testScript = ''
    machine.start(allow_reboot=True)
    machine.succeed("test -b /dev/vda")
    machine.succeed("mount | grep '/dev/vda on /state type ext2'")
    machine.succeed("touch /state/hi")
    machine.succeed("reboot")
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
  '';
}
