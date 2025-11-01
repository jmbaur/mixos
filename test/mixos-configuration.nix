{ pkgs, ... }:

let
  configfile = ./${pkgs.stdenv.hostPlatform.linuxArch}.config;
in
{
  bin = [ pkgs.strace ];

  mixos.testing.enable = true;

  boot.kernel = pkgs.linuxKernel.manualConfig {
    inherit (pkgs.linux_6_17) src version;
    inherit configfile;
  };

  boot.kernelModules = [ "nvme-tcp" ];

  state = {
    enable = true;
    fsType = "ext2";
    device = "/dev/vda";
    init = pkgs.writeScript "state-init.sh" ''
      #!/bin/sh
      mkfs.ext2 -L mixos-state /dev/vda
    '';
  };

  init.shell = {
    tty =
      {
        arm64 = "ttyAMA0";
        x86_64 = "ttyS0";
      }
      .${pkgs.stdenv.hostPlatform.linuxArch} or "console";
    action = "askfirst";
    process = "/bin/sh";
  };

  init.dhcp = {
    action = "respawn";
    process = "/bin/udhcpc -f -S";
  };

  etc."ntp.conf".source = pkgs.writeText "ntp.conf" ''
    server time.nist.gov
  '';

  etc."hostname".source = pkgs.writeText "hostname" ''
    mixos-test
  '';

  etc."modules.conf".source = pkgs.writeText "modules.conf" ''
    options nvme-tcp wq_unbound=Y
  '';

  mdev.rules = ''
    null 0:0 666
  '';
}
