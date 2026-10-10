#!/usr/bin/env bash
# session-sync.sh — Session layer ingestion for chum-memory.
# Reads a Claude Code or Codex hook payload from stdin, maps it to the
# chum-memory session event schema, and POSTs to the ingestion API.
#
# Called by hook-dispatch.sh for every relevant hook event. Keeps per-session
# state in .chum-cache/session-<provider>-<session-id>.json so events can
# reference the chum-mem session UUID for the whole lifetime of the shell.
#
# Provider is chosen by CHUM_PROVIDER (default "claude"). It is an open AI
# client identifier, for example "claude", "codex", "gemini", or "cursor".
#
# Errors are surfaced to stderr with exit 1 (non-blocking) when the API is
# unreachable — the user sees the error but their prompt still proceeds.

set -Eeuo pipefail
# An unhandled failure under `set -e` must say where it died: an empty error line
# hid a 3.5 h capture outage (FINDINGS F39). -E lets functions inherit the trap.
# Only the top-level shell reports: failures inside $(...) are handled by their `|| ...`.
trap 'rc=$?; [[ ${BASH_SUBSHELL:-0} -eq 0 ]] && echo "session-sync: aborted at line ${LINENO} (exit ${rc}) during ${HOOK_EVENT:-?}" >&2' ERR
# A hook killed at its timeout must not leave response/payload files in /tmp.
trap 'rm -f /tmp/chum-session-*-resp.$$.json' EXIT

API_URL="${CHUM_MEMORY_API_URL:-http://localhost:63001}"
FLUSH_ONLY=0
if [[ "${1:-}" == "--flush" ]]; then FLUSH_ONLY=1; fi
# ── API token (optional): sent as X-Chum-Token on every call. Single-word
# header so it can be expanded unquoted under bash 3.2 with `set -u`.
AUTH_HEADER=""
# Token: env var first, else the file the installer writes (~/.config/chum-mem/token).
if [[ -z "${CHUM_MEMORY_API_TOKEN:-}" && -r "${HOME}/.config/chum-mem/token" ]]; then
  CHUM_MEMORY_API_TOKEN="$(tr -d '[:space:]' < "${HOME}/.config/chum-mem/token")"; export CHUM_MEMORY_API_TOKEN
fi
if [[ -n "${CHUM_MEMORY_API_TOKEN:-}" ]]; then AUTH_HEADER="-HX-Chum-Token:${CHUM_MEMORY_API_TOKEN}"; fi
# Budget for the live session/start and session/event calls. It must stay well
# under the shortest hook timeout (PostToolUse, Notification, SubagentStop:
# 10 s): with 10 s here, an API that accepted the connection but hung got the
# hook killed by Claude Code before curl gave up, so the event was neither
# stored nor spooled, and the cached /health result was never dropped, so every
# hook in the next minute was lost the same way (review 3). On timeout the
# event is spooled and replayed by the detached replayer.
LIVE_CALL_TIMEOUT="${CHUM_LIVE_CALL_TIMEOUT_SECS:-6}"
[[ "$LIVE_CALL_TIMEOUT" =~ ^[0-9]+$ ]] || LIVE_CALL_TIMEOUT=6
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
CACHE_DIR="${PROJECT_ROOT}/.chum-cache"
umask 077   # outbox and quarantine files hold raw prompts and tool output (FINDINGS F37 L)
PROJECT_ID="${CHUM_MEM_PROJECT_ID:-}"
if [[ -z "$PROJECT_ID" ]]; then
  echo "session-sync: CHUM_MEM_PROJECT_ID not set, skipping session ingestion" >&2
  exit 0
fi
PROVIDER="$(printf '%s' "${CHUM_PROVIDER:-claude}" | tr '[:upper:]' '[:lower:]')"

mkdir -p "$CACHE_DIR"

# Read hook payload from stdin (not in --flush mode)
HOOK_PAYLOAD=""; HOOK_EVENT=""; AGENT_SESSION_ID="flush"
if [[ "$FLUSH_ONLY" -eq 0 ]]; then
  HOOK_PAYLOAD=$(cat)
  if [[ -z "$HOOK_PAYLOAD" ]]; then
    echo "session-sync: empty stdin payload, nothing to do" >&2
    exit 0
  fi
  HOOK_EVENT=$(echo "$HOOK_PAYLOAD" | jq -r '.hook_event_name // ""')
  AGENT_SESSION_ID=$(echo "$HOOK_PAYLOAD" | jq -r '.session_id // ""')
  if [[ -z "$AGENT_SESSION_ID" || "$AGENT_SESSION_ID" == "null" ]]; then
    echo "session-sync: ERROR missing session_id in hook payload" >&2
    exit 1
  fi
