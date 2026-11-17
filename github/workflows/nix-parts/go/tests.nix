{
  timedIf = "matrix.go-version == 'stable' && matrix.os == 'ubuntu-latest'"; # the run a local one compares with
  job = {
    strategy.matrix = {
      go-version = [ "stable" "oldstable" ];
      os = [ "ubuntu-latest" "macos-latest" "windows-latest" ];
    };
    runs-on = "\${{ matrix.os }}";
    defaults.run.shell = "bash"; # the timing steps are bash on windows too
    steps = [
      {
        uses = "actions/setup-go@v6";
        "with".go-version = "\${{ matrix.go-version }}";
      }
      { uses = "actions/checkout@v5"; }
    ];
  };
  work = [{ run = "go test -race ./..."; }];
}
