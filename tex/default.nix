{
  pkgs ? null,
  nixpkgs ? null,
}:
if nixpkgs != null && pkgs == null then {
  description = ''
LaTeX project configuration module.

Usage:
```nix
tex = v-utils.tex {
  inherit pkgs;
};
```

Then use in devShell:
```nix
devShells.default = pkgs.mkShell {
  shellHook = tex.shellHook;
  packages = [ ... ] ++ tex.enabledPackages;
};
```
'';
} else

{
  shellHook = "";
  enabledPackages = [];
}