fi

SESSION_STATE_FILE="${CACHE_DIR}/session-${PROVIDER}-${AGENT_SESSION_ID}.json"

# ── Helper: POST session_start ─────────────────────────────────────────────

# ── Outbox: events spooled while the API is slow/down, replayed later ──────
# One file per agent session. Each line is compact JSON:
#   {"kind":"event"|"end","ext":<agent session id>,"start":<session_start payload>,"body":<request>}
# so a replay can (re)create the server session first (session_start is
# idempotent on externalSessionId) and then post the body with the real id.
OUTBOX_DIR="${CACHE_DIR}/outbox"
mkdir -p "$OUTBOX_DIR"
OUTBOX="${OUTBOX_DIR}/${PROVIDER}-${AGENT_SESSION_ID}.jsonl"

session_start_payload() {
  local hostname_val os_val user_email user_name
  hostname_val=$(hostname 2>/dev/null || echo "")
  os_val=$(uname -s 2>/dev/null || echo "")
  # Identity: git email of the checkout (team decision 2026-10-08), falling
  # back to the OS user. Sent as session metadata until the API maps it to
  # app_users.
  user_email=$(git -C "$PROJECT_ROOT" config user.email 2>/dev/null || echo "")
  user_name="${USER:-$(id -un 2>/dev/null || echo "")}"
  jq -c -n \
    --arg projectId "$PROJECT_ID" \
    --arg externalSessionId "$AGENT_SESSION_ID" \
    --arg hostname "$hostname_val" \
    --arg os "$os_val" \
    --arg provider "$PROVIDER" \
    --arg userEmail "$user_email" \
    --arg userName "$user_name" \
    '{
      provider: $provider,
      projectId: $projectId,
      externalSessionId: $externalSessionId,
      metadata: {userEmail: $userEmail, userName: $userName}
    }
    + (
      ({hostname: $hostname, os: $os}
        | with_entries(select(.value != "" and .value != null))) as $l
      | if ($l | length) > 0 then {local: $l} else {} end
    )'
}

