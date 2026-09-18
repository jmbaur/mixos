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
        machine.execute("kill -QUIT 1", check_output=False)

    with subtest("second system"):
        machine.wait_for_console_text("executing init")
        machine.connected = False
        machine.connect()
        print(machine.succeed("hello"))

    with subtest("restart with nothing staged"):
        machine.fail("test -e /sysroot")
        machine.succeed("test -f /.manifest.json")

        # Immutable, so not even root gets to rewrite what this system is.
        machine.fail("echo >/.manifest.json")
        machine.fail("rm -f /.manifest.json")

        machine.succeed("touch /run/before-restart")
        machine.execute("kill -QUIT 1", check_output=False)

        machine.wait_for_console_text("switching to /sysroot")
        machine.connected = False
        machine.connect()

        # Still the same system, and a new one: the root it is on was built
        # from scratch rather than left as the shutdown took it apart.
        machine.succeed("hello")
        machine.fail("test -e /run/before-restart")

        # /etc is a mount the shutdown takes down, so it is only here again
        # because the system was brought all the way back up.
        machine.succeed("test -e /etc/inittab")
  '';
}
