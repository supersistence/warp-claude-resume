# warp-claude-resume

**Warp restores your panes after a restart, but the Claude Code sessions running
in them are gone.** This brings each pane back to **its own** conversation — not
"the newest one in this directory". Two panes open on the same repo come back to
two different sessions.

Two shell scripts, no build step, no dependencies beyond zsh (`python3`,
if present, adds session titles to the prompt). Warp doesn't do this
natively; a PR that tried ([#14956](https://github.com/warpdotdev/warp/pull/14956))
was closed unmerged in Sep 2026. If Warp ships it, [uninstall](#uninstall)
this and use the built-in version.

## How it works

Warp exports `WARP_TERMINAL_SESSION_UUID` into every local pane's shell. A
**restored** pane comes back with the same value it had before the restart; a
**new** pane gets a fresh random one.

1. A Claude Code `SessionStart` hook records which session is running in which
   pane, in `~/.warp-claude/panes/<pane-uuid>`.
2. When a shell starts, a one-shot `precmd` hook looks for a record for *this*
   pane. A restored pane finds one and is offered `claude --resume <that
   session>`. A new pane, an SSH pane, or a non-Warp terminal finds nothing and
   the shell starts normally.

Because the record is written when a session *starts*, only sessions started
(or resumed) after install are tracked. Existing panes catch up the first time
you run `claude --resume` in them.

## Requirements

- **Warp** with *Restore windows, tabs, and panes on startup* enabled
- **zsh** (Warp's default on macOS), or **Git Bash on Windows** — see
  [Windows (Git Bash)](#windows-git-bash). fish is not supported.
- **Claude Code** with `SessionStart` hook support
- macOS, Linux, or Windows with Git Bash. WSL should work but is untested.
  Panes over SSH never resume.

## Install

```sh
git clone https://github.com/supersistence/warp-claude-resume
cd warp-claude-resume
claude
```

Then tell Claude Code:

> Read README.md and install this. Merge the hook into my existing
> `~/.claude/settings.json` without overwriting other keys, and if I have a
> `claude` alias with flags, mirror them in `WARP_CLAUDE_RESUME_FLAGS`.

That's the whole install. The steps it performs are below — read them if you
want to see exactly what touches your config, or to do it by hand.

### Manual steps

```sh
bash test.sh          # optional, ~30s, touches nothing in $HOME
mkdir -p ~/.warp-claude
cp record-session.sh warp-claude.zsh ~/.warp-claude/
chmod +x ~/.warp-claude/record-session.sh
```

Add the hook to `~/.claude/settings.json`, merging with any existing keys:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "$HOME/.warp-claude/record-session.sh" } ] }
    ]
  }
}
```

Add to `~/.zshrc`, after your prompt framework and `PATH` setup:

```sh
source ~/.warp-claude/warp-claude.zsh
```

Optional knobs go on the lines *above* the `source`. These are off by default;
uncomment deliberately — together they relaunch every restored pane with
permissions bypassed and no prompt:

```sh
# WARP_CLAUDE_RESUME_FLAGS=(--permission-mode bypassPermissions)  # mirror your usual claude flags
# WARP_CLAUDE_AUTO=1                                              # resume without asking
```

## Windows (Git Bash)

Warp on Windows exports the same `WARP_TERMINAL_SESSION_UUID`, and a restored
pane keeps it. `warp-claude.bash` is the bash port of the shell side; the hook
is shared.

```sh
bash test-bash.sh                                              # optional, touches nothing in $HOME
powershell -NoProfile -ExecutionPolicy Bypass -File test-reap.ps1   # optional
mkdir -p ~/.warp-claude
cp record-session.sh warp-claude.bash warp-claude-reap.ps1 ~/.warp-claude/
```

Hook entry in `~/.claude/settings.json` (Claude Code runs hooks through Git Bash):

```json
{ "hooks": { "SessionStart": [
  { "hooks": [ { "type": "command", "command": "bash \"$HOME/.warp-claude/record-session.sh\"" } ] }
] } }
```

Warp's Git Bash sources `~/.bash_profile`, not `~/.bashrc`. Make sure
`~/.bash_profile` contains `test -f ~/.bashrc && . ~/.bashrc`, then in `~/.bashrc`:

```sh
# WARP_CLAUDE_RESUME_FLAGS=(--dangerously-skip-permissions --remote-control)
# WARP_CLAUDE_AUTO=1
# WARP_CLAUDE_STAGGER=3
# WARP_CLAUDE_REAP_ORPHANS=1
source ~/.warp-claude/warp-claude.bash
```

Same knobs and commands as zsh, plus:

| Variable / command | Default | Meaning |
|---|---|---|
| `WARP_CLAUDE_STAGGER` | `3` | With `AUTO=1`, start restored panes this many seconds apart instead of all at once. `0` = no pacing. Ctrl-C during the wait skips that pane. |
| `WARP_CLAUDE_REAP` | `1` | Before resuming, kill an orphaned copy of the same session (see below). `0` = off. |
| `WARP_CLAUDE_REAP_ORPHANS` | `0` | `1` = when Warp starts, kill **every** orphaned Warp pane tree in the background (once per 60s across panes; report in `~/.warp-claude/reap.log`). Opt-in because it kills processes this tool didn't start. |
| `warp-claude-reap` | | List every orphaned Warp pane process tree and offer to kill them (`-y` = no prompt; `--loose` = also leftovers of Warps that ran before this was installed — review that list first). |

Windows-specific behaviour worth knowing:

- **Ungraceful Warp exits leak processes.** If `warp.exe` crashes or is ended
  from Task Manager, Windows does not kill the processes in its panes: every
  pane's `bash` (and any `claude.exe` with its MCP servers) keeps running with no
  terminal. A leaked `claude` still owns its session, so after a restart the
  resumed copy and the orphan would both write the same transcript and both
  appear in Remote Control. Before each resume, `warp-claude-reap.ps1` looks the
  session up in Claude Code's `~/.claude/sessions/<pid>.json`, checks the PID's
  start time (so a reused PID never matches), and kills that tree only if it is
  rooted at Warp's `bash --noprofile --norc` **and that bash's dead parent was a
  `warp.exe`**. Windows can't name a dead process, so the reaper remembers every
  live Warp it sees (PID + start time, `~/.warp-claude/warp-instances`); a
  background run at each Warp start makes sure every Warp gets remembered. The
  parent check matters: MSYS2 children show their parent's command line, so a
  job you backgrounded in a live tab (`( job & )`, `nohup`) also looks like an
  orphaned `bash --noprofile --norc` — but its dead parent was a bash. The
  reaper also never touches the tree it is itself running in. A copy open in a
  live pane, VS Code or another terminal is never touched. Leaked
  shells with no claude (one ~24 MB `bash` per pane, per ungraceful exit) are
  left for `warp-claude-reap`, or swept on every Warp start with
  `WARP_CLAUDE_REAP_ORPHANS=1`. `OpenConsole.exe` and claude's MCP `node`
  processes did not leak in testing.
- **Typing into a resumed claude.** The resume runs from bash-preexec's
  `precmd`, before Warp's own hook, so Warp never learned a command had started
  and kept keystrokes in its input editor. The bash side now replays Warp's
  `warp_precmd` and a `Preexec` hook first. These are Warp's own bootstrap
  functions; if a future Warp renames them, that step is skipped and you can
  type via the rich-input toggle.
- **Remote Control** (`remoteControlAtStartup`) did not reconnect resumed
  sessions in testing; put `--remote-control` in `WARP_CLAUDE_RESUME_FLAGS`.
- `python3` may be the Microsoft Store stub. Both scripts probe for an
  interpreter that actually runs and fall back to `python`.

## Using it

Open Claude in a pane as usual. After a Warp restart, the restored pane shows:

```
claude 8f0b1c2d  ~/src/my_app  bypassPermissions
  Refactor auth middleware  2d ago · 3.1 MB · 41 prompts
  last: can you add a test for the expired-token path
