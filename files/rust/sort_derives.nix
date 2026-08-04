{ pkgs, extend ? {} }:
let
  core = import ../../utils/core.nix;

  base = {
    # Upstream keys on the last `::` segment, so `derive_more::Deref` sorts as `Deref` and
    # scatters path-qualified derives through the alphabet — the opposite of why they get
    # written out in full. Requires rs/sort_derives.nix's build; upstream's silently
    # ignores the key (serde skips unknown fields), which is why pre_commit.nix guards it.
    qualified_last = true;
  };

  merged = core.mergeConfig base extend;
in
(pkgs.formats.toml { }).generate "" merged
