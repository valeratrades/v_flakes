{
  pkgs ? null,
  nixpkgs ? null,
  # config options
  venv_path ? ".devenv/state/venv",
  src_path ? "py_src",
  # Deep-merged into ruff config. Lists are concatenated, attrsets recurse, scalars replace.
  ruff ? {},
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

  ruffFile = files.python.ruff { inherit pkgs; extend = ruff; };

  cargoNightly = pkgs.writeShellScript "cargo-nightly" ''
    export RUSTC_WRAPPER=
    if command -v cargo &>/dev/null; then
      exec cargo "$@"
    else
      exec rustup run nightly cargo "$@"
    fi
  '';

  pyprojectHook = ''
    ${cargoNightly} -Zscript -q ${./pyproject_merge.rs} ./pyproject.toml ${venv_path} ${src_path}
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