resume? [Y/n]
```

Enter resumes. The mode at the end appears only if you set
`WARP_CLAUDE_RESUME_FLAGS`.

The indented lines are read from Claude Code's own transcript for that
session, so you can tell panes apart: the title (your `/rename`, else Claude's
generated summary, else your first message), when the session was last active,
the transcript's size, how many messages you typed, and the last one. Slash
commands, tool output and system messages are skipped. The transcript is
treated as untrusted text: control characters, terminal escapes and bidi
overrides are stripped before anything is printed. Needs `python3` for the
title and messages; without it only the age and size are shown. If there's no
transcript (deleted, or older than `cleanupPeriodDays`) the lines are simply
omitted. Set `WARP_CLAUDE_DETAILS=0` to turn them off.

With `WARP_CLAUDE_AUTO=1` there is no prompt. If there's no terminal to prompt
on, it prints a one-line notice and does nothing.

Shell commands:

| Command | Does |
|---|---|
| `warp-claude-resume` | resume this pane now, ignoring the age limit (still prompts unless `AUTO=1`) |
| `warp-claude-list` | show every recorded pane → session |
| `warp-claude-forget` | drop this pane's record, stop offering |

Variables, set in `.zshrc` before the `source` line:

| Variable | Default | Meaning |
|---|---|---|
| `WARP_CLAUDE_RESUME_FLAGS` | `()` | zsh **array** of flags passed on every resume. A plain string is rejected with a warning and ignored. |
| `WARP_CLAUDE_AUTO` | `0` | `1` = resume without asking |
| `WARP_CLAUDE_MAX_AGE` | `604800` | seconds. Don't offer if Claude last started or resumed in this pane longer ago than this (7 days). Resuming refreshes it. |
| `WARP_CLAUDE_DISABLE` | `0` | `1` = off |
| `WARP_CLAUDE_DETAILS` | `1` | `0` = don't show the session's title, age and last message under the prompt |
| `WARP_CLAUDE_TRANSCRIPT_DIR` | `${CLAUDE_CONFIG_DIR:-~/.claude}/projects` | where to find Claude Code transcripts for those details |
| `WARP_CLAUDE_STATE_DIR` | `~/.warp-claude/panes` | where records are kept (never pruned) |

**Permission mode.** Claude never restores `bypassPermissions` or `plan` when
resuming — a session in either comes back in the default permission mode. If
you always launch with a flag (e.g. `alias cc='claude --permission-mode
bypassPermissions'`), put it in `WARP_CLAUDE_RESUME_FLAGS` so restored panes
match. Your aliases are deliberately bypassed: the resume resolves the `claude`
binary on `PATH` and calls it by absolute path, so an alias can't add flags the
prompt didn't show you.

