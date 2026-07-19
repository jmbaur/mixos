{ config, ... }: {
  name = "mixos-kernel-modules";

  mixos.nodes.machine = { config, pkgs, ... }: {
    # TODO(jared): formalize this as module option(s)
    etc."modprobe.d/mixos.conf".source = pkgs.writeText "modprobe-mixos.conf" ''
      options nvme-tcp wq_unbound=Y
    '';

    boot.extraModulePackages = [ config.boot.kernelPackages.jool ];
    boot.kernelModules = [
      "nvme-tcp"
      "jool"
    ];
  };

  testScript = ''
    import mixos

    mixos_machines = mixos.create_machines("${config.mixos.driverConfiguration}", create_machine)
    machine = mixos_machines.get("machine")

    try:
        # kernel module options are set correctly
        assert "Y" == machine.succeed("cat /sys/module/nvme_tcp/parameters/wq_unbound").strip()

        # out-of-tree module loads successfully
        machine.succeed("lsmod | grep jool")
    except: raise
    finally:
        machine.shutdown()
        machine.wait_for_shutdown()
        machine.release()
  '';
}
