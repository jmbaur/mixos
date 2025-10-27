{ lib, python }:

let
  pyproject = lib.importTOML ./pyproject.toml;
in
python.pkgs.buildPythonPackage {
  pname = pyproject.project.name;
  inherit (pyproject.project) version;

  pyproject = true;

  build-system = [ python.pkgs.setuptools ];
  dependencies = [ python.pkgs.schema ];

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./pyproject.toml
      ./mixos
    ];
  };
}
