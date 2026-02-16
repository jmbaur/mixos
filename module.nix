{
  options,
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib.asserts) checkAssertWarn;

  inherit (builtins)
    any
    attrNames
    attrValues
    concatStringsSep
    elem
    filter
    getAttr
    groupBy
    hasAttr
    isFunction
    listToAttrs
    mapAttrs
    ;

  inherit (lib)
    concatLines
    concatMapStringsSep
    const
    fileContents
    filterAttrs
    getBin
    getExe
    getExe'
    getOutput
    id
    literalExpression
    mapAttrsToList
    mergeOneOption
    mkBefore
    mkDefault
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    mkOptionType
    nameValuePair
    optionalString
    optionals
    subtractLists
    systems
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
in
{
  options = {
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

    nixpkgs = {
      nixpkgs = mkOption { };

      buildPlatform = mkOption {
        type = types.either types.str types.attrs;
      };

      hostPlatform = mkOption {
        type = types.either types.str types.attrs;
      };

      config = mkOption {
        type = types.attrs;
        default = { };
      };

      overlays = mkOption {
        default = [ ];
        type = types.listOf (mkOptionType {
          name = "nixpkgs-overlay";
          description = "nixpkgs overlay";
          check = isFunction;
          merge = mergeOneOption;
        });
      };
    };

    boot = {
      requiredKernelConfig = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };

      kernelPackages = mkOption {
        type = types.raw;
        description = ''
          A kernel package-set containing a kernel attribute and optionally one
          or more kernel modules (à la pkgs.linuxPackagesFor ...).
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
    };

    bin = mkOption {
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
            source = mkOption { type = types.path; };
          };
        }
      );
      default = { };
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
                  Whether to enable this process on startup.
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
        default = null;
        description = ''
          Program to initialize state. For example, formatting disks, creating
          device-mapper devices, etc.
        '';
      };
      fsType = mkOption {
        type = types.str;
        description = ''
          The filesystem type of the state device.
        '';
      };
      device = mkOption {
        type = types.str;
        description = ''
          The device being mounted.
        '';
      };
      options = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          The mount options to use when mounting the state device.
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
              default = fileContents ./.version;
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
      assertions = [
        (
          let
            missing = filter (
              kconfigOption: !kernelPackage.config.isYes kconfigOption
            ) config.boot.requiredKernelConfig;
          in
          {
            assertion = missing == [ ];
            message = ''
              Kernel configuration is not satisfied, please ensure the configuration has the following:

              ${concatLines (
                map (
                  opt:
                  # Assertion output is more readable when these are indented
                  # to four spaces each.
                  "    CONFIG_${opt}=y"
                ) missing
              )}'';
          }
        )
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
    }
    {
      _module.args.pkgs = import config.nixpkgs.nixpkgs {
        localSystem = systems.elaborate config.nixpkgs.buildPlatform;
        crossSystem = systems.elaborate config.nixpkgs.hostPlatform;
        inherit (config.nixpkgs) overlays config;
      };
    }
    {
      etc = {
        "inittab".source = pkgs.writeText "mixos-inittab" inittab;
        "mdev.conf".source = pkgs.writeText "mdev.conf" config.mdev.rules;
        "hosts".source = mkIf (kernelPackage.config.isYes "NET") (
          mkDefault (
            pkgs.writeText "etc-hosts" ''
              127.0.0.1 localhost
              ::1 localhost
            ''
          )
        );
        "os-release".source = osReleaseFormat.generate "os-release" config.mixos.osRelease;
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
      };

      # This mdev rule ensures all devices get their $MODALIAS value modprobed
      # to allow for automatic kernel module loading.
      mdev.rules = mkBefore ''
        $MODALIAS=.* 0:0 660 @modprobe "$MODALIAS"
      '';

      init = {
        mixos-startup = {
          tty = "console"; # Used so that state init output can be viewed
          action = "sysinit";
          process = toString [
            (getExe pkgs.mixos)
            "sysinit"
            ((pkgs.formats.json { }).generate "sysinit.json" {
              boot = {
                inherit (config.boot) kernelModules;
                kernel = listToAttrs (
                  map (option: nameValuePair option (kernelPackage.config.isYes option)) [
                    "CGROUPS"
                    "CONFIGFS_FS"
                    "DEBUG_FS_ALLOW_ALL"
                    "FTRACE"
                    "MODULES"
                    "SECURITYFS"
                    "SHMEM"
                    "UNIX" # implies CONFIG_NET
                    "UNIX98_PTYS"
                  ]
                );
              };
              state = {
                where = "/state";
              }
              // (
                if config.state.enable then
                  {
                    what = config.state.device;
                    type = config.state.fsType;
                    inherit (config.state) options init;
                  }
                else
                  {
                    what = "tmpfs";
                    type = "tmpfs";
                    options = [ "mode=755" ];
                    init = null;
                  }
              );
            })
          ];
        };

        init = {
          action = "restart";
          process = "/sbin/init";
        };

        reboot = {
          action = "ctrlaltdel";
          process = mkDefault "/sbin/reboot";
        };

        umount = {
          action = "shutdown";
          process = mkDefault "/bin/umount -a -r";
        };

        syslogd = {
          action = "respawn";
          process = mkDefault "/bin/syslogd -n -D";
        };

        klogd = {
          action = "respawn";
          process = mkDefault "/bin/klogd -n";
        };

        mdev = {
          action = "respawn";
          process = mkDefault "/bin/mdev -d -f -S";
        };

        crond = {
          action = "respawn";
          process = mkDefault "/bin/crond -f -S";
        };

        ntpd = mkIf (any id (map (hasAttr "ntp.conf") options.etc.definitions)) (mkDefault {
          action = "respawn";
          process = "/bin/ntpd -n";
        });

        test-backdoor = {
          inherit (config.mixos.testing) enable;
          action = "respawn";
          process = toString [
            (getExe pkgs.mixos)
            "test-backdoor"
          ];
        };
      };
    }
    {
      boot.requiredKernelConfig = [
        "BLK_DEV_LOOP"
        "EROFS_FS"
        "EROFS_FS_ZIP_LZMA"
        "FUTEX"
        "OVERLAY_FS"
        "RD_XZ"
        "TMPFS"
      ]
      ++ optionals (config.boot.firmware != [ ]) [
        "FW_LOADER_COMPRESS_XZ"
      ]
      ++ optionals (kernelPackage.config.isYes "MODULE_COMPRESS") [
        # This allows us to call finit_module() with the MODULE_INIT_COMPRESSED_FILE flag
        "MODULE_DECOMPRESS"
        "MODULE_COMPRESS_XZ"
      ];
    }
    {
      system.build.etc = pkgs.runCommand "mixos-etc" { } (
        "mkdir -p $out"
        + concatLines (
          mapAttrsToList (
            pathUnderEtc:
            { source }:
            ''
              mkdir -p $(dirname $out/etc/${pathUnderEtc})
              ln -sf ${source} $out/etc/${pathUnderEtc}
            ''
          ) config.etc
        )
      );

      system.build.root = checkAssertWarn config.assertions config.warnings (
        pkgs.buildEnv {
          name = "mixos-root";
          paths = [
            # Placed first so that it takes precedence over /etc contents in
            # derivations further below.
            config.system.build.etc
          ]
          ++ map getBin (
            config.bin
            ++ [
              pkgs.busybox
              pkgs.mixos
            ]
          )
          ++ map pkgs.compressFirmwareXz config.boot.firmware
          ++ optionals hasModules (
            [ (getOutput "modules" kernelPackage) ] ++ config.boot.extraModulePackages
          );
          pathsToLink = [
            "/bin"
            "/etc"
            "/lib/firmware"
            "/lib/modules/${kernelPackage.modDirVersion}"
          ];
          ignoreCollisions = true;
          postBuild = ''
            # Our root filesystem is read-only, so we must create all top-level
            # directories for any future mountpoints.
            mkdir -p $out/{etc,dev,proc,sys,var,tmp,state,root,home,passthru}

            # pid 1
            ln -sf $out/bin/init $out/init

            # /sbin -> /bin
            ln -sf $out/bin $out/sbin

            # /tmp is setup as a tmpfs on bootup, symlink it to /run since some
            # programs want to write there, but all should be ephemeral. We
            # spawn a subshell so that we can have our symlink(s) be relative
            # to the nix output, not the full path including the nix output
            # path.
            ln -sfr $out/tmp $out/run

            # Many pieces of software want to consume /etc/mtab. Systemd (via
            # tmpfiles) symlinks it to /proc/self/mounts
            ln -sfr $out/proc/self/mounts $out/etc/mtab

            ${optionalString hasModules ''
              find $out/lib/modules/${kernelPackage.modDirVersion}/ -name 'modules*' -not -name 'modules.builtin*' -not -name 'modules.order' -delete
              ${getExe' pkgs.buildPackages.kmod "depmod"} -b $out -C $out/etc/depmod.d -a ${kernelPackage.modDirVersion}
            ''}
          '';
        }
      );

      system.build.rootfs = pkgs.callPackage (
        {
          erofs-utils,
          jq,
          runCommand,
        }:
        runCommand "mixos.erofs"
          {
            __structuredAttrs = true;
            unsafeDiscardReferences.out = true;
            enableParallelBuilding = true;

            exportReferencesGraph.closure = [ config.system.build.root ];

            nativeBuildInputs = [
              erofs-utils
              jq
            ];
          }
          ''
            mkdir rootfs

            cp -r ${config.system.build.root}/. rootfs

            mkdir -p rootfs/nix/store
            for output_path in $(jq -r '.closure[].path' < "$NIX_ATTRS_JSON_FILE"); do
              cp -r $output_path rootfs/nix/store
            done

            mkfs.erofs -zlzma -L mixos --force-uid=0 --force-gid=0 --workers=$NIX_BUILD_CORES -T$SOURCE_DATE_EPOCH ''${outputs[out]} rootfs
          ''
      ) { };

      system.build.initrd = pkgs.makeInitrdNG {
        compressor = "xz";
        contents = [
          {
            source = "${pkgs.mixos}/libexec/mixos-rdinit";
            target = "/init";
          }
          {
            source = config.system.build.rootfs;
            target = "/rootfs";
          }
        ];
      };

      system.build.all = pkgs.buildEnv {
        name = "mixos-all";
        paths = [
          kernelPackage
          config.system.build.initrd
        ];
        postBuild = ''
          ln -sf ${pkgs.stdenv.hostPlatform.linux-kernel.target} $out/kernel
        '';
      };
    }
  ];
}
