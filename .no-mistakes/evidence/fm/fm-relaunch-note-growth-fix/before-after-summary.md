# Live relaunch-note growth: base 45dd50a5 vs fix ae27c714

Both labs: a disposable FM_HOME (bin/fm-lab-home.sh), private tmux server, a real Codex CLI worker
(codex-cli 0.163.0, machine login, effort low), driven only through `bin/fm-control.sh <id> relaunch --note-file`.
The same 40,001-byte note files are used for relaunches 1-3 in both labs. The Linux per-argument limit
(MAX_ARG_STRLEN) is 131,072 bytes including the terminating NUL.

| relaunch | base brief.md | base encoded arg | base result | fix brief.md | fix encoded arg | fix result |
|---|---|---|---|---|---|---|
| 1 (40 KB note) | 50,322 | 51,823 | relaunched, codex alive | 50,755 | 52,305 | relaunched, codex alive |
| 2 (40 KB note) | 90,841 | 92,342 | relaunched, codex alive | 50,842 | 52,392 | relaunched, codex alive; note 1 -> progress-notes.md |
| 3 (40 KB note) | 131,360 | 132,861 | **old worker stopped; `bash: /usr/bin/env: Argument list too long`; endpoint dead; journal failed:launching** | 50,842 | 52,392 | relaunched, codex alive |
| 4-6 (40 KB notes) | - | - | - | 50,842 | 52,392 | all relaunched, codex alive |
| 7-18 (6 KB notes) | - | - | - | 16,842 | 18,392 | all relaunched, codex alive |

Fix lab after 18 relaunches (312,018 note bytes in total): every note 1-17 appears exactly once in
data/<id>/progress-notes.md and never in brief.md; note 18 is the only note in brief.md and launch-brief.md;
the first 10,147 bytes of brief.md (the original instructions, including a quoted `## Progress note` heading and an
unissued marker pair) are byte-identical to the pre-relaunch original; no hidden staged file remains.
Two relaunches refused on pending composer text (one before history existed, one after) left brief.md and
progress-notes.md byte-identical (absent history stayed absent); each retry then archived each note once.
fm-teardown.sh --force removed state/<id>.control-relaunch.note.history-prior and kept data/<id>/progress-notes.md.

The fix's brief.md grows by 87 bytes between relaunch 1 and 2 only because the one-line
`Earlier progress notes: <path>` link first appears once history exists; it is constant from then on for equal-sized notes.

Lab note: Codex showed its folder-trust prompt for the new lab project, and accepting it would have written
~/.codex/config.toml. The lab therefore put a `codex` shim first on PATH through a lab-only rcfile shell. The shim
runs the real ~/.local/bin/codex with the normal login and adds one per-invocation, unsaved
`-c projects={"<lab project>"={trust_level="trusted"}}` override. The ~/.codex/config.toml sha256 was the same before
and after. On base, the E2BIG came from /usr/bin/env, the first program the launch line `env -u ... codex ...` runs,
before the shim was reached.
