# Canonical Lean for every consumer. Bumping `tag` forks the toolchain for the whole fleet: minor v_flakes bump.
{ lean4-nix }:
let
  tag = "v4.35.0";
in
{
  # consumer's `lean-toolchain` content, so elan/lake agree with the nix-provided lean
  toolchain = "leanprover/lean4:${tag}";
  # binary fetch through lean4-nix's own path; its manifests lag behind releases
  overlay = final: prev: {
    lean = (final.callPackage "${lean4-nix}/lib/toolchain.nix" { }).fetchBinaryLean {
      inherit tag;
      toolchain = {
        x86_64-linux.hash = "sha256-colZekRUMkbJInuMrlAXZ+CVzhf21Ei5X8So3Jcmj20=";
        aarch64-linux.hash = "sha256-yPD4o5IOg5cYsTQ+Z4H9gKPpsQJPvNcHjrMPVOgGsCg=";
        x86_64-darwin.hash = "sha256-C0O+XH7Ps2AWVmpBAFq2K9sEdD5r/Vg35F95bvR1C04=";
        aarch64-darwin.hash = "sha256-wMbzTzW6HcxcSl/RBv76uetehGlxJiTdLIaNUbYxd8I=";
      };
    };
  };
}
