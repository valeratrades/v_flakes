# Gate job that evaluates a shell condition and outputs `run = true/false`.
# Downstream jobs declare `needs = ["gate"]` and `if = "needs.gate.outputs.run == 'true'"`.
#
# `condition` is a shell expression — if it evaluates to true (exit 0), the gate passes.
# Example: '"$(git show HEAD~1:Cargo.toml | grep '\''^version'\'' | head -1)" != "$(grep '\''^version'\'' Cargo.toml | head -1)"'
{ condition }:
{
  name = "gate";
  value = {
    runs-on = "ubuntu-latest";
    outputs.run = "\${{ steps.check.outputs.run }}";
    steps = [
      {
        uses = "actions/checkout@v4";
        "with".fetch-depth = 2;
      }
      {
        id = "check";
        run = ''
          if [ ${condition} ]; then
            echo "run=true" >> "$GITHUB_OUTPUT"
          else
            echo "run=false" >> "$GITHUB_OUTPUT"
          fi
        '';
      }
    ];
  };
}
