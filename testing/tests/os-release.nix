_: {
  name = "mixos-os-release";

  mixos.nodes.machine = {
    mixos.osRelease.EXPERIMENT = "test";
  };

  testScript = ''
    machine.succeed("grep '^ID=mixos$' /etc/os-release")
    machine.succeed("grep '^VERSION_ID=' /etc/os-release")
    machine.succeed("grep '^EXPERIMENT=test$' /etc/os-release")
  '';
}
