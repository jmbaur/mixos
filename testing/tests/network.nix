{ config, ... }: {
  name = "mixos-network";

  mixos.nodes.machine = { lib, ... }: {
    boot.requiredKernelConfig.NET = lib.kernel.yes;
  };

  testScript = ''
    import mixos

    mixos_machines = mixos.create_machines("${config.mixos.driverConfiguration}", create_machine)
    machine = mixos_machines.get("machine")

    try:
        machine.succeed("ip link show dev lo | grep 'LOOPBACK,UP'")
    except: raise
    finally:
        machine.shutdown()
        machine.wait_for_shutdown()
        machine.release()
  '';
}
