{ pkgs, ... }:
{
  nixpkgs = {
    buildPlatform = "x86_64-linux";
    hostPlatform.config = "aarch64-unknown-linux-musl";
  };

  boot.kernel = pkgs.linuxKernel.manualConfig {
    inherit (pkgs.linux_6_15) src version;
    configfile = ./kernel.config;
    # not IFD since we provide the configfile at evaluation time
    allowImportFromDerivation = true;
  };

  init.shell = {
    tty = "console";
    action = "askfirst";
    process = "/bin/sh";
  };
}
