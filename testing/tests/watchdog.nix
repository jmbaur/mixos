_: {
  name = "mixos-watchdog";

  mixos.nodes.machine = { lib, pkgs, ... }: {
    boot.watchdog.enable = true;
    boot.watchdog.timeout = 10; # so the reset comes quickly
    boot.requiredKernelConfig.I6300ESB_WDT = lib.kernel.module;
    boot.kernelModules = [ "i6300esb" ];

    # State initialization is a convenient place to cause the early boot
    # process to fail, since it is the first piece of user code that we run.
    state = {
      enable = true;
      source = "none";
      fsType = "tmpfs";
      init = pkgs.writeScript "always-fails.sh" ''
        #!/bin/sh
        set -x
        false
      '';
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_console_text("mixos: state initialization failed")
    machine.wait_for_shutdown() # machine should shut down on its own after watchdog timeout
  '';
}
