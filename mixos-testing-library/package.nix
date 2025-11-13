{
  __editable ? false,
  buildPythonPackage,
  lib,
  mkPythonEditablePackage,
  schema,
  setuptools,
}:

let
  pyproject = lib.importTOML ./pyproject.toml;
in
if __editable then
  mkPythonEditablePackage {
    pname = pyproject.project.name;
    inherit (pyproject.project) version;

    root = "$REPO_ROOT/mixos-testing-library";

    build-system = [ setuptools ];
    dependencies = [ schema ];
  }
else
  buildPythonPackage {
    pname = pyproject.project.name;
    inherit (pyproject.project) version;

    pyproject = true;

    build-system = [ setuptools ];
    dependencies = [ schema ];

    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./pyproject.toml
        ./mixos
      ];
    };

    meta.mainProgram = "mixos";
  }
