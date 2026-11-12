# ---------------------------------------------------------------------------
# Warp + Claude Code: reattach a restored pane to its own Claude session.
# bash port of warp-claude.zsh, written for Warp on Windows with Git Bash.
#
# Source this from ~/.bashrc (Warp's Git Bash sources /etc/profile and then
# ~/.bash_profile, so make sure ~/.bash_profile sources ~/.bashrc):
#     WARP_CLAUDE_RESUME_FLAGS=(--dangerously-skip-permissions)   # optional
#     source ~/.warp-claude/warp-claude.bash
#
# Same knobs as the zsh version: WARP_CLAUDE_RESUME_FLAGS (bash ARRAY),
# WARP_CLAUDE_MAX_AGE, WARP_CLAUDE_AUTO, WARP_CLAUDE_DISABLE,
# WARP_CLAUDE_DETAILS, WARP_CLAUDE_TRANSCRIPT_DIR, WARP_CLAUDE_STATE_DIR.
#
# Nothing runs during the rc file. Warp pastes its bootstrap into the PTY, so
# reading stdin while rc files are being sourced would eat Warp's own input.
# The check is deferred to a one-shot entry in bash-preexec's precmd_functions,
# which Warp installs and honours.
# ---------------------------------------------------------------------------

# Windows: CLAUDE_CONFIG_DIR may be set as C:\... -- convert to POSIX first.
_warp_claude_posix() {
  case "$1" in
    [A-Za-z]:[\\/]*|[A-Za-z]:)
      if type -P cygpath >/dev/null 2>&1; then cygpath -u -- "$1" 2>/dev/null; return; fi ;;
  esac
  printf '%s' "$1"
}

: "${WARP_CLAUDE_STATE_DIR:=$HOME/.warp-claude/panes}"
export WARP_CLAUDE_STATE_DIR
: "${WARP_CLAUDE_MAX_AGE:=604800}"
: "${WARP_CLAUDE_AUTO:=0}"
: "${WARP_CLAUDE_DISABLE:=0}"
: "${WARP_CLAUDE_DETAILS:=1}"
: "${WARP_CLAUDE_STAGGER:=3}"   # seconds between AUTO resumes; 0 = all at once
: "${WARP_CLAUDE_REAP:=1}"      # kill an orphaned copy of the session before resuming
: "${WARP_CLAUDE_REAP_ORPHANS:=0}"  # 1 = on Warp start, sweep ALL orphaned Warp pane trees
if [[ -z ${WARP_CLAUDE_TRANSCRIPT_DIR:-} ]]; then
  WARP_CLAUDE_TRANSCRIPT_DIR="$(_warp_claude_posix "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")/projects"
fi
# warp-claude-reap.ps1 lives next to this file.
_WARP_CLAUDE_LIBDIR=$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)

# Accept an array; reject a scalar loudly rather than silently mis-splitting it.
if [[ "$(declare -p WARP_CLAUDE_RESUME_FLAGS 2>/dev/null)" == "declare -a"* ]]; then
  : # good
elif [[ -n ${WARP_CLAUDE_RESUME_FLAGS-} ]]; then
  printf '%s\n' "warp-claude: WARP_CLAUDE_RESUME_FLAGS must be an array, e.g." \
    "             WARP_CLAUDE_RESUME_FLAGS=(--dangerously-skip-permissions)" \
    "             ignoring the string value you set." >&2
  unset WARP_CLAUDE_RESUME_FLAGS
  WARP_CLAUDE_RESUME_FLAGS=()
else
  WARP_CLAUDE_RESUME_FLAGS=()
fi

