# The particles v_flakes ships, by the name a `jobs.<section>` list gives them. Each is
# `args: { program; ci ? null; }`; `ci` is a CI body for what the local program can't do there
# (a toolchain matrix, pre_ci's path-dep rewriting, rust-cache): `{ job; work; post ? [ ]; timedIf ? null; }`.
{ pkgs, rust, rs, runtimeInputs, cargoRoot, webUnstable, lastSupportedVersion, gistId }:
let
  lib = pkgs.lib;
  system = pkgs.stdenv.hostPlatform.system;
  parts = ../workflows/nix-parts;

  program = name: inputs: text: pkgs.writeShellApplication {
    inherit name text;
    runtimeInputs = inputs ++ runtimeInputs ++ [ pkgs.git ];
  };
  # every rust particle runs in the cargo root, with the shell's toolchain and wrapper
  cargo = name: inputs: text: assert rs != null || throw "v_flakes.github: `${name}` needs the `rs` module";
    program name ([ rust ] ++ rs.enabledPackages ++ inputs) ''
      cd "$(git rev-parse --show-toplevel)/${cargoRoot}"
      ${text}
    '';
  # job-level, not workflow-level: the shared jobs alongside need the repo root
  inCargoRoot = job:
    if cargoRoot == "." then job
    else lib.recursiveUpdate job { defaults.run.working-directory = cargoRoot; };
  # the jobs that `rm` `.cargo/config.toml`; the rest read the cfg from it
  withWebCfg = job:
    if webUnstable then lib.recursiveUpdate job { env.RUSTFLAGS = "--cfg web_sys_unstable_apis"; }
    else job;
  rustCi = { web ? false }: ci: ci // { job = inCargoRoot (if web then withWebCfg ci.job else ci.job); };

  machete = (import ../../langs/rs).machete system;
  sortDerives = (import ../../langs/rs).sort_derives system;
  qlty = import ../../tools/qlty.nix system;
  scriptRust = (import ../../langs/rs).default_nightly system; # v_flakes' own scripts', whatever toolchain the repo has
in
{
  rust-tests = { skipPatterns ? [ ] }:
    let skipArgs = lib.optionalString (skipPatterns != [ ]) (" -- " + lib.concatMapStringsSep " " (p: "--skip ${p}") skipPatterns); in
    {
      program = cargo "rust-tests" [ ] "cargo test --workspace${skipArgs}";
      ci = rustCi { } (import (parts + "/rust/tests.nix") { inherit lastSupportedVersion gistId skipArgs; });
    };

  rust-doc = { package ? null }:
    let
      # `cargo docs-rs` refuses to guess a member, and errors on one with no lib target, which a workspace's binary crate is
      cargoDocsCmd =
        if package != null then "cargo docs-rs -p ${package}"
        else ''
          for p in $(cargo metadata --no-deps --format-version 1 | jq -r '.packages[] | select([.targets[].kind[]] | any(. == "lib" or . == "proc-macro")) | .name'); do
            cargo docs-rs -p "$p"
          done
        '';
    in
    {
      # cargo-docs-rs isn't in nixpkgs: `cargo doc` with the warnings denied, which docs.rs' flags don't change
      program = cargo "rust-doc" [ ] ''RUSTDOCFLAGS=-Dwarnings cargo doc --no-deps ${if package != null then "-p ${package}" else "--workspace"}'';
      ci = rustCi { web = true; } (import (parts + "/rust/doc.nix") { inherit cargoDocsCmd; });
    };

  rust-clippy = {}:
    let cmd = "cargo clippy --workspace --all-targets -- -Dwarnings"; in
    {
      program = cargo "rust-clippy" [ ] cmd;
      ci = rustCi { web = true; } (import (parts + "/rust/clippy.nix") { inherit cmd; });
    };

  rust-miri = {}:
    let cmd = "cargo miri test --lib --bins"; in    # `--lib --bins` is what's needed in 99% of cases
    {
      program = cargo "rust-miri" [ ] "MIRIFLAGS=-Zmiri-strict-provenance ${cmd}";
      ci = rustCi { } (import (parts + "/rust/miri.nix") { inherit cmd; });
    };

  # Not upstream's build: it can't see an orphan in `[workspace.dependencies]` (tools/machete.nix)
  rust-machete = {}: { program = cargo "rust-machete" [ machete ] "cargo-machete"; };

  rust-sorted = {}: { program = cargo "rust-sorted" [ pkgs.cargo-sort ] "cargo sort --workspace --grouped --check || { echo 'Cargo.toml is not sorted: cargo sort -w fixes it'; exit 1; }"; };

  # Not upstream's build: it ignores the `qualified_last` key v_flakes patches in (tools/sort_derives.nix)
  rust-sorted-derives = {}: { program = cargo "rust-sorted-derives" [ sortDerives ] "cargo sort-derives --check || { echo 'Derives are not sorted: cargo sort-derives fixes it'; exit 1; }"; };

  rust-unused-features = {}: {
    program = cargo "rust-unused-features" [ pkgs.cargo-unused-features pkgs.jq ] ''
      unused-features analyze
      unused-features build-report --output "$TMPDIR/report.json"
      [ "$(jq length "$TMPDIR/report.json")" = 0 ] || { echo "Found unused features:"; cat "$TMPDIR/report.json"; exit 1; }
    '';
  };

  rust-leptosfmt = {}: { program = cargo "rust-leptosfmt" [ pkgs.leptosfmt ] "leptosfmt --check ."; };

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

  code-duplication = {}: {
    program = program "code-duplication" [ qlty scriptRust ] ''
      cd "$(git rev-parse --show-toplevel)"
      qlty init --no --no-upgrade-check >/dev/null
      RUSTC_WRAPPER= cargo -Zscript -q ${../workflows/code-duplication.rs}
    '';
  };

  go-tests = {}: { program = program "go-tests" [ pkgs.go ] "go test -race ./..."; ci = import (parts + "/go/tests.nix"); };
  go-gocritic = {}: { program = program "go-gocritic" [ pkgs.go ] "go run github.com/go-critic/go-critic/cmd/gocritic@latest check ."; ci = import (parts + "/go/gocritic.nix"); };
  go-security-audit = {}: { program = program "go-security-audit" [ pkgs.govulncheck ] "govulncheck ./..."; ci = import (parts + "/go/security_audit.nix"); };

  py-tests = {}: { program = program "py-tests" [ pkgs.uv ] "uv run pytest"; ci = import (parts + "/py/tests.nix"); };
}
