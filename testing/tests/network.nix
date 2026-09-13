{ config, ... }: {
  name = "mixos-network";

  mixos.nodes.machine = { lib, ... }: {
    boot.requiredKernelConfig.NET = lib.kernel.yes;
  };

  testScript = ''
    import mixos

    machine = mixos.create_machines("${config.mixos.driverConfiguration}", driver)["machine"]

    machine.succeed("ip link show dev lo | grep 'LOOPBACK,UP'")
  '';
}
