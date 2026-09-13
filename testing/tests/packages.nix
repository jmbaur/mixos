_: {
  name = "mixos-packages";

  mixos.nodes.machine = { pkgs, ... }: { packages = [ pkgs.hello ]; };

  testScript = ''
    machine.succeed("hello")
    machine.fail("helloo")
  '';
}
