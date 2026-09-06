{ pkgs ? null
, nixpkgs ? null
, # config options
  # Canonical interpreter for the fleet — consumers should not name a version.
  # Re-exported below so the devShell and the consumer's `packages.default`
  # cannot drift onto different pythons.
  python ? (if pkgs != null then pkgs.python312 else null)
, venv_path ? ".devenv/state/venv"
, src_path ? "py_src"
, # Deep-merged into ruff config. Lists are concatenated, attrsets recurse, scalars replace.
  ruff ? { }
,
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
      # python = pkgs.python313;         # Override the canonical interpreter
    };
    ```

    Then use in devShell:
    ```nix
    devShells.default = pkgs.mkShell {
      shellHook = py.shellHook;
      packages = [ ... ] ++ py.enabledPackages;
    };
    ```

    `py.python` re-exports the interpreter in use — build `packages.default` and any
    version string off it (`py.python.pythonVersion` is "3.12") instead of naming a
    version, so the shell and the package can never diverge:
    ```nix
    packages.default = pkgs.writeShellScriptBin pname "exec ''${pyEnv}/bin/python -m src \"$@\"";
    github = v-utils.github { lastSupportedVersion = "python-''${py.python.pythonVersion}"; ... };
    ```

    The shellHook will:
    - Copy ruff.toml to ./ruff.toml
    - Generate pyproject.toml with [build-system] if one doesn't exist
    - Overwrite controlled [tool.*] sections (pytest, ty, inline-snapshot) in pyproject.toml via py/pyproject-merge.rs
    - Create venv at venv_path if missing, activate it, and warn if stale
  '';
} else

  let
    files = import ../files;
    utils = import ../utils;

    ruffFile = files.python.ruff { inherit pkgs; extend = ruff; };

    # `py` is independent of `rs`, but pyproject-merge.rs is a `cargo -Zscript`.
    # Route through `utils.withCargo` so we use the nix cargo when `rs` is in
    # combine, fall back loudly to global rustup otherwise, and hard-error if
    # neither is reachable (instead of silently dispatching through a broken
    # rustup shim).
    pyprojectHook = utils.withCargo {
      caller = "py";
      body = ''
        _v_flakes_cargo -Zscript -q ${./pyproject-merge.rs} ./pyproject.toml ${venv_path} ${src_path}
      '';
    };
  in
  {
    inherit ruffFile python;

    shellHook = utils.mkShellHook ''
      cp -f ${ruffFile} ./ruff.toml
      ${pyprojectHook}
      if [ ! -d "${venv_path}" ]; then
        uv venv ${venv_path}
      fi
      source ${venv_path}/bin/activate
      _venv_recorded="$(grep '^VIRTUAL_ENV=' ${venv_path}/bin/activate 2>/dev/null | head -1 | sed "s/VIRTUAL_ENV='//;s/'$//")"
      _venv_actual="$(readlink -f ${venv_path})"
      if [ "$_venv_recorded" != "$_venv_actual" ]; then
        echo "warning: venv is stale (repo was moved?) — recreate with: rm -rf ${venv_path} && uv venv ${venv_path} && uv_sync"
      elif [ -f "uv.lock" ] && [ "${venv_path}" -ot "uv.lock" ]; then
        echo "warning: venv is older than uv.lock — run uv_sync"
      fi
      unset _venv_recorded _venv_actual
    '';

    # The shellHook runs `uv venv` and activates a python venv, so `uv` and a
    # python interpreter must be on PATH. Contribute them here (picked up via
    # `utils.combine` → `combined.enabledPackages`) rather than relying on the
    # consumer to supply them — devenv's `languages.python.uv.enable` is no
    # longer a prerequisite for a plain `mkShell` consumer.
    enabledPackages = [ pkgs.uv python ];
  }
