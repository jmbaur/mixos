mixosSystem:
{
  config,
  lib,
  hostPkgs,
  ...
}:
let
  inherit (lib)
    attrNames
    attrValues
    concatMap
    concatMapAttrsStringSep
    concatMapStrings
    concatMapStringsSep
    concatStringsSep
    elem
    escapeShellArgs
    filter
    flatten
    getExe
    head
    kernel
    length
    listToAttrs
    mapAttrs
    mapAttrs'
    mkBefore
    mkDefault
    mkIf
    mkOption
    nameValuePair
    optional
    optionalString
    optionals
    range
    remove
    stringAsChars
    substring
    toLower
    types
    unique
    zipListsWith
    ;

  # Reused for `qemuNicMac` and `qemuNICFlags`, so that the MixOS machines are
  # attached and addressed exactly the way the NixOS machines are.
  qemu-common = import "${hostPkgs.path}/nixos/lib/qemu-common.nix" {
    inherit (hostPkgs) lib stdenv;
  };

  # Declares `virtualisation.vlans`, `virtualisation.interfaces` and
  # `networking.primaryIP*Address`. It is written for guests that are not
  # NixOS, which is exactly what the MixOS machines are.
  guestNetworkingOptions = "${hostPkgs.path}/nixos/modules/virtualisation/guest-networking-options.nix";

  # The test driver exposes each machine to the test script under a name made
  # into a python identifier this way. See <nixpkgs/nixos/lib/testing/driver.nix>.
  pythonizeName =
    name:
    let
      first = substring 0 1 name;
      rest = substring 1 (-1) name;
    in
    (if builtins.match "[A-z_]" first == null then "_" else first)
    + stringAsChars (c: if builtins.match "[A-z0-9_]" c == null then "_" else c) rest;

  testConfig = config;

  # MixOS machines are numbered after the NixOS machines, so that every machine
  # in the test has a unique node number, and thus unique MAC and IP addresses.
  # See <nixpkgs/nixos/lib/testing/network.nix>.
  nodeNumbers = listToAttrs (
    zipListsWith nameValuePair (attrNames config.mixos.nodes) (
      range (length (attrNames config.allMachines) + 1) 254
    )
  );

  # The /etc/hosts entries for a set of machines, keyed by the name each is
  # reachable under.
  hostsEntries = concatMapAttrsStringSep "" (
    hostName: machineConfig:
    concatMapStrings (address: "${address} ${hostName}\n") (
      remove "" [
        machineConfig.networking.primaryIPAddress
        machineConfig.networking.primaryIPv6Address
      ]
    )
  );

  nixosHosts = hostsEntries (
    mapAttrs' (
      _: nodeConfig: nameValuePair nodeConfig.networking.hostName nodeConfig
    ) config.allMachines
  );

  # Handed to the NixOS machines via `defaults`, so that both kinds of machine
  # can reach each other by name.
  mixosHosts = hostsEntries config.mixos.nodes;

  machineTestModule =
    {
      name,
      config,
      pkgs,
      ...
    }:
    let
      inherit (config.virtualisation.test) nodeNumber;

      interfaces = attrValues config.virtualisation.allInterfaces;
      addressedInterfaces = filter (interface: interface.assignIP) interfaces;

      # The addressing scheme <nixpkgs/nixos/lib/testing/network.nix> gives the NixOS
      # machines.
      ipv4Address = interface: "192.168.${toString interface.vlan}.${toString nodeNumber}";
      ipv6Address = interface: "2001:db8:${toString interface.vlan}::${toString nodeNumber}";
    in
    {
      imports = [ guestNetworkingOptions ];

      options.virtualisation.test.nodeNumber = mkOption {
        type = types.ints.between 1 254;
        readOnly = true;
        internal = true;
        default =
          nodeNumbers.${name}
            or (throw "Can't have more than 254 machines in a test, including the MixOS ones!");
        defaultText = "assigned by the test framework";
        description = ''
          The number identifying this machine among all of the machines in the
          test, used to address it. Continues where the numbering of the NixOS
          machines leaves off.
        '';
      };

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
          default = 1 * 1024 * 1024 * 1024;
          defaultText = "1GiB";
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
        # Unlike the NixOS machines, which are attached to vlan 1 by default, a
        # MixOS machine only gets a network stack when the test asks for one.
        virtualisation.vlans = mkDefault [ ];

        networking = mkIf (addressedInterfaces != [ ]) {
          primaryIPAddress = ipv4Address (head addressedInterfaces);
          primaryIPv6Address = ipv6Address (head addressedInterfaces);
        };

        boot.kernelModules = [
          "virtio_balloon"
          "virtio_console"
          "virtio_pci"
          "virtio_rng"
        ]
        ++ optional (interfaces != [ ]) "virtio_net";

        boot.requiredKernelConfig = mkIf (interfaces != [ ]) {
          INET = kernel.yes;
          IPV6 = kernel.yes;
          NET = kernel.yes;
          VIRTIO_NET = kernel.module;
        };

        # Interfaces are found by MAC address and renamed, since the names the
        # kernel hands out depend on probe order. This is the job the udev
        # rules in <nixpkgs/nixos/lib/testing/network.nix> do for the NixOS machines.
        init.network = mkIf (interfaces != [ ]) {
          action = "sysinit";
          tty = "console"; # so that failures to set up the network are visible
          process =
            let
              networkConfig = (pkgs.formats.json { }).generate "mixos-test-network.json" (
                map (interface: {
                  inherit (interface) name;
                  # QEMU lowercases MAC addresses, and so does sysfs, so the
                  # machine can match against this verbatim.
                  mac = toLower (qemu-common.qemuNicMac interface.vlan nodeNumber);
                  addresses = optionals interface.assignIP [
                    "${ipv4Address interface}/24"
                    "${ipv6Address interface}/64"
                  ];
                }) interfaces
              );
            in
            "/bin/mixos test-network ${networkConfig}";
        };

        etc."hostname".source = mkDefault (pkgs.writeText "hostname" "${name}\n");

        etc."hosts" = mkIf (interfaces != [ ]) {
          source = pkgs.writeText "etc-hosts" ''
            127.0.0.1 localhost
            ::1 localhost
            ${nixosHosts}${mixosHosts}'';
        };

        mixos.testing.enable = true;

        # Reuse the same package set used by NixOS VM nodes.
        nixpkgs.pkgs = testConfig.node.pkgs;

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

  mixosNodeType =
    (mixosSystem {
      baseModules = [ machineTestModule ];
      modules = [ ];
    }).type;

  startScripts = mapAttrs (
    name: mixosConfig:
    let
      inherit (mixosConfig.testing.qemu) diskImage;
      kernelCmdline = [
        "debug"
      ]
      ++ optionals mixosConfig.nixpkgs.pkgs.stdenv.hostPlatform.isx86_64 [ "console=ttyS0,115200" ];
      qemuOpts = escapeShellArgs (
        mixosConfig.testing.qemu.args
        ++ [
          # TODO(jared): The NixOS VM test framework does some extra
          # steps to make vsock work without /dev/vhost-vsock
          # availability in the sandbox.
          # # Provide guest CIDs starting where NixOS VM nodes end, starting at 3 (lowest guest CID)
          # # https://github.com/nixos/nixpkgs/blob/master/nixos/lib/test-driver/src/test_driver/driver.py#L113
          # "-device"
          # "vhost-vsock-pci,guest-cid=${toString (3 + length (attrNames config.nodes))}"
          "-kernel"
          "${mixosConfig.system.build.toplevel}/kernel"
          "-initrd"
          "${mixosConfig.system.build.toplevel}/initrd"
          "-append"
          "${toString kernelCmdline}"
        ]
      );
      # Kept out of `escapeShellArgs` above, since the test driver hands the VDE
      # switch sockets to the start script through the environment.
      networkOpts = toString (
        flatten (
          zipListsWith (
            interface: nic:
            qemu-common.qemuNICFlags nic interface.vlan mixosConfig.virtualisation.test.nodeNumber
          ) (attrValues mixosConfig.virtualisation.allInterfaces) (range 1 255)
        )
      );
    in
    getExe (
      hostPkgs.writeShellApplication {
        name = "mixos-${name}-vm-start";
        runtimeInputs = [ config.qemu.package ];
        text = ''
          ${optionalString (diskImage != null) ''
            # The test driver points TMPDIR at the machine's state directory,
            # which it wipes before each run (unless --keep-machine-state is
            # passed), so the disk image cleans itself up.
            MIXOS_DISK_IMAGE="''${TMPDIR:-/tmp}/mixos-${name}-disk.qcow2"
            if ! test -e "$MIXOS_DISK_IMAGE"; then
              qemu-img create -f qcow2 "$MIXOS_DISK_IMAGE" ${toString diskImage}B
            fi
          ''}
          exec qemu-kvm ${qemuOpts} \
            ${networkOpts} \
            ${optionalString (diskImage != null) ''-drive "file=$MIXOS_DISK_IMAGE,if=virtio,format=qcow2"''} \
            "$@"
        '';
      }
    )
  ) config.mixos.nodes;
in
{
  options = {
    mixos = {
      nodes = mkOption {
        type = types.lazyAttrsOf mixosNodeType;
        default = { };
        visible = "shallow";
        description = ''
          MixOS configurations to be made available to the test environment.
        '';
      };
    };

    driverConfiguration = mkOption {
      type = types.submodule {
        options.vlans = mkOption {
          internal = true;
          type = types.listOf types.ints.unsigned;
          # The NixOS and the MixOS machines contribute their virtual networks
          # separately, and the driver must not be asked to start two VDE
          # switches for the same one.
          apply = unique;
        };
      };
    };
  };

  config = {
    # Both kinds of machine are VM nodes of the same test driver, so they share
    # one namespace of the names it exposes them to the test script under. Two
    # machines whose names pythonize alike would shadow each other there, so
    # compare the names the test script actually sees.
    assertions =
      let
        takenNames = map pythonizeName (attrNames config.allMachines);
        overlappingNames = filter (name: elem (pythonizeName name) takenNames) (
          attrNames config.mixos.nodes
        );
      in
      [
        {
          assertion = overlappingNames == [ ];
          message = "The test driver exposes these MixOS machines under the same names as NixOS machines in the same test: ${concatStringsSep ", " overlappingNames}";
        }
      ];

    # Hand the MixOS machines to the test driver along with the NixOS ones, so
    # that it creates, tracks and tears them down like any other VM node, and
    # so that a test with MixOS machines in it is never mistaken for a
    # single-machine test.
    driverConfiguration.vms = mapAttrs (name: startScript: {
      inherit name;
      start_script = startScript;
    }) startScripts;

    # The driver hands the MixOS machines to the test script like any other VM
    # node, but they don't run systemd, so take the systemd-only methods of the
    # driver's machine class away from them before the test starts.
    testScript = mkIf (config.mixos.nodes != { }) (mkBefore ''
      class SystemdUnsupportedError(Exception):
          """
          Raised when a test calls a systemd-only method of the NixOS test driver's
          machine class on a MixOS machine.
          """

      def _systemd_stub(machine_name: str, method: str):
          def stub(*args, **kwargs):
              raise SystemdUnsupportedError(
                  f"{machine_name}.{method}() is a systemd-only method of the NixOS "
                  "test driver, and MixOS machines do not run systemd"
              )

          stub.__name__ = method
          return stub

      for mixos_machine in [${concatMapStringsSep ", " pythonizeName (attrNames config.mixos.nodes)}]:
          for method in (
              "get_unit_info",
              "get_unit_property",
              "require_unit_state",
              "start_job",
              "stop_job",
              "switch_root",
              "systemctl",
              "wait_for_unit",
              "wait_for_x",
          ):
              setattr(mixos_machine, method, _systemd_stub(mixos_machine.name, method))
    '');

    # Have the driver start a VDE switch for the virtual networks that only
    # MixOS machines are attached to.
    driverConfiguration.vlans = concatMap (
      machine: map (interface: interface.vlan) (attrValues machine.virtualisation.allInterfaces)
    ) (attrValues config.mixos.nodes);

    defaults.networking.extraHosts = mixosHosts;
  };
}
