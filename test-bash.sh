#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Regression suite for the Windows / Git Bash port:
#   record-session.sh (Windows paths, Store python stub, CRLF)
#   warp-claude.bash  (the bash shell side)
#
#   bash test-bash.sh
#
# Runs in a throwaway temp dir with a stubbed `claude`. Touches nothing in $HOME.
# ---------------------------------------------------------------------------

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SRC/record-session.sh"
LIB="$SRC/warp-claude.bash"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
unset WARP_CLAUDE_ACTIVE WARP_CLAUDE_RAN WARP_CLAUDE_AUTO WARP_CLAUDE_DISABLE \
      WARP_CLAUDE_RESUME_FLAGS WARP_CLAUDE_TRANSCRIPT_DIR CLAUDE_CONFIG_DIR
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'EOF'
#!/bin/sh
echo "CLAUDE argc=$# : $*"
echo "CLAUDE cwd=$(pwd)"
echo "CLAUDE active=${WARP_CLAUDE_ACTIVE:-}"
echo "CLAUDE start=$(date +%s)"
EOF
chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

FHOME="$T/home"; mkdir -p "$FHOME"
STATE="$T/state"
PROJ="$T/proj dir"; mkdir -p "$PROJ"
WPROJ="$(cygpath -w "$PROJ")"                 # C:\...\proj dir
JPROJ="${WPROJ//\\/\\\\}"                     # JSON-escaped
PANE=00000000000000000000000000000001
SID=11111111-2222-3333-4444-555555555555

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
no()   { fail=$((fail+1)); printf '  FAIL  %s\n         want: %s\n         got : %s\n' "$1" "$2" "$3"; }
is()   { [ "$2" = "$3" ] && ok "$1" || no "$1" "$3" "$2"; }
has()  { case "$2" in *"$3"*) ok "$1";; *) no "$1" "contains: $3" "$2";; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1" "must NOT contain: $3" "$2";; *) ok "$1";; esac; }

hook() {  # hook <pane> <json> [PATH]
  printf '%s' "$2" | WARP_TERMINAL_SESSION_UUID="$1" WARP_CLAUDE_STATE_DIR="$STATE" \
    HOME="$FHOME" PATH="${3:-$PATH}" sh "$HOOK"
}
rec() { cat "$STATE/$PANE" 2>/dev/null; }
field() { rec | cut -f"$1"; }
reset() { rm -rf "$STATE"; }

# Run the shell side in a fresh interactive bash. Extra env via `env`.
# STAGGER=0 by default so AUTO tests don't wait on each other's slots; the
# stagger tests override it. POWERSHELL defaults to a no-op so the background
# start-of-Warp reaper run never touches real processes from this suite.
printf '#!/bin/sh\nexit 0\n' > "$BIN/nops"; chmod +x "$BIN/nops"
sh_run() {  # sh_run "<bash code>" [VAR=val ...]
  local code=$1; shift
  env HOME="$FHOME" WARP_CLAUDE_STATE_DIR="$STATE" WARP_TERMINAL_SESSION_UUID="$PANE" \
      WARP_CLAUDE_TRANSCRIPT_DIR="$T/projects" WARP_CLAUDE_STAGGER=0 \
      WARP_CLAUDE_POWERSHELL="$BIN/nops" "$@" \
      bash --norc --noprofile -i -c "$code" 2>&1 < /dev/null \
    | grep -v -e 'cannot set terminal process group' -e 'no job control in this shell'
}

echo "record-session.sh"

reset; hook "$PANE" "{\"session_id\":\"$SID\",\"cwd\":\"$JPROJ\",\"source\":\"startup\"}"
is   "windows cwd -> posix (python)"        "$(field 2)" "$PROJ"
is   "session id recorded"                  "$(field 1)" "$SID"
is   "no CR anywhere in record"             "$(rec | tr -cd '\r' | wc -c | tr -d ' ')" "0"

reset; hook "$PANE" "{\"session_id\":\"$SID\",\"cwd\":\"$JPROJ\"}" "/usr/bin:/bin"
is   "windows cwd -> posix (no python)"     "$(field 2)" "$PROJ"

# Store-stub python3 first on PATH: must fall through to a real interpreter
# (or the fallback parser), never record garbage.
STUB="$T/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\necho "Python was not found" >&2\nexit 9009\n' > "$STUB/python3"; chmod +x "$STUB/python3"
reset; hook "$PANE" "{\"session_id\":\"$SID\",\"cwd\":\"$JPROJ\"}" "$STUB:$PATH"
is   "store python3 stub is skipped"        "$(field 2)" "$PROJ"

