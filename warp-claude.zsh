# ---------------------------------------------------------------------------
# Warp + Claude Code: reattach a restored pane to its own Claude session.
#
# Source this from ~/.zshrc:
#     WARP_CLAUDE_RESUME_FLAGS=(--permission-mode bypassPermissions)   # optional
#     source ~/.warp-claude/warp-claude.zsh
#
# How it tells a restored pane from a new one:
#   - Warp exports $WARP_TERMINAL_SESSION_UUID into every local pane.
#   - A RESTORED pane comes back with the UUID it had before the restart, so a
#     record written by the SessionStart hook already exists for it.
#   - A BRAND NEW pane gets a freshly generated random UUID, so no record
#     exists and this does nothing at all.
#
# Nothing runs during .zshrc itself. The check is deferred to a one-shot
# precmd hook, so a prompt framework (powerlevel10k's instant prompt in
# particular, which redirects stdio during init) finishes first, and a Ctrl-C
# at the prompt can't abort the rest of your .zshrc.
#
# Knobs (set BEFORE the source line):
#   WARP_CLAUDE_RESUME_FLAGS
#         zsh ARRAY of flags always passed on resume. Mirror your own launch
#         alias here, e.g.
#             WARP_CLAUDE_RESUME_FLAGS=(--permission-mode bypassPermissions)
#         Must be an array. A plain string is rejected with a warning.
#   WARP_CLAUDE_MAX_AGE   seconds; ignore records older than this. Default 7d.
#   WARP_CLAUDE_AUTO      1 = resume without asking. Default 0 (prompt).
#   WARP_CLAUDE_DISABLE   1 = turn the whole thing off.
#   WARP_CLAUDE_DETAILS   1 = under the prompt, show the session's title,
#         when it was last used, its size and your last message, read from
#         Claude Code's own transcript. Default 1. 0 = id and path only.
#   WARP_CLAUDE_TRANSCRIPT_DIR   where Claude Code keeps transcripts.
#         Default ${CLAUDE_CONFIG_DIR:-~/.claude}/projects.
# ---------------------------------------------------------------------------

# Exported so the SessionStart hook writes where this reads. Without the
# export the two halves can silently disagree.
# Quoted: under GLOB_SUBST (set shell-wide by `emulate sh`) an unquoted
# default containing [ would be globbed and abort the source.
: "${WARP_CLAUDE_STATE_DIR:=$HOME/.warp-claude/panes}"
export WARP_CLAUDE_STATE_DIR
: ${WARP_CLAUDE_MAX_AGE:=604800}
: ${WARP_CLAUDE_AUTO:=0}
: ${WARP_CLAUDE_DISABLE:=0}
: ${WARP_CLAUDE_DETAILS:=1}
: "${WARP_CLAUDE_TRANSCRIPT_DIR:=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"

# Accept an array; reject a scalar loudly rather than silently discarding it,
# which is what `typeset -ga` would do to WARP_CLAUDE_RESUME_FLAGS="...".
if [[ ${(t)WARP_CLAUDE_RESUME_FLAGS-} == array* ]]; then
  : # good
elif [[ -n ${WARP_CLAUDE_RESUME_FLAGS-} ]]; then
  print -u2 -- "warp-claude: WARP_CLAUDE_RESUME_FLAGS must be an array, e.g."
  print -u2 -- "             WARP_CLAUDE_RESUME_FLAGS=(--permission-mode bypassPermissions)"
  print -u2 -- "             ignoring the string value you set."
  typeset -ga WARP_CLAUDE_RESUME_FLAGS=()
else
  typeset -ga WARP_CLAUDE_RESUME_FLAGS=()
fi

# Manually reattach the current pane, ignoring the age limit. Handy if you
# said "no" at the prompt and changed your mind.
warp-claude-resume() { _warp_claude_reattach force; }