# Spool and quarantine files are appended to by parallel hooks: Claude Code runs
# the PostToolUse hooks of parallel tool calls concurrently, and jq writes a long
# line in several write() calls. With a plain `>>`, 3 parallel 20 KB events left
# 2-3 of 3 lines corrupt (review 2, 2026-10-10) and the replayer parks corrupt
# lines for good. Lines are staged in a private file and appended under a mkdir
# lock (portable to bash 3.2, no flock on macOS). A lock older than a minute
# (writer killed at the hook timeout) is broken; after ~10 s of waiting the line
# is appended anyway rather than lost.
lock_file() {  # $1 file -> 0 when its lock is held (1 = gave up waiting)
  local lock="$1.lock" i=0
  while ! mkdir "$lock" 2>/dev/null; do
    i=$((i + 1))
    if [[ $((i % 20)) -eq 0 && -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
      rmdir "$lock" 2>/dev/null || true
    fi
    [[ "$i" -lt 100 ]] || return 1
    sleep 0.1
  done
  return 0
}
unlock_file() { rmdir "$1.lock" 2>/dev/null || true; }
append_line() {  # $1 file; stdin: the line(s) to append
  local f="$1" part="$1.part.$$" rc=0 locked=0
  cat > "$part" || { rm -f "$part"; return 1; }
  if lock_file "$f"; then locked=1; fi
  cat "$part" >> "$f" || rc=$?
  [[ "$locked" -eq 0 ]] || unlock_file "$f"
  rm -f "$part"
  return "$rc"
}

# Large bodies (a tool output can be hundreds of KB) go to jq and curl through
# stdin, never as an argument: argv is capped at 1 MB on macOS and a single
# argument at 128 KB on Linux ("Argument list too long" lost the event).
spool_line() {  # $1 kind (event|end), $2 body json
  printf '%s' "$2" | jq -c --arg kind "$1" --arg ext "$AGENT_SESSION_ID" \
    --argjson start "$(session_start_payload)" --arg api "$API_URL" \
    '{kind:$kind, ext:$ext, api:$api, start:$start, body:.}' | append_line "$OUTBOX"
}

flush_one() {
  local f="$1" tmp="$1.flushing.$$" line kind body start sid code ep api sent=0 total locked=0
  [[ -s "$f" ]] || { rm -f "$f"; return 0; }
  # Take the file under its append lock, so no writer is half-way through a line.
  if lock_file "$f"; then locked=1; fi
  mv "$f" "$tmp" || { [[ "$locked" -eq 0 ]] || unlock_file "$f"; return 0; }
  [[ "$locked" -eq 0 ]] || unlock_file "$f"
  total=$(grep -c . "$tmp" || true)
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
      # A line cut short by a killed writer, or two parallel hooks interleaving
      # their appends, used to kill the replayer here (jq parse error under set -e)
      # and strand every line behind it forever. Park it and carry on.
      printf '%s\n' "$line" >> "$OUTBOX_DIR/corrupt.parked"
      echo "session-sync: WARN outbox $(basename "$f"): skipped a corrupt line (kept in outbox/corrupt.parked)" >&2
      sent=$((sent + 1)); continue
    fi
    kind=$(printf '%s' "$line" | jq -r '.kind // "event"')
    # Lines record the API they were spooled for; older lines fall back to ours.
    api=$(printf '%s' "$line" | jq -r '.api // empty'); api="${api:-$API_URL}"
    start=$(printf '%s' "$line" | jq -c '.start')
    body=$(printf '%s' "$line" | jq -c '.body')
    sid=$(printf '%s' "$start" | curl -sS $AUTH_HEADER --max-time 10 -X POST -H 'Content-Type: application/json' --data-binary @- \
      "${api}/v1/ingest/session/start" 2>/dev/null | jq -r '.sessionId // empty' 2>/dev/null) || sid=""
    [[ -n "$sid" ]] || break
    body=$(printf '%s' "$body" | jq -c --arg sid "$sid" '.sessionId = $sid')
    case "$kind" in end) ep="session/end" ;; *) ep="session/event" ;; esac
    code=$(printf '%s' "$body" | curl -sS $AUTH_HEADER --max-time 15 -o /dev/null -w "%{http_code}" -X POST \
      -H 'Content-Type: application/json' --data-binary @- "${api}/v1/ingest/${ep}" 2>/dev/null) || code="000"
    [[ "$code" == 2* ]] || break
    sent=$((sent + 1))
  done < "$tmp"
  if [[ "$sent" -lt "$total" ]]; then
    # Unsent lines go back in front of anything spooled meanwhile, under the
    # append lock so a line appended between the read and the mv is not lost.
    locked=0; if lock_file "$f"; then locked=1; fi
    { grep . "$tmp" | tail -n +$((sent + 1)); [[ ! -s "$f" ]] || cat "$f"; } > "${f}.new"
    mv "${f}.new" "$f"
    [[ "$locked" -eq 0 ]] || unlock_file "$f"
    echo "session-sync: WARN outbox $(basename "$f"): replayed ${sent}/${total}, rest kept" >&2
    note_replay_failure "$f"
  else
    echo "session-sync: replayed ${sent} spooled lines from $(basename "$f")" >&2
    rm -f "${f%.jsonl}.fails"
  fi
  rm -f "$tmp"
}

# A spool file that keeps failing (its API URL no longer answers, or the server
# rejects the lines) used to be retried on every hook forever, silently. After
# CHUM_SPOOL_MAX_REPLAYS failed replays (default 50) or 7 days since the first
# failure, its lines move to .chum-cache/quarantine/ (marked "stale-spool"),
# where /chum-quarantine list|send|drop handles them, and the user is told once.
note_replay_failure() {  # $1 outbox file
  local f="$1" fails="${1%.jsonl}.fails" n=0 first now
  now=$(date +%s)
  if [[ -f "$fails" ]]; then read -r n first < "$fails" || true; fi
  n=$(( ${n:-0} + 1 )); first="${first:-$now}"
  if [[ "$n" -ge "${CHUM_SPOOL_MAX_REPLAYS:-50}" || $(( now - first )) -ge 604800 ]]; then
    mkdir -p "$QUARANTINE_DIR"
    jq -c --arg at "$(date -u +%FT%TZ)" '. + {matched:"stale-spool", at:$at}' "$f" 2>/dev/null \
      | append_line "$QUARANTINE_DIR/$(basename "$f")" && rm -f "$f" "$fails"
    printf 'chum-mem: spooled events in %s could not be delivered after %s attempts (target %s). They are held in .chum-cache/quarantine/: run /chum-quarantine list, then send or drop.' \
      "$(basename "$f")" "$n" "$(head -n 1 "$QUARANTINE_DIR/$(basename "$f")" | jq -r '.api // "?"' 2>/dev/null)" > "$QUARANTINE_DIR/.notice.global"
    echo "session-sync: WARN outbox $(basename "$f") moved to quarantine after ${n} failed replays" >&2
  else
    printf '%s %s\n' "$n" "$first" > "$fails"
  fi
}

