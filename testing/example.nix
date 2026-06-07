{
  config,
  pkgs,
  ...
}:

{
  testing.qemu.diskImage = 1024 * 1024 * 1024;

  packages = [ pkgs.strace ];

  mixos.osRelease.EXPERIMENT = "test";

  # Test that out-of-tree kernel module loading works
  boot.extraModulePackages = [ config.boot.kernelPackages.jool ];

  boot.kernelModules = [
    "nvme-tcp"
    "jool"
  ];

  state = {
    enable = true;
    fsType = "ext2";
    source = "/dev/vda";
    options = [ "debug" ];
    init = pkgs.writeScript "state-init.sh" ''
      #!/bin/sh
      if ! blkid | grep mixos-state; then
        mkfs.ext2 -L mixos-state /dev/vda
      fi
    '';
  };

  services.udhcpc.run = pkgs.writeScript "udhcpc-run" ''
    #!/bin/sh
    exec /bin/udhcpc -f -S
  '';

  etc."ntp.conf".source = pkgs.writeText "ntp.conf" ''
    server time.nist.gov
  '';

  etc."hostname".source = pkgs.writeText "hostname" ''
    mixos-test
  '';

  etc."modprobe.d/mixos.conf".source = pkgs.writeText "modprobe-mixos.conf" ''
    options nvme-tcp wq_unbound=Y
  '';

  mdev.rules = ''
    null 0:0 666
  '';

  users.root = {
    uid = 0;
    gid = 0;
    description = "System administrator";
    home = "/root";
    shell = "/bin/sh";
  };

  groups.root.id = 0;

  users.foo = {
    uid = 1;
    gid = 1;
  };

  groups.foo.id = 1;
}
