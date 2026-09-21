{ config, ... }:
let
  target = config.mixos.nodes.target;

  pkgs = target.nixpkgs.pkgs;

  disk =
    pkgs.runCommand "mixos-kexec-target-boot.erofs"
      {
        nativeBuildInputs = [ pkgs.erofs-utils ];
      }
      ''
        mkdir boot
        cp ${target.system.build.toplevel}/kernel boot/kernel
        cp ${target.system.build.toplevel}/initrd boot/initrd
        mkfs.erofs "$out" boot
      '';

  cmdline = "debug console=ttyS0,115200";

  bootMount = "/run/kexec-boot";

  bootDiskArgs = [
    "-drive"
    "file=${disk},if=virtio,format=raw,readonly=on"
  ];
in
{
  name = "mixos-kexec";

  mixos.nodes.machine =
    { lib, pkgs, ... }:
    {
      packages = [ pkgs.kexec-tools ];
      boot.requiredKernelConfig.KEXEC = lib.kernel.yes;
      testing.qemu.args = bootDiskArgs;
    };

  mixos.nodes.target =
    { lib, pkgs, ... }:
    {
      packages = [
        pkgs.hello
        pkgs.kexec-tools
      ];
      boot.requiredKernelConfig.KEXEC = lib.kernel.yes;
      testing.qemu.args = bootDiskArgs;
    };

  testScript = ''
    import datetime

    def load_kexec_kernel():
        machine.succeed(
            "mkdir -p ${bootMount}; "
            "grep -q ' ${bootMount} ' /proc/mounts "
            "|| mount -t erofs -o ro /dev/vda ${bootMount}"
        )

        machine.succeed(
            "/bin/kexec -l ${bootMount}/kernel "
            "--initrd=${bootMount}/initrd --append='${cmdline}'"
        )
        assert "1" == machine.succeed("cat /sys/kernel/kexec_loaded").strip()

    def expect_kexec():
        # waits for our shutdown and kexec output
        machine.wait_for_console_text(
            "tearing down stateful mounts", timeout=datetime.timedelta(seconds=60)
        )
        machine.wait_for_console_text(
            "kexec kernel loaded, booting it", timeout=datetime.timedelta(seconds=60)
        )

        machine.connected = False
        machine.connect()

    # TODO(jared): maybe we can do this in a better way?
    def kexec():
        machine.connect()
        backdoor = _mixos_backdoor(machine, 30)

        try:
            return backdoor.Reboot(reboot_type="kexec")
        finally:
            _mixos_forget_backdoor(machine)

    with subtest("a kexec with no kernel loaded is refused"):
        assert "0" == machine.succeed("cat /sys/kernel/kexec_loaded").strip()

        refused = None
        try:
            kexec()
        except Exception as error:
            refused = str(error)

        assert refused is not None, "a kexec with no kernel loaded was not refused"
        assert "RebootNotReady" in refused, f"refused with {refused}"

        # machine is still alive
        machine.succeed("true")

    with subtest("a restart with a kernel loaded is a kexec"):
        load_kexec_kernel()
        machine.succeed("touch /run/before-kexec")
        machine.execute("kill -QUIT 1", check_output=False)
        expect_kexec()

        # The kernel and initrd that were loaded, now the running system.
        machine.succeed("hello")
        machine.fail("test -e /run/before-kexec")

    with subtest("the backdoor asks for one the same way"):
        load_kexec_kernel()
        machine.succeed("touch /run/before-kexec")
        kexec()
        expect_kexec()
        machine.succeed("hello")
        machine.fail("test -e /run/before-kexec")
  '';
}
