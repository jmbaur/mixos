{ config, ... }:
{
  name = "mixos-vde-network";

  nodes.nixosnode = {
    virtualisation.vlans = [ 1 ];
  };

  # Attached to the same virtual network as the NixOS node, plus one that only
  # MixOS machines use.
  mixos.nodes.machine1.virtualisation.vlans = [
    1
    2
  ];

  mixos.nodes.machine2.virtualisation.vlans = [ 2 ];

  testScript = ''
    import mixos

    mixos_machines = mixos.create_machines("${config.mixos.driverConfiguration}", driver)
    machine1 = mixos_machines["machine1"]
    machine2 = mixos_machines["machine2"]

    start_all()
    nixosnode.wait_for_unit("network.target")

    # Interfaces are named and addressed following the NixOS node numbering,
    # which continues into the MixOS machines.
    machine1.succeed("ip -4 address show dev eth1 | grep 192.168.1.2")
    machine1.succeed("ip -4 address show dev eth2 | grep 192.168.2.2")
    machine2.succeed("ip -4 address show dev eth1 | grep 192.168.2.3")

    # MixOS and NixOS machines share a VDE switch.
    machine1.succeed("ping -c 1 192.168.1.1")
    machine1.succeed("ping -6 -c 1 2001:db8:1::1")
    nixosnode.succeed("ping -c 1 192.168.1.2")
    nixosnode.succeed("ping -c 1 -6 2001:db8:1::2")

    # The driver starts a VDE switch for networks that no NixOS node uses.
    machine1.succeed("ping -c 1 192.168.2.3")
    machine2.succeed("ping -c 1 192.168.2.2")

    # Both kinds of machine can reach each other by name.
    nixosnode.succeed("ping -c 1 machine1")
    machine1.succeed("ping -c 1 nixosnode")
  '';
}
