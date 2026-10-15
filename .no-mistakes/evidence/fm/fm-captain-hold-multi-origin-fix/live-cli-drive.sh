#!/usr/bin/env bash
# Live drive of bin/fm-captain-hold.sh in disposable lab homes.
# Usage: drive.sh <worktree> <base-root>
set -u
WT=$1
BASE=$2
HEAD_CAP="$WT/bin/fm-captain-hold.sh"
BASE_CAP="$BASE/bin/fm-captain-hold.sh"

new_lab() {
  local lab
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  "$WT/bin/fm-lab-home.sh" create "$lab" >/dev/null || exit 1
  mkdir -p "$lab/tmux"
  cat > "$lab/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
EOF
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$lab/data/backlog.md"
  printf '%s\n' "$lab"
}

# A scout origin as the fleet leaves it when its report is written.
add_origin() {  # <lab> <id>
  local lab=$1 id=$2
  (cd "$lab" && tasks-axi add "$id" "Investigate $id" --kind scout --repo sample --start \
    --file data/backlog.md) >/dev/null || { echo "could not add $id"; exit 1; }
  mkdir -p "$lab/data/$id"
  printf '# %s report\n\nThe shared captain choice is open.\n' "$id" > "$lab/data/$id/report.md"
  printf 'kind=scout\nmode=scout\nharness=claude\nwindow=firstmate:fm-%s\n' "$id" > "$lab/state/$id.meta"
  printf 'done: report complete\n' > "$lab/state/$id.status"
}

cap() {  # <script> <lab> <args...>
  local script=$1 lab=$2 rc
  shift 2
  printf '\n$ fm-captain-hold.sh %s\n' "$*"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    TMUX_TMPDIR="$lab/tmux" FM_HOME="$lab" "$script" "$@" 2>&1
  rc=$?
  printf '[exit %s]\n' "$rc"
  return 0
}

show_meta() {  # <lab> <id>
  printf '\n$ grep decision state/%s.meta\n' "$2"
  grep '^decision' "$1/state/$2.meta" || echo '(no decision lines)'
}

section() { printf '\n==================== %s ====================\n' "$*"; }

LAB_BASE=$(new_lab)
LAB=$(new_lab)
trap 'rm -rf "$LAB_BASE" "$LAB"' EXIT

section "S1 BASE fc8972c: second origin cannot complete against the shared call (bug reproduction)"
for o in lane-a lane-b; do add_origin "$LAB_BASE" "$o"; done
cap "$BASE_CAP" "$LAB_BASE" hold shared-call --title "Choose shared behavior" \
  --reason "the same captain choice was found by both lanes" --repo sample --origin lane-a
cap "$BASE_CAP" "$LAB_BASE" complete lane-a shared-call
cap "$BASE_CAP" "$LAB_BASE" complete lane-b shared-call
cap "$BASE_CAP" "$LAB_BASE" complete lane-b --carried-by lane-a shared-call
cap "$BASE_CAP" "$LAB_BASE" verify lane-b

section "S9 COMPAT: single-origin record written by BASE is read by HEAD"
show_meta "$LAB_BASE" lane-a
cap "$HEAD_CAP" "$LAB_BASE" verify lane-a
cap "$BASE_CAP" "$LAB_BASE" hold later-call --title "A later call lane A found" \
  --reason "captain must decide" --repo sample --origin lane-a
cap "$HEAD_CAP" "$LAB_BASE" complete lane-a later-call
show_meta "$LAB_BASE" lane-a
cap "$HEAD_CAP" "$LAB_BASE" verify lane-a

section "SETUP HEAD $(git -C "$WT" rev-parse --short HEAD): three scout origins, lane-a holds the shared call"
for o in lane-a lane-b lane-c; do add_origin "$LAB" "$o"; done
cap "$HEAD_CAP" "$LAB" hold shared-call --title "Choose shared behavior" \
  --reason "the same captain choice was found by lanes a and b" --repo sample --origin lane-a
