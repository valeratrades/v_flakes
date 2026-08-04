# cargo-sort-derives keys on the last `::` segment, so `derive_more::Deref` lands between
# `Debug` and `Eq`. The patch adds an opt-in `qualified_last` (`.sort-derives.toml` key or
# --qualified-last) that groups path-qualified derives after unqualified ones; without it
# the binary is byte-for-byte upstream's behavior, so unpatched CI still agrees.
# Drop once https://github.com/lusingander/cargo-sort-derives/issues/25 lands.
pkgs:
pkgs.cargo-sort-derives.overrideAttrs (o: {
  patches = (o.patches or [ ]) ++ [ ./sort_derives_qualified_last.patch ];
})
