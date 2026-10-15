#!/usr/bin/env bash
# Live non-forced scout teardown in disposable lab homes, base vs head.
# Usage: teardown-drive.sh <worktree> <base-root>
set -u
WT=$1
BASE=$2

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

add_origin() {  # <lab> <id>
  local lab=$1 id=$2
  (cd "$lab" && tasks-axi add "$id" "Investigate $id" --kind scout --repo sample --start \
    --file data/backlog.md) >/dev/null || { echo "could not add $id"; exit 1; }
  mkdir -p "$lab/data/$id"
  printf '# %s report\n\nThe shared captain choice is open.\n' "$id" > "$lab/data/$id/report.md"
  printf '%s\n' "window=firstmate:fm-$id" "worktree=$lab/projects/missing-$id" \
    "project=$lab/projects/sample" harness=claude kind=scout mode=scout "spawn_gen=lab-$id" \
    > "$lab/state/$id.meta"
  printf 'done: report complete\n' > "$lab/state/$id.status"
  labtmux "$lab" new-window -d -t firstmate -n "fm-$id"
}

labenv() {  # <lab> <cmd...>
  local lab=$1
  shift
  env -u TMUX -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    TMUX_TMPDIR="$lab/tmux" FM_PROCEVENT_CLAIM_ROOT="$lab/procevent-claims" FM_HOME="$lab" "$@"
}

labtmux() { local lab=$1; shift; labenv "$lab" tmux "$@"; }

run() {  # <lab> <label> <cmd...>
  local lab=$1 label=$2 rc
  shift 2
  printf '\n$ %s\n' "$label"
  labenv "$lab" "$@" 2>&1
  rc=$?
  printf '[exit %s]\n' "$rc"
}

state() {  # <lab>
  printf '\n$ tmux list-windows -t firstmate   # lab-private socket\n'
  labtmux "$1" list-windows -t firstmate -F '#{window_name}'
  printf '\n$ cat data/backlog.md\n'
  cat "$1/data/backlog.md"
}

section() { printf '\n==================== %s ====================\n' "$*"; }

drive() {  # <root> <label> <use-carried-by>
  local root=$1 label=$2 carried=$3 lab
  lab=$(new_lab)
  LABS="$LABS $lab"
  labtmux "$lab" new-session -d -s firstmate -n keep
  section "$label: lab $lab"
  for o in lane-a lane-b; do add_origin "$lab" "$o"; done
  run "$lab" "fm-captain-hold.sh hold shared-call --origin lane-a ..." \
    "$root/bin/fm-captain-hold.sh" hold shared-call --title "Choose shared behavior" \
    --reason "the same captain choice was found by both lanes" --repo sample --origin lane-a
  run "$lab" "fm-captain-hold.sh complete lane-a shared-call" "$root/bin/fm-captain-hold.sh" complete lane-a shared-call
  if [ "$carried" = 1 ]; then
    run "$lab" "fm-captain-hold.sh complete lane-b --carried-by lane-a shared-call" \
      "$root/bin/fm-captain-hold.sh" complete lane-b --carried-by lane-a shared-call
  else
    run "$lab" "fm-captain-hold.sh complete lane-b shared-call" "$root/bin/fm-captain-hold.sh" complete lane-b shared-call
  fi
  run "$lab" "fm-teardown.sh lane-a" "$root/bin/fm-teardown.sh" lane-a
  run "$lab" "fm-teardown.sh lane-b" "$root/bin/fm-teardown.sh" lane-b
  run "$lab" "fm-captain-hold.sh open shared-call" "$root/bin/fm-captain-hold.sh" open shared-call
  state "$lab"
  labtmux "$lab" kill-server
}

LABS=''
trap 'for l in $LABS; do labtmux "$l" kill-server 2>/dev/null; rm -rf "$l"; done' EXIT
drive "$BASE" "BASE fc8972c: second scout cannot pass the teardown gate" 0
drive "$WT" "HEAD $(git -C "$WT" rev-parse --short HEAD): second scout completes with --carried-by and tears down" 1

section CLEANUP
for l in $LABS; do labtmux "$l" kill-server 2>/dev/null; rm -rf "$l"; [ -e "$l" ] && echo "still present: $l" || echo "removed lab home: $l"; done
trap - EXIT
