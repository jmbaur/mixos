{ config, ... }: {
  name = "mixos-os-release";

  mixos.nodes.machine = {
    mixos.osRelease.EXPERIMENT = "test";
  };

  testScript = ''
    import mixos

    mixos_machines = mixos.create_machines("${config.mixos.driverConfiguration}", create_machine)
    machine = mixos_machines.get("machine")

    try:
        machine.succeed("grep '^ID=mixos$' /etc/os-release")
        machine.succeed("grep '^VERSION_ID=' /etc/os-release")
        machine.succeed("grep '^EXPERIMENT=test$' /etc/os-release")
    except: raise
    finally:
        machine.shutdown()
        machine.wait_for_shutdown()
        machine.release()
  '';
}
