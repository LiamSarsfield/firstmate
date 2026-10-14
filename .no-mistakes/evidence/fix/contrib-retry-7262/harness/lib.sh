ROOT=/home/liam/.no-mistakes/worktrees/9460a12c9cc4/01M4XSG3YVEPWAM49S2E62AD07
EVID=/home/liam/.no-mistakes/evidence/01M4XSG3YVEPWAM49S2E62AD07
SCR=/tmp/fm-contrib-live.uAFxiu
PROXY_PID=

start_proxy() { # workdir rules-json-text
  mkdir -p "$1"; printf '%s\n' "$2" > "$1/rules.json"; rm -f "$1/port"
  python3 -I "$SCR/fault-proxy.py" "$1" "$1/rules.json" & PROXY_PID=$!
  for _ in $(seq 50); do [ -s "$1/port" ] && break; sleep 0.1; done
  PROXY_URL="http://127.0.0.1:$(cat "$1/port")"; BUNDLE="$1/bundle.pem"
}
stop_proxy() { [ -z "$PROXY_PID" ] || { kill "$PROXY_PID" 2>/dev/null; wait "$PROXY_PID" 2>/dev/null; }; PROXY_PID=; }

new_lab() { # name url
  local lab
  lab=$(mktemp -d "$SCR/home.$1.XXXXXX")
  "$ROOT/bin/fm-lab-home.sh" create "$lab" >/dev/null || return 1
  printf '# Backlog\n\n## Queued\n- [ ] delivery - Contribution delivery %s (repo: sample) (kind: ship)\n' "$2" > "$lab/data/backlog.md"
  printf '%s\n' "$lab"
}

# Run a command as the watcher would see the poll: plain FM_HOME lab, no
# inherited overrides, real gh (through the log-only passthrough).
lab_run() { # lab call-log [extra env...] -- command...
  local lab=$1 log=$2; shift 2
  local -a extra=()
  while [ "$1" != -- ]; do extra+=("$1"); shift; done; shift
  ( cd "$ROOT" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_CONTRIBUTIONS_NOW \
      PATH="$SCR/bin:$PATH" GH_CALL_LOG="$log" FM_HOME="$lab" TMUX_TMPDIR="$lab/tmux" "${extra[@]}" "$@" )
}

PR=https://github.com/kunchenguid/firstmate/pull/7299
CORE='start: api repos/kunchenguid/firstmate/pulls/7299'
CLOSING='start: pr view https://github.com/kunchenguid/firstmate/pull/7299 --json headRefOid,reviewDecision'

lab_from_baseline() { # name
  local base lab
  base=$(cat "$SCR/baseline.path")
  lab=$(mktemp -d "$SCR/home.$1.XXXXXX")
  "$ROOT/bin/fm-lab-home.sh" create "$lab" >/dev/null || return 1
  cp -a "$base/data/." "$lab/data/"; cp -a "$base/state/." "$lab/state/"
  printf '%s\n' "$lab"
}

# scenario name mode(direct|shim) rules-json lab [env...]
# Writes $EVID/<name>.txt and prints a one-line summary.
scenario() {
  local name=$1 mode=$2 rules=$3 lab=$4; shift 4
  local w="$SCR/p-$name" log="$SCR/$name.calls" f="$EVID/$name.txt" out rc q0 q1 before
  : > "$log"
  start_proxy "$w" "$rules"
  local -a envs=(HTTPS_PROXY="$PROXY_URL" SSL_CERT_FILE="$BUNDLE" "$@")
  q0=$(wc -l < "$lab/state/.wake-queue" 2>/dev/null || echo 0)
  before=$(jq -c '.records[0] | {checked_at,error}' "$lab/data/delivery/contributions.json" 2>/dev/null || echo none)
  local t0=$(date +%s)
  if [ "$mode" = shim ]; then
    [ -f "$lab/state/contributions.check.sh" ] || lab_run "$lab" "$log" -- bin/fm-contributions.sh arm >/dev/null
    # Mirror fm-watch.sh run_check: bounded at FM_CHECK_TIMEOUT, stderr discarded.
    out=$(lab_run "$lab" "$log" "${envs[@]}" -- timeout 30 bash "$lab/state/contributions.check.sh" 2>/dev/null); rc=$?
  else
    out=$(lab_run "$lab" "$log" "${envs[@]}" -- bin/fm-contributions.sh poll); rc=$?
  fi
  local t1=$(date +%s)
  stop_proxy
  q1=$(wc -l < "$lab/state/.wake-queue" 2>/dev/null || echo 0)
  {
    printf '# scenario: %s\nmode: %s (%s)\nfault rules (CONNECT number -> injected response): %s\nextra env: %s\n' \
      "$name" "$mode" "$([ "$mode" = shim ] && echo 'armed state/contributions.check.sh, timeout 30, stderr to /dev/null like fm-watch.sh run_check' || echo 'bin/fm-contributions.sh poll')" \
      "$rules" "$(printf '%s ' "$@" | sed 's/GH_TOKEN=[^ ]*/GH_TOKEN=<invalid-literal>/')"
    printf 'record before: %s\n' "$before"
    printf '\n## poll exit=%s elapsed=%ss\n## poll stdout (what the watcher surfaces as a wake):\n%s\n' "$rc" "$((t1-t0))" "${out:-<empty>}"
    printf '\n## record after:\n'; jq '.records[0] | {url,checked_at,error,head:.observation.head,state:.observation.state}' "$lab/data/delivery/contributions.json" 2>/dev/null || echo '<no record>'
    printf '\n## wake-queue entries added: %s\n' "$((q1-q0))"
    [ "$q1" -le "$q0" ] || tail -n "$((q1-q0))" "$lab/state/.wake-queue"
    printf '\n## real gh invocations (argv, exit status, stderr) via log-only passthrough:\n'; sed 's/ --paginate --slurp//' "$log"
    printf '\n## proxy connections:\n'; cat "$w/proxy.log" 2>/dev/null || echo '<proxy unused>'
    printf '\n## grep -r SENTINEL lab home: '; grep -rl SENTINEL "$lab" 2>/dev/null || echo 'no match'
  } > "$f"
  printf '%s: rc=%s stdout=[%s] core=%s closing=%s error=%s wakes+%s\n' "$name" "$rc" "$out" \
    "$(grep -cFx "$CORE" "$log")" "$(grep -cFx "$CLOSING" "$log")" \
    "$(jq -c '.records[0].error' "$lab/data/delivery/contributions.json" 2>/dev/null)" "$((q1-q0))"
}

J500='{"status":500,"reason":"Internal Server Error","body":"{\"message\":\"Internal Server Error SENTINEL_X\"}"}'
H502='{"status":502,"reason":"Bad Gateway","content_type":"text/html","body":"<html><body><h1>502 Bad Gateway SENTINEL_X</h1></body></html>"}'
E503='{"status":503,"reason":"Service Unavailable","body":"{}"}'
R429='{"status":429,"reason":"Too Many Requests","body":"{\"message\":\"API rate limit exceeded SENTINEL_X\"}"}'
S403='{"status":403,"reason":"Forbidden","body":"{\"message\":\"You have exceeded a secondary rate limit. Please wait a few minutes before you try again. SENTINEL_X\",\"documentation_url\":\"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api#about-secondary-rate-limits\"}"}'
P403='{"status":403,"reason":"Forbidden","body":"{\"message\":\"Resource not accessible by integration SENTINEL_X\"}"}'
HANG='{"hang":true}'
