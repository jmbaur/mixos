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
    mkRenamedOptionModule
    optional
    optionalString
    subtractLists
    textClosureMap
    types
    unique
    ;

  osReleaseFormat = pkgs.formats.keyValue { };

  kernelPackage = config.boot.kernelPackages.kernel;

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
              ) (filterAttrs (const (getAttr "enable")) config.init)
            )
          );
    in
    builtins.foldl' (
      acc: action: if hasAttr action groups then acc + groups.${action} + "\n" else acc
    ) "" possibleActions;

  enabledServices = filterAttrs (const (getAttr "enable")) config.services;
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
          }
        '';
        description = ''
          Attribute set of kernel Kconfig options that must be included in the
          kernel provided to mixos. Values (from lib.kernel) are asserted
          against the configured kernel, where lib.kernel.module is satisfied
          with either 'y' or 'm'.
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
        default = pkgs.linuxPackages;
        defaultText = "pkgs.linuxPackages";
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

      kernelModules = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Kernel modules to load during early bootup.
        '';
      };

      watchdog.enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable watchdog integration. This ensures if the boot process fails,
          the system doesn't hang indefinitely.
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
              };
              id = mkOption {
                type = types.ints.u16;
              };
            };
          }
        )
      );
      default = { };
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
              };
              uid = mkOption { type = types.ints.u16; };
              gid = mkOption { type = types.ints.u16; };
              description = mkOption {
                type = types.str;
                default = "";
              };
              home = mkOption {
                type = types.str;
                default = "/var/empty";
              };
              shell = mkOption {
                type = types.path;
                default = "/bin/nologin";
              };
              groups = mkOption {
                type = types.listOf types.str;
                default = [ ];
              };
            };
          }
        )
      );
      default = { };
    };

    init = mkOption {
      default = { };
      type = types.attrsOf (
        types.submodule (
          { config, ... }:
          {
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
              };
            };

            # Used to ensure syslogd starts before anything else that uses the
            # "respawn" action.
            config = mkIf (config.action == "respawn") {
              deps = [ "syslogd" ];
            };
          }
        )
      );
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
            };
            VERSION_ID = mkOption {
              type = types.str;
              default = config.mixos.package.version;
            };
          };
        };
        default = { };
        description = ''
          /etc/os-release contents.
        '';
      };

      testing.enable = mkEnableOption "the mixos test backdoor service";
    };
  };

  config = mkMerge [
    {
      _module.args.pkgs = config.nixpkgs.pkgs;

      assertions = [
        {
          assertion =
            (config.boot.kernelModules != [ ] || config.boot.extraModulePackages != [ ]) -> hasModules;
          message = "Cannot declare kernel modules be loaded at runtime without having CONFIG_MODULES=y set in the kernel config";
        }
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
      ];

      mdev.rules = mkBefore (
        # This mdev rule ensures all devices
        # get their $MODALIAS value modprobed
        # to allow for automatic kernel module
        # loading.
        ''
          $MODALIAS=.* 0:0 660 @/sbin/modprobe "$MODALIAS"
        ''
        # This is needed by many programs (e.g.
        # nologin) to be world-writeable.
        + ''
          null 0:0 666
        ''
      );

      init = {
        init = {
          action = "restart";
          process = mkDefault "/bin/init";
        };

        reboot = {
          action = "ctrlaltdel";
          process = mkDefault "/bin/reboot";
        };

        umount = {
          action = "shutdown";
          process = mkDefault "/bin/umount -a -r";
        };

        swapoff = {
          action = "shutdown";
          process = mkDefault "/bin/swapoff -a";
        };

        syslogd = {
          action = "respawn";
          process = mkDefault "/bin/syslogd -n -D";
        };

        runsvdir = {
          action = "respawn";
          process = mkDefault "/bin/runsvdir -P /var/service";
        };
      };

      # Consider writing our own watchdog daemon, since this does not handle
      # the case where the watchdog character device does not exist, so runsv
      # constantly restarts the process.
      services.watchdog = mkIf config.boot.watchdog.enable {
        run = mkDefault (
          pkgs.writeScript "watchdog-run" ''
            #!/bin/sh
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

      services.klogd.run = mkDefault (
        pkgs.writeScript "klogd-run" ''
          #!/bin/sh
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
          exec ${getExe config.mixos.package} test-backdoor
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
            buildPackages,
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

            exportReferencesGraph.closure = [
              config.system.build.usr
              config.system.build.etc
            ]
            ++ optional (config.state.enable && config.state.init != null) config.state.init
            ++ mapAttrsToList (const (getAttr "run")) enabledServices;

            env.manifest = builtins.toJSON {
              inherit (builtins) storeDir;
              inherit (config.system.build) usr etc;
              init = getExe' pkgs.busybox "init";
              storeFS = "/mixos.erofs";
              boot = {
                inherit (config.boot) kernelModules;
                watchdog = if config.boot.watchdog.enable then { } else null;
              };
              state = if config.state.enable then removeAttrs config.state [ "enable" ] else null;
              services = mapAttrs (const (flip removeAttrs [ "enable" ])) enabledServices;
            };

            nativeBuildInputs = [
              (buildPackages.callPackage ./package.nix { buildTools = true; })
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
                  mapAttrsToList (
                    kconfig: value:
                    if value.tristate == null then
                      "--assert-unset ${kconfig}"
                    else
                      {
                        "y" = "--assert-yes ${kconfig}";
                        "m" = "--assert-yes-or-module ${kconfig}";
                        "n" = "--assert-no ${kconfig}";
                      }
                      .${value.tristate}
                  ) (filterAttrs (const (value: value ? freeform || value.optional)) config.boot.requiredKernelConfig)
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

              mkdir -p store initrd $out

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

              for output_path in $(jq -r '.closure[].path' <"$NIX_ATTRS_JSON_FILE"); do
                cp -r $output_path store/
              done

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
              mkfs.erofs $erofs_zip -L mixos --force-uid=0 --force-gid=0 --workers=$NIX_BUILD_CORES -T$SOURCE_DATE_EPOCH mixos.erofs store

              install -Dm0755 ${getExe config.mixos.package} initrd/init

              jq -r '.env.manifest' <"$NIX_ATTRS_JSON_FILE" >initrd/manifest.json
              install -Dm0644 mixos.erofs initrd/mixos.erofs
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
