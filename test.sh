#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Regression suite for warp-claude.
#
#   bash test.sh
#
# Runs everything in a throwaway temp directory with a stubbed `claude`.
# Touches nothing in $HOME. Safe to run any time; run it after ANY edit.
#
# Several of these guard against bugs that were live at some point and are not
# obvious from reading the code -- read the comment on a test before "fixing" it.
# ---------------------------------------------------------------------------

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SRC/record-session.sh"
ZSHLIB="$SRC/warp-claude.zsh"

command -v zsh >/dev/null 2>&1 || { echo "zsh not found"; exit 1; }
for f in "$HOOK" "$ZSHLIB"; do [ -f "$f" ] || { echo "missing: $f"; exit 1; }; done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# Isolate interactive zsh from the user's real ~/.zshrc: it can re-order PATH
# (shadowing the stubbed claude below with the real one) or even source
# warp-claude.zsh itself. Empty rc file so zsh-newuser-install stays quiet.
export ZDOTDIR="$T/zdot"; mkdir -p "$ZDOTDIR"; : > "$ZDOTDIR/.zshrc"
# And scrub the product's own guard vars: running the suite from inside a
# resumed claude session inherits WARP_CLAUDE_ACTIVE=1, which (correctly)
# makes every reattach a silent no-op.
unset WARP_CLAUDE_ACTIVE WARP_CLAUDE_RAN WARP_CLAUDE_AUTO WARP_CLAUDE_DISABLE
# macOS Terminal.app: /etc/zshrc sources /etc/zshrc_Apple_Terminal (ZDOTDIR
# does not stop that), which prints "Restored session: ..." on start and
# "Saving session..." on exit of every interactive zsh -- breaking every
# "prints nothing" check. SHELL_SESSIONS_DISABLE is Apple's off switch;
# dropping TERM_PROGRAM keeps that file from loading at all.
export SHELL_SESSIONS_DISABLE=1
unset TERM_PROGRAM TERM_SESSION_ID
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'EOF'
#!/bin/sh
echo "CLAUDE argc=$# : $*"
echo "CLAUDE cwd=$(pwd)"
EOF
chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

PANE1=00000000000000000000000000000001
PANE2=00000000000000000000000000000002
PANE3=00000000000000000000000000000003

pass=0; fail=0; skip=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
no()   { fail=$((fail+1)); printf '  FAIL  %s\n         want: %s\n         got : %s\n' "$1" "$2" "$3"; }
sk()   { skip=$((skip+1)); printf '  skip  %s (%s)\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || no "$1" "$3" "$2"; }
has()  { case "$2" in *"$3"*) ok "$1";; *) no "$1" "contains: $3" "$2";; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1" "must NOT contain: $3" "$2";; *) ok "$1";; esac; }

# run the hook with a given pane uuid and JSON payload
hook() { WARP_TERMINAL_SESSION_UUID="$1" WARP_CLAUDE_STATE_DIR="$STATE" HOME="$FHOME" \
         "$HOOK" <<EOF
$2
EOF
}
# start an interactive-ish zsh with the lib sourced; $1 = pane, rest = extra setup
zrun() {
  local pane="$1"; shift
  zsh -ic "export WARP_CLAUDE_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$pane'
$*
source '$ZSHLIB'
_warp_claude_reattach" </dev/null 2>&1
}

STATE="$T/panes"; FHOME="$T/home"; mkdir -p "$FHOME" "$T/empty"
PROJ="$FHOME/proj"; mkdir -p "$PROJ"

echo "warp-claude regression suite"
echo "  zsh $(zsh --version | awk '{print $2}')  |  $(uname -s)"
echo

# ---------------------------------------------------------------- syntax
echo "syntax"
sh -n "$HOOK" && ok "record-session.sh parses"  || no "record-session.sh parses" ok error
zsh -n "$ZSHLIB" && ok "warp-claude.zsh parses" || no "warp-claude.zsh parses" ok error
out=$(zsh -c "emulate sh; source '$ZSHLIB'; print PARSED" 2>&1)
is "parses under 'emulate sh'" "$out" "PARSED"

