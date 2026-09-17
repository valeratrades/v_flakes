# Claude Code PR assistant — responds to `@claude` mentions in issues, PR comments and reviews,
# and to the `claude` label on issues (bots can't be assignees, so labeling stands in for assignment).
# The label is seeded by github/labels.nix (synced on dev-shell entry).
# Generic across repos: no repo-specific values. Requires the CLAUDE_CODE_OAUTH_TOKEN secret.
# Share it across a whole org by setting it as an *organization* secret with "All repositories"
# visibility. Caveat: on the Free plan org secrets reach public repos only — private repos need
# a repo-level copy (or a Team/Enterprise org). Personal accounts have no org secrets at all.
let utils = import ../../../../utils;
in {
  standalone = true;

  name = "Claude Code";
  on = {
    issue_comment = { types = [ "created" ]; };
    pull_request_review_comment = { types = [ "created" ]; };
    issues = { types = [ "opened" "labeled" ]; };
    pull_request_review = { types = [ "submitted" ]; };
  };
  jobs = {
    claude = {
      "if" = "(github.event_name == 'issue_comment' && contains(github.event.comment.body, '@claude')) || (github.event_name == 'pull_request_review_comment' && contains(github.event.comment.body, '@claude')) || (github.event_name == 'pull_request_review' && contains(github.event.review.body, '@claude')) || (github.event_name == 'issues' && (contains(github.event.issue.body, '@claude') || contains(github.event.issue.title, '@claude') || github.event.label.name == 'claude'))";
      runs-on = "ubuntu-latest";
      permissions = {
        contents = "read";
        pull-requests = "read";
        issues = "read";
        id-token = "write";
        actions = "read"; # so Claude can read CI results on PRs
      };
      steps = [
        (utils.requireSecret { name = "CLAUDE_CODE_OAUTH_TOKEN"; })
        {
          name = "Checkout repository";
          uses = "actions/checkout@v4";
          "with" = { fetch-depth = 1; };
        }
        {
          name = "Run Claude Code";
          id = "claude";
          uses = "anthropics/claude-code-action@v1";
          "with" = {
            claude_code_oauth_token = "\${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}";
            label_trigger = "claude";
            additional_permissions = "actions: read\n";
            # The action defaults to `--permission-mode acceptEdits` plus a narrow --allowedTools
            # list, and headless has no prompt handler, so everything else (Bash, WebFetch,
            # WebSearch) is silently denied mid-run. bypassPermissions is appended after the
            # action's own args, and last --permission-mode wins.
            # The app token exported as GH_TOKEN has PR write, hence the `gh pr create` nudge.
            claude_args = ''--permission-mode bypassPermissions --append-system-prompt "Whenever you push commits to a branch, always finish by opening a pull request against the default branch with gh pr create (check gh pr list --head <branch> first; if one already exists, pushing was enough)."'';
          };
        }
      ];
    };
  };
}
