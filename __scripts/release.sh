#!/usr/bin/env bash
set -euo pipefail

# Validate args
if [[ $# -ne 1 ]] || [[ "$1" != "--patch" && "$1" != "--minor" && "$1" != "--major" ]]; then
    echo "error: exactly one argument required: --patch, --minor, or --major" >&2
    exit 1
fi
flag="$1"

# Assert no uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: uncommitted changes detected, please commit or stash first" >&2
    exit 1
fi

# Resolve cnix_release via symlink in ./tmp
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cnix_release_link="$repo_root/tmp/cnix_release.rs"

if [[ ! -L "$cnix_release_link" ]] || [[ ! -e "$cnix_release_link" ]]; then
    echo "error: $cnix_release_link symlink not found or broken" >&2
    echo "note: cnix_release is a personal script (~/nix/home/scripts/cnix_release.rs) specific to this setup." >&2
    echo "note: if you are not the repo owner, you can perform the release steps manually." >&2
    exit 1
fi

# Check if ./src changed since the last tagged commit
last_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)

src_changed=false
if [[ -z "$last_tag" ]]; then
    # No tags yet — treat src as changed
    src_changed=true
elif git diff --quiet "$last_tag" HEAD -- src/; then
    src_changed=false
else
    src_changed=true
fi

if [[ "$src_changed" == "true" ]]; then
    cargo t
    cargo release --no-confirm --execute --no-tag --no-push "$flag"

    # cargo release made a version-bump commit; squash it into the commit before it
    git reset --soft HEAD~1
    git commit --amend --no-edit
fi

"$cnix_release_link" --ignore_cargo "$flag"
