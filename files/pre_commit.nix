{ pkgs
, lib ? pkgs.lib
, # Drop the `Co-Authored-By: Claude` / `Generated with Claude Code` trailer from
  # every commit message. Off by default — opt in per repo.
  stripClaudeSignature ? false
, # `{ root; allow ? [ ]; }`: raster images under `root` must be webp (svg passes too). `allow`
  # holds repo-relative paths whose consumers need another format (a `/`-suffixed entry
  # covers a directory). Off when null.
  webAssets ? null
,
}:
assert webAssets == null || lib.subtractLists [ "allow" ] (builtins.attrNames webAssets) == [ "root" ]
  || throw "v_flakes files.preCommit: webAssets is { root; allow ? [ ]; }, got ${builtins.toJSON webAssets}";
{
  src = ./.;
  hooks = {
    strip-claude-signature = {
      enable = stripClaudeSignature;
      name = "strip Claude Code signature";
      entry = lib.getExe (import ./strip_claude_signature.nix { inherit pkgs; });
      stages = [ "commit-msg" ];
    };
    # A package built on default_nightly makes every builder (CI, the hosts, image builds)
    # fetch the devShell's docs and rust-analyzer.
    rust-build-toolchain = {
      enable = true;
      name = "packages build on rs.build_nightly";
      files = "^flake\\.nix$";
      pass_filenames = false;
      entry = lib.getExe (pkgs.writeShellApplication {
        name = "rust-build-toolchain";
        text = ''
          if grep -q makeRustPlatform flake.nix && ! grep -q build_nightly flake.nix; then
            echo "flake.nix builds with makeRustPlatform on the dev toolchain. Give it the build one:" >&2
            echo "  build_rust = v_flakes.rs.build_nightly system;" >&2
            echo "  rustPlatform = pkgs.makeRustPlatform { rustc = build_rust; cargo = build_rust; ... };" >&2
            echo "(keep v_flakes.rs.default_nightly for the devShell)" >&2
            exit 1
          fi
        '';
      });
    };
    # next/image and friends decode the source on every cache miss, so a 2MB png costs on each one.
    web-assets-webp = {
      enable = webAssets != null;
      name = "raster images are webp";
      files = lib.optionalString (webAssets != null)
        "(?i)^${lib.escapeRegex (lib.removeSuffix "/" webAssets.root)}/.*\\.(png|jpe?g|gif|bmp|tiff?|avif|ico|heic)$";
      excludes = map (p: "^${lib.escapeRegex p}${lib.optionalString (!lib.hasSuffix "/" p) "$"}") (webAssets.allow or [ ]);
      entry = lib.getExe (pkgs.writeShellApplication {
        name = "web-assets-webp";
        text = ''
          printf 'not webp: %s\n' "$@" >&2
          echo "convert (cwebp -q 90 photo, cwebp -lossless screenshot), or list it in webAssets.allow" >&2
          exit 1
        '';
      });
    };
    treefmt = {
      enable = true;
      # Override entry to re-stage files after formatting.
      # This prevents pre-commit from detecting file changes and re-running hooks.
      entry = lib.mkForce "bash -c 'treefmt --no-cache \"$@\" && git add -u' --";
      # Must be serial since `git add -u` needs exclusive access to the index lock
      require_serial = true;
      settings = {
        fail-on-change = false; # GHA's job, pre-commit hooks strictly *do*
        formatters = with pkgs; [
          nixpkgs-fmt
        ];
      };
    };
  };
}
