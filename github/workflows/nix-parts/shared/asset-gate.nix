# Fails CI when a committed generated asset no longer matches what its generator produces.
#
#   jobsOther = [ { name = "asset-gate"; args = { asset = "docs/x.svg"; command = "nix run .#film"; everySeconds = 86400; }; } ];
#
# `command` writes to the path in `$ASSET_OUT` (exported before it runs) — an app that takes the
# output path off an env var needs no argument threading here.
#
# `everySeconds = null` checks every run. A number guards the check behind a cache key bucketed on
# `now / everySeconds`: hit ⇒ the interval has already been paid for, skip. The bucket lives in the
# key rather than in the job body, so nothing here does clock arithmetic against a stored stamp; and
# Actions reads a branch's cache through to the default branch, which makes the interval one per
# repo rather than one per branch.
{ asset, command, everySeconds ? null, cache ? { nix-action = true; } }:
let
  nixCi = import ../../../cache.nix { inherit cache; };
  guarded = everySeconds != null;
  slug = builtins.replaceStrings [ "/" "." ] [ "-" "-" ] asset;
  stamp = ".asset-gate-stamp";
  key = "\${{ steps.bucket.outputs.key }}";
  unlessFresh = step: if guarded then step // { "if" = "steps.guard.outputs.cache-hit != 'true'"; } else step;
in
{
  name = "Asset gate";
  runs-on = "ubuntu-latest";
  # `command` is free to be a cargo invocation, and `.cargo/config.toml` points rustc-wrapper at an
  # sccache the runner doesn't have. Only Errors/Warnings inherit the rust base env, so unset here.
  env.RUSTC_WRAPPER = "";
  steps =
    [{
      name = "Checkout repository";
      uses = "actions/checkout@v4";
    }]
    ++ (if guarded then [
      {
        name = "Interval bucket";
        id = "bucket";
        run = ''echo "key=asset-gate-${slug}-$(( $(date -u +%s) / ${toString everySeconds} ))" >> $GITHUB_OUTPUT'';
      }
      {
        name = "Has this interval been checked";
        id = "guard";
        uses = "actions/cache/restore@v4";
        "with" = {
          path = stamp;
          inherit key;
        };
      }
    ] else [ ])
    ++ map unlessFresh (nixCi.setupSteps ++ [ nixCi.installStep nixCi.cacheStep ])
    ++ [
      (unlessFresh {
        name = "Regenerate ${asset} and compare";
        run = ''
          export ASSET_OUT="$(mktemp -d)/$(basename ${asset})"
          ${command}
          if ! cmp -s ${asset} "$ASSET_OUT"; then
            echo "::error file=${asset}::${asset} no longer matches its generator — regenerate and commit it: ${command}"
            exit 1
          fi
          echo "${asset} is current"
          : > ${stamp}
        '';
      })
    ]
    ++ (if guarded then [{
      name = "Record this interval as checked";
      "if" = "steps.guard.outputs.cache-hit != 'true'";
      uses = "actions/cache/save@v4";
      "with" = {
        path = stamp;
        inherit key;
      };
    }] else [ ]);
}
