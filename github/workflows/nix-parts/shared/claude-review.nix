# Automatic Claude code review on every PR open/update. Generic across repos.
# Requires the CLAUDE_CODE_OAUTH_TOKEN secret (see claude.nix for org-wide sharing).
let utils = import ../../../../utils;
in {
  standalone = true;

  name = "Claude Code Review";
  on = {
    pull_request = { types = [ "opened" "synchronize" "ready_for_review" "reopened" ]; };
  };
  jobs = {
    claude-review = {
      runs-on = "ubuntu-latest";
      permissions = {
        contents = "read";
        pull-requests = "read";
        issues = "read";
        id-token = "write";
      };
      steps = [
        (utils.requireSecret { name = "CLAUDE_CODE_OAUTH_TOKEN"; })
        {
          name = "Checkout repository";
          uses = "actions/checkout@v4";
          "with" = { fetch-depth = 1; };
        }
        {
          name = "Run Claude Code Review";
          id = "claude-review";
          uses = "anthropics/claude-code-action@v1";
          "with" = {
            claude_code_oauth_token = "\${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}";
            plugin_marketplaces = "https://github.com/anthropics/claude-code.git";
            plugins = "code-review@claude-code-plugins";
            prompt = "/code-review:code-review \${{ github.repository }}/pull/\${{ github.event.pull_request.number }} --comment\nWhen no issues are found, instead of the boilerplate no-issues body, post a short summary: what was checked (areas of the diff, classes of issues looked for) and why the changes are acceptable.";
          };
        }
      ];
    };
  };
}
