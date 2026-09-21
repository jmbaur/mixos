# Preface {#preface}

MixOS is not NixOS. It is a Nix OS: a minimal Linux system built with Nix, which boots with a single statically linked `mixos` executable and uses busybox for the system's init, shell and coreutils.

A MixOS system is built from the module in [`module.nix`](https://github.com/jmbaur/mixos/blob/main/module.nix), evaluated with `mixosSystem` from this flake:

```nix
{
  inputs.mixos.url = "github:jmbaur/mixos";

  outputs =
    { self, nixpkgs, mixos }:
    {
      mixosConfigurations.machine = mixos.lib.mixosSystem {
        modules = [
          (
            { pkgs, ... }:
            {
              nixpkgs.pkgs = nixpkgs.legacyPackages.x86_64-linux;
              packages = [ pkgs.hello ];
            }
          )
        ];
      };
    };
}
```

[](#ch-options) lists every option available in a base MixOS system.
