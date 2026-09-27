{
  strategy.matrix = {
    go-version = [ "stable" "oldstable" ];
    os = [ "ubuntu-latest" "macos-latest" "windows-latest" ];
  };
  runs-on = "\${{ matrix.os }}";
  steps = [
    {
      uses = "actions/setup-go@v6";
      "with".go-version = "\${{ matrix.go-version }}";
    }
    { uses = "actions/checkout@v5"; }
    { run = "go test -race ./..."; }
  ];
}
