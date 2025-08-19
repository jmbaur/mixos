{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = inputs: {
    overlays.default = final: prev: {
      mixos = final.callPackage ./package.nix { };
      python3 = prev.python3.override {
        packageOverrides = pyfinal: _: {
          mixos-testing-library = pyfinal.callPackage ./mixos-testing-library/package.nix { };
        };
      };
    };

    legacyPackages =
      inputs.nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ]
        (
          system:
          import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.self.overlays.default ];
          }
        );

    lib.mixosSystem =
      { modules }:
      inputs.nixpkgs.lib.evalModules {
        modules = [
          ./module.nix
          { nixpkgs.overlays = [ inputs.self.overlays.default ]; }
        ]
        ++ modules;
      };

    mixosConfigurations.test = inputs.self.lib.mixosSystem {
      modules = [
        ./test/mixos-configuration.nix
        { nixpkgs.nixpkgs = inputs.nixpkgs; }
      ];
    };

    devShells = inputs.nixpkgs.lib.mapAttrs (_: pkgs: {
      default = pkgs.mkShell {
        packages = with pkgs; [
          (python3.withPackages (p: [ p.mixos-testing-library ]))
          zig_0_14
        ];
      };
    }) inputs.self.legacyPackages;
  };
}