cap "$HEAD_CAP" "$LAB" complete lane-a shared-call

section "S2 HEAD: second origin without --carried-by is still refused, and pointed at the option"
cap "$HEAD_CAP" "$LAB" complete lane-b shared-call
show_meta "$LAB" lane-b

section "S3 HEAD: second origin completes with --carried-by against the one held task"
cap "$HEAD_CAP" "$LAB" complete lane-b --carried-by lane-a shared-call
show_meta "$LAB" lane-b
cap "$HEAD_CAP" "$LAB" open shared-call
printf '\n$ grep -c "Choose shared behavior" data/backlog.md   # rows for the shared call\n'
grep -c 'Choose shared behavior' "$LAB/data/backlog.md"
printf '\n$ tasks-axi show shared-call --full | grep -i origin\n'
(cd "$LAB" && tasks-axi show shared-call --full --file data/backlog.md) | grep -i 'origin' || echo '(no origin line)'

section "S4 HEAD: a later pass without the flag keeps the carrier; both origins verify"
cap "$HEAD_CAP" "$LAB" hold own-call --title "Call only lane B found" \
  --reason "captain must decide" --repo sample --origin lane-b
cap "$HEAD_CAP" "$LAB" complete lane-b own-call
show_meta "$LAB" lane-b
cap "$HEAD_CAP" "$LAB" verify lane-a
cap "$HEAD_CAP" "$LAB" verify lane-b
cap "$HEAD_CAP" "$LAB" open shared-call

section "S5 HEAD adversarial: a carrier the call was not held for is refused, nothing recorded"
cap "$HEAD_CAP" "$LAB" complete lane-c --carried-by lane-b shared-call
show_meta "$LAB" lane-c

section "S6 HEAD adversarial: malformed --carried-by uses are refused"
cap "$HEAD_CAP" "$LAB" complete lane-c --none --carried-by lane-a
cap "$HEAD_CAP" "$LAB" complete lane-c --carried-by lane-c shared-call
cap "$HEAD_CAP" "$LAB" complete lane-c --carried-by
cap "$HEAD_CAP" "$LAB" complete lane-c --carried-by lane-a
cap "$HEAD_CAP" "$LAB" complete lane-c --carried-by "../x" shared-call
show_meta "$LAB" lane-c

section "S7 HEAD: calls held by two owners need one complete per owner; inventory is the union"
cap "$HEAD_CAP" "$LAB" complete lane-c --carried-by lane-a shared-call own-call
show_meta "$LAB" lane-c
cap "$HEAD_CAP" "$LAB" complete lane-c --carried-by lane-a shared-call
cap "$HEAD_CAP" "$LAB" complete lane-c --carried-by lane-b own-call
show_meta "$LAB" lane-c
cap "$HEAD_CAP" "$LAB" verify lane-c

section "S8 HEAD adversarial: verify enforces the recorded carrier (carrier record removed)"
cp "$LAB/state/lane-b.meta" "$LAB/state/lane-b.meta.bak"
grep -v '^decision_carriers=' "$LAB/state/lane-b.meta.bak" > "$LAB/state/lane-b.meta"
show_meta "$LAB" lane-b
cap "$HEAD_CAP" "$LAB" verify lane-b
mv "$LAB/state/lane-b.meta.bak" "$LAB/state/lane-b.meta"
cap "$HEAD_CAP" "$LAB" verify lane-b

section "S10 HEAD compat: a hold with no recorded origin is still accepted and named"
cap "$HEAD_CAP" "$LAB" hold unowned-call --title "Call held without an origin" \
  --reason "captain must decide" --repo sample
cap "$HEAD_CAP" "$LAB" complete lane-c unowned-call
cap "$HEAD_CAP" "$LAB" verify lane-c

section "CLEANUP"
rm -rf "$LAB_BASE" "$LAB"
trap - EXIT
for d in "$LAB_BASE" "$LAB"; do [ -e "$d" ] && echo "still present: $d" || echo "removed lab home: $d"; done
