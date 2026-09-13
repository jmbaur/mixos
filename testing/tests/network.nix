_: {
  name = "mixos-network";

  mixos.nodes.machine = { lib, ... }: {
    boot.requiredKernelConfig.NET = lib.kernel.yes;
  };

  testScript = ''
    machine.succeed("ip link show dev lo | grep 'LOOPBACK,UP'")
  '';
}
