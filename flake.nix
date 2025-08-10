{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = inputs: {
    lib.mixosSystem =
      { modules }: inputs.nixpkgs.lib.evalModules { modules = [ ./module.nix ] ++ modules; };

    mixosConfigurations.test = inputs.self.lib.mixosSystem {
      modules = [
        ./test/mixos-configuration.nix
        { nixpkgs.nixpkgs = inputs.nixpkgs; }
      ];
    };

    devShells.x86_64-linux.default =
      let
        pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
      in
      pkgs.mkShell { packages = [ pkgs.zig_0_14 ]; };
  };
}
