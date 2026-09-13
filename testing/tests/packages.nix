{ config, ... }: {
  name = "mixos-packages";

  mixos.nodes.machine = { pkgs, ... }: { packages = [ pkgs.hello ]; };

  testScript = ''
    import mixos

    machine = mixos.create_machines("${config.mixos.driverConfiguration}", driver)["machine"]

    machine.succeed("hello")
    machine.fail("helloo")
  '';
}