# Sessions whose Claude process died (crash, closed terminal, kill) never send
# Stop/SessionEnd and stay "active" on the server forever. On SessionStart,
# close up to 5 of this checkout's own session-state files older than 12 h.
close_stale_sessions() {
  local st sid n=0 code
  while IFS= read -r st; do
    [[ -n "$st" && "$st" != "$SESSION_STATE_FILE" ]] || continue
    n=$((n + 1)); [[ "$n" -le 5 ]] || break
    sid=$(jq -r '.sessionId // ""' "$st" 2>/dev/null || echo "")
    if [[ -z "$sid" || "$sid" == "null" || "$sid" == "DEFERRED" ]]; then
      rm -f "$st"; continue   # never reached the server; its spooled lines replay on their own
    fi
    code=$(jq -c -n --arg sid "$sid" '{sessionId:$sid, summary:"[session ended without a Stop hook; closed by chum-mem at the next session start]"}' \
      | curl -sS $AUTH_HEADER --max-time 5 -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' \
          --data-binary @- "${API_URL}/v1/ingest/session/end" 2>/dev/null) || code="000"
    case "$code" in 2*|404) rm -f "$st"; echo "session-sync: closed stale session $sid" >&2 ;; esac
  done < <(find "$CACHE_DIR" -maxdepth 1 -name "session-${PROVIDER}-*.json" -mmin +720 2>/dev/null)
  return 0
}

