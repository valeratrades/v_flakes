{
  pkgs ? null,
  nixpkgs ? null,
  # config options
  ruff ? true,
}:
if nixpkgs != null && pkgs == null then {
  description = ''
Python project configuration module.

Usage:
```nix
py = v-utils.py {
  inherit pkgs;
  ruff = true;  # Copy ruff.toml (default: true)
};
```

Then use in devShell:
```nix
devShells.default = pkgs.mkShell {
  shellHook = py.shellHook;
  packages = [ ... ] ++ py.enabledPackages;
};
```

The shellHook will:
- Copy ruff.toml to ./ruff.toml (if ruff = true)
- Generate pyproject.toml if one doesn't exist
'';
} else

let
  files = import ../files;

  ruffFile = files.python.ruff { inherit pkgs; };

  ruffHook = if ruff then ''
    cp -f ${ruffFile} ./ruff.toml
  '' else "";

  pyprojectHook = ''
    if [ ! -f ./pyproject.toml ]; then
      cat > ./pyproject.toml << 'PYPROJECT_EOF'
    [build-system]
    requires = ["setuptools>=75.0"]
    build-backend = "setuptools.backends._legacy:_Backend"

    [tool.setuptools.packages.find]
    where = ["src"]
    PYPROJECT_EOF
      echo "Generated pyproject.toml"
    fi
  '';
in
{
  inherit ruffFile;

  shellHook = ''
    ${ruffHook}
    ${pyprojectHook}
  '';

  enabledPackages = [];
}