# Show what's recorded for every pane.
warp-claude-list() {
  emulate -L zsh
  setopt localoptions no_nomatch
  local f sid cwd ts mode found=0
  [[ -d $WARP_CLAUDE_STATE_DIR ]] || { print -- "no records"; return 0; }
  for f in $WARP_CLAUDE_STATE_DIR/*; do
    [[ -f $f ]] || continue
    found=1
    IFS=$'\t' read -r sid cwd ts mode < "$f"
    # (V): show control characters visibly. A tampered record must not be able
    # to put terminal escapes on screen via a diagnostic command.
    printf '%s  %-40s %s\n' "${${f:t}:0:8}" "${(V)sid}" "${(V)cwd}"
  done
  (( found )) || print -- "no records"
}

# Forget this pane's binding, so it stops offering to resume.
warp-claude-forget() {
  emulate -L zsh
  local pane=${WARP_TERMINAL_SESSION_UUID:-}
  [[ -n $pane && -z ${pane//[0-9a-fA-F]/} ]] || { print -- "not a Warp pane"; return 1; }
  rm -f -- "$WARP_CLAUDE_STATE_DIR/$pane" && print -- "forgotten"
}

# Print what a session was about, under the resume prompt:
#     "Draft methods section" · 2d ago · 3.1 MB · 41 prompts
#     last: can you tighten the county comparison table…
# Everything shown comes from the transcript, which is UNTRUSTED text (it holds
# pasted content, tool output, anything). python3 strips every control/format
# character and the field separator before zsh sees it; zsh then prints it
# with print -r and (V) only, never through print -P. Any failure -- no
# transcript, no python3, unreadable file -- prints nothing: details are a
# convenience and must never block or clutter the prompt.
_warp_claude_details() {
  emulate -L zsh
  setopt localoptions no_nomatch
  zmodload -F zsh/datetime +p:EPOCHSECONDS 2>/dev/null
  local sid=$1
  # Re-check: this function is callable on its own, and sid becomes part of a
  # glob pattern below.
  [[ -n $sid && -z ${sid//[0-9a-zA-Z_-]/} && ${#sid} -le 64 ]] || return 0
  local dir=$WARP_CLAUDE_TRANSCRIPT_DIR
  [[ $dir == /* && -d $dir ]] || return 0

  # $dir is not glob-substituted (emulate zsh), so only the * is a pattern.
  # Newest first if the same id somehow exists in two project folders.
  # Built as a string and expanded with ${~...}: a literal (N.om) qualifier
  # is a parse error when this file is sourced under `emulate sh`. (b) quotes
  # any pattern characters in $dir, so only the * and the qualifier are live.
  local -a files
  local pat="${(b)dir}/*/${sid}.jsonl(N.om)"
  files=( ${~pat} )
  (( ${#files} )) || return 0
  local f=$files[1]
  [[ -r $f ]] || return 0

  # mtime + size from zsh itself, so "last used" works even without python3.
  # zstat takes only one +element per call, so fetch the whole hash.
  local -A st
  zmodload -F zsh/stat b:zstat 2>/dev/null
  zstat -H st -- $f 2>/dev/null || st=()

  local ago= size=
  if [[ ${st[mtime]-} == <-> && ${st[size]-} == <-> ]]; then
    local now=${EPOCHSECONDS:-$(date +%s)} d
    (( d = now - st[mtime] )); (( d < 0 )) && d=0
    if   (( d < 60 ));      then ago="just now"
    elif (( d < 3600 ));    then ago="$(( d / 60 ))m ago"
    elif (( d < 86400 ));   then ago="$(( d / 3600 ))h ago"
    elif (( d < 1209600 )); then ago="$(( d / 86400 ))d ago"
    else                         ago="$(( d / 604800 ))w ago"
    fi
    if (( st[size] < 1048576 )); then size="$(( (st[size] + 1023) / 1024 )) KB"
    else size=$(LC_ALL=C printf '%.1f MB' $(( st[size] / 1048576.0 ))); fi
  fi

  # title, first prompt, last prompt, prompt count; joined by \x1f, which the
  # python side guarantees cannot occur inside a field. \x1f is not IFS
  # whitespace, so empty fields survive the split (a tab separator would
  # collapse them).
  local raw= title= first= last= count=
  if [[ -n ${commands[python3]:-} ]]; then
    raw=$(python3 - "$f" 2>/dev/null <<'PY'
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
    # Slash commands, their output, hook/system injections, interrupts.
    if t.startswith("<") or t.startswith("Caveat:") or t.startswith("[Request interrupted"):
        return False
    return True

title = summary = first = last = ""
count = 0
try:
    with open(sys.argv[1], "rb") as fh:
        for raw in fh:
            # Cheap pre-filter; most lines are assistant/tool traffic.
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
                        # /rename (custom) beats a generated title; latest wins.
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
    local -a parts
    local sep=$'\x1f'
    parts=( "${(@ps:$sep:)raw}" )
    if (( ${#parts} == 4 )); then
      title=$parts[1] first=$parts[2] last=$parts[3] count=$parts[4]
      [[ $count == <-> ]] || count=
    fi
  fi

  [[ -n $title || -n $ago ]] || return 0

  # Line 1: title · age · size · prompts. Colours via -P on constant strings
  # only; data via -r with (V) as a second guard.
  local -a meta
  [[ -n $ago ]] && meta+=( $ago )
  [[ -n $size ]] && meta+=( $size )
  [[ -n $count && $count != 0 ]] && meta+=( "$count prompt${${count:#1}:+s}" )
  print -rn -- "  "
  if [[ -n $title ]]; then
    print -Pn "%B"; print -rn -- "${(V)title}"; print -Pn "%b"
    (( ${#meta} )) && print -rn -- "  "
  fi
  print -Pn "%F{8}"; print -rn -- "${(j: · :)meta}"; print -Pn "%f"
  print

  # Line 2: the last thing you typed, if it adds anything over the title.
  if [[ -n $last && $last != $title ]]; then
    print -Pn "  %F{8}last:%f "; print -r -- "${(V)last}"
  fi
  return 0
}

# Report a directory to the terminal as the pane's cwd (OSC 7). The path is
# percent-encoded byte by byte (no_multibyte), so nothing but [A-Za-z0-9/._~-]
# and %XX ever reaches the terminal, whatever the path contains.
_warp_claude_osc7() {
  emulate -L zsh
  setopt no_multibyte
  local p=$1 out= c
  integer i
  for (( i = 1; i <= ${#p}; i++ )); do
    c=$p[i]
    if [[ $c == [A-Za-z0-9/._~-] ]]; then out+=$c
    else out+=%${(l:2::0:)$(( [##16] #c ))}
    fi
  done
  printf '\e]7;file://%s%s\a' "$HOST" "$out"
}

_warp_claude_reattach() {
  # Local option scope: correct under nounset, ksh_arrays, sh_word_split etc.
  emulate -L zsh
  zmodload -F zsh/datetime +p:EPOCHSECONDS 2>/dev/null
  local force=${1:-}

  # Guard against a nested shell inside a resumed session (exported), and
  # against this file being sourced twice in one shell (shell-scoped).
  [[ -z ${WARP_CLAUDE_ACTIVE:-} ]] || return 0

  local pane=${WARP_TERMINAL_SESSION_UUID:-}
  [[ -n $pane && -z ${pane//[0-9a-fA-F]/} && ${#pane} -le 64 ]] || return 0

  local rec="$WARP_CLAUDE_STATE_DIR/$pane"
  # -r as well as -f: an unreadable record must not print an error on every
  # shell start. Silence is the contract for anything we can't use.
  [[ -f $rec && -r $rec ]] || return 0

  local sid cwd ts mode
  IFS=$'\t' read -r sid cwd ts mode < $rec || return 0

  # The record is local, but it is still input: $sid reaches a command line
  # and $cwd reaches your terminal and `cd`.
  [[ -n $sid && -z ${sid//[0-9a-zA-Z_-]/} && ${#sid} -le 64 && $sid != -* ]] || return 0
  [[ $cwd == /* && $cwd != *[[:cntrl:]]* ]] || return 0
  # <-> alone accepts any digit run; zsh arithmetic warns past 19 digits.
  [[ $ts == <-> && ${#ts} -le 12 ]] || return 0

  local now=$EPOCHSECONDS
  [[ -n $now ]] || now=$(date +%s)
  if [[ $force != force ]]; then
    (( now - ts < WARP_CLAUDE_MAX_AGE )) || return 0
  fi

  # Flags to pass on resume: your standing choice, verbatim.
  local -a extra_args
  extra_args=("${WARP_CLAUDE_RESUME_FLAGS[@]}")

  # What permission mode we'll actually land in, for display. Handles both
  # `--permission-mode x` and `--permission-mode=x`.
  local shown_mode="" i
  i=${extra_args[(I)--permission-mode]}
  if (( i )); then
    shown_mode="${extra_args[i+1]-}"
  else
    i=${extra_args[(I)--permission-mode=*]}
    (( i )) && shown_mode="${${extra_args[i]-}#--permission-mode=}"
  fi

  [[ -d $cwd ]] || {
    print -Pn "%F{3}warp-claude:%f recorded directory is gone: "
    print -r -- "$cwd"
    return 0
  }

  if [[ $WARP_CLAUDE_AUTO != 1 ]]; then
    # No controlling terminal means no way to ask. Fail closed, but say so --
    # a silent no-op here is indistinguishable from "not installed".
    if [[ ! -t 0 || ! -t 1 ]]; then
      print -u2 -- "warp-claude: no terminal to prompt on; run 'warp-claude-resume' to reattach."
      return 0
    fi

    # Display the path with $HOME abbreviated only on a component boundary,
    # so /Users/bobby does not render as ~by.
    local disp=$cwd
    if [[ $cwd == $HOME || $cwd == $HOME/* ]]; then disp="~${cwd#$HOME}"; fi

    # Colour codes go through prompt expansion; the DATA does not -- print -P
    # on an untrusted path would expand %-escapes and, under PROMPT_SUBST,
    # execute $(...) inside it.
    # $sid goes through -P; that is safe only because of the charset check
    # above (no %, no $, no backslash can be in it). $disp never goes through -P.
    print -Pn "%F{6}claude%f %F{3}${sid[1,8]}%f  %F{8}"
    print -rn -- "$disp"
    print -Pn "%f"
    if [[ -n $shown_mode ]]; then
      print -Pn "  %F{8}"
      print -rn -- "$shown_mode"
      print -Pn "%f"
    fi
    print

    # Title, age and last message, so you can tell panes apart. Best effort.
    [[ $WARP_CLAUDE_DETAILS == 1 ]] && _warp_claude_details "$sid"

    local ans
    printf 'resume? [Y/n] '
    read -r ans || { print; return 0; }
    [[ $ans == [nN]* ]] && return 0
  fi

  # Resolve the binary BEFORE changing directory, to an absolute path, and
  # call that path: a bare `claude` here would be (a) alias-expanded at source
  # time, silently baking in flags the consent prompt never showed, and
  # (b) PATH-resolved after the cd, so with `.` in PATH a record could steer
  # the shell into a directory containing its own `claude`. Same reason for
  # `builtin cd`: a cd alias/function (zoxide etc.) must not intercept this.
  # $commands ignores relative/empty PATH entries, so the /* check is a second
  # layer, not the only one. Claude Code's local installer may define claude
  # only as `alias claude=/abs/path`; honour exactly that shape (an absolute
  # path with no spaces, i.e. no flags), nothing else. -x: a stale hash entry
  # must fail silently, not print "no such file" on every restore.
  local bin=${commands[claude]:-}
  if [[ $bin != /* ]]; then
    bin=${aliases[claude]:-}
    [[ $bin == /* && $bin != *[[:space:]]* ]] || bin=
  fi
  [[ -n $bin && -x $bin ]] || {
    print -u2 -- "warp-claude: claude not found in PATH"
    return 0
  }

  # Only move the shell once you've agreed to resume.
  builtin cd -- "$cwd" || {
    print -Pn "%F{1}warp-claude:%f could not enter "
    print -r -- "$cwd"
    return 0
  }

  # Tell Warp where the pane is now. Warp registers its own precmd hook AFTER
  # sourcing .zshrc, so it runs after this one -- i.e. not until claude exits.
  # Without this Warp never hears the directory: the file explorer and new
  # panes fall back to $HOME, and $HOME is what Warp saves as this pane's cwd
  # for the next restart. Found on a live Warp, not by reading.
  [[ -t 1 ]] && _warp_claude_osc7 "$PWD"

  local rc=0
  WARP_CLAUDE_ACTIVE=1 "$bin" "${extra_args[@]}" --resume "$sid" || rc=$?
  # 130 is Ctrl-C, 1 is often a normal quit. Only a clear failure to start is
  # worth commenting on, and even then don't assert why.
  if (( rc != 0 && rc != 130 && rc != 1 )); then
    print -Pn "%F{1}warp-claude:%f claude exited ${rc} resuming ${sid[1,8]}."
    print
    print -P "%F{8}run 'claude' for a fresh session, or 'warp-claude-forget' to stop offering.%f"
  fi
}

# Defer the check to just before the first prompt, then unregister. Running
# during .zshrc breaks powerlevel10k's instant prompt (stdio is redirected
# there, so the tty test fails and this would silently never fire) and would
# let a Ctrl-C at the prompt abort the rest of your .zshrc.
_warp_claude_precmd() {
  add-zsh-hook -d precmd _warp_claude_precmd 2>/dev/null
  unfunction _warp_claude_precmd 2>/dev/null
  _warp_claude_reattach
}

if [[ $WARP_CLAUDE_DISABLE != 1 && -o interactive \
      && -n ${WARP_TERMINAL_SESSION_UUID:-} && -z ${WARP_CLAUDE_ACTIVE:-} \
      && -z ${WARP_CLAUDE_RAN:-} ]]; then
  typeset -g WARP_CLAUDE_RAN=1          # shell-scoped: survives a second source
  autoload -Uz add-zsh-hook
  add-zsh-hook precmd _warp_claude_precmd
fi