# ------------------------------------------------------------- recording
echo; echo "recording"
hook "$PANE1" "{\"session_id\":\"sess-0001\",\"cwd\":\"$PROJ\"}"
hook "$PANE2" "{\"session_id\":\"sess-0002\",\"cwd\":\"$PROJ\"}"
[ -f "$STATE/$PANE1" ] && ok "record written" || no "record written" exists missing
is "record has 4 tab-separated fields" \
   "$(awk -F'\t' '{print NF}' "$STATE/$PANE1")" "4"
is "state dir is 0700" "$(ls -ld "$STATE" | cut -c2-10)" "rwx------"

# SessionStart also fires on compact, and by then Claude's cwd may have drifted
# (a `cd` in a Bash tool call carries over). Recording it re-keyed a resumed
# session onto the wrong project folder (seen live, Oct 2026). Compact keeps
# the pane's recorded cwd; startup/resume/clear still set it.
echo; echo "recording: compact keeps the launch directory"
hook "$PANE3" "{\"session_id\":\"sess-c\",\"cwd\":\"$PROJ\",\"source\":\"startup\"}"
hook "$PANE3" "{\"session_id\":\"sess-c\",\"cwd\":\"$T/empty\",\"source\":\"compact\"}"
is "compact does not overwrite cwd" "$(cut -f2 "$STATE/$PANE3")" "$PROJ"
hook "$PANE3" "{\"session_id\":\"sess-d\",\"cwd\":\"$T/empty\",\"source\":\"resume\"}"
is "resume sets cwd" "$(cut -f2 "$STATE/$PANE3")" "$T/empty"
is "resume sets sid" "$(cut -f1 "$STATE/$PANE3")" "sess-d"
rm -f "$STATE/$PANE3"
hook "$PANE3" "{\"session_id\":\"sess-e\",\"cwd\":\"$PROJ\",\"source\":\"compact\"}"
is "compact with no prior record writes normally" "$(cut -f2 "$STATE/$PANE3")" "$PROJ"
rm -f "$STATE/$PANE3"

# ------------------------------------------------- THE core requirement
echo; echo "core: per-pane identity"
o1=$(zrun "$PANE1" "WARP_CLAUDE_AUTO=1")
o2=$(zrun "$PANE2" "WARP_CLAUDE_AUTO=1")
has "pane 1 resumes its own session" "$o1" "--resume sess-0001"
has "pane 2 resumes its own session" "$o2" "--resume sess-0002"
hasnt "pane 1 does not get pane 2's session" "$o1" "sess-0002"

o=$(zrun "$PANE3" "WARP_CLAUDE_AUTO=1")
is "unknown pane does nothing" "$o" ""

