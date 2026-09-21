{
  options,
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib.asserts) checkAssertWarn;

  inherit (lib)
    any
    attrNames
    attrValues
    concatLines
    concatMapStringsSep
    concatStringsSep
    const
    elem
    escapeShellArgs
    filter
    filterAttrs
    flatten
    flip
    genAttrs
    getAttr
    getBin
    getExe
    getExe'
    getOutput
    groupBy
    hasAttr
    id
    kernel
    length
    listToAttrs
    literalExpression
    mapAttrs
    mapAttrsToList
    mkBefore
    mkDefault
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    mkPackageOption
    mkRenamedOptionModule
    optional
    optionalString
    subtractLists
    textClosureMap
    types
    unique
    versionAtLeast
    ;

  osReleaseFormat = pkgs.formats.keyValue { };

  manifestFormat = pkgs.formats.json { };

  kernelPackage = config.boot.kernelPackages.kernel;

  # NOTE: must have __structuredAttrs and exportReferencesGraph.closure set
  buildStoreErofs = dest: ''
    mkdir -p store

    for output_path in $(jq -r '.closure[].path' <"$NIX_ATTRS_JSON_FILE"); do
      cp -r $output_path store/
    done

    install -Dm0444 ${config.system.build.manifest} store/.manifest.json

    erofs_zip=
    if kconfig ${kernelPackage.configfile} --assert-yes EROFS_FS_ZIP_LZMA 2>/dev/null; then
      erofs_zip="-zlzma"
    elif kconfig ${kernelPackage.configfile} --assert-yes EROFS_FS_ZIP_ZSTD 2>/dev/null; then
      erofs_zip="-zzstd"
    elif kconfig ${kernelPackage.configfile} --assert-yes EROFS_FS_ZIP_DEFLATE 2>/dev/null; then
      erofs_zip="-zdeflate"
    else
      echo "could not detect erofs compression algorithm, using none"
    fi
    if [[ -n "$erofs_zip" ]]; then
      echo "Using $erofs_zip for erofs compression"
    fi

    mkfs.erofs $erofs_zip -L mixos -U ${config.mixos.storeUUID} --force-uid=0 --force-gid=0 --workers=$NIX_BUILD_CORES -T$SOURCE_DATE_EPOCH ${dest} store
  '';

  hasModules = kernelPackage.config.isYes "MODULES";

  possibleActions = [
    "sysinit"
    "wait"
    "once"
    "respawn"
    "askfirst"
    "shutdown"
    "restart"
    "ctrlaltdel"
  ];

  enabledInit = filterAttrs (const (getAttr "enable")) config.init;

  danglingDepAssertions = flatten (
    mapAttrsToList (
      name:
      { action, deps, ... }:
      map (
        dep:
        let
          reason =
            if !(hasAttr dep config.init) then
              "no such init entry is declared"
            else if !(hasAttr dep enabledInit) then
              "that init entry is disabled"
            else
              "that init entry has action '${enabledInit.${dep}.action}', and deps only order entries sharing the same action";
        in
        {
          assertion = false;
          message = "init entry '${name}' (action '${action}') depends on '${dep}', which cannot be resolved: ${reason}";
        }
      ) (filter (dep: !(hasAttr dep enabledInit && enabledInit.${dep}.action == action)) deps)
    ) enabledInit
  );

  # <id>:<runlevels>:<action>:<process>
  inittab =
    let
      groups =
        mapAttrs
          (
            _: groupEntries:
            let
              inittabTextAttrs = listToAttrs groupEntries;
            in
            textClosureMap id inittabTextAttrs (attrNames inittabTextAttrs)
          )
          (
            groupBy (getAttr "group") (
              mapAttrsToList (
                name:
                {
                  tty,
                  action,
                  process,
                  deps,
                  ...
                }:
                {
                  group = action;
                  inherit name;
                  value = {
                    inherit deps;
                    text = "${tty}::${action}:${process}"; # busybox /init does not implement runlevels
                  };
                }
              ) enabledInit
            )
          );
    in
    builtins.foldl' (
      acc: action: if hasAttr action groups then acc + groups.${action} + "\n" else acc
    ) "" possibleActions;

  modprobeConf = concatLines (
    mapAttrsToList (module: const "blacklist ${module}") (
      filterAttrs (const id) config.boot.modprobe.blacklist
    )
    ++ flatten (
      map (verb: mapAttrsToList (module: args: "${verb} ${module} ${args}") config.boot.modprobe.${verb})
        [
          "alias"
          "install"
          "options"
          "remove"
          "softdep"
          "weakdep"
        ]
    )
  );

  graphicsDrivers = pkgs.buildEnv {
    name = "graphics-drivers";
    paths = [ config.hardware.graphics.package ] ++ config.hardware.graphics.extraPackages;
  };
