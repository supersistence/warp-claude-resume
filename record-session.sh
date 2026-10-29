#!/bin/sh
# ---------------------------------------------------------------------------
# Claude Code SessionStart hook.
#
# Records which Claude session is live in which Warp pane, so that when Warp
# restores that pane after a restart the shell can reattach it to its OWN
# conversation -- not just "the newest one in this directory".
#
# The pane key is $WARP_TERMINAL_SESSION_UUID, which Warp exports into every
# local pane's shell. It is the same pane UUID Warp persists in its snapshot
# database, so a restored pane comes back with the identical value. The
# variable is undocumented; the format below is from Warp's own unit tests.
#
# Install: see README.md
# ---------------------------------------------------------------------------

# POSIX sh, no bashisms: Claude Code runs hook commands through `sh -c`, and
# /bin/sh is dash on many Linux systems, which rejects `set -o pipefail`.
set -u

STATE_DIR="${WARP_CLAUDE_STATE_DIR:-$HOME/.warp-claude/panes}"

pane="${WARP_TERMINAL_SESSION_UUID:-}"

# Not running inside a Warp pane (ssh, CI, a plain terminal). Nothing to
# record. Exit 0 so we never interfere with Claude starting up.
[ -n "$pane" ] || exit 0

# Reject anything that isn't the bare-hex UUID Warp emits, so a hostile value
# can never become a path component.
case "$pane" in
  *[!0-9a-fA-F]*) exit 0 ;;
  "")             exit 0 ;;
esac
[ "${#pane}" -le 64 ] || exit 0

payload="$(cat)"

# Pull session_id and cwd out of the hook payload. Prefer python3 for correct
# JSON handling; shlex.quote makes the eval safe for every field value.
sid=""
cwd=""
mode=""
if command -v python3 >/dev/null 2>&1; then
  eval "$(printf '%s' "$payload" | python3 -c '
import json, sys, shlex
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
def s(k):
    v = d.get(k, "")
    return v if isinstance(v, str) else ""
print("sid=" + shlex.quote(s("session_id")))
print("cwd=" + shlex.quote(s("cwd")))
print("mode=" + shlex.quote(s("permission_mode")))
print("src=" + shlex.quote(s("source")))
' 2>/dev/null)"
fi

# Fallback if python3 is missing or is a non-functional macOS CLT stub.
# Deliberately no eval and no JSON unescaping on this path: a value is taken
# literally up to the next unescaped quote, which means an embedded \" simply
# truncates it. Truncated is safe; a second parser with quoting rules is not.
# grep -o + head takes the FIRST match; a bare `sed s/.*"key"//` would be
# greedy and take the LAST, picking up a nested key of the same name.
_first_json_string() {
  printf '%s' "$payload" \
    | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 \
    | sed 's/.*"\([^"]*\)"$/\1/'
}
[ -n "$sid"  ] || sid="$(_first_json_string session_id)"
[ -n "$cwd"  ] || cwd="$(_first_json_string cwd)"
[ -n "$mode" ] || mode="$(_first_json_string permission_mode)"
[ -n "${src:-}" ] || src="$(_first_json_string source)"

[ -n "$sid" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

# On compact, the payload's cwd is wherever Claude's shell has wandered (a
# `cd` in a Bash tool call carries over), not the directory the session was
# launched from. Resuming there later re-keys the session onto a different
# project folder (new memory, new settings). Keep the cwd already on record
# for this pane; only startup/resume/clear may set it.
if [ "${src:-}" = compact ] && [ -r "${STATE_DIR}/${pane}" ]; then
  old_cwd="$(cut -f2 "${STATE_DIR}/${pane}" 2>/dev/null)"
  [ -n "$old_cwd" ] && cwd="$old_cwd"
fi

# session_id must look like a session id and nothing else -- this string is
# later passed to `claude --resume`, so it must not be able to carry shell
# metacharacters or extra flags.
case "$sid" in
  -*)               exit 0 ;;
  *[!0-9a-zA-Z_-]*) exit 0 ;;
esac
[ "${#sid}" -le 64 ] || exit 0

# cwd is written into a TAB-delimited record and later displayed. A tab or
# newline would split the record into bogus fields; other control characters
# are terminal escapes. Drop the record rather than write a corrupt one.
# [[:cntrl:]] is locale-dependent: under a UTF-8 locale (what Warp and Claude
# Code run) it also catches C1 controls and, on macOS, Unicode bidi overrides.
# Under LANG=C only ASCII controls are caught; the zsh side re-checks anyway.
case "$cwd" in
  *[[:cntrl:]]*) exit 0 ;;
  /*) ;;
  *) exit 0 ;;
esac

# Claude Code does not currently emit permission_mode in the SessionStart
# payload, so this is usually empty. Recorded when present so the format
# stays stable; nothing reads it back today. Anything unrecognised is dropped.
case "$mode" in
  default|acceptEdits|plan|auto|dontAsk|bypassPermissions) ;;
  *) mode="" ;;
esac

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
chmod 700 "$STATE_DIR" 2>/dev/null

# One record per pane. A new session in the same pane (including after /clear)
# overwrites it, so a pane always reattaches to whatever it last had.
# umask 077 so the temp file is born 0600; the chmod after is belt-and-braces.
# mkdir above runs before the umask on purpose: a 0700 dir is what we want,
# and chmod 700 pins it even if the dir pre-existed with looser permissions.
tmp="${STATE_DIR}/.${pane}.tmp.$$"
umask 077
if printf '%s\t%s\t%s\t%s\n' "$sid" "$cwd" "$(date +%s)" "$mode" > "$tmp" 2>/dev/null; then
  chmod 600 "$tmp" 2>/dev/null
  mv -f "$tmp" "${STATE_DIR}/${pane}" 2>/dev/null
fi
rm -f "$tmp" 2>/dev/null

# Deliberately no cleanup of old records. Records are ~100 bytes, one per pane
# UUID; nothing reads a stale one (the zsh side ignores records older than
# WARP_CLAUDE_MAX_AGE). A prune existed and was removed: STATE_DIR is
# user-settable, and any `find -delete` under a user-chosen path is a way to
# lose real files. `rm -rf ~/.warp-claude/panes` is the manual reset.

exit 0
