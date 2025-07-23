{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "mixos-rdinit";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./src
      ./Cargo.toml
      ./Cargo.lock
    ];
  };

  cargoLock.lockFile = ./Cargo.lock;

  separateDebugInfo = true;
  stripAllList = [ "bin" ];

  meta.mainProgram = "mixos-rdinit";
}
