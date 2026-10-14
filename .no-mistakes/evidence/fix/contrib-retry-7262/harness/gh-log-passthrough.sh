#!/usr/bin/env bash
# Log-only passthrough to the real gh: records argv, exit status and stderr
# in $GH_CALL_LOG, then returns real gh's output and status unchanged.
log=${GH_CALL_LOG:?}
err=$(mktemp "${TMPDIR:-/tmp}/gh-err.XXXXXX")
printf 'start: %s\n' "$*" >> "$log"
rc=0
/home/liam/.local/bin/gh "$@" 2> "$err" || rc=$?
cat "$err" >&2
block=$(printf 'end: %s\nrc: %s\n' "$*" "$rc"; sed 's/^/stderr: /' "$err")
printf '%s\n' "$block" >> "$log"
rm -f "$err"
exit "$rc"
