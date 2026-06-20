{ gistId ? "b48e6f02c61942200e7d1e3eeabf9bcb" }:
let utils = import ../../../../utils;
in {
  name = "Update LOC Badge";
  runs-on = "ubuntu-latest";
  steps = [
    {
      name = "Checkout repository";
      uses = "actions/checkout@v4";
    }
    (utils.requireSecret {
      name = "loc_gist_token";
      hint = [
        "Create a token, then: gh secret set loc_gist_token --repo <owner>/<repo> --body YOUR_TOKEN"
        "Bulk-provision all repos: https://github.com/valeratrades/nix/tree/e4338bf5943d7403b949a8e079f9073987d9cd68/home/scripts/shared_github_secrets.bash"
      ];
    })
    {
      name = "Install tokei";
      run = "cargo install tokei";
    }
    {
      name = "Count lines of code";
      id = "count";
      run = ''
        # Extract repository name (e.g., "valeratrades/readme-fw" -> "readme-fw")
        PNAME="''${GITHUB_REPOSITORY##*/}"
        echo "pname=$PNAME" >> $GITHUB_OUTPUT

        LOC=$(tokei --output json | jq '.Total.code')
        echo "loc=$LOC" >> $GITHUB_OUTPUT
        echo "Lines of code for $PNAME: $LOC"

        # Generate JSON with project-specific filename
        echo "{\"schemaVersion\": 1, \"label\": \"LoC\", \"message\": \"$LOC\", \"color\": \"lightblue\"}" > ''${PNAME}-loc.json
      '';
    }
    {
      name = "Display generated JSON";
      run = "cat \${{ steps.count.outputs.pname }}-loc.json";
    }
    {
      name = "Update gist";
      uses = "exuanbo/actions-deploy-gist@v1";
      "with" = {
        token = "\${{ secrets.loc_gist_token }}";
        gist_id = gistId;
        file_path = "\${{ steps.count.outputs.pname }}-loc.json";
      };
    }
  ];
}
