# One run of "$exclusive_name" at a time per repo, its worktrees included: runs side by side share the cores, and slow each
# other into timeouts. -f/--force kills the running one and takes its place; whoever waits on it waits on the new one.
exclusive_dir="${XDG_RUNTIME_DIR:-/tmp}/v_flakes-exclusive/$exclusive_name-$(git rev-parse --path-format=absolute --git-common-dir | sha256sum | cut -c1-12)"
exclusive_id="$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$exclusive_dir"
exclusive_force=
exclusive_args=()
for a in "$@"; do
  case "$a" in
  -f | --force) exclusive_force=1 ;;
  *) exclusive_args+=("$a") ;;
  esac
done
set -- "${exclusive_args[@]}"

exclusive_describe() {
  local id pid since cwd
  read -r id pid since cwd <"$exclusive_dir/$1" || return 1
  echo "run $id (pid $pid, since $since, in $cwd), its output in $exclusive_dir/$id.log"
}
exclusive_alive() {
  local id pid rest
  [ -e "$exclusive_dir/$1" ] && read -r id pid rest <"$exclusive_dir/$1" && kill -0 "$pid" 2>/dev/null
}
exclusive_field() {
  local id pid rest
  read -r id pid rest <"$exclusive_dir/$1" && echo "${!2}"
}
# the run's processes: its descendants in its session, not a server it started on its own (a stack outliving the run)
exclusive_kill() {
  local sid p
  sid="$(ps -o sid= -p "$1")" || return 0 # gone already
  exclusive_tree() {
    local c
    for c in $(ps -o pid= --ppid "$1"); do exclusive_tree "$c"; done
    echo "$1"
  }
  for p in $(exclusive_tree "$1"); do
    [ "$(ps -o sid= -p "$p")" != "$sid" ] || kill "-$2" "$p" 2>/dev/null || true # exited while the tree was walked
  done
}

exec 9>>"$exclusive_dir/lock"
if ! flock -n 9; then
  if [ -n "$exclusive_force" ]; then
    printf '%s %s %s %s\n' "$exclusive_id" "$$" "$(date +%T)" "$PWD" >"$exclusive_dir/next.$$"
    mv "$exclusive_dir/next.$$" "$exclusive_dir/next"
    victim="$(exclusive_field holder pid)" || { sleep 1 && victim="$(exclusive_field holder pid)"; } # the holder writes it just after it locks
    echo "$exclusive_name: -f: killing $(exclusive_describe holder)" >&2
    kill -TERM "$victim" 2>/dev/null || true # exited since it was read: the lock is free, or a waiter's
    flock -w 30 9 || {
      exclusive_kill "$victim" KILL
      flock 9
    }
  else
    echo "$exclusive_name: $(exclusive_describe holder) holds the lock; waiting for it. -f/--force kills it and runs this one" >&2
    waited="$(exclusive_field holder id)" || waited= # the holder writes it just after it locks
    while :; do
      if exclusive_alive next; then on=next; else
        flock -n 9 && break
        on=holder
      fi
      now="$(exclusive_field "$on" id)" || continue # replaced as it was read
      if [ "$now" != "$waited" ]; then
        echo "$exclusive_name: $waited was replaced; waiting on $(exclusive_describe "$on")" >&2
        waited="$now"
      fi
      sleep 1
    done
  fi
fi
printf '%s %s %s %s\n' "$exclusive_id" "$$" "$(date +%T)" "$PWD" >"$exclusive_dir/holder"
if [ -e "$exclusive_dir/next" ] && [ "$(exclusive_field next id)" = "$exclusive_id" ]; then rm "$exclusive_dir/next"; fi
find "$exclusive_dir" -name '*.log' -delete # a waiter tailing one keeps reading it
exec > >(tee "$exclusive_dir/$exclusive_id.log") 2>&1

# shellcheck disable=SC2329 # the trap's
exclusive_stop() {
  if exclusive_alive next; then echo "$exclusive_name: killed by the -f of $(exclusive_describe next)" >&2; fi
  exclusive_kill "$exclusive_child" TERM
  wait "$exclusive_child" || true # its status is the kill's
  exit 143
}
trap exclusive_stop TERM INT
