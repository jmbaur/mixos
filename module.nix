{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib.asserts) checkAssertWarn;

  inherit (lib)
    attrNames
    concatMapStringsSep
    escapeShellArgs
    isFunction
    mapAttrs
    mergeOneOption
    mkEnableOption
    mkMerge
    mkOption
    mkOptionType
    optionalAttrs
    textClosureMap
    types
    ;

  bin = pkgs.buildEnv {
    name = "mixos-bin";
    paths = map lib.getBin config.bin;
    pathsToLink = [ "/bin" ];
  };

  # <id>:<runlevels>:<action>:<process>
  inittabTextAttrs = mapAttrs (
    _:
    {
      tty,
      action,
      process,
      deps,
    }:
    {
      inherit deps;
      text = "${tty}::${action}:${process}";
    }
  ) config.init;

  mountState = escapeShellArgs (
    [ "mount" ]
    ++ (
      if config.state.enable then
        [
          "-t"
          "${config.state.fsType}"
        ]
        ++ lib.optionals (config.state.options != [ ]) [
          "-o"
          (lib.concatStringsSep "," config.state.options)
        ]
        ++ [ config.state.what ]
      else
        [
          "-t"
          "tmpfs"
          "tmpfs"
        ]
    )
    ++ [ "/state" ]
  );
