{
  pkgs ? null,
  nixpkgs ? null,
  # config options
  ruff ? true,
  venv_path ? ".devenv/state/venv",
  src_path ? "py_src",
}:
if nixpkgs != null && pkgs == null then {
  description = ''
Python project configuration module.

Usage:
```nix
py = v-utils.py {
  inherit pkgs;
  ruff = true;       # Copy ruff.toml (default: true)
  venv_path = ".devenv/state/venv";  # Venv path for ty (default)
  src_path = "py_src";               # Source path for tools (default)
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
- Ensure tool sections (pytest, ty, inline-snapshot) are present in pyproject.toml
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
    where = ["${src_path}"]
    PYPROJECT_EOF
      echo "Generated pyproject.toml"
    fi
  '';

  # Ensure each tool section exists in pyproject.toml, append if missing
  ensureSection = header: content: ''
    if ! grep -q '^\[${header}\]' ./pyproject.toml 2>/dev/null; then
      printf '\n[${header}]\n${content}\n' >> ./pyproject.toml
    fi
  '';

  toolSectionsHook = ''
    ${ensureSection "tool.pytest.ini_options" "typeguard-packages = \"${src_path}\""}
    ${ensureSection "tool.ty.environment" "python = \"${venv_path}\"\nextra-search-paths = [\"${src_path}\"]"}
    ${ensureSection "tool.inline-snapshot" "format-command = \"ruff format --stdin-filename {filename}\""}
  '';
in
{
  inherit ruffFile;

  shellHook = ''
    ${ruffHook}
    ${pyprojectHook}
    ${toolSectionsHook}
  '';

  enabledPackages = [];
}
