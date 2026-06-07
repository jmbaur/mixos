mixosSystem:
{
  config,
  lib,
  hostPkgs,
  ...
}:
let
  inherit (lib)
    escapeShellArgs
    getExe
    mapAttrs
    mkOption
    optionalString
    optionals
    types
    ;

  testConfig = config;

  machineTestModule =
    { config, pkgs, ... }:
    let
      configfile = ./${pkgs.stdenv.hostPlatform.linuxArch}.config;
    in
    {
      options.testing.qemu = {
        args = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Arguments passed to qemu when spawning the VM.
          '';
        };
        cpus = mkOption {
          type = types.ints.positive;
          default = 1;
          description = ''
            The number of cpus to provide to the VM.
          '';
        };
        memory = mkOption {
          type = types.ints.positive;
          default = 512 * 1024 * 1024;
          defaultText = "512MiB";
          description = ''
            The amount of memory to provide to the VM.
          '';
        };
        diskImage = mkOption {
          type = types.nullOr types.ints.positive;
          default = null;
          description = ''
            The size of disk image to create for the machine. This will
            be exposed as a virtio block device to the VM.
          '';
        };
      };

      config = {
        mixos.testing.enable = true;

        # Reuse the same package set used by NixOS VM nodes.
        nixpkgs.pkgs = testConfig.node.pkgs;

        # Default to a sane kernel.
        boot.kernelPackages = lib.mkDefault (
          pkgs.linuxKernel.packagesFor (
            pkgs.linuxKernel.manualConfig {
              inherit (pkgs.linux_6_18) src version;
              inherit configfile;
            }
          )
        );

        testing.qemu.args = [
          "-nographic"
          "-smp"
          (toString config.testing.qemu.cpus)
          "-m"
          "${(toString config.testing.qemu.memory)}B"
        ]
        ++ optionals config.boot.watchdog.enable [
          "-device"
          "i6300esb"
        ];

        # TODO(jared): consider using CONFIG_BASH_IS_ASH in busybox config.
        packages = [ pkgs.bashNonInteractive ];

        # copied from https://github.com/nixos/nixpkgs/blob/master/nixos/modules/testing/test-instrumentation.nix#L28
        services.nixos-test-backdoor.run = pkgs.writeShellScript "nixos-test-backdoor-run" ''
          export USER=root
          export HOME=/root
          export DISPLAY=:0.0

          # Determine if this script is ran with nounset
          strict="false"
          if set -o | grep --quiet --perl-regexp "nounset\s+on"; then
              strict="true"
          fi

          if [[ -e /etc/profile ]]; then
              # TODO: Currently shell profiles are not checked at build time,
              # so we need to unset stricter options to source them
              set +o nounset
              # shellcheck disable=SC1091
              source /etc/profile
              [ "$strict" = "true" ] && set -o nounset
          fi

          # Don't use a pager when executing backdoor
          # actions. Because we use a tty, commands like systemctl
          # or nix-store get confused into thinking they're running
          # interactively.
          export PAGER=

          cd /tmp
          exec < /dev/hvc0 > /dev/hvc0
          while ! exec 2> /dev/console; do sleep 0.1; done
          echo "connecting to host..." >&2
          stty -F /dev/hvc0 raw -echo # prevent nl -> cr/nl conversion
          # The following line is essential since it signals to
          # the test driver that the shell is ready.
          # See: the connect method in the Machine class.
          echo "Spawning backdoor root shell..."
          # Passing the terminal device makes bash run non-interactively.
          # Otherwise we get errors on the terminal because bash tries to
          # setup things like job control.
          # Note: calling bash explicitly here instead of sh makes sure that
          # we can also run non-NixOS guests during tests. This, however, is
          # mostly futureproofing as the test instrumentation is still very
          # tightly coupled to NixOS.
          PS1="" exec ${pkgs.bashNonInteractive}/bin/bash --norc /dev/hvc0
        '';
      };
    };

  nodes = mapAttrs (
    name: module:
    let
      mixosConfig = mixosSystem {
        baseModules = [ machineTestModule ];
        modules = [ module ];
      };
      inherit (mixosConfig.config.testing.qemu) diskImage;
      kernelCmdline = [
        "debug"
      ]
      ++ optionals mixosConfig._module.args.pkgs.stdenv.hostPlatform.isx86_64 [ "console=ttyS0,115200" ];
      qemuOpts = escapeShellArgs (
        mixosConfig.config.testing.qemu.args
        ++ [
          # TODO(jared): The NixOS VM test framework does some extra
          # steps to make vsock work without /dev/vhost-vsock
          # availability in the sandbox.
          # # Provide guest CIDs starting where NixOS VM nodes end, starting at 3 (lowest guest CID)
          # # https://github.com/nixos/nixpkgs/blob/master/nixos/lib/test-driver/src/test_driver/driver.py#L113
          # "-device"
          # "vhost-vsock-pci,guest-cid=${toString (3 + length (attrNames config.nodes))}"
          "-kernel"
          "${mixosConfig.config.system.build.toplevel}/kernel"
          "-initrd"
          "${mixosConfig.config.system.build.toplevel}/initrd"
          "-append"
          "${toString kernelCmdline}"
        ]
      );
    in
    getExe (
      hostPkgs.writeShellApplication {
        name = "mixos-${name}-vm-start";
        runtimeInputs = [ config.qemu.package ];
        text = ''
          ${optionalString (diskImage != null) ''
            MIXOS_DISK_IMAGE=$(mktemp -p "''${TMPDIR:-/tmp}" mixos-${name}-disk-XXXX)
            qemu-img create -f qcow2 "$MIXOS_DISK_IMAGE" ${toString diskImage}B
          ''}
          exec qemu-kvm ${qemuOpts} \
            ${optionalString (diskImage != null) ''-drive "file=$MIXOS_DISK_IMAGE,if=virtio"''} \
            "$@"
        '';
      }
    )
  ) config.mixos.nodes;
in
{
  options.mixos = {
    nodes = mkOption {
      type = types.attrsOf types.deferredModule;
      default = { };
      description = ''
        MixOS configurations to be made available to the test environment.
      '';
    };

    driverConfiguration = mkOption {
      readOnly = true;
      internal = true;
      type = types.path;
    };
  };

  config = {
    extraPythonPackages = p: [ p.mixos ];

    mixos.driverConfiguration = (hostPkgs.formats.json { }).generate "mixos-driver-configuration.json" {
      inherit nodes;
    };
  };
}
