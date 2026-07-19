{ config, ... }: {
  name = "mixos-users-groups";

  mixos.nodes.machine = {
    users.root = {
      uid = 0;
      gid = 0;
      description = "System administrator";
      home = "/root";
      shell = "/bin/sh";
    };

    groups.root.id = 0;

    users.foo = {
      uid = 1;
      gid = 1;
      shell = "/bin/sh";
    };
    groups.foo.id = 1;

    # shell defaults to /bin/nologin
    users.bar = {
      uid = 2;
      gid = 2;
    };
    groups.bar.id = 2;
  };

  testScript = ''
    import mixos

    mixos_machines = mixos.create_machines("${config.mixos.driverConfiguration}", create_machine)
    machine = mixos_machines.get("machine")

    try:
        assert "uid=0" in machine.succeed("su -l root -c id")
        assert "uid=1" in machine.succeed("su -l foo -c id")
        machine.fail("su -l bar -c id")
    except: raise
    finally:
        machine.shutdown()
        machine.wait_for_shutdown()
        machine.release()
  '';
}
