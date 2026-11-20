# The particles v_flakes ships, by the name a `jobs.<section>` list gives them. Each is
# `args: { program; prepare ? null; ci ? null; ciCache ? [ ]; badges ? { }; release ? null; }`; `ci` is a CI body for what the local
# program can't do there (miri's toolchain): `{ job; work; post ? [ ]; timedIf ? null; }`; `release` one more, run on release tags only.
# `badges`: gist key -> a job output of seconds, which the section's `report` job writes as that badge.
{ pkgs, rust, rs, runtimeInputs, cargoRoot, lastSupportedVersion }:
let
  lib = pkgs.lib;
  system = pkgs.stdenv.hostPlatform.system;
  parts = ../workflows/nix-parts;

  program = name: inputs: text: pkgs.writeShellApplication {
    inherit name text;
    runtimeInputs = inputs ++ runtimeInputs ++ [ pkgs.gitMinimal ];
  };
  # every rust particle runs in the cargo root, with the shell's toolchain and wrapper, and what CI's
  # nix-shell gives every rust job (install.nix): a linker, pkg-config, openssl, the section's packages' .pc files
  pkgConfigPath = lib.concatMapStringsSep ":" (p: "${p.dev or p}/lib/pkgconfig") ([ pkgs.openssl ] ++ runtimeInputs);
  cargo = name: inputs: text: assert rs != null || throw "v_flakes.github: `${name}` needs the `rs` module";
    program name ([ rust pkgs.stdenv.cc pkgs.mold pkgs.pkg-config ] ++ rs.enabledPackages ++ inputs) ''
      export PKG_CONFIG_PATH="${pkgConfigPath}''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
      cd "$(git rev-parse --show-toplevel)/${cargoRoot}"
      ${text}
    '';
  # one that reads the crate rather than building it: no toolchain
  crateTool = name: inputs: text: program name inputs ''
    cd "$(git rev-parse --show-toplevel)/${cargoRoot}"
    ${text}
  '';
  # job-level, not workflow-level: the shared jobs alongside need the repo root
  inCargoRoot = job:
    if cargoRoot == "." then job
    else lib.recursiveUpdate job { defaults.run.working-directory = cargoRoot; };
  rustCi = ci: ci // { job = inCargoRoot ci.job; };

  machete = (import ../../langs/rs).machete system;
  sortDerives = (import ../../langs/rs).sort_derives system;
  qlty = import ../../tools/qlty.nix system;
  scriptRust = # v_flakes' own scripts', whatever toolchain the repo has: the canonical nightly's, without the dev extensions
    let p = import (import ../../pins/nixpkgs.nix) { inherit system; overlays = [ (import (import ../../pins/rust_overlay.nix)) ]; };
    in p.rust-bin.nightly.${import ../../langs/rs/nightly_version.nix}.minimal;