in
{
  imports = [ (mkRenamedOptionModule [ "bin" ] [ "packages" ]) ];

  options = {
    # TODO(jared): Use https://github.com/nixos/nixpkgs/blob/6e2d3fe12f15d592ebd45e721f65831232838b2e/lib/default.nix#L96 when we have it
    assertions = mkOption {
      type = types.listOf types.unspecified;
      internal = true;
      default = [ ];
    };

    warnings = mkOption {
      internal = true;
      default = [ ];
      type = types.listOf types.str;
    };

    nixpkgs.pkgs = mkOption {
      type = types.pkgs;
      description = "The pkgs module argument.";
    };

    boot = {
      requiredKernelConfig = mkOption {
        type = types.attrsOf types.raw;
        default = { };
        example = ''
          {
            TMPFS = lib.kernel.yes;
            OVERLAY_FS = lib.kernel.module;
            LOG_BUF_SHIFT = lib.kernel.freeform "18";
          }
        '';
        description = ''
          Attribute set of kernel Kconfig options that must be included in the
          kernel provided to mixos. Values (from lib.kernel) are asserted
          against the configured kernel, where lib.kernel.module is satisfied
          with either 'y' or 'm'. Non-tristate values (lib.kernel.freeform) are
          asserted for equality, ignoring any quoting of string values. Options
          marked as optional (lib.kernel.option) are not asserted.
        '';
      };

      kernelPackages = mkOption {
        type = types.raw;
        apply =
          kernelPackages:
          kernelPackages.extend (
            self: super: {
              kernel = super.kernel.override (originalArgs: {
                kernelPatches = (originalArgs.kernelPatches or [ ]) ++ config.boot.kernelPatches;
              });
            }
          );
        default = pkgs.linuxPackages_7_2;
        defaultText = "pkgs.linuxPackages_7_2";
        description = ''
          A kernel package-set containing a kernel attribute and optionally one
          or more kernel modules (à la pkgs.linuxPackagesFor ...).
        '';
      };

      kernelPatches = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = ''
          A list of additional patches to apply to the kernel. See NixOS
          documentation for more information.
        '';
      };

      extraModulePackages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        example = literalExpression "[ config.boot.kernelPackages.nvidia_x11 ]";
        description = ''
          A list of additional packages supplying kernel modules.
        '';
      };

      firmware = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = ''
          List of packages containing firmware files.  Such files
          will be loaded automatically if the kernel asks for them
          (i.e., when it has detected specific hardware that requires
          firmware to function).  If multiple packages contain firmware
          files with the same name, the first package in the list takes
          precedence.  Note that you must rebuild your system if you add
          files to any of these directories.
        '';
      };

      initrd.prepend = mkOption {
        type = types.listOf types.path;
        default = [ ];
        example = literalExpression ''[ "''${pkgs.microcode-intel}/intel-ucode.img" ]'';
        description = ''
          Other initrd files to prepend to the initrd MixOS builds. The kernel
          unpacks the concatenated archives in order, each one either a plain
          cpio archive or a compressed one.

          Since MixOS owns the initrd, this is how CPU microcode gets supplied.
          Microcode is the one thing here that must be an _uncompressed_ cpio
          archive, and must come first (see `lib.mkOrder`), because the kernel
          scans for it in the raw initrd before unpacking any of it.
        '';
      };

      kernelModules = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Kernel modules to load during early bootup.
        '';
      };

      modprobe = {
        alias = mkOption {
          type = types.attrsOf types.str;
          default = { };
          example = {
            "usb:v1D6Bp0001d*" = "my_driver";
          };
          description = ''
            Extra module aliases, keyed by alias (shell-style wildcards
            allowed).
          '';
        };

        blacklist = mkOption {
          type = types.attrsOf types.bool;
          default = { };
          example = {
            nouveau = true;
          };
          description = ''
            Kernel modules that will not be loaded automatically. Note that
            this only prevents a module from being loaded by one of its
            aliases (e.g. by the mdev `$MODALIAS` rule); modprobing a module
            by its real name still loads it, use `boot.modprobe.install` with
            `/bin/false` to prevent that as well.
          '';
        };

        install = mkOption {
          type = types.attrsOf types.str;
          default = { };
          example = {
            nouveau = "/bin/false";
          };
          description = ''
            Commands to run instead of inserting a module into the kernel,
            keyed by module name.
          '';
        };

        remove = mkOption {
          type = types.attrsOf types.str;
          default = { };
          example = {
            mymod = "/bin/rmmod --wait mymod";
          };
          description = ''
            Commands to run instead of removing a module from the kernel,
            keyed by module name.
          '';
        };

        options = mkOption {
          type = types.attrsOf (types.separatedString " ");
          default = { };
          example = {
            i915 = "enable_psr=0";
          };
          description = ''
            Module parameters to use when loading a module, keyed by module
            name. Definitions from multiple modules are joined with a space.
          '';
        };

        softdep = mkOption {
          type = types.attrsOf (types.separatedString " ");
          default = { };
          example = {
            hid_generic = "pre: hid_multitouch";
          };
          description = ''
            Soft dependencies to load alongside a module, keyed by module
            name. Unlike real dependencies, a soft dependency failing to load
            does not fail the module being loaded.
          '';
        };

        weakdep = mkOption {
          type = types.attrsOf (types.separatedString " ");
          default = { };
          example = {
            mymod = "mymod_helper";
          };
          description = ''
            Weak dependencies of a module, keyed by module name. These are not
            loaded along with the module, they only record that the modules
            belong together for tooling that consumes the information.
          '';
        };
      };

      watchdog = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Enable watchdog integration. This ensures if the boot process
            fails, the system doesn't hang indefinitely.
          '';
        };

        timeout = mkOption {
          type = types.addCheck types.ints.positive (timeout: timeout >= 10) // {
            description = "integer of at least 10";
          };
          default = 90;
          description = ''
            Watchdog timeout.
          '';
        };
      };
    };

    hardware.graphics = {
      enable = mkEnableOption "hardware accelerated graphics drivers";

      package = mkPackageOption pkgs "mesa" { };

      extraPackages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        example = literalExpression "[ pkgs.intel-media-driver ]";
        description = ''
          Additional packages to add to the driver lookup path. This is how
          OpenCL, VA-API and VDPAU drivers are made available, among others.
        '';
      };
    };

    packages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        Packages to be included in the runtime system and available in $PATH.
      '';
    };

    etc = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            source = mkOption {
              type = types.path;
              description = ''
                Path to place in /etc
              '';
            };
            mode = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "0400";
              description = ''
                Copy file to destination with permissions, or symlink if null.
              '';
            };
          };
        }
      );
      default = { };
      example = literalExpression ''
        { "hostname".source = pkgs.writeText "hostname" "my-machine"; }
      '';
      description = ''
        Files to place in /etc, keyed by their path relative to /etc. Each
        entry is either symlinked into the store or, if a mode is given,
        copied with that mode.
      '';
    };

    groups = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              name = mkOption {
                type = types.str;
                default = name;
                description = ''
                  Name of the group, as it appears in /etc/group. Defaults to
                  the attribute name.
                '';
              };
              id = mkOption {
                type = types.ints.u16;
                description = ''
                  Group ID. There is no automatic allocation, so this must be
                  chosen, and kept unique, by hand.
                '';
              };
            };
          }
        )
      );
      default = { };
      description = ''
        Groups to create in /etc/group.
      '';
    };

    users = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              name = mkOption {
                type = types.str;
                default = name;
                description = ''
                  Name of the user, as it appears in /etc/passwd. Defaults to
                  the attribute name.
                '';
              };
              uid = mkOption {
                type = types.ints.u16;
                description = ''
                  User ID. There is no automatic allocation, so this must be
                  chosen, and kept unique, by hand.
                '';
              };
              gid = mkOption {
                type = types.ints.u16;
                description = ''
                  ID of the user's primary group. This is the raw ID rather
                  than a name, so it must match the `id` of the intended entry
                  in `groups`.
                '';
              };
              description = mkOption {
                type = types.str;
                default = "";
                description = ''
                  The GECOS field of the user's /etc/passwd entry.
                '';
              };
              home = mkOption {
                type = types.str;
                default = "/var/empty";
                description = ''
                  The user's home directory. Nothing creates it, so a
                  directory that does not otherwise exist stays missing.
                '';
              };
              shell = mkOption {
                type = types.path;
                default = "/bin/nologin";
                description = ''
                  The user's login shell.
                '';
              };
              groups = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = ''
                  Names of supplementary groups the user is a member of, on
                  top of the primary group named by `gid`.
                '';
              };
            };
          }
        )
      );
      default = { };
      description = ''
        Users to create in /etc/passwd.
      '';
    };

    init = mkOption {
      default = { };
      type = types.attrsOf (
        types.submodule (_: {
          options = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Whether to enable this process.
              '';
            };

            tty = mkOption {
              type = types.str;
              default = "null";
              example = "tty1";
              description = ''
                This field is used by BusyBox init to specify the controlling
                tty for the specified process to run on.  The contents of this
                field are appended to "/dev/" and used as-is.  There is no need
                for this field to be unique, although if it isn't you may have
                strange results.  If this field is left blank, then the init's
                stdin/out will be used.
              '';
            };

            action = mkOption {
              type = types.enum possibleActions;
              description = ''
                sysinit actions are started first, and init waits for them to
                complete. wait actions are started next, and init waits for
                them to complete. once actions are started next (and not waited
                for).

                askfirst and respawn are started next. For askfirst, before
                running the specified process, init displays the line "Please
                press Enter to activate this console" and then waits for the
                user to press enter before starting it.

                shutdown actions are run on halt/reboot/poweroff, or on
                SIGQUIT. Then the machine is halted/rebooted/powered off, or
                for SIGQUIT, restart action is exec'ed (init process is
                replaced by that process). If no restart action specified,
                SIGQUIT has no effect.

                ctrlaltdel actions are run when SIGINT is received (this might
                be initiated by Ctrl-Alt-Del key combination). After they
                complete, normal processing of askfirst / respawn resumes.
              '';
            };

            process = mkOption {
              type = types.either types.str types.package;
              example = "/bin/echo 'hello, world'";
              description = ''
                Specifies the process to be executed and it's command line.
              '';
            };

            deps = mkOption {
              type = types.listOf types.str;
              default = [ ];
              example = [ "mount-state" ];
              description = ''
                Names of other init entries this one must be ordered after.
                Ordering only applies within a single action: every name
                listed here must name an enabled entry with the same `action`
                as this one, or evaluation fails.
              '';
            };
          };
        })
      );
      description = ''
        Entries for busybox init's /etc/inittab, keyed by a name used only for
        ordering with `deps`. Actions run in the order listed under `action`,
        not in the order entries are declared here.
      '';
    };

    services = mkOption {
      type = types.attrsOf (
        types.submodule (_: {
          options = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Whether to enable this service.
              '';
            };

            run = mkOption {
              type = types.path;
              example = literalExpression "/bin/httpd";
              description = ''
                Specifies the process to be executed for this service.
              '';
            };
          };
        })
      );
      default = { };
      description = ''
        Long-running processes to supervise, keyed by service name. Each one
        becomes a service directory under /var/service, run by the runsvdir
        started from `init`.
      '';
    };

    mdev.rules = mkOption {
      type = types.lines;
      description = ''
        Rules to be interpreted by mdev, placed in `/etc/mdev.conf`.
      '';
    };

    state = {
      enable = mkEnableOption "persistence of state";
      init = mkOption {
        type = types.nullOr types.path;
        example = literalExpression ''pkgs.writeScript "state-init" "mkfs.ext4 /dev/sda"'';
        description = ''
          Program to initialize state, for example for formatting
          disks, creating device-mapper devices, etc. This program
          will run on every boot, thus it should be idempotent if the
          backing device has already been initialized.
        '';
      };
      fsType = mkOption {
        type = types.str;
        example = "ext4";
        description = ''
          The filesystem type of the state device.
        '';
      };
      source = mkOption {
        type = types.str;
        example = "/dev/sda";
        description = ''
          The device being mounted.
        '';
      };
      options = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          The mount options to use when mounting the state device. Available
          options can usually be found in fs/<fstype>/super.c of the kernel
          source. In addition, any of the `MOUNT_ATTR_*` names can be used with
          name lowercased and the "MOUNT_ATTR_" prefix removed (see
          `<linux.mount.h>`).
        '';
      };
    };

    system = {
      build = mkOption {
        default = { };
        description = ''
          Attribute set of derivations used to set up the system.
        '';
        type = types.submoduleWith {
          modules = [
            {
              freeformType = with types; lazyAttrsOf (uniq unspecified);
            }
          ];
        };
      };
    };

    mixos = {
      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ./package.nix { };
        defaultText = "pkgs.mixos";
        description = ''
          The mixos package to use.
        '';
      };

      osRelease = mkOption {
        type = types.submodule {
          freeformType = osReleaseFormat.type;
          options = {
            ID = mkOption {
              type = types.str;
              default = "mixos";
              description = ''
                The `ID` field of /etc/os-release, identifying the operating
                system.
              '';
            };
            VERSION_ID = mkOption {
              type = types.str;
              default = config.mixos.package.version;
              defaultText = literalExpression "config.mixos.package.version";
              description = ''
                The `VERSION_ID` field of /etc/os-release.
              '';
            };
          };
        };
        default = { };
        description = ''
          /etc/os-release contents.
        '';
      };

      storeUUID = mkOption {
        type = types.str;
        default = "cb67e325-87bc-4235-b2fd-cd5d54efe14b";
        description = ''
          UUID of the erofs image, fixed for reproducibility.
        '';
      };

      testing.enable = mkEnableOption "the mixos test backdoor service";
    };
  };

  config = mkMerge [
    {
      _module.args.pkgs = config.nixpkgs.pkgs;

      assertions = danglingDepAssertions ++ [
        {
          # For leveraging nullfs, to simplify initrd logic.
          assertion = versionAtLeast config.boot.kernelPackages.kernel.version "7.0";
          message = "MixOS requires Linux kernel version 7.0 or greater";
        }
        {
          assertion =
            (config.boot.kernelModules != [ ] || config.boot.extraModulePackages != [ ]) -> hasModules;
          message = "Cannot declare kernel modules be loaded at runtime without having CONFIG_MODULES=y set in the kernel config";
        }
        (
          let
            restartEntries = attrNames (filterAttrs (const ({ action, ... }: action == "restart")) enabledInit);
          in
          {
            # Only the first restart action entry is ran by busybox.
            assertion = length restartEntries <= 1;
            message = "Only one init entry may have the 'restart' action, since BusyBox init only ever runs the first one. Declared by: ${concatStringsSep ", " restartEntries}";
          }
        )
        (
          let
            userGids = unique (mapAttrsToList (_: { gid, ... }: gid) config.users);
            groupIds = unique (mapAttrsToList (_: { id, ... }: id) config.groups);
            diff = subtractLists groupIds userGids;
          in
          {
            assertion = diff == [ ];
            message = "Some users have GIDs that do not correspond to any declared group. Missing groups with IDs: ${
              concatMapStringsSep ", " toString diff
            }";
          }
        )
      ];

      etc = mkMerge [
        {
          "inittab".source = pkgs.writeText "mixos-inittab" inittab;
          "mdev.conf".source = pkgs.writeText "mdev.conf" config.mdev.rules;
          "os-release".source = osReleaseFormat.generate "os-release" config.mixos.osRelease;
          "hosts".source = mkDefault (
            pkgs.writeText "etc-hosts" ''
              127.0.0.1 localhost
              ::1 localhost
            ''
          );
          "passwd".source = pkgs.writeText "passwd" (
            concatLines (
              map (
                {
                  name,
                  uid,
                  gid,
                  description,
                  home,
                  shell,
                  ...
                }:
                "${name}:x:${toString uid}:${toString gid}:${description}:${home}:${shell}"
              ) (attrValues config.users)
            )
          );
          "group".source = pkgs.writeText "group" (
            concatLines (
              map (
                { name, id, ... }:
                let
                  members = mapAttrsToList (_: { name, ... }: name) (
                    filterAttrs (_: { groups, ... }: elem name groups) config.users
                  );
                in
                "${name}:x:${toString id}:${concatStringsSep "," members}"
              ) (attrValues config.groups)
            )
          );
        }
        {
          "modprobe.d/00-mixos.conf" = mkIf (modprobeConf != "") {
            source = pkgs.writeText "mixos-modprobe.conf" modprobeConf;
          };
        }
      ];

      mdev.rules = mkBefore (
        # This mdev rule ensures all devices
        # get their $MODALIAS value modprobed
        # to allow for automatic kernel module
        # loading.
        #
        # The leading "-" tells mdev to keep
        # matching rules after this one. Without
        # it, rule processing stops at the first
        # match, so any uevent carrying a
        # MODALIAS would never reach the rules
        # below, and a device needing both its
        # driver loaded and a rule of its own
        # applied would only ever get the driver.
        ''
          -$MODALIAS=.* 0:0 660 @/sbin/modprobe "$MODALIAS"
        ''
        # This is needed by many programs (e.g.
        # nologin) to be world-writeable.
        + ''
          null 0:0 666
        ''
      );

      init = {
        restart = {
          action = "restart";
          process = mkDefault "/bin/mixos switch-root";
        };

        reboot = {
          action = "ctrlaltdel";
          process = mkDefault "/bin/reboot";
        };

        shutdown = {
          action = "shutdown";
          process = mkDefault "/bin/mixos shutdown";
        };

        runsvdir = {
          action = "respawn";
          process = mkDefault "/bin/runsvdir -P /var/service";
        };
      };

      services.watchdog = mkIf config.boot.watchdog.enable {
        run = mkDefault (
          pkgs.writeScript "watchdog-run" ''
            #!/bin/sh

            while [ ! -c /dev/watchdog ]; do
              if [ -z "$warned" ] && [ -S /dev/log ]; then
                logger -t watchdog "no /dev/watchdog, waiting for the device to appear"
                warned=1
              fi

              sleep 1
            done

            exec /bin/watchdog -F /dev/watchdog
          ''
        );
      };

      services.mdev.run = mkDefault (
        pkgs.writeScript "mdev-run" ''
          #!/bin/sh
          exec /bin/mdev -d -f -S
        ''
      );

      services.syslogd.run = mkDefault (
        pkgs.writeScript "syslogd-run" ''
          #!/bin/sh
          exec /bin/syslogd -n -D
        ''
      );

      services.klogd.run = mkDefault (
        pkgs.writeScript "klogd-run" ''
          #!/bin/sh

          # Since runsvdir gives us no ordering, we wait for syslogd's socket
          # (/dev/log) so we can get early kernel logs into syslogd.
          while [ ! -S /dev/log ]; do
            sleep 0.1
          done

          exec /bin/klogd -n
        ''
      );

      services.crond.run = mkDefault (
        pkgs.writeScript "crond-run" ''
          #!/bin/sh
          exec /bin/crond -f -S
        ''
      );

      services.ntpd = mkIf (any id (map (hasAttr "ntp.conf") options.etc.definitions)) {
        run = mkDefault (
          pkgs.writeScript "ntpd-run" ''
            #!/bin/sh
            exec /bin/ntpd -n
          ''
        );
      };

      services.test-backdoor = mkIf config.mixos.testing.enable {
        run = pkgs.writeScript "test-backdoor-run" ''
          #!/bin/sh
          exec /bin/mixos test-backdoor
        '';
      };
    }
    {
      boot.requiredKernelConfig = mkMerge [
        {
          BLK_DEV_LOOP = kernel.module;
          EROFS_FS = kernel.module;
          OVERLAY_FS = kernel.module;
        }
        (genAttrs (
          [
            "EPOLL"
            "EVENTFD"
            "FUTEX"
            "RD_XZ"
            "TIMERFD"
            "TMPFS"
          ]
          ++ optional (config.boot.firmware != [ ]) "FW_LOADER_COMPRESS_XZ"
        ) (const kernel.yes))
      ];
    }
    {
      system.build.etc = pkgs.runCommand "mixos-etc" { } (
        "mkdir -p $out"
        + concatLines (
          flatten (
            mapAttrsToList (
              pathUnderEtc:
              { source, mode }:
              [ "mkdir -p $(dirname $out/${pathUnderEtc})" ]
              ++ [
                (
                  if mode != null then
                    "install -vm${mode} ${source} $out/${pathUnderEtc} "
                  else
                    "ln -svf ${source} $out/${pathUnderEtc} "
                )
              ]
            ) config.etc
          )
        )
      );

      system.build.kernelModules = pkgs.buildEnv {
        name = "mixos-kernel-modules";
        paths = [
          (getOutput "modules" kernelPackage)
          (pkgs.writeTextDir "lib/modules/${kernelPackage.modDirVersion}/modules.stub" "") # ensure buildEnv doesn't barf if extraModulePackages is empty
        ]
        ++ config.boot.extraModulePackages;
        pathsToLink = [
          "/etc"
          "/lib"
        ];
        # Regenerate kmod's modules* files. This picks up any out-of-tree
        # modules that might be included in the configuration.
        postBuild = optionalString hasModules ''
          find $out/lib/modules/${kernelPackage.modDirVersion}/ -name 'modules*' -not -name 'modules.builtin*' -not -name 'modules.order' -delete
          ${getExe' pkgs.buildPackages.kmod "depmod"} -b $out -C $out/etc/depmod.d -a ${kernelPackage.modDirVersion}
          rm -rf $out/etc
        '';
      };

      system.build.manifest = manifestFormat.generate "mixos-manifest.json" {
        inherit (builtins) storeDir;
        inherit (config.system.build) usr etc;
        init = [ (getExe' pkgs.busybox "init") ];
        boot = {
          inherit (config.boot) kernelModules;
          watchdog =
            if config.boot.watchdog.enable then { inherit (config.boot.watchdog) timeout; } else null;
        };
        graphics = if config.hardware.graphics.enable then { drivers = graphicsDrivers; } else null;
        state = if config.state.enable then removeAttrs config.state [ "enable" ] else null;
        services = mapAttrs (const (flip removeAttrs [ "enable" ])) (
          filterAttrs (const (getAttr "enable")) config.services
        );
      };

      # Can be used with "mixos switch-root" by mounting it at /run/nextstore.
      # The image carries its own manifest at /.manifest.json.
      system.build.erofs = pkgs.callPackage (
        {
          erofs-utils,
          jq,
          stdenvNoCC,
        }:
        stdenvNoCC.mkDerivation {
          name = "mixos-store.erofs";

          __structuredAttrs = true;
          unsafeDiscardReferences.out = true;
          enableParallelBuilding = true;

          exportReferencesGraph.closure = [ config.system.build.manifest ];

          nativeBuildInputs = [
            config.mixos.package.buildtools
            erofs-utils
            jq
          ];

          buildCommand = buildStoreErofs "$out";
        }
      ) { };

      system.build.usr = pkgs.buildEnv {
        name = "mixos-usr";
        paths = [
          config.system.build.kernelModules
        ]
        ++ map getBin (
          config.packages
          ++ [
            pkgs.busybox
            config.mixos.package
          ]
        )
        ++ map pkgs.compressFirmwareXz config.boot.firmware;
        pathsToLink = [
          "/bin"
          "/sbin"
          "/lib"
          "/share"
        ];
        ignoreCollisions = false;
        postBuild = ''
          for dir in bin sbin; do
            rm -f $out/$dir/modprobe
            ln -sf $out/bin/mixos $out/$dir/modprobe
          done
        '';
      };

      system.build.initrd = checkAssertWarn config.assertions config.warnings (
        pkgs.callPackage (
          {
            cpio,
            erofs-utils,
            jq,
            stdenvNoCC,
            xz,
          }:
          stdenvNoCC.mkDerivation {
            name = "mixos-initrd";

            __structuredAttrs = true;
            unsafeDiscardReferences.out = true;
            enableParallelBuilding = true;

            exportReferencesGraph.closure = [ config.system.build.manifest ];

            nativeBuildInputs = [
              config.mixos.package.buildtools # only works because buildtools is always built for buildPlatform
              cpio
              erofs-utils
              jq
              xz
            ];

            buildCommand = ''
              echo "Using kernel configuration '${kernelPackage.configfile}'"

              # Make build-time assertions on kernel configuration, since
              # evaluation-time access to kernel configuration is limited.
              kconfig ${kernelPackage.configfile} ${
                escapeShellArgs (
                  flatten (
                    mapAttrsToList (
                      kconfig: value:
                      if value ? freeform then
                        [
                          "--assert-value"
                          "${kconfig}=${toString value.freeform}"
                        ]
                      else if value.tristate == null then
                        [
                          "--assert-unset"
                          kconfig
                        ]
                      else
                        {
                          "y" = [
                            "--assert-yes"
                            kconfig
                          ];
                          "m" = [
                            "--assert-yes-or-module"
                            kconfig
                          ];
                          "n" = [
                            "--assert-no"
                            kconfig
                          ];
                        }
                        .${value.tristate}
                    ) (filterAttrs (const (value: !value.optional)) config.boot.requiredKernelConfig)
                  )
                )
              }

              # Make some more build-time assertions on kernel configuration,
              # predicated on the value of other kernel configuration options.
              # We do it like this as opposed to conditionally including
              # assertions at evaluation time since we cannot depend on having
              # access to the full configuration at evaluation time.
              if kconfig ${kernelPackage.configfile} --assert-yes MODULE_COMPRESS 2>/dev/null; then
                kconfig ${kernelPackage.configfile} --assert-yes MODULE_DECOMPRESS
              fi

              mkdir -p initrd $out

              # Prepended archives are concatenated ahead of our cpio
              # stream; the kernel unpacks each segment in turn.
              ${concatMapStringsSep "\n" (prepend: ''cat ${prepend} >>"$out/initrd"'') config.boot.initrd.prepend}

              # Copy kernel modules that are crucial for booting. We don't need
              # to provide any user-customizability here since the root
              # filesystem is _inside_ the initrd.
              copy-modules-closure \
                ${config.system.build.kernelModules}/lib/modules/${kernelPackage.modDirVersion} \
                initrd/lib/modules/${kernelPackage.modDirVersion} \
                loop erofs overlay
              cp \
                ${config.system.build.kernelModules}/lib/modules/${kernelPackage.modDirVersion}/modules.* \
                initrd/lib/modules/${kernelPackage.modDirVersion}

              install -Dm0755 ${getExe config.mixos.package} initrd/init
              ${buildStoreErofs "initrd/mixos.erofs"}
              (cd initrd && find . -print0 | sort -z | cpio --quiet -o -H newc -R +0:+0 --reproducible --null | eval -- xz --check=crc32 --lzma2=dict=512KiB >> "$out/initrd")
            '';
          }
        ) { }
      );

      system.build.toplevel = pkgs.buildEnv {
        name = "mixos-toplevel";
        paths = [
          kernelPackage
          config.system.build.initrd
        ];
        postBuild = ''
          ln -sf ${
            kernelPackage.target
              # TODO(jared): remove when we no longer support release-26.05
              or pkgs.stdenv.hostPlatform.linux-kernel.target
          } $out/kernel
        '';
      };
    }
  ];
}
