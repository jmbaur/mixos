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
    mkForce
    mkMerge
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
          # What the test driver reaches the varlink backdoor over.
          "vmw_vsock_virtio_transport"
          "vsock"
        ]
        ++ optional (interfaces != [ ]) "virtio_net";

        boot.requiredKernelConfig = mkMerge [
          {
            VIRTIO_VSOCKETS = kernel.module;
            VSOCKETS = kernel.module;
          }
          (mkIf (interfaces != [ ]) {
            INET = kernel.yes;
            IPV6 = kernel.yes;
            NET = kernel.yes;
            VIRTIO_NET = kernel.module;
          })
        ];

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
          # The vsock device the driver attaches is a vhost-user one, which can
          # only work with guest memory it can map itself.
          "-object"
          "memory-backend-memfd,id=mem0,size=${toString config.testing.qemu.memory},share=on"
          "-machine"
          "memory-backend=mem0"
        ]
        ++ optionals config.boot.watchdog.enable [
          "-device"
          "i6300esb"
        ];

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
        {
          # The machines are reached over vsock, which needs the driver's
          # vhost-device-vsock and guest memory qemu can share, neither of
          # which macOS has. The same reason the framework's own SSH backdoor
          # is Linux-only.
          assertion = config.mixos.nodes != { } -> hostPkgs.stdenv.hostPlatform.isLinux;
          message = "MixOS machines in a test are not supported on macOS host systems!";
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

    # MixOS machines are reached over vsock, which the driver only sets up when
    # it is asked for the SSH backdoor.
    driverConfiguration.enable_ssh_backdoor = mkIf (config.mixos.nodes != { }) (mkForce true);

    # What the test script talks to the MixOS machines with.
    extraPythonPackages = p: [ p.mixos ];

    testScript = mkIf (config.mixos.nodes != { }) (mkBefore ''
      import datetime as _dt
      import mixos as _mixos

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

      MIXOS_BACKDOOR_PORT = 8000
      MIXOS_BACKDOOR_ATTR = "_mixos_backdoor"

      class MixosBackdoorError(Exception):
          """Raised when the varlink backdoor of a MixOS machine cannot be reached."""

      def _mixos_forget_backdoor(machine):
          """Lets go of the connection, so that the next call opens a new one."""
          backdoor = getattr(machine, MIXOS_BACKDOOR_ATTR, None)

          if backdoor is not None:
              setattr(machine, MIXOS_BACKDOOR_ATTR, None)
              backdoor.__exit__(None, None, None)

      def _mixos_backdoor(machine, timeout):
          if machine.vsock_host is None:
              raise MixosBackdoorError(
                  f"{machine.name}: the driver set up no vsock socket for this machine"
              )

          backdoor = getattr(machine, MIXOS_BACKDOOR_ATTR, None)

          if backdoor is None:
              backdoor = _mixos.Machine(
                  f"vsock-mux:{machine.vsock_host}:{MIXOS_BACKDOOR_PORT}"
              ).__enter__()
              setattr(machine, MIXOS_BACKDOOR_ATTR, backdoor)

          backdoor.set_timeout(timeout)

          return backdoor

      # MixOS machines have no shell on the virtio console the driver's own
      # commands would go to. Commands go to test-backdoor over vsock.
      def _mixos_execute(machine):
          def execute(command, check_return=True, check_output=True, timeout=_dt.timedelta(minutes=15)):
              # A machine the test has taken down leaves a connection that is
              # no good to anyone, so let go of it before waiting for the
              # machine to be back up.
              if not machine.connected:
                  _mixos_forget_backdoor(machine)

              # Dialling a machine that is down screws up the multiplexer, so
              # ensure we are connected first.
              machine.connect()

              # "set -eu" rather than the driver's "set -euo pipefail", since
              # this is busybox ash rather than bash.
              argv = ["/bin/sh", "-c", f"set -eu; {command}"]
              seconds = int(timeout.total_seconds()) if timeout is not None else None

              # Longer than the command is given, so that a command running too
              # long is the backdoor's to report rather than a dead connection.
              backdoor = _mixos_backdoor(machine, None if seconds is None else seconds + 30)

              try:
                  if not check_output:
                      # No reply to wait for: this is how a test runs a command
                      # that takes the machine, and with it the backdoor, down.
                      backdoor.RunCommand(command=argv, timeout=seconds, _oneway=True)
                      _mixos_forget_backdoor(machine)
                      return (-2, "")

                  response = backdoor.RunCommand(command=argv, timeout=seconds)
              except OSError:
                  # Whatever went wrong with it, the connection is no longer one
                  # to hand the next command to.
                  _mixos_forget_backdoor(machine)
                  raise

              # The driver's shell backdoor leaves stderr on the console, so
              # this is where it would have shown up.
              if response["stderr"]:
                  machine.log(response["stderr"].rstrip())

              return (response["exit_code"] if check_return else -1, response["stdout"])

          return execute

      # The driver takes a machine down by writing "poweroff" to the shell it
      # expects on the virtio console, which a MixOS machine does not have.
      # Ask test-backdoor to signal PID 1 instead.
      def _mixos_shutdown(machine):
          def shutdown():
              if not machine.booted:
                  return

              # A machine the test has taken down leaves a connection that is
              # no good to anyone, so let go of it before waiting for the
              # machine to be back up.
              if not machine.connected:
                  _mixos_forget_backdoor(machine)

              # Dialling a machine that is down screws up the multiplexer, so
              # ensure we are connected first.
              machine.connect()

              backdoor = _mixos_backdoor(machine, 30)

              try:
                  # No reply to wait for: the backdoor goes down with the
                  # machine it is taking down.
                  backdoor.Reboot(reboot_type="poweroff", _oneway=True)
              finally:
                  _mixos_forget_backdoor(machine)

              machine.wait_for_shutdown()

          return shutdown

      # The driver hands the MixOS machines to the test script like any other
      # VM node, but they don't run systemd, so take the systemd-only methods
      # of the driver's machine class away from them before the test starts.
      for _mixos_machine in [${concatMapStringsSep ", " pythonizeName (attrNames config.mixos.nodes)}]:
          _mixos_machine._execute = _mixos_execute(_mixos_machine)
          _mixos_machine.shutdown = _mixos_shutdown(_mixos_machine)

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
              setattr(_mixos_machine, method, _systemd_stub(_mixos_machine.name, method))
    '');

    # Have the driver start a VDE switch for the virtual networks that only
    # MixOS machines are attached to.
    driverConfiguration.vlans = concatMap (
      machine: map (interface: interface.vlan) (attrValues machine.virtualisation.allInterfaces)
    ) (attrValues config.mixos.nodes);

    defaults = {
      networking.extraHosts = mixosHosts;

      # The vsock device the driver attaches to every machine in the test,
      # MixOS or not, is a vhost-user one, which can only work with guest
      # memory it can map itself. Most NixOS nodes have this on already, since
      # virtiofs needs it too.
      virtualisation.qemu.enableSharedMemory = mkIf (config.mixos.nodes != { }) (mkDefault true);
    };
  };
}
