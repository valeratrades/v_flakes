# `nix run .#test`: the repo's particles. $spec is their table, each program and prepare a .drv built only once selected.
usage() {
	cat <<EOF
nix run .#test [-- [--severity errors|warnings] [--serial] [name…]]
  every particle (or those named), in parallel; exits non-zero iff an error particle fails
  --severity <s>  only that section's; then any failure exits non-zero (as CI runs it)
  --serial        one at a time, so no particle's time is inflated by another's (CI)
particles:
$(jq -r '.[] | "  \(.severity)\t\(.name)"' "$spec")
EOF
}

severity='' serial='' names=()
while (($#)); do
	case $1 in
	--severity)
		[[ ${2:-} == errors || ${2:-} == warnings ]] || { echo "--severity takes errors or warnings, got '${2:-}'" >&2; exit 2; }
		severity=$2
		shift 2
		;;
	--serial) serial=1 && shift ;;
	-h | --help) usage && exit 0 ;;
	-*) { echo "unknown flag $1"; usage; } >&2 && exit 2 ;;
	*) names+=("$1") && shift ;;
	esac
done

unknown=$(jq -r '[.[].name] as $all | $ARGS.positional - $all | .[]' "$spec" --args "${names[@]}")
[ -z "$unknown" ] || { echo "no such particle: $unknown" >&2; usage >&2; exit 2; }
selected=$(jq -c --arg sev "$severity" '[.[] | select(($ARGS.positional == [] or (.name | IN($ARGS.positional[]))) and ($sev == "" or .severity == $sev))]' "$spec" --args "${names[@]}")
off=$(jq -r --arg sev "$severity" '.[] | select(.name | IN($ARGS.positional[])) | select(.severity != $sev) | .name' "$spec" --args "${names[@]}")
[ -z "$severity" ] || [ -z "$off" ] || { echo "not $severity particles: $off" >&2; exit 2; }
[ "$(jq length <<<"$selected")" -gt 0 ] || { echo "no particle selected" >&2; exit 2; }

cd "$(git rev-parse --show-toplevel)"
logs=$(mktemp -d "${TMPDIR:-/tmp}/particles.XXXXXX")

mapfile -t drvs < <(jq -r '[.[] | .program, .prepare | select(. != null)] | unique[]' <<<"$selected")
# --keep-going: a particle that doesn't build fails alone, below
nix build --no-link --keep-going "${drvs[@]/%/^out}" || true
out() { [ -e "$(nix-store --query --outputs "$1")" ] && nix-store --query --outputs "$1"; }

declare -A status secs prepared
fail() { status[$1]=failed && printf '%s\n' "$2" >>"$logs/$1.log" && echo "✗ $1"; }

mapfile -t prepares < <(jq -r '[.[] | select(.prepare != null) | .prepare] | unique[]' <<<"$selected")
mapfile -t prepareBins < <(jq -r '[.[] | select(.prepare != null) | {prepare, prepareBin}] | unique_by(.prepare)[] | .prepareBin' <<<"$selected")
for i in "${!prepares[@]}"; do
	drv=${prepares[$i]}
	if ! p=$(out "$drv"); then
		prepared[$drv]="did not build: $drv"
	elif ! "$p/${prepareBins[$i]}" >"$logs/prepare-$i.log" 2>&1 </dev/null; then
		prepared[$drv]="its prepare failed: $logs/prepare-$i.log"$'\n'"$(<"$logs/prepare-$i.log")"
	fi
done

run_one() {
	local s=$EPOCHREALTIME rc=0
	"$2" >>"$logs/$1.log" 2>&1 </dev/null || rc=$?
	printf '%s %s %s\n' "$rc" "$s" "$EPOCHREALTIME" >"$logs/$1.stat"
}
us() { local t=${1//[.,]/}; echo $((10#$t)); }
finish() {
	local rc s e mark
	read -r rc s e <"$logs/$1.stat"
	secs[$1]=$(($(us "$e") - $(us "$s")))
	if [ "$rc" = 0 ]; then status[$1]=ok mark=✓; else status[$1]=failed mark=✗; fi
	printf '%s %s %d.%ds\n' "$mark" "$1" $((secs[$1] / 1000000)) $((secs[$1] / 100000 % 10))
}

declare -A pids
mapfile -t order < <(jq -r '.[].name' <<<"$selected")
while IFS=$'\t' read -r name program prepare bin; do
	secs[$name]=0
	if [ "$prepare" != null ] && [ -n "${prepared[$prepare]:-}" ]; then
		fail "$name" "${prepared[$prepare]}"
	elif ! p=$(out "$program"); then
		fail "$name" "did not build: $program (its build log is above)"
	elif [ -n "$serial" ]; then
		run_one "$name" "$p/$bin"
		finish "$name"
	else
		run_one "$name" "$p/$bin" &
		pids[$!]=$name
	fi
done < <(jq -r '.[] | [.name, .program, (.prepare // "null"), .bin] | @tsv' <<<"$selected")
while ((${#pids[@]})); do
	wait -n -p finished
	finish "${pids[$finished]}"
	unset "pids[$finished]"
done

width=$(printf '%s\n' "${order[@]}" | wc -L)
failed=0 failed_errors=0
echo
for name in "${order[@]}"; do
	sev=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .severity' <<<"$selected")
	printf '%-*s  %-8s  %-6s  %d.%ds\n' "$width" "$name" "$sev" "${status[$name]}" $((secs[$name] / 1000000)) $((secs[$name] / 100000 % 10))
	if [ "${status[$name]}" = failed ]; then
		failed=$((failed + 1))
		[ "$sev" != errors ] || failed_errors=$((failed_errors + 1))
	fi
done
for name in "${order[@]}"; do
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		echo "::group::$name (${status[$name]})"
		cat "$logs/$name.log"
		echo "::endgroup::"
		[ "${status[$name]}" = ok ] || echo "::error::$name failed"
	elif [ "${status[$name]}" = failed ]; then
		printf '\n━━ %s ━━\n' "$name"
		cat "$logs/$name.log"
	fi
done
echo "logs: $logs"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	for name in "${order[@]}"; do
		echo "${name}_seconds=$((secs[$name] / 1000000))"
		echo "${name}_status=${status[$name]}"
	done >>"$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		echo "| particle | severity | status | seconds |"
		echo "|---|---|---|---|"
		for name in "${order[@]}"; do
			echo "| $name | $(jq -r --arg n "$name" '.[] | select(.name == $n) | .severity' <<<"$selected") | ${status[$name]} | $((secs[$name] / 1000000)) |"
		done
	} >>"$GITHUB_STEP_SUMMARY"
fi

if [ -n "$severity" ]; then
	[ "$failed" = 0 ]
else
	[ "$failed_errors" = 0 ]
fi