_warp_claude_ok_pane() { [[ -n $1 && $1 != *[!0-9a-fA-F]* && ${#1} -le 64 ]]; }
_warp_claude_ok_sid()  { [[ -n $1 && $1 != *[!0-9a-zA-Z_-]* && ${#1} -le 64 && $1 != -* ]]; }

# Print the absolute path of a Python that actually runs. The Windows Store
# `python3` stub is on PATH but only prints "Python was not found".
_warp_claude_python() {
  local c p
  for c in python3 python; do
    p=$(type -P "$c" 2>/dev/null) || continue
    [[ $p == /* ]] || continue
    "$p" -I -c '' >/dev/null 2>&1 && { printf '%s' "$p"; return 0; }
  done
  return 1
}

warp-claude-resume() { _warp_claude_reattach force; }

# Run warp-claude-reap.ps1 (Windows only; see that file for what counts as an
# orphan). Prints its report lines. Silent no-op without powershell.exe.
_warp_claude_run_reaper() {
  local reap="$_WARP_CLAUDE_LIBDIR/warp-claude-reap.ps1" ps
  [[ -f $reap ]] || return 0
  ps=${WARP_CLAUDE_POWERSHELL:-$(type -P powershell.exe 2>/dev/null)}
  [[ -n $ps && -x $ps ]] || return 0
  # Remembered Warp PIDs live next to the pane records (~/.warp-claude/).
  local inst="${WARP_CLAUDE_STATE_DIR%/*}/warp-instances"
  if type -P cygpath >/dev/null 2>&1; then
    reap=$(cygpath -w -- "$reap"); inst=$(cygpath -w -- "$inst")
  fi
  "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$reap" "$@" -InstancesFile "$inst" 2>/dev/null | tr -d '\r'
}

_warp_claude_sessions_dir() {
  printf '%s/sessions' "$(_warp_claude_posix "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")"
}

# When Warp dies ungracefully on Windows (crash, Task Manager), its panes'
# processes are NOT killed: an orphaned claude for this session can still be
# running, with no terminal, writing the same transcript and holding its own
# Remote Control connection. Kill exactly that tree before resuming. Matching is
# by Claude Code's own ~/.claude/sessions/<pid>.json (pid + start time), and
# only trees with no live Warp above them qualify -- a copy open in another
# live pane, VS Code etc. is never touched. Found on a live Windows Warp.
_warp_claude_reap_session() {
  local sid=$1 sd line
  [[ $WARP_CLAUDE_REAP == 1 ]] || return 0
  _warp_claude_ok_sid "$sid" || return 0
  sd=$(_warp_claude_sessions_dir)
  # Cheap pre-filter: no session file names this id => no powershell start.
  grep -qsF "\"sessionId\":\"$sid\"" "$sd"/*.json 2>/dev/null || return 0
  type -P cygpath >/dev/null 2>&1 && sd=$(cygpath -w -- "$sd")
  while IFS= read -r line; do
    [[ -n $line ]] && printf '\e[90mwarp-claude: %s\e[0m\n' "${line//[[:cntrl:]]/}"
  done < <(_warp_claude_run_reaper -SessionId "$sid" -SessionsDir "$sd" -Kill)
  return 0
}

# Runs once per Warp start, from the first pane's first prompt (at most once
# per 60s across all panes; claimed under a mkdir lock, stale >60s is broken),
# detached in the background so the prompt never waits on powershell.
#
# Always (when WARP_CLAUDE_REAP=1): the reaper records the live warp.exe PID.
# That record is how it later recognises this Warp's panes as orphans -- see
# warp-claude-reap.ps1 -- so without this run, a Warp that is killed would
# leave orphans nothing can safely match. Lists any orphans into reap.log.
#
# WARP_CLAUDE_REAP_ORPHANS=1 additionally kills them: every ungraceful Warp exit
# leaks one bash tree per pane (~24 MB each, unusable: no terminal). Opt-in,
# because it kills processes this tool did not start.
_warp_claude_sweep_orphans() {
  [[ $WARP_CLAUDE_REAP == 1 || $WARP_CLAUDE_REAP_ORPHANS == 1 ]] || return 0
  local -a args=(-All)
  [[ $WARP_CLAUDE_REAP_ORPHANS == 1 ]] && args+=(-Kill)
  local dir=$WARP_CLAUDE_STATE_DIR stamp lock now m log
  stamp="$dir/.swept"; lock="$dir/.sweep.lock"; log="${dir%/*}/reap.log"
  mkdir -p -- "$dir" 2>/dev/null || return 0
  now=${EPOCHSECONDS:-$(date +%s)}
  if [[ -d $lock ]]; then
    m=$(stat -c %Y -- "$lock" 2>/dev/null)
    [[ $m =~ ^[0-9]+$ ]] && (( now - m > 60 )) && rmdir -- "$lock" 2>/dev/null
  fi
  mkdir -- "$lock" 2>/dev/null || return 0
  m=
  [[ -f $stamp ]] && read -r m < "$stamp"
  if [[ $m =~ ^[0-9]{1,12}$ ]] && (( now - m < 60 )); then
    rmdir -- "$lock" 2>/dev/null; return 0
  fi
  printf '%s\n' "$now" > "$stamp" 2>/dev/null
  rmdir -- "$lock" 2>/dev/null
  # ( ... & ): double fork, so no job-control notice and nothing waits on it.
  ( { printf '%s sweep%s\n' "$(date '+%F %T')" "${args[1]:+ (kill)}"; _warp_claude_run_reaper "${args[@]}"; } \
      >> "$log" 2>&1 < /dev/null & )
  return 0
}

# List every orphaned Warp pane tree left by ungraceful Warp exits, and offer
# to kill them.
#   -y       kill without asking
#   --loose  also match orphans of Warps the reaper never saw alive (e.g. from
#            before this was installed). Review the list before saying yes:
#            a job you backgrounded in a live tab can look the same.
warp-claude-reap() {
  local out line ans yes= a
  local -a mode=(-All)
  for a in "$@"; do
    case $a in
      -y) yes=1 ;;
      --loose) mode+=(-Loose) ;;
      *) echo "usage: warp-claude-reap [-y] [--loose]" >&2; return 2 ;;
    esac
  done
  out=$(_warp_claude_run_reaper "${mode[@]}")
  if [[ -z $out ]]; then
    echo "no orphaned Warp panes"
    [[ ${#mode[@]} == 1 ]] && echo "(leftovers from a Warp this never saw running: warp-claude-reap --loose)"
    return 0
  fi
  while IFS= read -r line; do printf '%s\n' "${line//[[:cntrl:]]/}"; done <<< "$out"
  if [[ -z $yes ]]; then
    printf 'kill these %s trees? [y/N] ' "$(grep -c . <<< "$out")"
    read -r ans || { echo; return 0; }
    [[ $ans == [yY]* ]] || return 0
  fi
  out=$(_warp_claude_run_reaper "${mode[@]}" -Kill)
  while IFS= read -r line; do printf '%s\n' "${line//[[:cntrl:]]/}"; done <<< "$out"
}

warp-claude-list() {
  local f sid cwd ts mode found=0 name
  [[ -d $WARP_CLAUDE_STATE_DIR ]] || { echo "no records"; return 0; }
  for f in "$WARP_CLAUDE_STATE_DIR"/*; do
    [[ -f $f ]] || continue
    found=1
    IFS=$'\t' read -r sid cwd ts mode < "$f"
    name=${f##*/}
    # Control characters shown as '?': a tampered record must not be able to
    # put terminal escapes on screen via a diagnostic command.
    printf '%s  %-40s %s\n' "${name:0:8}" "${sid//[[:cntrl:]]/?}" "${cwd//[[:cntrl:]]/?}"
  done
  (( found )) || echo "no records"
}

warp-claude-forget() {
  local pane=${WARP_TERMINAL_SESSION_UUID:-}
  _warp_claude_ok_pane "$pane" || { echo "not a Warp pane"; return 1; }
  rm -f -- "$WARP_CLAUDE_STATE_DIR/$pane" && echo "forgotten"
}

# Title / age / size / last prompt, read from the (UNTRUSTED) transcript.
# Python strips every control/format char; bash prints data with %s only.
# Any failure prints nothing.
_warp_claude_details() {
  local sid=$1
  _warp_claude_ok_sid "$sid" || return 0
  local dir=$WARP_CLAUDE_TRANSCRIPT_DIR
  [[ $dir == /* && -d $dir ]] || return 0

  # Newest first if the same id exists in two project folders. "$dir" is
  # quoted, so only the * is a pattern. An unmatched glob stays literal and
  # fails the -f test.
  local f g=
  for f in "$dir"/*/"$sid".jsonl; do
    [[ -f $f && -r $f ]] || continue
    if [[ -z $g || $f -nt $g ]]; then g=$f; fi
  done
  [[ -n $g ]] || return 0
  f=$g

  local ago= size= st mtime bytes
  st=$(stat -c '%Y %s' -- "$f" 2>/dev/null)
  read -r mtime bytes <<< "$st"
  if [[ $mtime =~ ^[0-9]+$ && $bytes =~ ^[0-9]+$ ]]; then
    local now=${EPOCHSECONDS:-$(date +%s)} d
    (( d = now - mtime )); (( d < 0 )) && d=0
    if   (( d < 60 ));      then ago="just now"
    elif (( d < 3600 ));    then ago="$(( d / 60 ))m ago"
    elif (( d < 86400 ));   then ago="$(( d / 3600 ))h ago"
    elif (( d < 1209600 )); then ago="$(( d / 86400 ))d ago"
    else                         ago="$(( d / 604800 ))w ago"
    fi
    if (( bytes < 1048576 )); then size="$(( (bytes + 1023) / 1024 )) KB"
    else size="$(( bytes / 1048576 )).$(( (bytes % 1048576) * 10 / 1048576 )) MB"; fi
  fi

  local raw= title= first= last= count= py wf
  if py=$(_warp_claude_python); then
    # Hand Windows Python a Windows path rather than relying on MSYS argument
    # conversion.
    wf=$f
    type -P cygpath >/dev/null 2>&1 && wf=$(cygpath -w -- "$f" 2>/dev/null)
    raw=$(PYTHONUTF8=1 PYTHONIOENCODING=utf-8 "$py" -I - "$wf" 2>/dev/null <<'PY'
import sys, json, unicodedata

def clean(s, n):
    # Drop every Unicode control/format/private/unassigned char (Cc Cf Co Cn
    # Cs): terminal escapes, bidi overrides, zero-width tricks. Whitespace
    # runs (incl. newlines) collapse to one space.
    out = []
    for ch in s:
        if ch.isspace():
            out.append(" ")
        elif unicodedata.category(ch)[0] != "C":
            out.append(ch)
    s = " ".join("".join(out).split())
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"

def text_of(msg):
    c = msg.get("content") if isinstance(msg, dict) else None
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        parts = []
        for it in c:
            if not isinstance(it, dict):
                continue
            if it.get("type") == "tool_result":
                return ""          # a tool result, not something you typed
            if it.get("type") == "text" and isinstance(it.get("text"), str):
                parts.append(it["text"])
        return " ".join(parts)
    return ""

def typed(t):
    t = t.strip()
    if not t:
        return False
    if t.startswith("<") or t.startswith("Caveat:") or t.startswith("[Request interrupted"):
        return False
    return True

title = summary = first = last = ""
count = 0
try:
    with open(sys.argv[1], "rb") as fh:
        for raw in fh:
            if (b'"user"' not in raw and b'itle"' not in raw
                    and b'"summary"' not in raw):
                continue
            try:
                d = json.loads(raw)
            except Exception:
                continue
            if not isinstance(d, dict):
                continue
            ty = d.get("type")
            if isinstance(ty, str) and ty.endswith("title"):
                for k in ("customTitle", "aiTitle", "title"):
                    v = d.get(k)
                    if isinstance(v, str) and v.strip():
                        if k == "customTitle" or not title.startswith("\0c"):
                            title = ("\0c" if k == "customTitle" else "") + v
                        break
            elif ty == "summary" and isinstance(d.get("summary"), str):
                summary = d["summary"]
            elif ty == "user":
                if d.get("isMeta") or d.get("isSidechain") or d.get("isCompactSummary"):
                    continue
                t = text_of(d.get("message"))
                if typed(t):
                    count += 1
                    if not first:
                        first = t
                    last = t
except Exception:
    sys.exit(0)

title = title[2:] if title.startswith("\0c") else title
shown = title or summary or first
fields = [clean(shown, 72), clean(first, 90), clean(last, 90), str(count)]
sys.stdout.write("\x1f".join(f.replace("\x1f", " ") for f in fields))
PY
)
    # \x1f is not IFS whitespace, so empty fields survive the split.
    local -a parts=()
    IFS=$'\x1f' read -r -d '' -a parts < <(printf '%s' "$raw")
    if (( ${#parts[@]} == 4 )); then
      title=${parts[0]} first=${parts[1]} last=${parts[2]} count=${parts[3]}
      [[ $count =~ ^[0-9]+$ ]] || count=
    fi
  fi

  [[ -n $title || -n $ago ]] || return 0
  title=${title//[[:cntrl:]]/} last=${last//[[:cntrl:]]/}

  local meta= m
  for m in "$ago" "$size"; do [[ -n $m ]] && meta+="${meta:+ · }$m"; done
  if [[ -n $count && $count != 0 ]]; then
    m="$count prompt"; [[ $count != 1 ]] && m+="s"; meta+="${meta:+ · }$m"
  fi
  printf '  '
  if [[ -n $title ]]; then
    printf '\e[1m%s\e[0m' "$title"
    [[ -n $meta ]] && printf '  '
  fi
  printf '\e[90m%s\e[0m\n' "$meta"
  if [[ -n $last && $last != "$title" ]]; then
    printf '  \e[90mlast:\e[0m %s\n' "$last"
  fi
  return 0
}

# Report the pane's cwd to the terminal (OSC 7). Our precmd entry runs before
# Warp's own warp_precmd (Warp appends its hooks after the rc files), so
# without this Warp would not learn the directory until claude exits.
# Percent-encoded byte by byte: nothing but [A-Za-z0-9/._~:-] and %XX reaches
# the terminal. Windows form (/C:/dev), which is the standard file URI shape.
_warp_claude_osc7() {
  local p=$1 out= c i hex
  type -P cygpath >/dev/null 2>&1 && p="/$(cygpath -m -- "$p" 2>/dev/null)"
  local LC_ALL=C
  for (( i = 0; i < ${#p}; i++ )); do
    c=${p:i:1}
    if [[ $c == [A-Za-z0-9/._~:-] ]]; then out+=$c
    else printf -v hex '%%%02X' "'$c"; out+=$hex
    fi
  done
  printf '\e]7;file://%s%s\a' "${HOSTNAME:-localhost}" "$out"
}

# AUTO mode: when Warp restores many panes at once, start their claudes one
# every WARP_CLAUDE_STAGGER seconds instead of all together. Each pane takes
# the next free start slot from "$STATE_DIR/.stagger-next" under a mkdir lock
# (atomic on NTFS too), then sleeps until its slot. A slot in the past means
# "now", so the file never needs resetting. If the lock can't be had (stuck
# for >10s => broken as stale) we start without waiting: staggering is a
# courtesy and must never stop a pane from resuming.
# Returns 1 if the wait was interrupted (Ctrl-C), meaning "don't resume".
_warp_claude_stagger_wait() {
  local gap=$WARP_CLAUDE_STAGGER sid=$1
  [[ $gap =~ ^[0-9]{1,3}$ ]] || gap=3
  (( gap > 0 )) || return 0
  local dir=$WARP_CLAUDE_STATE_DIR lock="$WARP_CLAUDE_STATE_DIR/.stagger.lock"
  local next="$WARP_CLAUDE_STATE_DIR/.stagger-next"
  local now tries=0 got=0 at m
  while (( tries++ < 50 )); do
    if mkdir -- "$lock" 2>/dev/null; then got=1; break; fi
    m=$(stat -c %Y -- "$lock" 2>/dev/null)
    now=${EPOCHSECONDS:-$(date +%s)}
    if [[ $m =~ ^[0-9]+$ ]] && (( now - m > 10 )); then
      rmdir -- "$lock" 2>/dev/null
      continue
    fi
    sleep 0.1
  done
  (( got )) || return 0
  now=${EPOCHSECONDS:-$(date +%s)}
  at=
  [[ -f $next ]] && read -r at < "$next"
  [[ $at =~ ^[0-9]{1,12}$ ]] || at=0
  (( at < now )) && at=$now
  printf '%s\n' "$(( at + gap ))" > "$next" 2>/dev/null
  rmdir -- "$lock" 2>/dev/null
  local wait=$(( at - now ))
  (( wait > 0 )) || return 0
  [[ -t 1 ]] && printf '\e[90mwarp-claude: resuming %s in %ss (Ctrl-C to skip)\e[0m\n' "${sid:0:8}" "$wait"
  sleep "$wait" || return 1
  return 0
}

# Tell Warp a command is starting, as if you had typed it.
#
# We run inside precmd, BEFORE Warp's own warp_precmd (Warp appends its hooks
# after the rc files). Without this, Warp never gets a Precmd/Preexec pair for
# the resume, still believes the pane is sitting at its input editor, and
# routes your keystrokes there instead of to the PTY: claude's TUI renders but
# you can't type into it. Found on a live Windows Warp, not by reading.
#
# So replay the normal lifecycle: warp_precmd (closes the bootstrap block and
# reports a prompt), then a Preexec hook naming the command. After claude
# exits and we return, the rest of the precmd chain runs warp_precmd again,
# which sends CommandFinished -- exactly the typed-command sequence.
# Uses Warp's own bootstrap functions, so it is a no-op outside Warp or if a
# future Warp renames them.
_warp_claude_announce() {
  declare -F warp_precmd >/dev/null 2>&1 || return 0
  [[ -n ${WARP_SESSION_ID:-} ]] || return 0
  local cmd=${1//[[:cntrl:]]/}
  warp_precmd
  if [[ ${WARP_IN_MSYS2:-} == true ]] && declare -F warp_send_hook_via_kv_pairs_start >/dev/null 2>&1; then
    warp_send_hook_via_kv_pairs_start "Preexec"
    warp_send_hook_kv_pair "command" "$cmd"
    warp_send_hook_kv_pair "session_id" "$WARP_SESSION_ID"
    warp_send_hook_via_kv_pairs_end
  elif declare -F warp_send_json_message >/dev/null 2>&1 && declare -F warp_escape_json >/dev/null 2>&1; then
    warp_send_json_message "{\"hook\": \"Preexec\", \"value\": {\"command\": \"$(warp_escape_json "$cmd")\", \"session_id\": $WARP_SESSION_ID}}"
  fi
  declare -F warp_maybe_send_reset_grid_osc >/dev/null 2>&1 && warp_maybe_send_reset_grid_osc
  return 0
}

_warp_claude_reattach() {
  local force=${1:-}
  [[ -z ${WARP_CLAUDE_ACTIVE:-} ]] || return 0

  local pane=${WARP_TERMINAL_SESSION_UUID:-}
  _warp_claude_ok_pane "$pane" || return 0

  local rec="$WARP_CLAUDE_STATE_DIR/$pane"
  [[ -f $rec && -r $rec ]] || return 0

  local sid cwd ts mode
  IFS=$'\t' read -r sid cwd ts mode < "$rec" || return 0

  # The record is local, but it is still input: $sid reaches a command line
  # and $cwd reaches your terminal and `cd`.
  _warp_claude_ok_sid "$sid" || return 0
  [[ $cwd == /* && $cwd != *[[:cntrl:]]* ]] || return 0
  [[ $ts =~ ^[0-9]{1,12}$ ]] || return 0

  local now=${EPOCHSECONDS:-$(date +%s)}
  if [[ $force != force ]]; then
    (( now - ts < WARP_CLAUDE_MAX_AGE )) || return 0
  fi

  local -a extra_args=("${WARP_CLAUDE_RESUME_FLAGS[@]}")

  # Mode we'll land in, for display only.
  local shown_mode= i
  for (( i = 0; i < ${#extra_args[@]}; i++ )); do
    case ${extra_args[i]} in
      --dangerously-skip-permissions) shown_mode=bypassPermissions ;;
      --permission-mode)   shown_mode=${extra_args[i+1]-} ;;
      --permission-mode=*) shown_mode=${extra_args[i]#--permission-mode=} ;;
    esac
  done
  shown_mode=${shown_mode//[[:cntrl:]]/}

  if [[ ! -d $cwd ]]; then
    printf '\e[33mwarp-claude:\e[0m recorded directory is gone: %s\n' "$cwd"
    return 0
  fi

  # Before any prompt, countdown or launch: from here on Warp must route keys
  # to the PTY (the Y/n answer and Ctrl-C need that too, not just claude).
  local shown_cmd="claude"
  (( ${#extra_args[@]} )) && shown_cmd+=" ${extra_args[*]}"
  shown_cmd+=" --resume $sid"
  _warp_claude_announce "$shown_cmd"

  if [[ $WARP_CLAUDE_AUTO != 1 ]]; then
    if [[ ! -t 0 || ! -t 1 ]]; then
      echo "warp-claude: no terminal to prompt on; run 'warp-claude-resume' to reattach." >&2
      return 0
    fi

    local disp=$cwd
    if [[ $cwd == "$HOME" || $cwd == "$HOME"/* ]]; then disp="~${cwd#"$HOME"}"; fi

    # Colour codes are constant format strings; data only ever goes through %s.
    printf '\e[36mclaude\e[0m \e[33m%s\e[0m  \e[90m%s\e[0m' "${sid:0:8}" "$disp"
    [[ -n $shown_mode ]] && printf '  \e[90m%s\e[0m' "$shown_mode"
    printf '\n'

    [[ $WARP_CLAUDE_DETAILS == 1 ]] && _warp_claude_details "$sid"

    local ans
    printf 'resume? [Y/n] '
    read -r ans || { echo; return 0; }
    [[ $ans == [nN]* ]] && return 0
    _warp_claude_reap_session "$sid"
  else
    # AUTO: reap BEFORE the stagger wait, so the wait is the last thing
    # before launch. The reaper starts powershell (0.7s idle, several seconds
    # when a dozen panes start at once); after the wait it skewed launches
    # off their slots -- two panes started 1s apart on a live restart.
    _warp_claude_reap_session "$sid"
    # Prompt mode is staggered by you; only AUTO needs pacing. A manual
    # `warp-claude-resume` (force) never waits.
    if [[ $force != force ]]; then
      _warp_claude_stagger_wait "$sid" || return 0
    fi
  fi

  # Resolve the binary BEFORE the cd, to an absolute path, ignoring aliases
  # and functions (type -P): an alias must not add flags the prompt never
  # showed, and a `claude` inside the recorded directory must not be picked
  # up via a relative PATH entry. An alias that is exactly an absolute path
  # (no spaces, so no flags) is honoured, as in the zsh version.
  local bin
  bin=$(type -P claude 2>/dev/null)
  if [[ $bin != /* ]]; then
    bin=${BASH_ALIASES[claude]:-}
    [[ $bin == /* && $bin != *[[:space:]]* ]] || bin=
  fi
  if [[ -z $bin || ! -x $bin ]]; then
    echo "warp-claude: claude not found in PATH" >&2
    return 0
  fi

  builtin cd -- "$cwd" || {
    printf '\e[31mwarp-claude:\e[0m could not enter %s\n' "$cwd"
    return 0
  }

  [[ -t 1 ]] && _warp_claude_osc7 "$PWD"

  local rc=0
  WARP_CLAUDE_ACTIVE=1 "$bin" "${extra_args[@]}" --resume "$sid" || rc=$?
  if (( rc != 0 && rc != 130 && rc != 1 )); then
    printf '\e[31mwarp-claude:\e[0m claude exited %s resuming %s.\n' "$rc" "${sid:0:8}"
    printf "\e[90mrun 'claude' for a fresh session, or 'warp-claude-forget' to stop offering.\e[0m\n"
  fi
}

# One-shot: remove ourselves from precmd_functions, then run the check.
_warp_claude_precmd() {
  local -a keep=() f
  for f in "${precmd_functions[@]}"; do
    [[ $f == _warp_claude_precmd ]] || keep+=("$f")
  done
  precmd_functions=("${keep[@]}")
  unset -f _warp_claude_precmd
  _warp_claude_sweep_orphans
  _warp_claude_reattach
}

if [[ $WARP_CLAUDE_DISABLE != 1 && $- == *i* \
      && -n ${WARP_TERMINAL_SESSION_UUID:-} && -z ${WARP_CLAUDE_ACTIVE:-} \
      && -z ${WARP_CLAUDE_RAN:-} ]]; then
  WARP_CLAUDE_RAN=1          # shell-scoped: survives a second source
  precmd_functions+=(_warp_claude_precmd)
fi
