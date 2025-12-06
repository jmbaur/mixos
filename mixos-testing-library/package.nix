{
  __editable ? false,
  buildPythonPackage,
  lib,
  mkPythonEditablePackage,
  schema,
  setuptools,
}:

let
  pname = pyproject.project.name;
  inherit (pyproject.project) version;
  pyproject = lib.importTOML ./pyproject.toml;
  build-system = [ setuptools ];
  dependencies = [ schema ];
in
if __editable then
  mkPythonEditablePackage {
    inherit
      pname
      version
      build-system
      dependencies
      ;

    root = "$REPO_ROOT/mixos-testing-library";
  }
else
  buildPythonPackage {
    inherit
      pname
      version
      build-system
      dependencies
      ;

    pyproject = true;

    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./pyproject.toml
        ./mixos
      ];
    };

    meta.mainProgram = "mixos";
  }
