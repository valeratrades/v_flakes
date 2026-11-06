# Steps writing shields.io endpoint files `<repo>-<key>.json` into the badge gist, which readme_fw's badges read.
# `badges.<key> = { label; message; }`, `message` a bash expression.
{ gistId, badges, condition ? null }:
let utils = import ../../../../utils;
in map (step: if condition == null then step else step // { "if" = condition; }) [
  (utils.requireSecret {
    name = "loc_gist_token";
    hint = [
      "Create a token, then: gh secret set loc_gist_token --repo <owner>/<repo> --body YOUR_TOKEN"
      "Bulk-provision all repos: https://github.com/valeratrades/nix/tree/e4338bf5943d7403b949a8e079f9073987d9cd68/home/scripts/shared_github_secrets.bash"
    ];
  })
  {
    name = "Update badge gist";
    env.GH_TOKEN = "\${{ secrets.loc_gist_token }}";
    run = ''
      PNAME="''${GITHUB_REPOSITORY##*/}"
      gh api -X PATCH gists/${gistId} --silent \
    '' + builtins.concatStringsSep " \\\n" (builtins.attrValues (builtins.mapAttrs
      (key: { label, message }: ''  -f "files[$PNAME-${key}.json][content]={\"schemaVersion\": 1, \"label\": \"${label}\", \"message\": \"${message}\", \"color\": \"lightblue\"}"'')
      badges)) + "\n";
  }
]
