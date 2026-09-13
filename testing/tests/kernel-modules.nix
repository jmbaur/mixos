{ config, ... }: {
  name = "mixos-kernel-modules";

  mixos.nodes.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      # TODO(jared): formalize this as module option(s)
      etc."modprobe.d/mixos.conf".source = pkgs.writeText "modprobe-mixos.conf" ''
        options nvme-tcp wq_unbound=Y
      '';

      boot.extraModulePackages = [ config.boot.kernelPackages.jool ];
      boot.kernelModules = [
        "nvme-tcp"
        "jool"

        # "i2c" is a kernel module that nixpkgs builds into kernel, so we test
        # here that we can gracefully skip over drivers that are not built as
        # modules, but requested to be loaded as such at runtime. See
        # https://github.com/nixos/nixpkgs/blob/5f0dc9a0153be4a724176e0b436e06a7e1bfe4fe/pkgs/os-specific/linux/kernel/common-config.nix#L192
        "i2c"
      ];

      # Ensure that our comment above is accurate.
      boot.requiredKernelConfig.I2C = lib.kernel.yes;

      # The IDE controller of qemu's default machine is present before
      # userspace starts, and ata_piix is deliberately left out of
      # boot.kernelModules: the machine is expected to work out what it needs
      # from the device itself.
      boot.requiredKernelConfig.ATA_PIIX = lib.kernel.module;
    };

  testScript = ''
    import mixos

    machine = mixos.create_machines("${config.mixos.driverConfiguration}", driver)["machine"]

    # kernel module options are set correctly
    assert "Y" == machine.succeed("cat /sys/module/nvme_tcp/parameters/wq_unbound").strip()

    # out-of-tree module loads successfully
    machine.succeed("lsmod | grep jool")

    # builtin driver fails to load
    machine.succeed("dmesg | grep 'failed to load module i2c'")

    # a driver nobody asked for is loaded from the modalias of its device along with
    # everything it depends on
    machine.succeed("grep -q '^ata_piix ' /proc/modules")
    machine.succeed("grep -q '^libata ' /proc/modules")
  '';
}