in
{
  rust-tests = { skipPatterns ? [ ] }:
    let skipArgs = lib.optionalString (skipPatterns != [ ]) (" -- " + lib.concatMapStringsSep " " (p: "--skip ${p}") skipPatterns); in
    {
      prepare = cargo "rust-tests-prepare" [ pkgs.cargo-nextest ] "cargo nextest run --workspace --no-run";
      # nextest runs the test binaries side by side, and no doctests; `cargo test --doc` refuses a workspace without a library
      program = cargo "rust-tests" [ pkgs.cargo-nextest pkgs.jq ] ''
        cargo nextest run --workspace --no-tests=warn${skipArgs}
        if cargo metadata --no-deps --format-version 1 | jq -e '[.packages[].targets[].kind[]] | any(. == "lib" or . == "proc-macro")' > /dev/null; then
          cargo test --workspace --doc${skipArgs}
        fi
      '';
      ciCache = rs.ciCache;
      badges = { build = "prepare_seconds"; test = "seconds"; };
      release = if lastSupportedVersion == null then null else rustCi (import (parts + "/rust/tests.nix") { inherit lastSupportedVersion skipArgs; });
    };

  rust-doc = { package ? null }:
    {
      # cargo-docs-rs isn't in nixpkgs: `cargo doc` of the documented members, as their `[package.metadata.docs.rs]` asks docs.rs (`--cfg docsrs`
      # for rustdoc only); one invocation per set of whole-invocation flags, so rustdoc runs the members of each side by side
      program = cargo "rust-doc" [ pkgs.jq ] ''
        cargo metadata --no-deps --format-version 1 | jq -r --arg only ${lib.escapeShellArg (if package == null then "" else package)} '
          [ .packages[] | select([.targets[].kind[]] | any(. == "lib" or . == "proc-macro")) | select($only == "" or .name == $only)
            | (.metadata.docs.rs // {}) as $d
            | { name, all: ($d["all-features"] // false), bare: ($d["no-default-features"] // false),
                features: [($d.features // [])[] as $f | "\(.name)/\($f)"], rustdoc: (($d["rustdoc-args"] // []) | join(" ")) } ]
          | group_by([.all, .bare, .rustdoc])[]
          | [ (map("-p " + .name) | join(" ")),
              ([if .[0].all then "--all-features" else empty end, if .[0].bare then "--no-default-features" else empty end]
                + (map(.features[]) | if . == [] then [] else ["--features", join(",")] end) | join(" ")),
              .[0].rustdoc ]
          | join("\u001f")' | while IFS=$'\x1f' read -r packages flags rustdoc; do # not a tab: whitespace in IFS folds an empty field away
          # shellcheck disable=SC2086 # packages and flags are cargo's words
          RUSTDOCFLAGS="-Dwarnings --cfg docsrs $rustdoc" cargo doc --no-deps $packages $flags
        done
      '';
      ciCache = rs.ciCache;
    };

  rust-clippy = {}: {
    program = cargo "rust-clippy" [ ] "cargo clippy --workspace --all-targets -- -Dwarnings";
    ciCache = rs.ciCache;
  };

  rust-miri = {}:
    let cmd = "cargo miri test --lib --bins"; in    # `--lib --bins` is what's needed in 99% of cases
    {
      program = cargo "rust-miri" [ ] "MIRIFLAGS=-Zmiri-strict-provenance ${cmd}";
      ci = rustCi (import (parts + "/rust/miri.nix") { inherit cmd; });
    };

  # Not upstream's build: it can't see an orphan in `[workspace.dependencies]` (tools/machete.nix)
  rust-machete = {}: { program = crateTool "rust-machete" [ machete ] "cargo-machete"; };

  rust-sorted = {}: { program = crateTool "rust-sorted" [ pkgs.cargo-sort ] "cargo-sort --workspace --grouped --check || { echo 'Cargo.toml is not sorted: cargo sort -w fixes it'; exit 1; }"; };

  # Not upstream's build: it ignores the `qualified_last` key v_flakes patches in (tools/sort_derives.nix)
  rust-sorted-derives = {}: { program = crateTool "rust-sorted-derives" [ sortDerives ] "cargo-sort-derives sort-derives --check || { echo 'Derives are not sorted: cargo sort-derives fixes it'; exit 1; }"; };

  rust-unused-features = {}: {
    program = cargo "rust-unused-features" [ pkgs.cargo-unused-features pkgs.jq ] ''
      unused-features analyze
      unused-features build-report --output "$TMPDIR/report.json"
      [ "$(jq length "$TMPDIR/report.json")" = 0 ] || { echo "Found unused features:"; cat "$TMPDIR/report.json"; exit 1; }
    '';
  };

  rust-leptosfmt = {}: { program = crateTool "rust-leptosfmt" [ pkgs.leptosfmt ] "leptosfmt --check ."; };

  tokei = {}: {
    program = program "tokei" [ pkgs.tokei pkgs.jq ] ''
      cd "$(git rev-parse --show-toplevel)"
      read -r comments code < <(tokei -o json | jq -er '.Rust | "\(.comments) \(.code)"' || { echo "tokei measures Rust comments, and this repo has no Rust" >&2; exit 1; })
      if [ $((comments * 100)) -ge $((code * 15)) ]; then
        echo "Rust comments are $comments lines to $code of code: they should be under 15%"
        exit 1
      fi
    '';
  };

  # `excludePatterns`: qlty globs of files whose likeness is by nature (a translation of another, say)
  code-duplication = { excludePatterns ? [ ] }: {
    program = program "code-duplication" [ qlty scriptRust ] ''
      cd "$(git rev-parse --show-toplevel)"
      rm -f .qlty/qlty.toml # `qlty init` keeps an existing one: CI's, from scratch, is what runs
      qlty init --no --no-upgrade-check >/dev/null
      ${lib.optionalString (excludePatterns != [ ]) ''
        grep -qx 'exclude_patterns = \[' .qlty/qlty.toml
        sed -i 's|^exclude_patterns = \[$|&${lib.concatMapStrings (p: "\\n  ${builtins.toJSON p},") excludePatterns}|' .qlty/qlty.toml
      ''}
      RUSTC_WRAPPER="" cargo -Zscript -q ${../workflows/code-duplication.rs}
    '';
  };

  go-tests = {}: { program = program "go-tests" [ pkgs.go ] "go test -race ./..."; ci = import (parts + "/go/tests.nix"); };
  go-gocritic = {}: { program = program "go-gocritic" [ pkgs.go ] "go run github.com/go-critic/go-critic/cmd/gocritic@latest check ."; ci = import (parts + "/go/gocritic.nix"); };
  go-security-audit = {}: { program = program "go-security-audit" [ pkgs.govulncheck ] "govulncheck ./..."; ci = import (parts + "/go/security_audit.nix"); };

  py-tests = {}: { program = program "py-tests" [ pkgs.uv ] "uv run pytest"; ci = import (parts + "/py/tests.nix"); };
}
