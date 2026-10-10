#!/usr/bin/env bash
# chum-quarantine.sh — review, release or discard session events that the
# sensitive-content guard held back from team memory.
#
# Usage: chum-quarantine.sh list            show held items (secrets masked)
#        chum-quarantine.sh send [SESSION]  release held items to team memory
#        chum-quarantine.sh drop [SESSION]  discard held items for good
# SESSION is the Claude session id prefix shown by `list`; omit it to act on all.
# The project is taken from CLAUDE_PROJECT_DIR, then the git root of $PWD.
set -uo pipefail
umask 077  # outbox, quarantine and state files hold raw session content: owner-only
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
QDIR="$PROJECT_DIR/.chum-cache/quarantine"
OUTBOX="$PROJECT_DIR/.chum-cache/outbox"
CMD="${1:-list}"; WHO="${2:-}"

shopt -s nullglob
files=("$QDIR"/*.jsonl)
if [[ -n "$WHO" ]]; then
  # "${sel[@]+"${sel[@]}"}": expanding an EMPTY array under `set -u` is an
  # "unbound variable" error on bash 3.2 (macOS /bin/bash); this idiom is not.
  sel=(); for f in "${files[@]}"; do [[ "$(basename "$f")" == *"$WHO"* ]] && sel+=("$f"); done; files=("${sel[@]+"${sel[@]}"}")
fi
if [[ ${#files[@]} -eq 0 ]]; then echo "chum-quarantine: nothing held${WHO:+ for $WHO}"; exit 0; fi

mask() { # replace every matched secret with *** so a listing never prints one
  local text="$1" line name flags re d=$'\001'
  # The private-key rule matches only the BEGIN line, so the key body after it
  # was printed (review 3), and the /chum-quarantine skill runs this inside
  # Claude, where the PostToolUse hook would then send that body (no header
  # left to match) to team memory. Hide everything from a PEM header on first.
  text=$(printf '%s' "$text" | sed -E 's/-----BEGIN [A-Z ]*PRIVATE KEY-----.*/*** [private key hidden]/' 2>/dev/null || printf '***')
  # The substitution is delimited by \001, not "/": several rules contain "/"
  # (postgres://user:pw@, hooks.slack.com/services/) and with "/" sed rejected
  # the command, the fallback printed the text UNMASKED, and `list` showed the
  # password it was supposed to hide.
  while IFS='|' read -r name flags re; do
    [[ -z "$name" || "$name" == \#* || -z "$re" ]] && continue
    if [[ "$flags" == *i* ]]; then text=$(printf '%s' "$text" | sed -E "s${d}${re}${d}***${d}Ig" 2>/dev/null || printf '***')
    else text=$(printf '%s' "$text" | sed -E "s${d}${re}${d}***${d}g" 2>/dev/null || printf '***'); fi
  done < <(cat "$SCRIPTS_DIR/sensitive-patterns.txt" "$PROJECT_DIR/.chum-sensitive-patterns" 2>/dev/null)
  # Long opaque token runs the rules have no shape for are hidden too.
  text=$(printf '%s' "$text" | sed -E 's/[A-Za-z0-9+\/=_-]{40,}/***/g' 2>/dev/null || printf '***')
  printf '%s' "$text"
}

case "$CMD" in
  list)
    for f in "${files[@]}"; do
      sid=$(basename "$f" .jsonl); n=$(grep -c . "$f")
      echo "== $sid: $n held item(s)"
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        kind=$(printf '%s' "$line" | jq -r '.body.eventType // .kind // "?"')
        matched=$(printf '%s' "$line" | jq -r '.matched // "?"')
        at=$(printf '%s' "$line" | jq -r '.at // ""')
        # Tool events keep their output under payload.metadata (payload.message is
        # just the tool name). Mask the WHOLE field first, then cut to 160 chars:
        # cutting first could leave half a key that no rule matches any more.
        preview=$(printf '%s' "$line" | jq -r '
          (if ((.body.eventType // "") | startswith("tool_"))
             then (.body.payload.metadata.output // .body.payload.metadata.input // .body.payload.message)
             else (.body.payload.message // .body.summary) end // "") | tostring' | tr '\n' ' ')
        preview=$(mask "$preview")
        echo "  - $at $kind [$matched]: ${preview:0:160}"
      done < "$f"
    done
    echo "Release with: chum-quarantine.sh send [SESSION]   Discard with: chum-quarantine.sh drop [SESSION]"
    ;;
  send)
    mkdir -p "$OUTBOX"
    for f in "${files[@]}"; do
      sid=$(basename "$f" .jsonl)
      # Held lines use the outbox line format, so releasing is a move into the
      # outbox; the detached replayer sends them with the usual retries.
      jq -c 'del(.matched, .at)' "$f" >> "$OUTBOX/$sid.jsonl" && rm -f "$f"
      echo "released $(basename "$f") -> outbox"
    done
    if [[ -x "$SCRIPTS_DIR/session-sync.sh" ]]; then
      api=$(jq -r '.apiUrl // empty' "$PROJECT_DIR/.chum-mem" 2>/dev/null)
      pid=$(jq -r '.projectId // empty' "$PROJECT_DIR/.chum-mem" 2>/dev/null)
      # The replayer needs the project id the hooks normally export.
      CHUM_MEMORY_API_URL="${CHUM_MEMORY_API_URL:-${api:-http://localhost:63001}}" \
        CHUM_MEM_PROJECT_ID="${CHUM_MEM_PROJECT_ID:-$pid}" \
        CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPTS_DIR/session-sync.sh" --flush 2>&1 | sed 's/^/  /'
    fi
    ;;
  drop)
    for f in "${files[@]}"; do rm -f "$f" && echo "discarded $(basename "$f")"; done
    ;;
  *) echo "usage: $0 list|send|drop [SESSION]" >&2; exit 2 ;;
esac
