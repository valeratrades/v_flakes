# Default GitHub repository labels
[
  # Type
  { name = "t:chore"; color = "#0052CC"; description = "Small non-imaginative task"; }
  { name = "t:enhancement"; color = "#a2eeef"; description = "New feature or request"; }
  { name = "t:bug"; color = "#d73a4a"; description = "Something isn't working"; }
  { name = "t:question"; color = "#d876e3"; description = "Further information is requested"; }

  # Category
  { name = "c:ci"; color = "#808080"; description = "GHAs, flakes, tooling plugs"; }
  { name = "c:test"; color = "#0000ff"; description = "Testing, coverage, and test data"; }
  { name = "c:perf"; color = "#7a3274"; description = "Improve speed (runtime, comp-time, iteration)"; }
  { name = "claude"; color = "#D97706"; description = "Hand this issue to Claude to implement"; }
  { name = "c:docs"; color = "#0075ca"; description = "Improvements or additions to documentation"; }
  { name = "c:rewrite"; color = "#008672"; description = "Code quality"; }

  # Extensions
  { name = "ext:breaking"; color = "#000000"; description = "Implementing should be postponed until next major version"; }
  { name = "ext:hack"; color = "#895129"; description = "Hacky feature"; }
  { name = "ext:good_first_issue"; color = "#7057ff"; description = "Good for newcomers"; }
  { name = "ext:help_wanted"; color = "#0e8a16"; description = "Extra attention is needed"; }
  { name = "ext:invalid"; color = "#e4e669"; description = "This doesn't seem right"; }
]
