{ config, ... }:
let
  target = config.mixos.nodes.target;
  targetManifest = baseNameOf target.system.build.manifest;
in
{
  name = "mixos-switch-root";

  mixos.nodes.machine = {
    testing.qemu.args = [
      "-drive"
      "file=${target.system.build.erofs},if=virtio,format=raw,readonly=on"
    ];

    init.restart = {
      tty = "console";
      process = "/bin/mixos switch-root ${targetManifest}";
    };
  };

  mixos.nodes.target = { pkgs, ... }: { packages = [ pkgs.hello ]; };

  testScript = ''
    with subtest("first system"):
        machine.fail("hello")
        machine.succeed("mkdir -p /sysroot && mount -t erofs -o ro /dev/vda /sysroot")
        machine.execute("kill -QUIT 1")

    with subtest("second system"):
        machine.wait_for_console_text("executing init")
        machine.connected = False
        machine.connect()
        print(machine.succeed("hello"))
  '';
}