`WARP_CLAUDE_MAX_AGE` only controls *offering*. Claude Code itself deletes
transcripts after `cleanupPeriodDays` (default 30) — raise that in
`~/.claude/settings.json` if you want sessions to live longer, and keep
`WARP_CLAUDE_MAX_AGE` at or below it.

## Caveats

- `WARP_TERMINAL_SESSION_UUID` is exported on purpose for external tools
  ([warp#11130](https://github.com/warpdotdev/warp/pull/11130), May 2026) but
  isn't on docs.warp.dev yet. If Warp renames or drops it, panes simply stop
  being offered a resume; nothing errors.
- Only panes restored from Warp's snapshot keep their UUID. Panes from a Tab
  Config or launch config, Warp's cloud agent panes, and SSH panes never resume.
- `/clear` starts a new session; the pane follows whatever it last had.
- The record keeps the directory the session was *launched* from. A `cd` in a
  Bash tool call changes Claude's own cwd, and `SessionStart` fires again on
  compact with that drifted cwd; recording it would resume the session under a
  different project folder (new memory and settings). Compact only refreshes
  the session id and timestamp.
- Resuming `cd`s into the recorded directory, which fires `chpwd` hooks
  (direnv, zoxide). With `AUTO=1` that happens without a prompt; tools that
  require a per-directory allow are unaffected.
- The control-character check assumes a UTF-8 locale (what Warp and Claude
  Code use). Under `LANG=C` only ASCII controls are caught, and on Linux a
  Unicode bidi-override character in a directory name is not caught at all, so
  the path shown at the prompt could display reversed.
- With `AUTO=1`, every recorded pane launches Claude the moment Warp opens, and
  a long-idle large session may come back on Claude's own "Resume from
  summary?" dialog rather than at a prompt.

## Should I trust this?

You're being asked to source a script at every shell start and let it launch
`claude` with your permission flags. Skepticism is correct. What you can check
yourself:

- **Two files, meant to be read.** `record-session.sh` (~130 lines, POSIX sh,
  runs inside Claude Code's hook, writes one file). `warp-claude.zsh` (~410
  lines, runs in your shell, reads that file and, for the prompt details,
  the session's transcript). No network, no `sudo`, no
  `eval` of anything but `shlex.quote`d output, nothing deleted automatically.
- **It writes exactly three things:** `~/.warp-claude/`, one hook entry in
  `~/.claude/settings.json`, and lines you add to `~/.zshrc`. It reads one
  more: the transcript in `~/.claude/projects/` for the session it offers.
- **`bash test.sh`** — 90 checks in a temp dir that never touches `$HOME`,
  including the attacks below (record tampering, flag injection, `$(…)` in a
  directory name or transcript under `PROMPT_SUBST`, terminal escapes in a
  transcript, alias and `PATH` substitution).
- **`shellcheck -s sh --enable=all record-session.sh`** — clean, no warnings.
- Before publishing, the scripts went through two rounds of independent
  adversarial review that executed attacks rather than reading for them.
  Everything it found is fixed and has a regression test.

## Security notes

The record file can't inject flags or run code, even if something else on your
machine tampers with it. Everything in it is validated before use:

- The session id must be `[0-9a-zA-Z_-]{1,64}` and not start with `-`; the
  pane UUID must be bare hex; the directory must be absolute with no control
  characters. Anything else is silently ignored.
- The directory is printed literally (`print -r`), never through prompt
  expansion, so a directory named `$(…)` can't execute at shell startup.
- `cd` happens only after you accept; declining leaves your shell where it was.
- Resume flags come only from your own `WARP_CLAUDE_RESUME_FLAGS`, never from
  the record. `claude` is resolved via zsh's `$commands` table to an absolute
  path *before* the `cd`, and `builtin cd` is used, so a shell function, an
  alias carrying flags, or a `claude` executable inside the recorded directory
  (with `.` in `PATH`) can't be substituted. (Your own `.zshrc` can, of course —
  an alias to a bare absolute path is honoured, since that's how Claude Code's
  local installer defines it.)
- The transcript is read, never executed. Only text you typed and titles
  are extracted, by a fixed python3 script fed the file path as an argument;
  every Unicode control and format character is dropped, fields are
  truncated, and the result is printed literally. Without `python3` no
  transcript content is shown at all.
- `warp-claude-list` shows control characters escaped rather than raw.
- Nothing is deleted automatically. Records are ~100 bytes each and are never
  pruned; `warp-claude-forget` removes one on request, and
  `rm -rf ~/.warp-claude/panes` is the full reset.
- Records hold a session id, a directory, a timestamp, and (when Claude emits
  it) a permission mode — no conversation content. Dir is `0700`, files `0600`.

## Uninstall

Nothing here touches Warp's own files or database. To disable instantly, add
`WARP_CLAUDE_DISABLE=1` above the `source` line. To remove:

1. Delete the `WARP_CLAUDE_*` and `source` lines from `~/.zshrc`.
2. Remove the `SessionStart` entry from `~/.claude/settings.json` (check it's
   still valid JSON: `jq . ~/.claude/settings.json`).
3. `rm -rf ~/.warp-claude`

Your conversations live in `~/.claude/projects/` and are unaffected.

## License

MIT — see [LICENSE](LICENSE).
