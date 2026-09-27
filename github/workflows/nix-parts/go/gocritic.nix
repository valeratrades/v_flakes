{
  runs-on = "ubuntu-latest";
  steps = [
    { uses = "actions/setup-go@v6"; }
    { uses = "actions/checkout@v5"; }
    {
      run = ''
        go install github.com/go-critic/go-critic/cmd/gocritic@latest
        gocritic check .
      '';
    }
  ];
}
