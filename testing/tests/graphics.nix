_: {
  name = "mixos-graphics";

  mixos.nodes.machine = {
    hardware.graphics.enable = true;

    # mesa is large
    testing.qemu.memory = 4 * 1024 * 1024 * 1024;
  };

  testScript = ''
    machine.succeed("test -L /run/opengl-driver")
    machine.succeed("test -e /run/opengl-driver/lib/libEGL_mesa.so")
  '';
}
