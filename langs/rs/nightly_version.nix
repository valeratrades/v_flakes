# The date half of the canonical nightly. Split out from default_nightly.nix so consumers
# that need the *name* rather than the derivation (CI matrices, DEFAULT_CARGO_NIGHTLY_VERSION
# in the NixOS config) derive it from the same pin instead of restating it.
# Same bump policy as default_nightly.nix.
"2026-06-29"