# ── Sensitive-content guard ──────────────────────────────────────────────────
# Every event is scanned against scripts/sensitive-patterns.txt plus the repo's
# optional .chum-sensitive-patterns. A match is HELD in .chum-cache/quarantine/
# (same line format as the outbox) and a notice is left for hook-dispatch to show
# the user. Nothing held is ever sent unless chum-quarantine.sh releases it.
# CHUM_SENSITIVE_GUARD=0 disables the scan (not recommended).
SCRIPTS_DIR_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUARANTINE_DIR="${CACHE_DIR}/quarantine"
scan_sensitive() {  # $1 text -> prints matched rule names; exit 0 when any matched
  [[ "${CHUM_SENSITIVE_GUARD:-1}" == "1" ]] || return 1
  local text="$1" name flags re hits=""
  while IFS='|' read -r name flags re; do
    [[ -z "$name" || "$name" == \#* || -z "$re" ]] && continue
    if [[ "$flags" == *i* ]]; then
      printf '%s' "$text" | grep -Eiq -- "$re" 2>/dev/null && hits="${hits:+$hits,}$name"
    else
      printf '%s' "$text" | grep -Eq -- "$re" 2>/dev/null && hits="${hits:+$hits,}$name"
    fi
  done < <(cat "$SCRIPTS_DIR_SELF/sensitive-patterns.txt" "${PROJECT_ROOT:-$PWD}/.chum-sensitive-patterns" 2>/dev/null)
  [[ -n "$hits" ]] || return 1
  printf '%s' "$hits"
}
quarantine_line() {  # $1 kind (event|end), $2 body json, $3 matched names, $4 where (prompt|tool output|reply)
  mkdir -p "$QUARANTINE_DIR"
  printf '%s' "$2" | jq -c --arg kind "$1" --arg ext "$AGENT_SESSION_ID" --arg api "$API_URL" --arg matched "$3" \
    --arg at "$(date -u +%FT%TZ)" --argjson start "$(session_start_payload)" \
    '{kind:$kind, ext:$ext, api:$api, matched:$matched, at:$at, start:$start, body:.}' \
    | append_line "$QUARANTINE_DIR/${PROVIDER}-${AGENT_SESSION_ID}.jsonl"
  # The notice is per agent session: with parallel sessions in one checkout a
  # shared file would surface session A's warning in session B's terminal.
  printf 'chum-mem: NOT sent to team memory — secret-shaped content (%s) found in your %s. It is held locally in .chum-cache/quarantine/. Run /chum-quarantine list to review, send to store it anyway, drop to discard. Held items are never sent on their own.' \
    "$3" "$4" > "$QUARANTINE_DIR/.notice.${AGENT_SESSION_ID}"
  echo "session-sync: held $1 from $4 (matched: $3)" >&2
}

# Replay every spooled file for this project (all sessions), oldest first.
# Runs in a DETACHED process (see spawn_flush): replays take ~1.5 s per line
# over a tunnel and must not be killed by the hook's 10-60 s timeout.
flush_outbox() {
  local f
  # Recover files a killed replay left behind (they still hold every unsent line).
  for f in "$OUTBOX_DIR"/*.flushing.*; do
    [[ -e "$f" ]] || continue
    if [[ -n "$(find "$f" -mmin +2 2>/dev/null)" ]]; then
      cat "$f" >> "${f%%.flushing.*}" && rm -f "$f"
    fi
  done
  for f in "$OUTBOX_DIR"/*.jsonl; do
    [[ -e "$f" ]] || continue
    flush_one "$f"
  done
}

# Start one detached replayer if there is anything to replay and none is running.
spawn_flush() {
  local lock="$OUTBOX_DIR/.flush.lock" n f
  # Counted in the shell: `ls glob glob | wc -l` returns non-zero when a glob has
  # no match, and under `set -e` that silently ended the whole script before the
  # event was posted (found 2026-10-09: every hook lost once the outbox was clean).
  n=0
  for f in "$OUTBOX_DIR"/*.jsonl "$OUTBOX_DIR"/*.flushing.*; do [[ -e "$f" ]] && n=$((n + 1)); done
  [[ "$n" -gt 0 ]] || return 0
  if [[ -d "$lock" ]]; then
    # stale lock (replayer died) after 15 minutes
    [[ -n "$(find "$lock" -mmin +15 2>/dev/null)" ]] && rmdir "$lock" 2>/dev/null || return 0
  fi
  mkdir "$lock" 2>/dev/null || return 0
  ( nohup bash "$0" --flush >> "$OUTBOX_DIR/flush.log" 2>&1; rmdir "$lock" 2>/dev/null ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

ensure_session_started() {
  if [[ -f "$SESSION_STATE_FILE" ]]; then
    return 0
  fi
  if [[ "${CHUM_SPOOL_ONLY:-0}" == "1" ]]; then
    # API is down: no server session id yet. The replay creates it.
    printf '{"sessionId":"DEFERRED","deferredStart":true}\n' > "$SESSION_STATE_FILE"
    return 0
  fi

  local payload
  payload=$(session_start_payload)

  local response http_code
  response=$(curl -sS $AUTH_HEADER --max-time "$LIVE_CALL_TIMEOUT" \
    -o /tmp/chum-session-start-resp.$$.json \
    -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${API_URL}/v1/ingest/session/start" 2>&1) || {
    # Health passed but the call timed out or the connection dropped (busy API,
    # tunnel flap). Spool this event instead of losing it: the replay creates
    # the session later, exactly as when the health gate trips.
    echo "session-sync: WARN session_start failed — API unreachable at ${API_URL}; spooling: $response" >&2
    rm -f /tmp/chum-session-start-resp.$$.json
    CHUM_SPOOL_ONLY=1
    printf '{"sessionId":"DEFERRED","deferredStart":true}\n' > "$SESSION_STATE_FILE"
    return 0
  }

  http_code="$response"
  if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
    local body
    body=$(cat /tmp/chum-session-start-resp.$$.json 2>/dev/null || echo "")
    rm -f /tmp/chum-session-start-resp.$$.json
    if spoolable_code "$http_code" "session_start"; then
      CHUM_SPOOL_ONLY=1
      printf '{"sessionId":"DEFERRED","deferredStart":true}\n' > "$SESSION_STATE_FILE"
      return 0
    fi
    echo "session-sync: ERROR session_start returned HTTP ${http_code}: ${body}" >&2
    exit 1
  fi

  mv /tmp/chum-session-start-resp.$$.json "$SESSION_STATE_FILE"
}

# A transient server answer must not lose the event. 5xx (database restarting,
# pool exhausted), 429 and 408 used to `exit 1` here and the prompt/tool
# output/reply was gone (review 2: a 503 on session/event dropped the prompt and
# the reply, and the Stop hook died before session/end). A 401/403 (token not
# set up yet, or rotated) is spooled too, so the turn replays once the token is
# fixed; it is still reported as an ERROR at the end so the user sees the notice.
AUTH_FAILED_CODE=""
spoolable_code() {  # $1 http code, $2 call name -> 0 when the caller should spool
  case "$1" in
    5??|429|408)
      echo "session-sync: WARN $2 returned HTTP $1 — server busy or restarting; spooling" >&2
      return 0 ;;
    401|403)
      echo "session-sync: WARN $2 returned HTTP $1 — token rejected; spooling until it is fixed" >&2
      AUTH_FAILED_CODE="$1"
      return 0 ;;
  esac
  return 1
}

# ── Helper: POST session_event_append ──────────────────────────────────────

post_event() {
  local event_type="$1"
  local payload_json="$2"

  ensure_session_started

  local chum_session_id
  chum_session_id=$(jq -r '.sessionId // ""' "$SESSION_STATE_FILE")

  if [[ -z "$chum_session_id" || "$chum_session_id" == "null" || "$chum_session_id" == "DEFERRED" ]]; then
    if [[ "${CHUM_SPOOL_ONLY:-0}" == "1" ]]; then
      chum_session_id="DEFERRED"
    else
      rm -f "$SESSION_STATE_FILE"
      ensure_session_started
      chum_session_id=$(jq -r '.sessionId // ""' "$SESSION_STATE_FILE")
      if [[ -z "$chum_session_id" || "$chum_session_id" == "null" ]]; then
        echo "session-sync: ERROR no sessionId in ${SESSION_STATE_FILE}" >&2
        exit 1
      fi
    fi
  fi

  local event_id event_time idempotency_key
  # No python3 here: two interpreter spawns per event were a visible share of hook
  # latency under load (overnight D7). uuidgen + perl ship with macOS and Debian.
  event_id=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]') || event_id=""
  [[ -n "$event_id" ]] || event_id=$(python3 -c 'import uuid; print(uuid.uuid4())')
  event_time=$(perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%03dZ", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1000' 2>/dev/null) || event_time=""
  [[ -n "$event_time" ]] || event_time=$(date -u +%FT%T.000Z)
  idempotency_key=$(printf '%s|%s|%s' "$chum_session_id" "$event_type" "$event_id" | shasum -a 256 | cut -d' ' -f1)

  # The two JSON documents are handed to jq as files, not --argjson arguments:
  # a 1 MB tool output made jq fail with "Argument list too long" (argv cap
  # 1 MB on macOS, 128 KB per argument on Linux) and the event was lost.
  local full_payload tmp_p="/tmp/chum-session-payload-resp.$$.json" tmp_r="/tmp/chum-session-raw-resp.$$.json"
  printf '%s' "$payload_json" > "$tmp_p"
  printf '%s' "$HOOK_PAYLOAD" > "$tmp_r"
  full_payload=$(jq -c -n \
    --arg sessionId "$chum_session_id" \
    --arg eventId "$event_id" \
    --arg idempotencyKey "$idempotency_key" \
    --arg eventType "$event_type" \
    --arg eventTime "$event_time" \
    --arg provider "$PROVIDER" \
    --slurpfile payload "$tmp_p" \
    --slurpfile rawPayload "$tmp_r" \
    '{
      sessionId: $sessionId,
      eventId: $eventId,
      idempotencyKey: $idempotencyKey,
      provider: $provider,
      eventType: $eventType,
      eventTime: $eventTime,
      payload: $payload[0],
      rawPayload: $rawPayload[0]
    }')
  rm -f "$tmp_p" "$tmp_r"

  local http_code matched where
  if matched=$(scan_sensitive "$full_payload"); then
    case "$event_type" in prompt) where="prompt" ;; response) where="reply" ;; *) where="tool input/output" ;; esac
    quarantine_line event "$full_payload" "$matched" "$where"
    return 0
  fi
  if [[ "${CHUM_SPOOL_ONLY:-0}" == "1" ]]; then
    spool_line event "$full_payload"
    return 0
  fi
  http_code=$(printf '%s' "$full_payload" | curl -sS $AUTH_HEADER --max-time "$LIVE_CALL_TIMEOUT" \
    -o /tmp/chum-session-event-resp.$$.json \
    -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "${API_URL}/v1/ingest/session/event" 2>&1) || {
    echo "session-sync: WARN session_event_append failed — API unreachable at ${API_URL}; spooling" >&2
    rm -f /tmp/chum-session-event-resp.$$.json
    spool_line event "$full_payload"
    # The rest of this run (the Stop hook's session/end) spools at once instead
    # of waiting out another timeout and getting the hook killed.
    CHUM_SPOOL_ONLY=1
    return 0
  }

  if [[ "$http_code" != "200" && "$http_code" != "201" && "$http_code" != "202" ]]; then
    local body
    body=$(cat /tmp/chum-session-event-resp.$$.json 2>/dev/null || echo "")
    rm -f /tmp/chum-session-event-resp.$$.json
    if spoolable_code "$http_code" "session_event_append"; then
      spool_line event "$full_payload"
      return 0
    fi
    echo "session-sync: ERROR session_event_append returned HTTP ${http_code}: ${body}" >&2
    exit 1
  fi
  rm -f /tmp/chum-session-event-resp.$$.json
}

# ── Helper: POST session_end ───────────────────────────────────────────────

end_session() {
  if [[ ! -f "$SESSION_STATE_FILE" ]]; then
    return 0
  fi

  local chum_session_id
  chum_session_id=$(jq -r '.sessionId // ""' "$SESSION_STATE_FILE")

  local summary_text matched
  summary_text=$(echo "$HOOK_PAYLOAD" | jq -r '.last_assistant_message // ""')
  if matched=$(scan_sensitive "$summary_text"); then
    # The session must still close; only the summary text is held.
    quarantine_line end "$(jq -c -n --arg summary "$summary_text" '{sessionId: "DEFERRED", summary: $summary}')" "$matched" "reply"
    summary_text="[summary held back by the chum-mem sensitive-content guard]"
  fi

  if [[ "${CHUM_SPOOL_ONLY:-0}" == "1" ]]; then
    spool_line end "$(jq -c -n --arg summary "$summary_text" '{sessionId: "DEFERRED", summary: $summary}')"
    rm -f "$SESSION_STATE_FILE"
    return 0
  fi

  if [[ -z "$chum_session_id" || "$chum_session_id" == "null" || "$chum_session_id" == "DEFERRED" ]]; then
    rm -f "$SESSION_STATE_FILE"
    ensure_session_started
    if [[ "${CHUM_SPOOL_ONLY:-0}" == "1" ]]; then  # session_start just failed: spool the end too
      spool_line end "$(jq -c -n --arg summary "$summary_text" '{sessionId: "DEFERRED", summary: $summary}')"
      rm -f "$SESSION_STATE_FILE"; return 0
    fi
    chum_session_id=$(jq -r '.sessionId // ""' "$SESSION_STATE_FILE")
    [[ -n "$chum_session_id" && "$chum_session_id" != "null" ]] || { rm -f "$SESSION_STATE_FILE"; return 0; }
  fi

  local payload
  payload=$(jq -c -n \
    --arg sessionId "$chum_session_id" \
    --arg summary "$summary_text" \
    '{sessionId: $sessionId, summary: $summary}')

  local http_code
  # 20 s, under the Stop/SessionEnd hook timeout (30 s) so a hung API spools
  # the end instead of the hook being killed with it in flight.
  http_code=$(curl -sS $AUTH_HEADER --max-time 20 \
    -o /tmp/chum-session-end-resp.$$.json \
    -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${API_URL}/v1/ingest/session/end" 2>&1) || {
    echo "session-sync: WARN session_end failed — API unreachable at ${API_URL}; spooling" >&2
    rm -f /tmp/chum-session-end-resp.$$.json
    spool_line end "$payload"
    rm -f "$SESSION_STATE_FILE"
    return 0
  }

  if [[ "$http_code" != "200" && "$http_code" != "201" && "$http_code" != "202" ]]; then
    local body
    body=$(cat /tmp/chum-session-end-resp.$$.json 2>/dev/null || echo "")
    rm -f /tmp/chum-session-end-resp.$$.json
    if spoolable_code "$http_code" "session_end"; then
      spool_line end "$payload"
      rm -f "$SESSION_STATE_FILE"
      return 0
    fi
    echo "session-sync: ERROR session_end returned HTTP ${http_code}: ${body}" >&2
    exit 1
  fi
  rm -f /tmp/chum-session-end-resp.$$.json
  rm -f "$SESSION_STATE_FILE"
}

# ── Dispatch by hook event ─────────────────────────────────────────────────

# Payload schema required by the API (see SessionEventPayload in
# rust/crates/chum_mem_contracts/src/lib.rs):
#   { message, toolName, command, exitCode, filePath, diffStat, metadata }
# Unknown fields are silently dropped by the server's JSON deserializer —
# anything extra must go inside `metadata` to survive round-trip.

if [[ "$FLUSH_ONLY" -eq 1 ]]; then
  flush_outbox
  exit 0
fi
if [[ "${CHUM_SPOOL_ONLY:-0}" != "1" ]]; then
  spawn_flush
fi

case "$HOOK_EVENT" in
  SessionStart)
    [[ "${CHUM_SPOOL_ONLY:-0}" == "1" ]] || close_stale_sessions
    ensure_session_started
    ;;
  UserPromptSubmit)
    prompt_payload=$(echo "$HOOK_PAYLOAD" | jq -c '{
      message: (.prompt // ""),
      metadata: {source: "UserPromptSubmit"}
    }')
    post_event "prompt" "$prompt_payload"
    ;;
  PreToolUse)
    tool_payload=$(echo "$HOOK_PAYLOAD" | jq -c '{
      toolName: (.tool_name // ""),
      message: (.tool_name // ""),
      metadata: {
        toolUseId: (.tool_use_id // ""),
        input: (.tool_input // {})
      }
    }')
    post_event "tool_call" "$tool_payload"
    ;;
  PostToolUse)
    tool_payload=$(echo "$HOOK_PAYLOAD" | jq -c '{
      toolName: (.tool_name // ""),
      message: (.tool_name // ""),
      filePath: (.tool_input.file_path // .tool_input.path // null),
      command: (.tool_input.command // null),
      metadata: {
        toolUseId: (.tool_use_id // ""),
        input: (.tool_input // {}),
        output: (.tool_response // null)
      }
    }')
    post_event "tool_result" "$tool_payload"
    ;;
  Notification)
    notif_payload=$(echo "$HOOK_PAYLOAD" | jq -c '{
      message: (.message // ""),
      metadata: {
        title: (.title // ""),
        notificationType: (.notification_type // "")
      }
    }')
    post_event "annotation" "$notif_payload"
    ;;
  PreCompact)
    compact_payload=$(echo "$HOOK_PAYLOAD" | jq -c '{
      message: (.trigger // "precompact"),
      metadata: {
        trigger: (.trigger // ""),
        customInstructions: (.custom_instructions // "")
      }
    }')
    post_event "summary" "$compact_payload"
    ;;
  SubagentStop)
    subagent_payload=$(echo "$HOOK_PAYLOAD" | jq -c '{
      message: (.last_assistant_message // "subagent stopped"),
      metadata: {
        agentId: (.agent_id // ""),
        agentType: (.agent_type // ""),
        lastAssistantMessage: (.last_assistant_message // "")
      }
    }')
    post_event "summary" "$subagent_payload"
    ;;
  Stop)
    stop_payload=$(echo "$HOOK_PAYLOAD" | jq -c '{
      message: (.last_assistant_message // ""),
      metadata: {source: "Stop"}
    }')
    post_event "response" "$stop_payload"
    end_session
    ;;
  SessionEnd)
    end_session
    ;;
  *)
    echo "session-sync: unknown hook event '${HOOK_EVENT}', skipping" >&2
    ;;
esac

# A rejected token spooled the turn above; still fail so hook-dispatch shows the
# "NOT being captured ... HTTP 401 = run install-tunnel-agent.sh token" notice.
if [[ -n "$AUTH_FAILED_CODE" ]]; then
  echo "session-sync: ERROR HTTP ${AUTH_FAILED_CODE} from ${API_URL} (token missing or wrong); this turn is spooled in .chum-cache/outbox/ and replays once the token works" >&2
  exit 1
fi
exit 0