reset; hook "$PANE" "{\"session_id\":\"$SID\",\"cwd\":\"C:/Windows\"}"
is   "forward-slash drive path"             "$(field 2)" "/c/Windows"

reset; hook "$PANE" "{\"session_id\":\"$SID\",\"cwd\":\"relative\\\\dir\"}"
is   "relative path rejected"               "$(rec)" ""

reset; hook "$PANE" "{\"session_id\":\"--evil\",\"cwd\":\"$JPROJ\"}"
is   "sid starting with - rejected"         "$(rec)" ""
reset; hook "$PANE" "{\"session_id\":\"a;b\",\"cwd\":\"$JPROJ\"}"
is   "sid with metachar rejected"           "$(rec)" ""
reset; hook "$PANE" "{\"session_id\":\"$SID\",\"cwd\":\"C:\\\\x\\u001b[31m\"}"
is   "cwd with escape char rejected"        "$(rec)" ""
reset; hook "" "{\"session_id\":\"$SID\",\"cwd\":\"$JPROJ\"}"
is   "no Warp pane -> no record"            "$(ls "$STATE" 2>/dev/null)" ""
reset; hook "zz-not-hex" "{\"session_id\":\"$SID\",\"cwd\":\"$JPROJ\"}"
is   "non-hex pane rejected"                "$(ls "$STATE" 2>/dev/null)" ""

reset; hook "$PANE" "{\"session_id\":\"$SID\",\"cwd\":\"$JPROJ\",\"source\":\"startup\"}"
hook "$PANE" "{\"session_id\":\"newsid\",\"cwd\":\"C:\\\\Windows\",\"source\":\"compact\"}"
is   "compact keeps recorded cwd"           "$(field 2)" "$PROJ"
is   "compact refreshes sid"                "$(field 1)" "newsid"

echo "warp-claude.bash"

reset; hook "$PANE" "{\"session_id\":\"$SID\",\"cwd\":\"$JPROJ\"}"

out=$(sh_run "WARP_CLAUDE_RESUME_FLAGS=(--dangerously-skip-permissions); source '$LIB'; declare -p precmd_functions")
has  "interactive Warp shell registers precmd" "$out" "_warp_claude_precmd"
is   "silent at source time"                "$(sh_run "source '$LIB'")" ""

out=$(env HOME="$FHOME" WARP_TERMINAL_SESSION_UUID="$PANE" bash --norc --noprofile -c "source '$LIB'; declare -p precmd_functions 2>&1")
hasnt "non-interactive shell does not register" "$out" "_warp_claude_precmd"
out=$(sh_run "source '$LIB'; declare -p precmd_functions" WARP_CLAUDE_ACTIVE=1)
hasnt "nested in a resumed claude: no register" "$out" "_warp_claude_precmd"
out=$(sh_run "source '$LIB'; declare -p precmd_functions" WARP_TERMINAL_SESSION_UUID=)
hasnt "not a Warp pane: no register"        "$out" "_warp_claude_precmd"

out=$(sh_run "WARP_CLAUDE_RESUME_FLAGS=(--dangerously-skip-permissions); source '$LIB'; for f in \"\${precmd_functions[@]}\"; do \$f; done; declare -p precmd_functions" WARP_CLAUDE_AUTO=1)
has  "AUTO resumes with flags"              "$out" "CLAUDE argc=3 : --dangerously-skip-permissions --resume $SID"
has  "resumes in recorded dir"              "$out" "CLAUDE cwd=$PROJ"
has  "WARP_CLAUDE_ACTIVE set for child"     "$out" "CLAUDE active=1"
hasnt "precmd entry removed after one run"  "$out" "_warp_claude_precmd"
has  "OSC 7 skipped without a tty"          "$(printf '%q' "$out")" "CLAUDE"
hasnt "no OSC 7 without a tty"              "$out" $'\e]7;'

