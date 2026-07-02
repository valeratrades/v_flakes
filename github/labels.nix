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

  # Importance (0 = trivial, 9 = critical)
  { name = "i:0"; color = "#0e8a16"; }
  { name = "i:1"; color = "#3d9712"; }
  { name = "i:2"; color = "#6da40f"; }
  { name = "i:3"; color = "#9cb00b"; }
  { name = "i:4"; color = "#ccbd08"; }
  { name = "i:5"; color = "#fbca04"; }
  { name = "i:6"; color = "#ea9804"; }
  { name = "i:7"; color = "#d96604"; }
  { name = "i:8"; color = "#c73405"; }
  { name = "i:9"; color = "#b60205"; }

  # Extensions
  { name = "ext:breaking"; color = "#000000"; description = "Implementing should be postponed until next major version"; }
  { name = "ext:from_todo"; color = "#bfd4f2"; description = "Auto-generated from a TODO comment"; }
  { name = "ext:hack"; color = "#895129"; description = "Hacky feature"; }
  { name = "ext:good_first_issue"; color = "#7057ff"; description = "Good for newcomers"; }
  { name = "ext:help_wanted"; color = "#0e8a16"; description = "Extra attention is needed"; }
  { name = "ext:invalid"; color = "#e4e669"; description = "This doesn't seem right"; }
]