o=$(zsh -ic "export WARP_CLAUDE_STATE_DIR='$STATE'; unset WARP_TERMINAL_SESSION_UUID
WARP_CLAUDE_AUTO=1; source '$ZSHLIB'; _warp_claude_reattach" </dev/null 2>&1)
is "non-Warp shell does nothing" "$o" ""

o=$(zsh -c "export WARP_CLAUDE_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$PANE1'; source '$ZSHLIB'" 2>&1)
is "non-interactive shell is silent" "$o" ""

# ------------------------------------------------------------ resume flags
echo; echo "resume flags"
o=$(zrun "$PANE1" "WARP_CLAUDE_RESUME_FLAGS=(--permission-mode bypassPermissions); WARP_CLAUDE_AUTO=1")
has "flags are passed" "$o" "--permission-mode bypassPermissions --resume sess-0001"
o=$(zrun "$PANE1" "WARP_CLAUDE_AUTO=1")
hasnt "no flags by default" "$o" "--permission-mode"
o=$(zrun "$PANE1" "WARP_CLAUDE_RESUME_FLAGS='--permission-mode bypassPermissions'; WARP_CLAUDE_AUTO=1")
has "scalar flags warn, not silently dropped" "$o" "must be an array"

# ------------------------------------------------------------- SECURITY
echo; echo "security"

# 1. command injection via a directory name, under PROMPT_SUBST.
#    This is the single most important test in the file.
mkdir -p "$T/\$(touch $T/CANARY)x"
printf 'sidz\t%s\t%s\t\n' "$T/\$(touch $T/CANARY)x" "$(date +%s)" > "$STATE/$PANE3"
zsh -ic "setopt prompt_subst; export WARP_CLAUDE_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$PANE3'; source '$ZSHLIB'; _warp_claude_reattach" \
  </dev/null >/dev/null 2>&1
[ -f "$T/CANARY" ] && no "no command execution via cwd + PROMPT_SUBST" "no canary" "CANARY CREATED" \
                   || ok "no command execution via cwd + PROMPT_SUBST"
rm -f "$STATE/$PANE3"

# 2. flag injection through the session id
hook "$PANE3" '{"session_id":"--dangerously-skip-permissions","cwd":"/tmp"}'
[ -f "$STATE/$PANE3" ] && no "flag-shaped session id rejected" rejected written \
                       || ok "flag-shaped session id rejected"

# 3. path traversal through the pane uuid
hook "../../etc/evil" '{"session_id":"s","cwd":"/tmp"}'
[ -f "$T/etc/evil" ] && no "path traversal via pane uuid rejected" rejected written \
                     || ok "path traversal via pane uuid rejected"

# 4. record-splitting and terminal escapes through cwd
hook "$PANE3" '{"session_id":"s1","cwd":"/tmp/a\t9999999999\tbypassPermissions"}'
[ -f "$STATE/$PANE3" ] && no "tab in cwd rejected" rejected written || ok "tab in cwd rejected"
hook "$PANE3" '{"session_id":"s1","cwd":"relative/path"}'
[ -f "$STATE/$PANE3" ] && no "relative cwd rejected" rejected written || ok "relative cwd rejected"
hook "$PANE3" '{"session_id":null,"cwd":"/tmp"}'
[ -f "$STATE/$PANE3" ] && no "JSON null session id rejected" rejected written || ok "JSON null session id rejected"

# 5. a corrupt timestamp must not spew shell errors on every startup
printf 'sid-x\t%s\tnot-a-number\t\n' "$PROJ" > "$STATE/$PANE3"
o=$(zrun "$PANE3" "WARP_CLAUDE_AUTO=1")
is "corrupt timestamp is silent" "$o" ""
rm -f "$STATE/$PANE3"

# ------------------------------------------------- SECURITY, zsh side
echo; echo "security: zsh side (record is untrusted here too)"

# a. an alias on `claude` defined before the source line must not be baked in
o=$(zrun "$PANE1" "alias claude='claude --dangerously-skip-permissions'; WARP_CLAUDE_AUTO=1")
has   "claude alias is bypassed (binary resolved)" "$o" "--resume sess-0001"
hasnt "claude alias cannot smuggle flags" "$o" "dangerously"

# a2. Claude Code's local installer defines claude ONLY as an alias to an
#     absolute path. That shape must work; an alias with flags must not.
o=$(zrun "$PANE1" "export PATH='$T/empty'; alias claude='$BIN/claude'; WARP_CLAUDE_AUTO=1")
has   "alias-only install (bare absolute path) resumes" "$o" "--resume sess-0001"
o=$(zrun "$PANE1" "export PATH='$T/empty'; alias claude='$BIN/claude --dangerously-skip-permissions'; WARP_CLAUDE_AUTO=1")
hasnt "alias-only install with flags is refused, not honoured" "$o" "dangerously"
o=$(zrun "$PANE1" "hash claude=/nonexistent/claude; WARP_CLAUDE_AUTO=1")
hasnt "stale hash entry fails silently" "$o" "no such file"

# b. a cd alias/function (zoxide etc.) must not intercept the directory change
o=$(zrun "$PANE1" "alias cd='cd /'; WARP_CLAUDE_AUTO=1")
has "cd alias is bypassed (builtin cd)" "$o" "CLAUDE cwd=$PROJ"

# c. `.` in PATH + a record pointing at a directory that contains its own
#    `claude`: the binary must be resolved BEFORE the cd
EVIL="$T/evil"; mkdir -p "$EVIL"
printf '#!/bin/sh\necho ATTACKER-CLAUDE-RAN\n' > "$EVIL/claude"; chmod +x "$EVIL/claude"
printf 'sid-e\t%s\t%s\t\n' "$EVIL" "$(date +%s)" > "$STATE/$PANE3"
o=$(zrun "$PANE3" "export PATH=\".:\$PATH\"; WARP_CLAUDE_AUTO=1")
hasnt "record dir cannot supply the claude binary" "$o" "ATTACKER"
has   "…the PATH claude runs instead" "$o" "CLAUDE argc"
rm -f "$STATE/$PANE3"

# d. record fields the zsh side must reject even though the hook would never write them
printf -- '--dangerously-skip-permissions\t%s\t%s\t\n' "$PROJ" "$(date +%s)" > "$STATE/$PANE3"
o=$(zrun "$PANE3" "WARP_CLAUDE_AUTO=1")
is "zsh side rejects flag-shaped sid" "$o" ""
printf 'sid;touch %s/CANARY2\t%s\t%s\t\n' "$T" "$PROJ" "$(date +%s)" > "$STATE/$PANE3"
o=$(zrun "$PANE3" "WARP_CLAUDE_AUTO=1")
is "zsh side rejects metacharacters in sid" "$o" ""
[ -f "$T/CANARY2" ] && no "sid metacharacters not executed" "no canary" "CANARY2 CREATED" || ok "sid metacharacters not executed"
printf 'sid-c\t%s\t%s\t\n' "$PROJ/"$'\e'"]0;PWNED"$'\a' "$(date +%s)" > "$STATE/$PANE3"
o=$(zrun "$PANE3" "WARP_CLAUDE_AUTO=1")
is "zsh side rejects control chars in cwd" "$o" ""
printf 'sid-t\t%s\t%s\t\n' "$PROJ" "9999999999999999999999999999999999999999" > "$STATE/$PANE3"
o=$(zrun "$PANE3" "WARP_CLAUDE_AUTO=1")
is "oversize timestamp is silent (no arithmetic warning)" "$o" ""
printf 'sid-u\t%s\t%s\t\n' "$PROJ" "$(date +%s)" > "$STATE/$PANE3"; chmod 000 "$STATE/$PANE3"
o=$(zrun "$PANE3" "WARP_CLAUDE_AUTO=1")
if [ "$(id -u)" = 0 ]; then sk "unreadable record is silent" "running as root"; else is "unreadable record is silent" "$o" ""; fi
chmod 600 "$STATE/$PANE3"; rm -f "$STATE/$PANE3"

# e. warp-claude-list must not put raw escapes on the terminal
printf 'sid-l\t%s\t%s\t\n' "$PROJ/"$'\e'"[2J" "$(date +%s)" > "$STATE/$PANE3"
n=$(zsh -ic "export WARP_CLAUDE_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$PANE3'; source '$ZSHLIB'; warp-claude-list" </dev/null 2>&1 | grep -c $'\e')
is "warp-claude-list escapes control chars" "$n" "0"
rm -f "$STATE/$PANE3"

# f. sourcing under GLOB_SUBST with a glob char in the state path
out=$(zsh -c "setopt glob_subst; WARP_CLAUDE_STATE_DIR='$T/a[b]'; source '$ZSHLIB'; print PARSED" 2>&1)
is "parses under GLOB_SUBST with [ in state path" "$out" "PARSED"

# g. the grep fallback (python3 absent/broken) must parse the real key, not a
#    forged one embedded in cwd, and must never eval
NOPY="$T/nopy"; mkdir -p "$NOPY"; printf '#!/bin/sh\nexit 1\n' > "$NOPY/python3"; chmod +x "$NOPY/python3"
PATH="$NOPY:$PATH" hook "$PANE3" "{\"session_id\":\"real-sid\",\"cwd\":\"$PROJ/x\\\\\"session_id\\\\\":\\\\\"--evil\\\\\"\"}"
[ -f "$STATE/$PANE3" ] && is "grep fallback takes the real session_id" "$(cut -f1 "$STATE/$PANE3")" "real-sid" \
                       || ok "grep fallback: forged record refused entirely"
rm -f "$STATE/$PANE3"
PATH="$NOPY:$PATH" hook "$PANE3" "{\"session_id\":\"fb-ok\",\"cwd\":\"$PROJ\"}"
is "grep fallback writes a normal record" "$(cut -f1 "$STATE/$PANE3" 2>/dev/null)" "fb-ok"
rm -f "$STATE/$PANE3"
# a second, real "session_id" key nested later in the payload must lose to the
# first one (this is the head -1 in _first_json_string; tail -1 would fail here)
PATH="$NOPY:$PATH" hook "$PANE3" "{\"session_id\":\"first\",\"meta\":{\"session_id\":\"--evil\"},\"cwd\":\"$PROJ\"}"
is "grep fallback takes the FIRST session_id key" "$(cut -f1 "$STATE/$PANE3" 2>/dev/null)" "first"
rm -f "$STATE/$PANE3"

# h. the hook must never delete anything. A prune used to live here; this
#    pins its absence: an old, non-record file in the state dir survives a run.
touch -t 200001010000 "$STATE/keep-me.txt" "$STATE/0ldhexname"
hook "$PANE1" "{\"session_id\":\"sess-0001\",\"cwd\":\"$PROJ\"}"
{ [ -f "$STATE/keep-me.txt" ] && [ -f "$STATE/0ldhexname" ]; } && ok "hook deletes nothing in the state dir" \
  || no "hook deletes nothing in the state dir" "both files kept" "something was deleted"
rm -f "$STATE/keep-me.txt" "$STATE/0ldhexname"

# ------------------------------------------------------------- robustness
echo; echo "robustness"
for opt in nounset ksh_arrays sh_word_split extended_glob warn_create_global; do
  o=$(zrun "$PANE1" "setopt $opt; WARP_CLAUDE_RESUME_FLAGS=(--permission-mode bypassPermissions); WARP_CLAUDE_AUTO=1")
  has "works under setopt $opt" "$o" "--resume sess-0001"
done

o=$(zsh -ic "export WARP_CLAUDE_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$PANE1'
MATCH=keepme; WARP_CLAUDE_AUTO=1; source '$ZSHLIB'; _warp_claude_reattach >/dev/null; print \"M=\$MATCH\"" </dev/null 2>&1 | tail -1)
is "does not clobber caller's \$MATCH" "$o" "M=keepme"

o=$(zsh -ic "export WARP_CLAUDE_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$PANE1'; source '$ZSHLIB'; warp-claude-list" </dev/null 2>&1)
has "warp-claude-list lists records" "$o" "sess-0001"

rm -rf "$T/gone"
printf 'sid-g\t%s\t%s\t\n' "$T/gone" "$(date +%s)" > "$STATE/$PANE3"
o=$(zrun "$PANE3" "WARP_CLAUDE_AUTO=1")
has "missing directory warns instead of resuming elsewhere" "$o" "directory is gone"
hasnt "missing directory does not launch claude" "$o" "CLAUDE argc"
rm -f "$STATE/$PANE3"

# stale record
printf 'sid-o\t%s\t1\t\n' "$PROJ" > "$STATE/$PANE3"
o=$(zrun "$PANE3" "WARP_CLAUDE_AUTO=1")
is "record older than MAX_AGE is ignored" "$o" ""
o=$(zsh -ic "export WARP_CLAUDE_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$PANE3'
WARP_CLAUDE_AUTO=1; source '$ZSHLIB'; warp-claude-resume" </dev/null 2>&1)
has "warp-claude-resume overrides MAX_AGE" "$o" "--resume sid-o"
rm -f "$STATE/$PANE3"

o=$(zrun "$PANE1" "WARP_CLAUDE_DISABLE=1; WARP_CLAUDE_AUTO=1
source '$ZSHLIB'")
: # DISABLE is checked at the top-level guard, exercised via the pty test below

# ---------------------------------------------------------------- details
# The resume prompt shows the session's title, age and last message, read
# from Claude Code's transcript. That transcript is untrusted text.
echo; echo "details (transcript summary under the prompt)"
TX="$T/transcripts"; mkdir -p "$TX/-proj"
python3 - "$TX/-proj/sess-0001.jsonl" "$T" <<'PYEOF'
import json, sys
t = sys.argv[2]
rows = [
  {"type": "summary", "summary": "Generated summary", "leafUuid": "x"},
  {"type": "user", "message": {"role": "user", "content": "<command-name>/clear</command-name>"}},
  {"type": "user", "isMeta": True, "message": {"role": "user", "content": "META-SHOULD-NOT-SHOW"}},
  {"type": "user", "message": {"role": "user", "content": "Draft the methods\nsection"}},
  {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "TOOLRESULT-SHOULD-NOT-SHOW"}]}},
  {"type": "user", "message": {"role": "user", "content": [{"type": "text",
     # %F{1} goes first: the message is truncated at 90 chars and $t (the
     # temp dir) is long on macOS, so anything after it would be cut off.
     "text": "tighten the table %F{1}red \u001b[2J\u001b]0;PWNED\u0007 \u202egnp $(touch " + t + "/CANARY3)"}]}},
  {"type": "custom-title", "customTitle": "Methods draft", "sessionId": "sess-0001"},
]
with open(sys.argv[1], "w") as f:
    for r in rows: f.write(json.dumps(r) + "\n")
    f.write("{not json\n")
