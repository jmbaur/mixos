{ config, ... }:
let
  target = config.mixos.nodes.target;
in
{
  name = "mixos-switch-root";

  mixos.nodes.machine = {
    testing.qemu.args = [
      "-drive"
      "file=${target.system.build.erofs},if=virtio,format=raw,readonly=on"
    ];
  };

  mixos.nodes.target = { pkgs, ... }: { packages = [ pkgs.hello ]; };

  testScript = ''
    with subtest("first system"):
        assert "/dev/loop1" == machine.succeed("losetup -f").strip()
        machine.fail("hello")
        machine.succeed("mkdir -p /run/nextstore && mount -t erofs -o ro /dev/vda /run/nextstore")
        machine.succeed("test -f /run/nextstore/.manifest.json")
        machine.execute("kill -QUIT 1", check_output=False)

    with subtest("second system"):
        machine.wait_for_console_text("switching to /run/nextstore", timeout=60)
        machine.wait_for_console_text("executing init", timeout=60)
        machine.connected = False
        machine.connect()
        machine.succeed("hello")
        assert "/dev/loop0" == machine.succeed("losetup -f").strip()

    with subtest("restart with nothing staged"):
        machine.fail("test -e /run/nextstore")
        assert "/nix/store/.manifest.json" == machine.succeed("readlink /run/mixos/manifest.json").strip()

        machine.fail("echo >/run/mixos/manifest.json")

        machine.succeed("touch /run/before-restart")
        machine.execute("kill -QUIT 1", check_output=False)

        machine.wait_for_console_text(r"switching to /(?!\S)", timeout=60)
        machine.connected = False
        machine.connect()

        machine.succeed("hello")
        machine.fail("test -e /run/before-restart")
        machine.succeed("test -e /etc/inittab")

    with subtest("restart with a store lacking a manifest"):
        machine.succeed("mkdir -p /run/nextstore && mount -t tmpfs none /run/nextstore")
        machine.execute("kill -QUIT 1", check_output=False)

        machine.wait_for_console_text("no manifest at /.manifest.json under /run/nextstore", timeout=60)
        machine.wait_for_console_text(r"switching to /(?!\S)", timeout=60)
        machine.connected = False
        machine.connect()

        machine.succeed("hello")
  '';
}
