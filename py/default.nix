{
  pkgs ? null,
  nixpkgs ? null,
  # config options
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
- Copy ruff.toml to ./ruff.toml
- Generate pyproject.toml with [build-system] if one doesn't exist
- Overwrite controlled [tool.*] sections (pytest, ty, inline-snapshot) in pyproject.toml
'';
} else

let
  files = import ../files;

  ruffFile = files.python.ruff { inherit pkgs; };

  # Controlled tool sections for pyproject.toml
  toolSections = {
    tool.pytest.ini_options = {
      typeguard-packages = src_path;
    };
    tool.ty.environment = {
      python = venv_path;
      extra-search-paths = [ src_path ];
    };
    tool.inline-snapshot = {
      format-command = "ruff format --stdin-filename {filename}";
    };
  };

  toolSectionsFile = (pkgs.formats.toml {}).generate "pyproject-tools.toml" toolSections;

  # Controlled section prefixes — any [header] starting with these is ours to overwrite
  controlledPrefixes = [ "tool.pytest" "tool.ty" "tool.inline-snapshot" ];

  # awk script: strip sections whose headers match controlled prefixes, preserve everything else
  awkScript = let
    conditions = builtins.concatStringsSep " || " (
      map (p: "index(header, \"[${p}\") == 1") controlledPrefixes
    );
  in pkgs.writeText "strip-sections.awk" ''
    BEGIN { skip = 0 }
    /^\[/ {
      header = $0
      gsub(/[[:space:]]*$/, "", header)
      if (${conditions}) {
        skip = 1
        next
      } else {
        skip = 0
      }
    }
    !skip { print }
  '';

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
    _pyproject_stripped=$(awk -f ${awkScript} ./pyproject.toml)
    _pyproject_stripped=$(printf '%s' "$_pyproject_stripped" | sed -e :a -e '/^[[:space:]]*$/{ $d; N; ba; }')
    printf '%s\n\n' "$_pyproject_stripped" > ./pyproject.toml
    cat ${toolSectionsFile} >> ./pyproject.toml
  '';
in
{
  inherit ruffFile;

  shellHook = ''
    cp -f ${ruffFile} ./ruff.toml
    ${pyprojectHook}
  '';

  enabledPackages = [];
}
