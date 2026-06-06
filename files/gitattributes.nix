{ pkgs, lfs ? null }:
let
  # All file extensions that should be handled by LFS
  lfsPatterns = {
    audio = [
      "*.mp3"
      "*.flac"
      "*.wav"
      "*.ogg"
      "*.m4a"
      "*.aac"
      "*.opus"
      "*.wma"
    ];
    images = [
      "*.jpg"
      "*.jpeg"
      "*.png"
      "*.gif"
      "*.bmp"
      "*.tiff"
      "*.webp"
      "*.svg"
    ];
    documents = [
      "*.pdf"
      "*.excalidraw"
    ];
    data = [
      "*.json"
      "*.csv"
      "*.parquet"
      "*.pkl"
      "*.npy"
      "*.npz"
      "*.db"
      "*.sqlite"
      "*.sqlite3"
      "*.onnx"
    ];
  };

  # Patterns we never want to manually merge: on conflict, keep the current
  # branch's version (the `ours` driver, registered in the devshell shellHook as
  # `git config merge.ours.driver true`). Feature branches merge into master, so
  # "ours" == the newer state in our workflow. Applies regardless of LFS.
  alwaysOurs = [ "*.pdf" "*.excalidraw" ];

  # Patterns that are ALWAYS LFS-tracked, even when the project sets lfs = false.
  # These are binary-ish, large, and never benefit from text diffs, so we pin
  # them to LFS regardless of the global flag (as if lfs = true for them alone).
  alwaysLfs = [ "*.pdf" "*.excalidraw" ];

  # Lockfiles get the same treatment, but are never LFS-tracked, so they're
  # emitted as a standalone section rather than folded into the LFS patterns.
  # .pre-commit-config.yaml is generated/managed, not hand-merged, so it rides
  # along here too.
  lockfiles = [ "Cargo.lock" "flake.lock" ".pre-commit-config.yaml" ];

  isOurs = pattern: builtins.elem pattern alwaysOurs;
  isAlwaysLfs = pattern: builtins.elem pattern alwaysLfs;

  # Generate a single line for a pattern
  # enable = true: add LFS tracking
  # enable = false: explicitly disable LFS tracking (just unset `filter`, keep
  #   git's auto-detection of text vs binary intact — preserves real diffs on
  #   json/csv/svg/excalidraw while still showing "Binary files differ" for
  #   actually-binary content like mp3/png/pdf)
  # `merge=ours` is appended (lfs=false) or substituted for `merge=lfs`
  # (lfs=true) on alwaysOurs patterns so a conflict never blocks a merge.
  # alwaysLfs patterns force enable, ignoring the flag entirely.
  mkLfsLine = enable: pattern:
    if (enable || isAlwaysLfs pattern)
    then
      (if isOurs pattern
      then "${pattern} filter=lfs diff=lfs merge=ours -text"
      else "${pattern} filter=lfs diff=lfs merge=lfs -text")
    else
      (if isOurs pattern
      then "${pattern} -filter merge=ours"
      else "${pattern} -filter");

  # Generate a section with a comment header
  mkSection = enable: name: patterns:
    let
      lines = map (mkLfsLine enable) patterns;
    in
    ''
      # ${name}
      ${builtins.concatStringsSep "\n" lines}
    '';

  # Lockfiles section — independent of LFS, only emitted when we touch the file
  # at all (i.e. lfs != null).
  lockSection =
    let
      lines = map (p: "${p} merge=ours") lockfiles;
    in
    ''
      # Generated/locked files (keep current branch's version on conflict)
      ${builtins.concatStringsSep "\n" lines}
    '';

  # Generate all LFS-related content
  mkLfsContent = enable:
    builtins.concatStringsSep "\n" [
      (mkSection enable "Audio formats" lfsPatterns.audio)
      (mkSection enable "Image formats" lfsPatterns.images)
      (mkSection enable "Documents" lfsPatterns.documents)
      (mkSection enable "Data" lfsPatterns.data)
      lockSection
    ];

  content =
    if lfs == true then mkLfsContent true
    else if lfs == false then mkLfsContent false
    else "";
in
pkgs.writeText "gitattributes" content
