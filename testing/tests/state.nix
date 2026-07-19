{ config, ... }: {
  name = "mixos-state";

  mixos.nodes.machine = { pkgs, ... }: {
    testing.qemu.diskImage = 1024 * 1024 * 1024;

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
    import mixos

    mixos_machines = mixos.create_machines("${config.mixos.driverConfiguration}", create_machine)
    machine = mixos_machines.get("machine")

    try:
        machine.succeed("test -b /dev/vda")
        machine.succeed("mount | grep '/dev/vda on /state type ext2'")
    except: raise
    finally:
        machine.shutdown()
        machine.wait_for_shutdown()
        machine.release()
  '';
}