PYEOF
dz() { zsh -c "setopt prompt_subst; WARP_CLAUDE_TRANSCRIPT_DIR='$TX'; ${2-}
source '$ZSHLIB'; _warp_claude_details '$1'" </dev/null 2>&1; }
o=$(dz sess-0001)
has   "custom title (/rename) is shown" "$o" "Methods draft"
has   "prompt count counts only typed prompts" "$o" "2 prompts"
has   "last typed message is shown" "$o" "last:"
has   "…with its text" "$o" "tighten the table"
hasnt "slash-command noise is skipped" "$o" "command-name"
hasnt "isMeta messages are skipped" "$o" "META-SHOULD-NOT-SHOW"
hasnt "tool results are skipped" "$o" "TOOLRESULT-SHOULD-NOT-SHOW"
hasnt "no ESC from transcript reaches the terminal" "$o" $'\e[2J'
hasnt "no OSC title-set from transcript" "$o" $'\e]0;'
hasnt "no BEL from transcript" "$o" $'\a'
hasnt "no bidi override from transcript" "$o" $'‮'
has   "%-escapes in transcript are printed literally, not expanded" "$o" "%F{1}red"
[ -f "$T/CANARY3" ] && no "no command execution via transcript + PROMPT_SUBST" "no canary" "CANARY3 CREATED" \
                    || ok "no command execution via transcript + PROMPT_SUBST"
o=$(dz sess-0001 "setopt ksh_arrays nounset sh_word_split")
has   "details work under ksh_arrays/nounset/sh_word_split" "$o" "Methods draft"
o=$(dz no-such-session)
is    "no transcript prints nothing" "$o" ""
o=$(dz '../../etc' )
is    "path-shaped id prints nothing" "$o" ""
printf '{"type":"user","message":{"content":"only one"}}\n' > "$TX/-proj/sess-0002.jsonl"
o=$(dz sess-0002)
has   "no title falls back to first prompt" "$o" "only one"
hasnt "last line omitted when it equals the title" "$o" "last:"
o=$(dz sess-0002 "export PATH='$NOPY'")
has   "without working python3, still shows age and size" "$o" "1 KB"

# ------------------------------------------------------------------ OSC 7
echo; echo "directory report"
o=$(zsh -fc "source '$ZSHLIB'; HOST=h; _warp_claude_osc7 '/a b/100%/é'" | od -An -c | tr -d ' \n')
is "OSC 7 path is percent-encoded byte by byte" "$o" '033]7;file://h/a%20b/100%25/%C3%A9\a'

# ---------------------------------------------------------------- pty tests
echo; echo "interactive (pty)"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import pty' 2>/dev/null; then
  cat > "$T/ptyh.py" <<'PYEOF'
import os, pty, sys, select, time, fcntl, signal
rc, reply = sys.argv[1], (sys.argv[2].encode() if len(sys.argv) > 2 else b"")
out = b""
pid, fd = pty.fork()
if pid == 0:
    os.environ["ZDOTDIR"] = os.path.dirname(rc)
    os.execvp("zsh", ["zsh", "-i"]); os._exit(1)
# Hard deadline. Whatever else goes wrong below (a pty read that never returns,
# a child that ignores exit), this test ends in 20s with what was captured.
def _deadline(*_):
    try: os.kill(pid, 9)
    except Exception: pass
    sys.stdout.write(out.decode(errors="replace") + "\n[ptyh: deadline hit]\n"); sys.stdout.flush()
    os._exit(0)
signal.signal(signal.SIGALRM, _deadline); signal.alarm(20)
# Non-blocking master: on macOS a read on the master after the slave has
# closed can block forever instead of returning EOF, hanging the whole suite
# on the trailing read below (intermittent -- it's a race with zsh's exit).
fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)
sent = False; t0 = time.time()
while time.time() - t0 < 8:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try: d = os.read(fd, 4096)
        except OSError: break
        if not d: break
        out += d
        if not sent and (b"[Y/n]" in out or b"CLAUDE argc" in out):
            if reply: os.write(fd, reply)
            sent = True
    elif sent or b"CLAUDE" in out: break
