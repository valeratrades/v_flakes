{ pkgs
, lib ? pkgs.lib
, # Drop the `Co-Authored-By: Claude` / `Generated with Claude Code` trailer from
  # every commit message. Off by default — opt in per repo.
  stripClaudeSignature ? false
,
}: {
  src = ./.;
  hooks = {
    strip-claude-signature = {
      enable = stripClaudeSignature;
      name = "strip Claude Code signature";
      entry = lib.getExe (import ./strip_claude_signature.nix { inherit pkgs; });
      stages = [ "commit-msg" ];
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
