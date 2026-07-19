{ config, ... }: {
  name = "mixos-packages";

  mixos.nodes.machine = { pkgs, ... }: { packages = [ pkgs.hello ]; };

  testScript = ''
    import mixos

    mixos_machines = mixos.create_machines("${config.mixos.driverConfiguration}", create_machine)
    machine = mixos_machines.get("machine")

    try:
        machine.succeed("hello")
        machine.fail("helloo")
    except: raise
    finally:
        machine.shutdown()
        machine.wait_for_shutdown()
        machine.release()
  '';
}
