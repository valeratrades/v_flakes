# Nix install + binary-cache steps for generated workflows that use the nix env.
# `cache` selects exactly one mechanism:
#   { nix-action = true; }  → nix-community/cache-nix-action — private GH-Actions cache,
#                             free, safe for private repos (default).
#   { cachix = "<name>"; }  → cachix/cachix-action — public/org cache; pushing needs the
#                             CACHIX_AUTH_TOKEN secret. Use only for PUBLIC repos: a public
#                             cache publishes every pushed path.
#
# installStep pins lazy-trees so generated CI agrees with the lazy-trees flake.lock a
# Determinate dev produces — otherwise private git inputs NAR-mismatch (the whole reason
# combine.determinate_nix exists).
{ cache ? { nix-action = true; } }:
let
  hasCachix = cache ? cachix;
  hasNixAction = (cache.nix-action or false) != false;
in
assert (hasCachix != hasNixAction) || throw
  "v_flakes cache: set exactly one of `cache.cachix = \"<name>\"` or `cache.nix-action = true`";
{
  installStep = {
    name = "Install Nix";
    uses = "DeterminateSystems/nix-installer-action@main";
    "with".extra-conf = "lazy-trees = true";
  };

  cacheStep =
    if hasCachix then {
      name = "Setup Cachix";
      uses = "cachix/cachix-action@v15";
      "with" = {
        name = cache.cachix;
        authToken = "\${{ secrets.CACHIX_AUTH_TOKEN }}";
      };
    } else {
      name = "Setup Nix cache";
      uses = "nix-community/cache-nix-action@v7";
      "with" = {
        primary-key = "nix-\${{ runner.os }}-\${{ hashFiles('**/flake.lock') }}";
        restore-prefixes-first-match = "nix-\${{ runner.os }}-";
      };
    };
}
