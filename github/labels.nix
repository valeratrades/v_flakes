# Default GitHub repository labels
[
  # Type. `chore -> feature -> enhancement -> research` is one axis: how much of the end result is known when the issue is filed.
  { name = "t:feature"; color = "#2bd4a0"; description = "End result is known, the work to get there isn't small"; }
  { name = "t:enhancement"; color = "#a2eeef"; description = "A direction — the end shape is decided along the way"; }
  { name = "t:epic"; color = "#0b3d91"; description = "Large scope, delivered through sub-issues — too big for one `t:feature` / `t:enhancement`"; }
  { name = "t:bug"; color = "#d73a4a"; description = "Something isn't working"; }
  { name = "t:architectural"; color = "#5319e7"; description = "Refactor of code structure or functionality. Key distinction is refinement of existing structure."; }
  { name = "t:question"; color = "#d876e3"; description = "Deliverable is an answer, — a sort of `t:research` and `t:decision` combination"; }
  { name = "t:chore"; color = "#0052CC"; description = "Small, and fully specified — no decisions left. Also works as catch-all for small stuff."; }

  # Category
  { name = "c:ci"; color = "#808080"; description = "GHAs, flakes, tooling plugs"; }
  { name = "c:test"; color = "#0000ff"; description = "Testing, coverage, and test data"; }
  { name = "c:perf"; color = "#7a3274"; description = "Improve speed (runtime, comp-time, iteration)"; }
  { name = "c:docs"; color = "#0075ca"; description = "Improvements or additions to documentation"; }
  { name = "c:cq"; color = "#008672"; description = "Code quality"; } # was `c:rewrite` before, but that doesn't compose with all `Type`s

  #Q: there seems to be some overlap between `Category` and `Type` sections

  #DEPRECATE: insofar has been insanely confusing, - full switch towards `i:*`
  ## Severity of a bug; the `i:*` below is derived from it
  #{ name = "severity:low"; color = "#c9e6a0"; description = "Bug: cosmetic or easily worked around"; }
  #{ name = "severity:medium"; color = "#f8dcb0"; description = "Bug: degrades a feature"; }
  #{ name = "severity:high"; color = "#f5b2b3"; description = "Bug: data loss, or a feature is unusable"; }

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

  # Hours: done within N with 68% certainty (1σ). Fibonacci, like zenhub estimates.
  { name = "h:1"; color = "#c3dfed"; }
  { name = "h:2"; color = "#accee8"; }
  { name = "h:3"; color = "#94b8e3"; }
  { name = "h:5"; color = "#7b9edf"; }
  { name = "h:8"; color = "#617fdc"; }
  { name = "h:13"; color = "#475bd9"; }
  { name = "h:21"; color = "#2d32d7"; }
  { name = "h:34"; color = "#2e21c6"; }
  { name = "h:55"; color = "#361bb0"; }
  { name = "h:89"; color = "#3b1599"; }
  { name = "h:144"; color = "#3c1081"; }
  { name = "h:233"; color = "#3a0b69"; }

  # Extensions
  { name = "ext:breaking"; color = "#000000"; description = "Implementing should be postponed until next major version"; }
  { name = "ext:from_todo"; color = "#bfd4f2"; description = "Auto-generated from a TODO comment"; }
  { name = "ext:hack"; color = "#895129"; description = "Hacky feature"; }
  { name = "ext:good_first_issue"; color = "#7057ff"; description = "Good for newcomers"; }
  { name = "ext:help_wanted"; color = "#0e8a16"; description = "Extra attention is needed"; }
  { name = "ext:invalid"; color = "#e4e669"; description = "This doesn't seem right"; }
  (import ./workflows/nix-parts/shared/claude.nix).label
]