try:
    os.write(fd, b"\nexit\n"); time.sleep(0.4); out += os.read(fd, 65536)
except Exception: pass
try: os.kill(pid, 9); os.waitpid(pid, 0)
except Exception: pass
sys.stdout.write(out.decode(errors="replace"))
PYEOF
  mkrc() { mkdir -p "$T/rc$1"; printf '%s\n' "$2" > "$T/rc$1/.zshrc"; }
  BASE="export WARP_CLAUDE_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$PANE1'"

  mkrc A "$BASE
WARP_CLAUDE_AUTO=1
source '$ZSHLIB'
print AFTER-ZSHRC"
  o=$(python3 "$T/ptyh.py" "$T/rcA/.zshrc" 2>&1)
  has "precmd hook fires in a real terminal" "$o" "CLAUDE argc"
  # .zshrc must finish BEFORE claude launches (powerlevel10k instant prompt)
  a=$(printf '%s' "$o" | grep -n 'AFTER-ZSHRC' | head -1 | cut -d: -f1)
  c=$(printf '%s' "$o" | grep -n 'CLAUDE argc'  | head -1 | cut -d: -f1)
  { [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; } \
    && ok ".zshrc completes before claude launches" \
    || no ".zshrc completes before claude launches" "AFTER-ZSHRC first" "zshrc=$a claude=$c"

  mkrc B "$BASE
WARP_CLAUDE_AUTO=1
source '$ZSHLIB'
source '$ZSHLIB'"
  n=$(python3 "$T/ptyh.py" "$T/rcB/.zshrc" 2>&1 | grep -c 'CLAUDE argc')
  is "double source launches claude once" "$n" "1"

  mkrc C "$BASE
WARP_CLAUDE_DISABLE=1
source '$ZSHLIB'
print DISABLED-OK"
  o=$(python3 "$T/ptyh.py" "$T/rcC/.zshrc" 2>&1)
  hasnt "WARP_CLAUDE_DISABLE=1 suppresses everything" "$o" "CLAUDE argc"

  mkrc D "$BASE
source '$ZSHLIB'"
  o=$(python3 "$T/ptyh.py" "$T/rcD/.zshrc" "$(printf 'n\n')" 2>&1)
  has "prompt is shown" "$o" "resume?"
  hasnt "answering n does not launch claude" "$o" "CLAUDE argc"

  mkrc E "$BASE
WARP_CLAUDE_TRANSCRIPT_DIR='$TX'
source '$ZSHLIB'"
  o=$(python3 "$T/ptyh.py" "$T/rcE/.zshrc" "$(printf 'n\n')" 2>&1)
  has "prompt shows the session title" "$o" "Methods draft"
  has "prompt shows the last message" "$o" "tighten the table"
  mkrc F "$BASE
WARP_CLAUDE_TRANSCRIPT_DIR='$TX'
WARP_CLAUDE_DETAILS=0
source '$ZSHLIB'"
  o=$(python3 "$T/ptyh.py" "$T/rcF/.zshrc" "$(printf 'n\n')" 2>&1)
  hasnt "WARP_CLAUDE_DETAILS=0 hides details" "$o" "Methods draft"
  has   "…but still prompts" "$o" "resume?"

  o=$(python3 "$T/ptyh.py" "$T/rcD/.zshrc" "$(printf '\n')" 2>&1)
  has "bare enter accepts" "$o" "CLAUDE argc"
  has "accepting cds into the recorded directory" "$o" "CLAUDE cwd=$PROJ"
  # Warp's own precmd runs after ours, so without this report Warp never
  # learns the pane's directory and restores it (and its file explorer) at ~.
  has "accepting reports the directory to the terminal (OSC 7)" "$o" "]7;file://"
else
  sk "interactive prompt tests" "python3 with pty module not available"
fi

echo
echo "----------------------------------------"
printf 'pass %d   fail %d   skip %d\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
