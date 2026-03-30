{
  name = "Pytest";
  runs-on = "ubuntu-latest";
  timeout-minutes = 30;
  steps = [
    { uses = "actions/checkout@v4"; }
    {
      uses = "actions/setup-python@v5";
      "with".python-version = "3.x";
    }
    {
      name = "Install uv";
      uses = "astral-sh/setup-uv@v6";
    }
    {
      name = "Install dependencies";
      run = "uv sync --prerelease=allow --no-install-project --dev";
    }
    {
      name = "Run tests";
      run = "uv run pytest";
    }
  ];
}
