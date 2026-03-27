{ pkgs, extend ? {} }:
let
  core = import ../../utils/core.nix;

  base = {
    line-length = 210;
    indent-width = 2;
    fix = true;
    show-fixes = true;
    src = [ "src" "test" ];
    # not-in-test = false;
    # target-version = "py312";
    preview = true;
    # respect-gitignore = false;

    exclude = [
      ".bzr"
      ".direnv"
      ".eggs"
      ".env"
      ".git"
      ".git-rewrite"
      ".hg"
      ".idea"
      ".ipynb_checkpoints"
      ".mypy_cache"
      ".nox"
      ".pants.d"
      ".pyenv"
      ".pytest_cache"
      ".pytype"
      ".ruff_cache"
      ".svn"
      ".tox"
      ".venv"
      ".vscode"
      "__pypackages__"
      "_build"
      "buck-out"
      "build"
      "dist"
      "infra"
      "node_modules"
      "site-packages"
      "venv"
      "**/.venv/**"
      "**/migrations/**"
    ];

    format = {
      quote-style = "double";
      indent-style = "tab";
      docstring-code-format = true; # false
      skip-magic-trailing-comma = false;
    };

    lint.isort = {
      combine-as-imports = true;
      required-imports = [ "from __future__ import annotations" ];
      # force-single-line = true;
      # single-line-exclusions = ["typing"];
      # lines-after-imports = 2;
    };

    lint = {
      # Allow fix for all enabled rules (when `--fix`) is provided.
      fixable = [ "ALL" ];
      unfixable = [ ];
      dummy-variable-rgx = "^(_+|(_+[a-zA-Z0-9_]*[a-zA-Z0-9]+?))$";
      task-tags = [
        "TODO"
        "FIXME"
        "Q"
        "BUG"
        "NB"
        "XXX"
        "NOTE"
        "DEPRECATE"
        "TEST"
        "HACK"
      ];

       select = [
         "C4"   # flake8-comprehensions
         "E"    # pycodestyle errors
         "F"    # pyflakes
         "W"    # pycodestyle warnings
         "C90"  # mccabe complexity
         "D"    # pydocstyle
         # "DTZ"  # flake8-datetimez
         "UP"   # pyupgrade
         "S"    # flake8-bandit (security)
         "T10"  # flake8-debugger
         "ICN"  # flake8-import-conventions
         "PIE"  # flake8-pie
         # "PT"   # flake8-pytest-style
         "PYI"  # flake8-pyi (stub files)
         "Q"    # flake8-quotes
         "I"    # isort
         "RSE"  # flake8-raise
         "TID"  # flake8-tidy-imports
         # "SIM"  # flake8-simplify
         # "ARG"  # flake8-unused-arguments
         # "ERA"  # eradicate (commented-out code)
         "PD"   # pandas-vet
         # "PGH"  # pygrep-hooks
         # "PLW"  # pylint warnings
         "NPY"  # numpy-specific rules
         "RUF"  # ruff-specific rules
       ];

      ignore = [
				"E111"  # Indentation is not a multiple of N — conflicts with tab indent-style
				"E114"  # Indentation is not a multiple of N (comment) — same
				"E117"  # Over-indented — same
				"E261"  # Two spaces before inline comment
				"E262"  # Inline comment should start with '# '
				"E265"  # Block comment should start with '# '
				"E401"  # Multiline imports
        "D100"  # Missing docstring in public module
        "D104"  # Missing docstring in public package
        "D105"  # Missing docstring in magic method
        # keep checking if D210 (blank line after docstring) ever gets added to ruff. Currently they're bikeshedding to infinity, but worth keeping an eye on.
        "D202"  # No blank lines allowed after function docstring (we want them)
        "D206" # conflicts with ruff formatter
        "D401"  # Relax NumPy docstring convention: First line should be in imperative mood
        "E262"  # no-space-after-inline-comment
        "E401"  # (duplicate)
        "E501" # Line length regulated by formatter
        "E703"  # don't complain about semicolons
        "E713"  # Test for membership should be `not in`
        "E714"  # `${value} is not` instead of `not ${value} is`
        "E722"  # Do not use bare `except`
        "E741"  # Ambiguous var name (I'm a Golang man)
        "F403"  # Undefined names from star imports
        "F405"  # Warns when using anything from star imports
        "PT011" # pytest.raises too broad
        "RUF005" # unpack-instead-of-concatenating-to-collection-literal
        "SIM102" # Use single `if` instead of nested
        "SIM108" # Use ternary operator
        "TD002" # Missing author in TODO
        "TD003" # Missing issue link after TODO
        "TRY003" # Avoid long messages outside exception class
        "W191" # conflicts with ruff formatter
        "C408"  # Unnecessary `dict()` call — {} and dict() are identical bytecode, pure bikeshed
        "S311"  # `random` not suitable for crypto — if we needed crypto we wouldn't be writing python
        # "C901"  # Too complex
        # "D101"  # Missing docstring in public class
        # "D102"  # Missing docstring in public method
        # "D103"  # Missing docstring in public function
        # "D107"  # Missing docstring in `__init__`
        # "D200"  # One-line docstring should fit on one line
        # "D203"  # 1 blank line required before class docstring
        # "D205"  # 1 blank line required between summary and description
        # "D212"  # Multi-line docstring summary should start at first line
        # "D400"  # First line should end with a period
        # "D413"  # Missing blank line after last section
        # "D415"  # First line should end with period/question/exclamation
        # "D416"  # Section name should end with a colon
        # "PD011" # Use `.to_numpy()` instead of `.values`
        # "PD901" # `df` is a bad variable name
        # "RUF006" # Store a reference to the return value of `asyncio.create_task`
        # "RUF012" # Mutable class attributes should be annotated with `typing.ClassVar`
        # "S101"  # Use of assert detected
        # "S105"  # Possible hardcoded password
        # "S106"  # Possible hardcoded password
        # "S113"  # Probable use of requests call without timeout
        # "S603"  # `subprocess` call: check for execution of untrusted input
      ];
    };

    lint.per-file-ignores."tests/**/*.py" = [
      "D100"    # Missing docstring in public module
      "D103"    # Missing docstring in public function
      "B018"    # Useless expression (flake8-bugbear)
      "FBT001"  # Boolean positional argument (flake8-boolean-trap)
      "S101"    # Use of `assert` detected
      "RUF003"  # Ambiguous unicode character in comment
      "B011"    # Do not `assert False` (flake8-bugbear)
      "PLR2004" # Magic value used in comparison
    ];

    lint.per-file-ignores."**/migrations/**/*.py" = [
      "D103"  # Missing docstring in public function
      "D400"  # First line should end with a period
      "D415"  # First line should end with period/question/exclamation
    ];

    lint.pydocstyle.convention = "numpy";
  };

  merged = core.mergeConfig base extend;
in
(pkgs.formats.toml { }).generate "ruff.toml" merged
