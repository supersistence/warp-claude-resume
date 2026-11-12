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
| `warp-claude.bash` | bash port of the zsh side, for Warp on Windows with Git Bash. Same knobs. |
| `test-bash.sh` | Suite for the Windows/Git Bash port (hook path handling, bash side, AUTO stagger, Warp lifecycle, reaper wiring, orphan sweep). 90 checks. |
| `warp-claude-reap.ps1` | Windows: finds/kills process trees orphaned by an ungraceful Warp exit. |
| `test-reap.ps1` | Reaper suite against real synthetic orphan trees (incl. reaper running inside one). 19 checks. |
| `README.md` | User-facing docs |
| `LICENSE` | MIT |

## Working on this

```sh
bash test.sh        # must be 90/90 (89 + 1 skip when run as root) before and after any change
```

On Windows (Git Bash) instead:

```sh
bash test-bash.sh                                                   # 90/90
powershell -NoProfile -ExecutionPolicy Bypass -File test-reap.ps1   # 19/19
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

Nov 12 2026: Windows / Git Bash port. Hook now probes for a working python
(the Store `python3` stub exists but fails), forces LF output from Windows
python, and converts `C:\dev` cwd to `/c/dev` via cygpath. `warp-claude.bash`
registers in bash-preexec's `precmd_functions` (Warp's bash bootstrap is pasted
into the PTY, so nothing may read stdin during rc files). Warp's Git Bash
sources `~/.bash_profile`, not `~/.bashrc`. Pane UUID confirmed to survive a
Warp restart on Windows. `bash test-bash.sh` 48/48 on Git Bash 5.2 / Windows 11;
real `claude -p` SessionStart wrote a correct record. Not yet confirmed: a full
Warp restart resuming via the bash side, and whether Warp on Windows honours
OSC 7.

Nov 12 2026 (later): `WARP_CLAUDE_STAGGER` (default 3s) paces AUTO resumes when
many panes restore at once: each pane claims the next start slot from
`$STATE_DIR/.stagger-next` under a mkdir lock (stale >10s is broken; lock
failure starts immediately). Ctrl-C during the wait skips that pane; manual
`warp-claude-resume` never waits. 61/61.

Nov 12 2026 (later): first real Windows restart resumed every pane in the right
dir, but keystrokes went to Warp's input editor, not claude: launching from
precmd (before warp_precmd) meant Warp never saw Precmd/Preexec for it.
`_warp_claude_announce` now replays warp_precmd + a Preexec hook (Warp's own
bootstrap functions; no-op if absent) before any prompt or launch. Also
`remoteControlAtStartup` did not reconnect resumed sessions; user flags now
include `--remote-control`. 66/66. Not yet confirmed on a live restart.

Nov 12 2026 (later): typing fix confirmed on a live Windows restart. Found
that killing warp.exe leaves every pane's process tree running (bash, and any
claude.exe + MCP servers): a resumed session then had two live claudes on one
transcript, each with its own Remote Control bridge. `warp-claude-reap.ps1`
matches ~/.claude/sessions/<pid>.json (pid + procStart FILETIME, so PID reuse
never matches) and kills a tree only if it has no live warp.exe above it and is
rooted at Warp's `bash --noprofile --norc` with a dead parent. Run per-session
before each resume (`WARP_CLAUDE_REAP=1`, ~0.7s, skipped entirely unless a
session file names the id); `warp-claude-reap` sweeps all orphans on request.
77/77 + 13/13. Not yet confirmed on a live restart.

Nov 12 2026 (later): second live kill test: one claude per session, all under
the new Warp, none in orphan trees; 32 shell-only orphans left for
`warp-claude-reap` (by design). Launches were 16s then 1s apart: the reaper
(powershell startup) ran after the stagger wait. AUTO now reaps before the
wait. 78/78.

Nov 12 2026 (later): third kill test: launches 14:26:04/:06/:10 (pacing OK).
Each kill leaks one bash per pane and nothing else (OpenConsole and MCP node
die with Warp / claude). Added opt-in `WARP_CLAUDE_REAP_ORPHANS=1`: first
pane's first prompt sweeps all orphan trees in a detached background job, at
most once per 60s. Live run killed 63 leaked trees; 37 tab shells, 34
OpenConsole, 9 MCP node and 3 claudes untouched. 86/86. Note: shells inside a
resumed claude inherit WARP_CLAUDE_ACTIVE=1, so the hook (correctly) does
nothing there -- test from a real new tab, not from a claude Bash tool.

Nov 12 2026 (later): fourth kill test: sweep killed 18 of 34 orphans, then
itself. MSYS children inherit the parent's command line, so the sweep's own
double-forked launcher was a `bash --noprofile --norc` with a dead parent --
indistinguishable from an orphaned pane, and so would be any `( job & )` /
nohup job in a live tab. Orphan roots now also need their dead parent to be a
REMEMBERED warp.exe (pid + start FILETIME in ~/.warp-claude/warp-instances,
appended by every reaper run; a list-only run at each Warp start guarantees
each Warp is seen alive). The reaper excludes its own ancestry. `--loose` (manual
only) drops the warp check for pre-tracking leftovers. 90/90 + 19/19.
