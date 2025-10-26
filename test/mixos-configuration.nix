{ pkgs, ... }:

let
  configfile = ./${pkgs.stdenv.hostPlatform.linuxArch}.config;
in
{
  mixos.testing.enable = true;

  boot.kernel = pkgs.linuxKernel.manualConfig {
    inherit (pkgs.linux_6_17) src version;
    inherit configfile;
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
}
