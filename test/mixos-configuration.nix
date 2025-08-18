{
  config,
  lib,
  pkgs,
  ...
}:
{
  nixpkgs = {
    buildPlatform = "x86_64-linux";
    hostPlatform.config = "aarch64-unknown-linux-musl";
  };

  boot.kernel = pkgs.linuxKernel.manualConfig {
    inherit (pkgs.linux_6_15) src version;
    configfile = ./kernel.config;
    # TODO(jared): Remove when we have https://github.com/NixOS/nixpkgs/pull/434608
    allowImportFromDerivation = false;
    config = lib.listToAttrs (
      map
        (
          line:
          let
            match = lib.match "(.*)=\"?(.*)\"?" line;
          in
          {
            name = lib.elemAt match 0;
            value = lib.elemAt match 1;
          }
        )
        (
          lib.filter (line: !(lib.hasPrefix "#" line || line == "")) (
            lib.splitString "\n" (builtins.readFile ./kernel.config)
          )
        )
    );
  };

  init.shell = {
    tty = "ttyAMA0";
    action = "askfirst";
    process = "/bin/sh";
  };

  system.build.test = pkgs.pkgsBuildBuild.callPackage (
    { writeShellApplication, qemu }:
    writeShellApplication {
      name = "mixos-test";
      runtimeInputs = [ qemu ];
      # TODO(jared): Make the qemu options generic to the host platform.
      text = ''
        qemu-system-${pkgs.stdenv.hostPlatform.qemuArch} -M virt -m 2G -cpu cortex-a53 -kernel ${config.system.build.all}/Image -initrd ${config.system.build.all}/initrd -nographic -append debug
      '';
    }
  ) { };
}
