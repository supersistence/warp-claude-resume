# warp-claude-resume

Per-pane Claude Code session resume for Warp. Two shell scripts; no build step.

Several decisions in the scripts look simplifiable and aren't — reverting them
reintroduces bugs that were found by executing the code, not by reading it.
Each one has a comment in the source explaining why, and usually a regression
test. Read the comment before changing the code.

## Layout

| File | Role |
|---|---|
| `record-session.sh` | Claude Code `SessionStart` hook. POSIX sh. Writes a pane→session record. |
| `warp-claude.zsh` | Sourced from `.zshrc`. Registers a one-shot `precmd` hook that offers to resume. |
| `test.sh` | Regression suite. 90 checks. Run after every edit. |
| `README.md` | User-facing docs |
| `LICENSE` | MIT |

## Working on this

```sh
bash test.sh        # must be 90/90 (89 + 1 skip when run as root) before and after any change
```

The suite runs in a temp directory with a stubbed `claude` and touches nothing
in `$HOME`. Several tests exist because of a specific bug that was live at some
point — if one starts failing, read the comment above it before "fixing" the test.

## Non-obvious constraints

- `record-session.sh` must stay **POSIX sh** — Claude Code runs hook commands
  through `sh -c`, and `/bin/sh` is dash on many systems. `set -o pipefail` is
  not available. No `[[`, no `local`, no arrays.
- `warp-claude.zsh` runs inside the user's interactive shell. It must be silent
  and side-effect-free unless a record for the current pane exists.
- Untrusted data (`cwd` from the hook payload, anything in a record file, and
  anything read from a Claude Code transcript) must never reach `print -P`,
  `eval`, or an unquoted command line.
- `_warp_claude_details` reads transcripts via python3, which strips all
  Unicode control/format characters. It must stay best-effort: any failure
  prints nothing and never blocks the prompt.

## Status

Verified on macOS (Aug 24 2026): 43/43 on zsh 5.9 / Darwin 25, and a real
end-to-end Warp restart resumed the right session, with both prompt and
`WARP_CLAUDE_AUTO=1` modes.

Sep 25 2026: added session details under the prompt (`WARP_CLAUDE_DETAILS`).
Suite 83/83 + 1 root skip on zsh 5.9 / Linux, and 84/84 on macOS (zsh 5.9 /
Darwin 27). A real Warp restart on macOS showed the details lines and resumed
the right session. No open items.

Sep 28 2026: resumed panes were restoring at `~` (file explorer and new panes
too). Warp registers its `precmd` hook after `.zshrc`, so ours runs first and
Warp never heard the directory while claude was running. Fixed by emitting
OSC 7 after the `cd`; confirmed against Warp's snapshot db on live panes.
Suite 86/86 on macOS. Not yet confirmed across a full Warp restart.

Oct 29 2026: compact re-recorded a drifted cwd (Bash `cd` carries over, and
SessionStart has no matcher), re-keying a resumed session onto the wrong
project folder with empty memory. Hook now keeps the recorded cwd on
`source=compact`. Four tests added; 90/90 on macOS. Uncommitted.
