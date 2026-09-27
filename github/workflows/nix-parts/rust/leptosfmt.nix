{
  name = "leptosfmt";
  runs-on = "ubuntu-latest";
  steps = [
    { uses = "actions/checkout@v5"; }
    { uses = "LesnyRumcajs/leptosfmt-action@v0.1.0"; }
  ];
}
