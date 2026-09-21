_: {
  name = "mixos-network";

  mixos.nodes.machine = { lib, pkgs, ... }: {
    boot.requiredKernelConfig.NET = lib.kernel.yes;

    services.udhcpc.run = pkgs.writeScript "udhcpc-run" ''
      #!/bin/sh
      exec /bin/udhcpc -f -i eth0
    '';
  };

  testScript = ''
    machine.succeed("ip link show dev lo | grep 'LOOPBACK,UP'")
    machine.wait_until_succeeds("ip addr show dev eth0 | grep 10.0.2.15")
  '';
}