in
{
  options = {
    assertions = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      internal = true;
      default = [ ];
    };

    warnings = lib.mkOption {
      internal = true;
      default = [ ];
      type = lib.types.listOf lib.types.str;
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
        type = lib.types.listOf (mkOptionType {
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

      kernel = mkOption {
        type = types.package;
        description = ''
          A kernel packaged from the nixpkgs Linux kernel build recipe.
        '';
        # TODO(jared): remove once https://github.com/NixOS/nixpkgs/pull/423933 is merge
        #
        # This allows for the nix output containing the kernel image to be
        # separated from the nix output containing the kernel modules, meaning we
        # don't have to ship our filesystem image with an unecessary kernel
        # image.
        apply =
          kernel:
          kernel.overrideAttrs (
            old:
            optionalAttrs (old.passthru.config.isYes "MODULES") {
              outputs = old.outputs ++ [ "modules" ];
              postInstall = ''
                unset modules
                ${old.postInstall or ""}
                modules=${placeholder "modules"}
                mkdir -p $modules
                mv $out/lib $modules
              '';
            }
          );
      };
    };

    bin = mkOption {
      type = types.listOf types.package;
      default = [ ];
    };

    etc = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            source = mkOption { type = types.path; };
            mode = mkOption {
              type = types.nonEmptyStr;
              default = "0400";
            };
          };
        }
      );
      default = { };
    };

    init = mkOption {
      default = { };
      type = types.attrsOf (
        types.submodule {
          options = {
            tty = mkOption {
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
              type = types.enum [
                "sysinit"
                "wait"
                "once"
                "respawn"
                "askfirst"
                "shutdown"
                "restart"
                "ctrlaltdel"
              ];
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
              description = ''
                Specifies the process to be executed and it's command line.
              '';
            };

            deps = mkOption {
              default = [ ];
              type = types.listOf types.str;
            };
          };
        }
      );
    };

    state = {
      enable = mkEnableOption "state";
      fsType = mkOption { type = types.str; };
      options = mkOption {
        type = types.listOf types.str;
        default = [ ];
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
  };

  config = mkMerge [
    {
      assertions = [
        {
          assertion = lib.all config.boot.kernel.config.isYes config.boot.requiredKernelConfig;
          message = "Kernel configuration is not satisfied, please ensure the following options are configured: ${
            concatMapStringsSep " " (opt: "${opt}=y") config.boot.requiredKernelConfig
          }";
        }
      ];
    }
    {
      nixpkgs.overlays = [
        (final: _: {
          mixos-rdinit = final.callPackage ./package.nix { };
        })
      ];

      _module.args.pkgs = import config.nixpkgs.nixpkgs {
        localSystem = lib.systems.elaborate config.nixpkgs.buildPlatform;
        crossSystem = lib.systems.elaborate config.nixpkgs.hostPlatform;
        inherit (config.nixpkgs) overlays config;
      };
    }
    {
      bin = [ pkgs.busybox ];

      etc = {
        "inittab".source = pkgs.writeText "mixos-inittab" (
          (textClosureMap lib.id inittabTextAttrs (attrNames inittabTextAttrs) + "\n")
        );
        "mdev.conf".source = pkgs.writeText "mixos-mdev" "";
      };

      init = {
        sysinit = {
          action = "sysinit";
          process = pkgs.writeScript "mixos-startup" ''
            #!/bin/sh

            # Create initial char/block nodes
            mdev -f -s -S

            # Create basic filesystems and setup read/write /etc
            mkdir -p /dev/pts
            mount -t devpts devpts -o nosuid,noexec /dev/pts
            mount -t configfs configfs /sys/kernel/config
            mount -t tmpfs tmpfs /tmp
            mkdir -p /tmp/.etc/work /tmp/.etc/upper
            mount -t overlay overlay -o lowerdir=/etc,upperdir=/tmp/.etc/upper,workdir=/tmp/.etc/work /etc 

            # Mount state directory and bind to /var
            ${mountState}
            mount -o bind /state /var

            # Ensure basic state directories exist
            mkdir -p /var/log
            mkdir -p /var/spool/cron/crontabs
          '';
        };

        restart = {
          action = "restart";
          process = "/sbin/init";
        };

        reboot = {
          action = "ctrlaltdel";
          process = "/sbin/reboot";
        };

        umount = {
          action = "shutdown";
          process = "/bin/umount -a -r";
        };

        syslog = {
          action = "respawn";
          process = "/bin/syslogd -n -D";
        };

        klogd = {
          action = "respawn";
          process = "/bin/klogd -n";
          deps = [ "syslog" ];
        };

        mdev = {
          action = "respawn";
          process = "/bin/mdev -d -f -S";
          deps = [ "syslog" ];
        };

        crond = {
          action = "respawn";
          process = "/bin/crond -f -S";
          deps = [ "syslog" ];
        };
      };
    }
    {
      boot.requiredKernelConfig = [
        "BLK_DEV_LOOP"
        "CONFIGFS_FS"
        "DEVTMPFS_MOUNT"
        "EROFS_FS"
        "EROFS_FS_ZIP_LZMA"
        "OVERLAY_FS"
        "RD_XZ"
        "UNIX98_PTYS"
      ];
    }
    {
      system.build.root = checkAssertWarn config.assertions config.warnings (
        pkgs.runCommand "mixos-root" { } ''
          # our root filesystem is read-only, so we must create all top-level
          # directories for any future mountpoints
          mkdir -p $out/{lib,etc,dev,proc,sys,var,tmp,state}

          # pid 1
          ln -sf ${bin}/bin/init $out/init

          # kernel modules
          ${lib.optionalString (config.boot.kernel ? modules) ''
            ln -sf ${lib.getOutput "modules" config.boot.kernel}/lib/modules $out/lib/modules
          ''}

          # /bin (and /sbin)
          ln -sf ${bin}/bin $out/bin && ln -sf $out/bin $out/sbin

          # /tmp is setup as a tmpfs on bootup, symlink it to /run and /var/run
          # since some programs want to write there, but all should be
          # ephemeral. We spawn a subshell so that we can have our symlink(s)
          # be relative to the nix output, not the full path including the nix
          # output path.
          (pushd $out && ln -sf ./tmp ./run && ln -sf ./tmp ./var/run)

          # /etc
          ${lib.concatLines (
            lib.mapAttrsToList (
              pathUnderEtc:
              { source, mode }:
              ''
                mkdir -p $(dirname $out/etc/${pathUnderEtc})
                ln -sf ${source} $out/etc/${pathUnderEtc}
              ''
            ) config.etc
          )}
        ''
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
            source = "${pkgs.busybox}/bin";
            target = "/bin";
          }
          {
            source = config.system.build.rootfs;
            target = "/rootfs";
          }
          {
            source = lib.getExe pkgs.mixos-rdinit;
            target = "/init";
          }
        ];
      };

      system.build.all = pkgs.buildEnv {
        name = "mixos-all";
        paths = [
          config.boot.kernel
          config.system.build.initrd
        ];
      };
    }
  ];
}
