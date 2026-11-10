{ pkgs, syncArgs, cargoNightly, gitOpsScript }:
pkgs.writeShellScriptBin "git_ops" ''
  if [ "$1" = "sync-github" ]; then
    exec ${cargoNightly} -Zscript -q ${gitOpsScript} "$@" ${syncArgs}
  else
    exec ${cargoNightly} -Zscript -q ${gitOpsScript} "$@"
  fi
''