out=$(sh_run "WARP_CLAUDE_RESUME_FLAGS='--dangerously-skip-permissions'; source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1)
has  "string flags rejected loudly"         "$out" "must be an array"
has  "string flags not passed"              "$out" "CLAUDE argc=2 : --resume $SID"

out=$(sh_run "alias claude='$BIN/claude --evil-flag'; source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1)
hasnt "alias flags never used"              "$out" "--evil-flag"

out=$(sh_run "claude() { echo HIJACK; }; source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1)
hasnt "shell function never used"           "$out" "HIJACK"

out=$(sh_run "source '$LIB'; _warp_claude_reattach")
has  "prompt mode w/o tty fails closed"     "$out" "no terminal to prompt on"
hasnt "prompt mode w/o tty does not launch" "$out" "CLAUDE argc"

printf '%s\t%s\t%s\t\n' "$SID" "$PROJ" "1000" > "$STATE/$PANE"
is   "stale record not offered"             "$(sh_run "source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1)" ""
has  "warp-claude-resume ignores age"       "$(sh_run "source '$LIB'; warp-claude-resume" WARP_CLAUDE_AUTO=1)" "CLAUDE argc"

printf '%s\t%s\t%s\t\n' "--help" "$PROJ" "$(date +%s)" > "$STATE/$PANE"
is   "tampered sid in record ignored"       "$(sh_run "source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1)" ""
printf '%s\t%s\t%s\t\n' "$SID" 'relative/$(touch PWNED)' "$(date +%s)" > "$STATE/$PANE"
sh_run "source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1 >/dev/null
is   "tampered cwd ignored, nothing executed" "$(ls "$FHOME" | grep -c PWNED)" "0"
mkdir -p "$T/\$(touch PWNED2)"
printf '%s\t%s\t%s\t\n' "$SID" "$T/\$(touch PWNED2)" "$(date +%s)" > "$STATE/$PANE"
out=$(sh_run "source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1)
is   "\$(...) in dir name never executes"   "$(find "$T" -name PWNED2 -type f | wc -l | tr -d ' ')" "0"
has  "\$(...) dir still resumes literally"  "$out" 'CLAUDE cwd='"$T"'/$(touch PWNED2)'

printf '%s\t%s\t%s\t\n' "$SID" "$T/gone" "$(date +%s)" > "$STATE/$PANE"
has  "missing dir reported, not launched"   "$(sh_run "source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1)" "recorded directory is gone"

echo "warp lifecycle (typing into resumed claude)"
# Stand-ins for Warp's bootstrap functions; each logs its call in order.
WARPSTUB='WARP_SESSION_ID=42; WARP_IN_MSYS2=true
warp_precmd() { echo "W:precmd"; }
warp_send_hook_via_kv_pairs_start() { echo "W:start:$1"; }
warp_send_hook_kv_pair() { echo "W:kv:$1=$2"; }
warp_send_hook_via_kv_pairs_end() { echo "W:end"; }
warp_maybe_send_reset_grid_osc() { echo "W:grid"; }'
printf '%s\t%s\t%s\t\n' "$SID" "$PROJ" "$(date +%s)" > "$STATE/$PANE"
out=$(sh_run "$WARPSTUB
WARP_CLAUDE_RESUME_FLAGS=(--dangerously-skip-permissions --remote-control); source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1)
seq=$(printf '%s\n' "$out" | grep -E '^(W:|CLAUDE argc)' | tr '\n' '|')
is   "precmd, then Preexec, then claude"    "$seq" "W:precmd|W:start:Preexec|W:kv:command=claude --dangerously-skip-permissions --remote-control --resume $SID|W:kv:session_id=42|W:end|W:grid|CLAUDE argc=4 : --dangerously-skip-permissions --remote-control --resume $SID|"
out=$(sh_run "$WARPSTUB
source '$LIB'; _warp_claude_reattach")
has  "prompt mode: Warp told before the Y/n" "$out" "W:start:Preexec"
printf '%s\t%s\t%s\t\n' "--bad" "$PROJ" "$(date +%s)" > "$STATE/$PANE"
hasnt "nothing sent to Warp for a bad record" "$(sh_run "$WARPSTUB
source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1)" "W:"
printf '%s\t%s\t%s\t\n' "$SID" "$PROJ" "$(date +%s)" > "$STATE/$PANE"
out=$(sh_run "WARP_SESSION_ID=42; WARP_IN_MSYS2=false
warp_precmd() { echo W:precmd; }
warp_escape_json() { printf '%s' \"\$1\"; }
warp_send_json_message() { echo \"W:json:\$1\"; }
source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1)
has  "non-MSYS Warp: JSON Preexec"          "$out" "W:json:{\"hook\": \"Preexec\", \"value\": {\"command\": \"claude --resume $SID\", \"session_id\": 42}}"
out=$(sh_run "WARP_SESSION_ID=42; warp_precmd() { echo W:precmd; }; source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1)
has  "partial Warp functions: still resumes" "$out" "CLAUDE argc=2"

echo "orphan reaping (stubbed powershell; real reaper is test-reap.ps1)"
cat > "$BIN/fakeps" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/ps.log"
echo "killed tree 4242 (started 12:00:00, 11 procs, 665 MB): claude pid 4243"
printf 'esc\033]0;pwned\007line\n'
EOF
chmod +x "$BIN/fakeps"
SD="$FHOME/.claude/sessions"; mkdir -p "$SD"
printf '%s\t%s\t%s\t\n' "$SID" "$PROJ" "$(date +%s)" > "$STATE/$PANE"
rm -f "$T/ps.log"
out=$(sh_run "source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1 WARP_CLAUDE_POWERSHELL="$BIN/fakeps")
is   "no session file for sid: reaper not started" "$(cat "$T/ps.log" 2>/dev/null)" ""
printf '{"pid":4243,"sessionId":"%s","procStart":"1"}' "$SID" > "$SD/4243.json"
out=$(sh_run "source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1 WARP_CLAUDE_POWERSHELL="$BIN/fakeps")
has  "reaper called for this session, kill mode" "$(cat "$T/ps.log")" "-SessionId $SID -SessionsDir"
has  "reaper called with -Kill"             "$(cat "$T/ps.log")" "-Kill"
hasnt "reaper never in -All mode on resume" "$(cat "$T/ps.log")" "-All"
seq=$(printf '%s\n' "$out" | grep -E 'killed tree|CLAUDE argc' | sed 's/.*\(killed tree\|CLAUDE argc\).*/\1/' | tr '\n' '|')
is   "reap reported before claude starts"   "$seq" "killed tree|CLAUDE argc|"
hasnt "reaper output can't inject escapes"  "$out" $'\e]0;'
# Reap must run BEFORE the stagger wait: after it, powershell's startup time
# pushed launches off their slots (two panes 1s apart on a live restart).
cat > "$BIN/stampps" <<EOF
#!/bin/sh
date +%s > "$T/ps.when"
EOF
chmod +x "$BIN/stampps"
rm -f "$T/ps.when"; printf '%s\n' "$(( $(date +%s) + 3 ))" > "$STATE/.stagger-next"
out=$(sh_run "source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1 WARP_CLAUDE_STAGGER=2 WARP_CLAUDE_POWERSHELL="$BIN/stampps")
started=$(printf '%s\n' "$out" | sed -n 's/^CLAUDE start=//p')
reaped=$(cat "$T/ps.when" 2>/dev/null || echo 0)
[ -n "$started" ] && [ $(( started - reaped )) -ge 2 ] && ok "AUTO: reap runs before the stagger wait" \
  || no "AUTO: reap runs before the stagger wait" "reap >=2s before launch" "reap=$reaped launch=$started"
rm -f "$STATE/.stagger-next"
rm -f "$T/ps.log"
sh_run "source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1 WARP_CLAUDE_REAP=0 WARP_CLAUDE_POWERSHELL="$BIN/fakeps" >/dev/null
is   "WARP_CLAUDE_REAP=0 disables it"       "$(cat "$T/ps.log" 2>/dev/null)" ""
printf '{"pid":1,"sessionId":"%s-other","procStart":"1"}' "$SID" > "$SD/4243.json"
sh_run "source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1 WARP_CLAUDE_POWERSHELL="$BIN/fakeps" >/dev/null
is   "other session's file: reaper not started" "$(cat "$T/ps.log" 2>/dev/null)" ""
out=$(sh_run "source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1 WARP_CLAUDE_POWERSHELL="$T/nope")
has  "missing powershell: still resumes"    "$out" "CLAUDE argc"
rm -f "$T/ps.log"
out=$(sh_run "source '$LIB'; warp-claude-reap" WARP_CLAUDE_POWERSHELL="$BIN/fakeps")
is   "warp-claude-reap lists, no tty -> no kill" "$(cat "$T/ps.log")" "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $(cygpath -w "$SRC/warp-claude-reap.ps1") -All -InstancesFile $(cygpath -w "$T/warp-instances")"
rm -f "$T/ps.log"
sh_run "source '$LIB'; warp-claude-reap --loose -y" WARP_CLAUDE_POWERSHELL="$BIN/fakeps" >/dev/null
has  "warp-claude-reap --loose passes -Loose" "$(tail -1 "$T/ps.log")" "-All -Loose -Kill"
has  "bad warp-claude-reap arg rejected"    "$(sh_run "source '$LIB'; warp-claude-reap --nuke")" "usage:"
rm -f "$T/ps.log"
sh_run "source '$LIB'; warp-claude-reap -y" WARP_CLAUDE_POWERSHELL="$BIN/fakeps" >/dev/null
has  "warp-claude-reap -y kills all"        "$(tail -1 "$T/ps.log")" "-All -Kill"
rm -rf "$SD"

echo "orphan sweep on Warp start (WARP_CLAUDE_REAP_ORPHANS)"
PRECMD='for f in "${precmd_functions[@]}"; do $f; done'
rm -f "$STATE/$PANE" "$STATE/.swept" "$T/ps.log" "$T/reap.log"; rmdir "$STATE/.sweep.lock" 2>/dev/null
sh_run "source '$LIB'; $PRECMD" WARP_CLAUDE_POWERSHELL="$BIN/fakeps" >/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/ps.log" ] && break; sleep 0.5; done
# Default: still runs once per Warp start, list-only, so the reaper records
# this Warp's PID (without that record its orphans can never be matched).
has  "default: start-of-Warp run happens (records Warp)" "$(cat "$T/ps.log" 2>/dev/null)" "-All -InstancesFile"
hasnt "default: list only, never kills"     "$(cat "$T/ps.log" 2>/dev/null)" "-Kill"
rm -f "$T/ps.log" "$STATE/.swept"
sh_run "source '$LIB'; $PRECMD" WARP_CLAUDE_REAP=0 WARP_CLAUDE_POWERSHELL="$BIN/fakeps" >/dev/null; sleep 1
is   "REAP=0 and REAP_ORPHANS=0: no powershell at all" "$(cat "$T/ps.log" 2>/dev/null)" ""
rm -f "$T/ps.log" "$STATE/.swept"
t0=$(date +%s)
out=$(sh_run "source '$LIB'; $PRECMD" WARP_CLAUDE_REAP_ORPHANS=1 WARP_CLAUDE_POWERSHELL="$BIN/fakeps")
[ $(( $(date +%s) - t0 )) -lt 5 ] && ok "prompt does not wait on the sweep" || no "prompt does not wait on the sweep" "<5s" "slow"
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/ps.log" ] && break; sleep 0.5; done
has  "sweeps all orphans, kill mode (pane with no record)" "$(cat "$T/ps.log" 2>/dev/null)" "-All -Kill"
has  "report written to reap.log"           "$(cat "$T/reap.log" 2>/dev/null)" "killed tree 4242"
is   "nothing printed into the pane"        "$out" ""
rm -f "$T/ps.log"
sh_run "source '$LIB'; $PRECMD" WARP_CLAUDE_REAP_ORPHANS=1 WARP_CLAUDE_POWERSHELL="$BIN/fakeps" >/dev/null; sleep 1
is   "second pane within 60s does not sweep again" "$(cat "$T/ps.log" 2>/dev/null)" ""
printf '%s\n' "$(( $(date +%s) - 120 ))" > "$STATE/.swept"; mkdir "$STATE/.sweep.lock"; touch -d '2 minutes ago' "$STATE/.sweep.lock"
sh_run "source '$LIB'; $PRECMD" WARP_CLAUDE_REAP_ORPHANS=1 WARP_CLAUDE_POWERSHELL="$BIN/fakeps" >/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/ps.log" ] && break; sleep 0.5; done
has  "stale sweep lock broken, sweep runs"  "$(cat "$T/ps.log" 2>/dev/null)" "-All -Kill"
rm -f "$T/ps.log" "$STATE/.swept"
sh_run "source '$LIB'; $PRECMD" WARP_CLAUDE_REAP_ORPHANS=1 WARP_CLAUDE_POWERSHELL="$T/nope" >/dev/null; sleep 1
is   "missing powershell: sweep is a no-op" "$(cat "$T/ps.log" 2>/dev/null)" ""
rm -f "$STATE/.swept" "$T/reap.log"

echo "details"
mkdir -p "$T/projects/C--proj"
TR="$T/projects/C--proj/$SID.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"content":"first thing I typed"}}'
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}'
  printf '%s\n' '{"type":"ai-title","aiTitle":"Generated title"}'
  printf '%s\n' '{"type":"user","message":{"content":"last \u001b[31mred\u001b[0m one \u202e evil"}}'
} > "$TR"
out=$(sh_run "source '$LIB'; _warp_claude_details $SID")
has  "title shown"                          "$out" "Generated title"
has  "prompt count excludes tool results"   "$out" "2 prompts"
# ESC is dropped; the now-inert "[31m" text that followed it stays (as in zsh).
has  "last prompt shown"                    "$out" "last [31mred[0m one evil"
hasnt "ESC from transcript stripped"        "$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')" $'\e'
hasnt "bidi override stripped"              "$out" $'\u202e'
printf '%s\n' '{"type":"custom-title","customTitle":"My rename"}' >> "$TR"
has  "/rename beats generated title"        "$(sh_run "source '$LIB'; _warp_claude_details $SID")" "My rename"
is   "bad sid -> no details"                "$(sh_run "source '$LIB'; _warp_claude_details '../x'")" ""

echo "stagger (AUTO)"
now=$(date +%s)
P2=00000000000000000000000000000002; P3=00000000000000000000000000000003
rm -rf "$STATE"; mkdir -p "$STATE"
for p in "$PANE" "$P2" "$P3"; do printf '%s\t%s\t%s\t\n' "$SID" "$PROJ" "$now" > "$STATE/$p"; done
for p in "$PANE" "$P2" "$P3"; do
  sh_run "source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1 WARP_CLAUDE_STAGGER=2 \
    WARP_TERMINAL_SESSION_UUID="$p" > "$T/out.$p" &
done
wait
starts=$(cat "$T"/out.* | sed -n 's/^CLAUDE start=//p' | sort -n)
is   "all three panes resumed"              "$(printf '%s\n' "$starts" | grep -c .)" "3"
span=$(( $(printf '%s\n' "$starts" | tail -1) - $(printf '%s\n' "$starts" | head -1) ))
[ "$span" -ge 3 ] && ok "starts spread out (span ${span}s; 3 panes @2s)" \
                  || no "starts spread out" ">=3s" "${span}s"
is   "lock released"                        "$(ls -d "$STATE/.stagger.lock" 2>/dev/null)" ""

rm -f "$STATE/.stagger-next"
sh_run "source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1 >/dev/null
is   "STAGGER=0: no slot file written"      "$(ls -a "$STATE" | grep -c stagger-next)" "0"

printf '%s\n' "$(( $(date +%s) + 300 ))" > "$STATE/.stagger-next"
t0=$(date +%s); out=$(sh_run "source '$LIB'; warp-claude-resume" WARP_CLAUDE_AUTO=1 WARP_CLAUDE_STAGGER=2)
has  "manual resume never waits for a slot" "$out" "CLAUDE argc"
[ $(( $(date +%s) - t0 )) -lt 10 ] && ok "manual resume was immediate" || no "manual resume was immediate" "<10s" "slow"

printf 'garbage\n' > "$STATE/.stagger-next"
t0=$(date +%s); out=$(sh_run "source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1 WARP_CLAUDE_STAGGER=2)
has  "corrupt slot file -> resumes now"     "$out" "CLAUDE argc"
[ $(( $(date +%s) - t0 )) -lt 10 ] && ok "corrupt slot file did not delay" || no "corrupt slot file did not delay" "<10s" "slow"

rm -f "$STATE/.stagger-next"; mkdir "$STATE/.stagger.lock"; touch -d '1 minute ago' "$STATE/.stagger.lock"
out=$(sh_run "source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1 WARP_CLAUDE_STAGGER=2)
has  "stale lock broken, pane resumes"      "$out" "CLAUDE argc"
is   "stale lock cleaned up"                "$(ls -d "$STATE/.stagger.lock" 2>/dev/null)" ""

out=$(sh_run "source '$LIB'; _warp_claude_reattach" WARP_CLAUDE_AUTO=1 WARP_CLAUDE_STAGGER='$(touch PWNED3)')
has  "bad STAGGER value falls back, resumes" "$out" "CLAUDE argc"
is   "bad STAGGER value never executed"     "$(find "$T" "$FHOME" -name PWNED3 | wc -l | tr -d ' ')" "0"

echo "list / forget"
printf '%s\t%s\t%s\t\n' "$SID" "$PROJ" "$(date +%s)" > "$STATE/$PANE"
has  "list shows record"                    "$(sh_run "source '$LIB'; warp-claude-list")" "$SID"
has  "forget"                               "$(sh_run "source '$LIB'; warp-claude-forget")" "forgotten"
is   "record gone after forget"             "$(ls "$STATE" | grep -c "^$PANE$")" "0"
is   "other panes' records untouched"       "$(ls "$STATE" | grep -c "^$P2$")" "1"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
