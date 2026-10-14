# Live validation: retry transient contribution forge reads once (issue #7262)

## Setup

- Lab home: a marked lab home made by `bin/fm-lab-home.sh create` (FM_HOME), with a private TMUX_TMPDIR. TMUX and NO_MISTAKES_GATE were unset.
- Owned contributions: real public objects, read-only.
  - PR https://github.com/kunchenguid/firstmate/pull/7302 (backlog row `delivery`)
  - Issue https://github.com/kunchenguid/firstmate/issues/7262 (backlog row `filed`)
- Product under test: the branch-head `bin/fm-contributions.sh poll`, run on its own and through the real watcher, `bin/fm-watch-checkpoint.sh` with the check registered by `fm-contributions.sh arm`.
- gh: the real binary (gh 2.100.0) with the machine's existing keyring login. A pass-through shim on PATH logged each call, then ran the real gh unchanged.
- Fault injection: `harness-fault-proxy.py`, a local HTTPS proxy reached through HTTPS_PROXY. Its scratch CA was trusted only through SSL_CERT_FILE in the poll's environment. It forwards each request to the real api.github.com, unless a rule injects an HTTP status, a TCP reset or a hang for a matching path. gh therefore prints its real error text for each fault.
- Baseline: base commit 24f3a6b8 (`git archive` of `bin/`) run against the same lab and the same injection.
- The PR scenarios (S*, W*) each started from the same primed PR snapshot: one clean observation, `error: null`, and an empty wake queue.
  E1 restored that snapshot once and then ran three polls in a row on purpose.
  I1/I2 used a separate primed snapshot of issue #7262. Its two existing signals (one maintainer comment, one ready-for-pr label) were acknowledged and its wake queue emptied first.
- What this branch changes: one retry within the 5 s read bound for transient failures, and the transient/permanent classification.
  The failing read's first error line already reached the wake line and the record at the base commit (see S2-base, W1-base).
  This branch keeps that text through the retry.
- The proxy log shows gh never retries a request internally, so "retry once" is exactly 2 HTTP requests.

## Files

| File | Scenarios |
|---|---|
| 01-transient-500-before-after.txt | S1 happy path. S2 one HTTP 500: branch retries and stays quiet. S2-base: the base commit wakes. |
| 02-persistent-5xx-and-graphql-closing-read.txt | S3 persistent 500. S4a–d: GraphQL closing read (`gh pr view`) with 502/503 and empty, HTML or JSON bodies. |
| 03-http-status-classes-core-read.txt | S5 404, S6 401 and S7 plain 403 are not retried. S8/S9 secondary-rate-limit 403 and S10/S11 429 are retried once. |
| 04-network-dns-tls-errors.txt | S12/S13 TCP reset, S14 connection refused, S15 DNS failure, S16 TLS failure. All are retried once. |
| 05-timeouts-and-read-bound.txt | S17 hang: budget refusal, no retry, no wake. S18 500 then a hung retry: the 500 is kept, inside the 5 s read bound. |
| 06-watcher-checkpoint-wake.txt | W1 one 500: checkpoint quiet (exit 124). W2 persistent 500: wake with the read and gh's text. W1-base: the base commit wakes. |
| 07-failure-episode.txt | E1: persistent failure wakes once, a second failure poll is silent, and a healthy poll clears the error. |
| 08-issue-two-wave-reads.txt | I1 issue comments 502 once: recovered. I2 issue events 503 persistent: one wake, error kept. |
| harness-fault-proxy.py | The fault-injecting proxy used above. It logs no headers. |
