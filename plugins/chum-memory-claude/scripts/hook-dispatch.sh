#!/usr/bin/env bash
# hook-dispatch.sh — unified hook wrapper for chum-memory across Claude Code
# and Codex. Reads the hook payload once from stdin, runs session-sync.sh
# with it, then runs sync.sh (repository layer) for turn-boundary events
# only, and finally emits the provider-appropriate control JSON.
#
# Provider is selected by CHUM_PROVIDER (default "claude"). The same scripts
# work for both hosts because the Claude Code and Codex hook payloads share
# the same top-level shape (session_id, hook_event_name, cwd, prompt,
# tool_name/tool_input/tool_response).
#
# Scripts location is resolved from:
#   1. CHUM_SCRIPTS_DIR env var (set by the Codex installer)
#   2. CLAUDE_PLUGIN_ROOT/scripts (set by Claude Code)
#   3. dirname $0 (fallback — works when called with an absolute path)

set -uo pipefail
# Hook timing is opt-in (CHUM_HOOK_TIMING_LOG). Milliseconds come from bash 5's
# $EPOCHREALTIME when present, else perl (ships with macOS); never python3 — two
# interpreter spawns per hook were a measurable share of hook latency under load.
__TLOG="${CHUM_HOOK_TIMING_LOG:-}"
__now_ms(){ if [[ -n "${EPOCHREALTIME:-}" ]]; then printf '%s' "${EPOCHREALTIME/./}" | cut -c1-13; else perl -MTime::HiRes=time -e 'printf "%d", time()*1000'; fi; }
__T0=0; [[ -n "$__TLOG" ]] && __T0=$(__now_ms)
__tlog(){ [[ -n "$__TLOG" ]] && printf "%s\t%s\t%s\t%s\n" "$(date -u +%FT%TZ)" "${HOOK_EVENT:-?}" "$1" "$(( $(__now_ms) - __T0 ))" >> "$__TLOG"; }

PROVIDER="$(printf '%s' "${CHUM_PROVIDER:-claude}" | tr '[:upper:]' '[:lower:]')"

# Resolve scripts directory
if [[ -n "${CHUM_SCRIPTS_DIR:-}" ]]; then
  SCRIPTS_DIR="$CHUM_SCRIPTS_DIR"
elif [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  SCRIPTS_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
else
  SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# Read the full hook payload from stdin once
HOOK_PAYLOAD=$(cat)

# Extract hook event name and (Codex) cwd fallback
HOOK_EVENT=$(echo "$HOOK_PAYLOAD" | jq -r '.hook_event_name // ""' 2>/dev/null || echo "")
PAYLOAD_CWD=$(echo "$HOOK_PAYLOAD" | jq -r '.cwd // ""' 2>/dev/null || echo "")

# Resolve project dir: prefer Claude env var, else payload cwd, else $PWD
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  PROJECT_DIR="$CLAUDE_PROJECT_DIR"
elif [[ -n "$PAYLOAD_CWD" && "$PAYLOAD_CWD" != "null" ]]; then
  PROJECT_DIR="$PAYLOAD_CWD"
else
  PROJECT_DIR="$PWD"
fi
export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
export CHUM_PROVIDER="$PROVIDER"

# ── Health gate — if the API is slow or down, DO NOT drop the event: run the
# session layer in spool mode (events go to .chum-cache/outbox.jsonl and are
# flushed on a later hook), skip the repository layer, and tell the model.
# Server URL: env wins; else the committed .chum-mem "apiUrl"; else localhost.
API_URL="${CHUM_MEMORY_API_URL:-}"
if [[ -z "$API_URL" && -f "${PROJECT_DIR}/.chum-mem" ]]; then
  API_URL=$(jq -r '.apiUrl // empty' "${PROJECT_DIR}/.chum-mem" 2>/dev/null || true)
fi
API_URL="${API_URL:-http://localhost:63001}"
export CHUM_MEMORY_API_URL="$API_URL"
# ── API token (optional): sent as X-Chum-Token on every call. Single-word
# header so it can be expanded unquoted under bash 3.2 with `set -u`.
AUTH_HEADER=""
# Token: env var first, else the file the installer writes (~/.config/chum-mem/token).
if [[ -z "${CHUM_MEMORY_API_TOKEN:-}" && -r "${HOME}/.config/chum-mem/token" ]]; then
  CHUM_MEMORY_API_TOKEN="$(tr -d '[:space:]' < "${HOME}/.config/chum-mem/token")"; export CHUM_MEMORY_API_TOKEN
fi
if [[ -n "${CHUM_MEMORY_API_TOKEN:-}" ]]; then AUTH_HEADER="-HX-Chum-Token:${CHUM_MEMORY_API_TOKEN}"; fi
API_HEALTHY=1
# Health gate. The default budget is 5 s (was 2 s): through the IAP tunnel a
# healthy API answers in ~0.5 s idle but 1-2 s when several sessions share the
# tunnel, and a tripped gate spools the whole turn (nothing is sent live). Order:
# env CHUM_HEALTH_TIMEOUT_SECS, then .chum-mem "healthTimeoutSecs", then 5.
HEALTH_TIMEOUT="${CHUM_HEALTH_TIMEOUT_SECS:-}"
if [[ -z "$HEALTH_TIMEOUT" && -f "${PROJECT_DIR}/.chum-mem" ]]; then
  HEALTH_TIMEOUT="$(jq -r '.healthTimeoutSecs // empty' "${PROJECT_DIR}/.chum-mem" 2>/dev/null || true)"
fi
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-5}"
if ! curl -sf $AUTH_HEADER --max-time "$HEALTH_TIMEOUT" "${API_URL}/health" >/dev/null 2>&1; then
  API_HEALTHY=0
fi
export CHUM_API_HEALTHY="$API_HEALTHY"
if [[ "$API_HEALTHY" -eq 0 ]]; then
  UNAVAIL_MSG="ChumMemory API unreachable at ${API_URL} — memory retrieval unavailable this turn; session events are being spooled locally and will sync later."
  if [[ -x "${SCRIPTS_DIR}/session-sync.sh" ]]; then
    CHUM_MEM_FILE_PRE="${PROJECT_DIR}/.chum-mem"
    if [[ -f "$CHUM_MEM_FILE_PRE" ]]; then
      export CHUM_MEM_PROJECT_ID="$(jq -r '.projectId // ""' "$CHUM_MEM_FILE_PRE" 2>/dev/null || echo "")"
    fi
    printf '%s' "$HOOK_PAYLOAD" | CHUM_SPOOL_ONLY=1 bash "${SCRIPTS_DIR}/session-sync.sh" >/dev/null 2>&1 || true
  fi
  __tlog spooled 2>/dev/null || true
  # Only the two turn-start events may add context. Emitting additionalContext on
  # Stop/SessionEnd makes Claude Code continue the conversation until --max-turns
  # (observed overnight: 8 looped sessions, ~$1.1 each) — so stay silent there.
  case "$HOOK_EVENT" in
    SessionStart|UserPromptSubmit)
      case "$PROVIDER" in
        codex) printf '{"systemMessage":"%s"}\n' "$UNAVAIL_MSG" ;;
        *)     printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$HOOK_EVENT" "$UNAVAIL_MSG" ;;
      esac ;;
  esac
  exit 0
fi

# ── Resolve project identity (.chum-mem) ──
CHUM_MEM_FILE="${PROJECT_DIR}/.chum-mem"
CHUM_MEM_EXISTED=0
if [[ -f "$CHUM_MEM_FILE" ]]; then
  CHUM_MEM_EXISTED=1
  # Retry: a concurrent hook may be mid-write (observed fork race: 11/75 reads empty).
  for _try in 1 2 3 4 5 6 7 8; do
    RESOLVED_PROJECT_ID=$(jq -r '.projectId // ""' "$CHUM_MEM_FILE" 2>/dev/null || echo "")
    [[ -n "$RESOLVED_PROJECT_ID" && "$RESOLVED_PROJECT_ID" != "null" ]] && break
    sleep 0.2
  done
  if [[ -z "${RESOLVED_PROJECT_ID:-}" || "$RESOLVED_PROJECT_ID" == "null" ]]; then
    # Existing file but unreadable: never mint a new id over a committed one.
    echo "chum-memory: .chum-mem present but unreadable; skipping this event" >&2
    exit 0
  fi
fi
if [[ -n "${RESOLVED_PROJECT_ID:-}" && "$RESOLVED_PROJECT_ID" != "null" ]]; then
  CANDIDATE_PROJECT_ID="$RESOLVED_PROJECT_ID"
elif [[ -n "${CHUM_MEM_PROJECT_ID:-}" ]]; then
  CANDIDATE_PROJECT_ID="$CHUM_MEM_PROJECT_ID"
else
  # Auto-register project via API using a local project id, not a git remote.
  if command -v uuidgen >/dev/null 2>&1; then
    CANDIDATE_PROJECT_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
  else
    CANDIDATE_PROJECT_ID=$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)
  fi
fi
PROJECT_NAME=$(basename "$PROJECT_DIR")
RESOLVE_PAYLOAD=$(jq -n --arg projectId "$CANDIDATE_PROJECT_ID" --arg name "$PROJECT_NAME" \
  '{projectId: $projectId, name: $name}')
RESOLVE_RESP=$(curl -sf $AUTH_HEADER --max-time 5 -X POST -H "Content-Type: application/json" \
  -d "$RESOLVE_PAYLOAD" "${API_URL}/v1/projects/resolve" 2>/dev/null) || RESOLVE_RESP=""
if [[ -n "$RESOLVE_RESP" ]]; then
  RESOLVED_PROJECT_ID=$(echo "$RESOLVE_RESP" | jq -r '.projectId // ""' 2>/dev/null || echo "")
  if [[ -n "$RESOLVED_PROJECT_ID" && "$RESOLVED_PROJECT_ID" != "null" && "$CHUM_MEM_EXISTED" -eq 0 ]]; then
    # First registration only; atomic so a concurrent reader never sees a partial file.
    echo "$RESOLVE_RESP" | jq '{projectId: .projectId, name: .name}' > "${CHUM_MEM_FILE}.tmp.$$" 2>/dev/null \
      && mv -f "${CHUM_MEM_FILE}.tmp.$$" "$CHUM_MEM_FILE" || rm -f "${CHUM_MEM_FILE}.tmp.$$"
  fi
fi
export CHUM_MEM_PROJECT_ID="${RESOLVED_PROJECT_ID:-${CHUM_MEM_PROJECT_ID:-}}"

# ── Ensure .mcp.json carries the project ID in the URL for Claude Code ──
# Claude Code's HTTP MCP transport uses the URL from .mcp.json. The env var
# expansion in headers may not have access to CHUM_MEM_PROJECT_ID (set in hook
# subprocess, not parent). Embedding it in the URL guarantees delivery.
if [[ -n "${CHUM_MEM_PROJECT_ID:-}" ]]; then
  MCP_JSON_PATH="${SCRIPTS_DIR}/../.mcp.json"
  MCP_URL_WITH_PROJECT="${API_URL}/mcp?projectId=${CHUM_MEM_PROJECT_ID}"
  if [[ -f "$MCP_JSON_PATH" ]]; then
    CURRENT_URL=$(jq -r '.mcpServers["chum-memory"].url // ""' "$MCP_JSON_PATH" 2>/dev/null || echo "")
    if [[ "$CURRENT_URL" != "$MCP_URL_WITH_PROJECT" ]]; then
      jq --arg url "$MCP_URL_WITH_PROJECT" \
        '.mcpServers["chum-memory"].url = $url' "$MCP_JSON_PATH" > "${MCP_JSON_PATH}.tmp" \
        && mv "${MCP_JSON_PATH}.tmp" "$MCP_JSON_PATH"
    fi
  fi
fi

# ── Session layer (always runs for every event) ──
SESSION_STDERR=""
if [[ -x "${SCRIPTS_DIR}/session-sync.sh" ]]; then
  SESSION_STDERR=$(printf '%s' "$HOOK_PAYLOAD" | bash "${SCRIPTS_DIR}/session-sync.sh" 2>&1 >/dev/null) || {
    echo "chum-memory session-sync error: ${SESSION_STDERR}" >&2
  }
fi

__tlog session_layer
# A held (quarantined) event leaves a notice; show it to the user once.
SYSTEM_MSG=""
QNOTICE="${PROJECT_DIR}/.chum-cache/quarantine/.notice"
if [[ -f "$QNOTICE" ]]; then
  SYSTEM_MSG=$(jq -Rs '.' < "$QNOTICE" 2>/dev/null | sed 's/^"//;s/"$//'); rm -f "$QNOTICE"
fi
# ── Repository layer (only on turn-boundary events) ──
case "$HOOK_EVENT" in
  UserPromptSubmit|SessionStart)
    if [[ -x "${SCRIPTS_DIR}/sync.sh" ]]; then
      bash "${SCRIPTS_DIR}/sync.sh" "$PROJECT_DIR" >/dev/null 2>&1 || true
    fi
    ;;
esac

__tlog repo_layer
# ── Emit provider-appropriate control JSON ──
emit_claude() {
  local event="$1" message="$2"
  if [[ -n "${SYSTEM_MSG:-}" ]]; then
    printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$SYSTEM_MSG" "$event" "$message"
  else
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$event" "$message"
  fi
}

emit_codex() {
  # Codex reads `systemMessage` from stdout JSON. Keep it short so it isn't
  # injected verbatim into every turn.
  local message="$1"
  [[ -n "${SYSTEM_MSG:-}" ]] && message="${SYSTEM_MSG}\\n${message}"
  printf '{"systemMessage":"%s"}\n' "$message"
}

USER_PROMPT_MSG="ChumMemory is active. Relevant team memory for this prompt (if any) is appended below: ALWAYS read it before answering and attribute what you use. For deeper recall call mem_search; for code structure call knowledge_query(layer:repository). Original retrieval order for any code-navigation or recall step: FIRST call MCP knowledge_report(layer:unified) and treat its compact markdown as primary high-level context; SECOND call repository-layer knowledge_query for architecture/components/relationships; THIRD call mem_search(mode:hybrid, disclosureLevel:overview, small limit); ONLY THEN Read/Grep/Glob/Edit. Before editing a file, call knowledge_query(neighbors, nodeId:'file:<path>', layer:repository) after the prelude. Grep/Glob is fallback only. Three-way hybrid search: lexical + pgvector + Chroma ML. Unified reports include repository digest, session communities, and cross-layer summary. Load the ChumMemory skill for the full cookbook if unsure."
SESSION_START_BASE="ChumMemory plugin active (PCKC v2.2.3, MCP server: chum-memory). Multi-project mode: each project folder has its own project ID (auto-resolved via .chum-mem). Repository layer (knowledge_query, knowledge_communities, layer-specific knowledge_report) is STRICTLY per-project — projectId is required, no global fallback. Unified knowledge_report keeps repository strict and uses session-layer global fallback for continuity signals. Session layer knowledge queries fall back to global project if no project-specific snapshot exists. mem_search falls back to global project for historical memories. The hook auto-runs repository_sync before every turn — do NOT call project_import or repository_sync manually. On every code-related prompt use this strict order: MCP knowledge_report(layer:unified) first; repository-layer knowledge_query second; mem_search third; Read/Grep/Glob/Edit last. Two layers: repository (code structure, AST) and session (interaction history); unified is report-only. Always pass layer. Three-way hybrid search (lexical + pgvector + Chroma). Typed partitions for per-type precision. Hierarchical communities (level-0 + level-1). Governance: use claim_govern to pin/archive/reject claims. Load the ChumMemory skill for the full cookbook and decision tree."


# ── Automatic recall: search memory for the prompt itself and inject the top
# hits, so retrieval does not depend on the model deciding to call a tool or on
# how the user phrases the question. One REST call, bounded output.
fetch_prompt_memory_escaped() {
  local api_url="${CHUM_MEMORY_API_URL:-http://localhost:63001}"
  local prompt limit body resp md
  prompt=$(echo "$HOOK_PAYLOAD" | jq -r '.prompt // ""' 2>/dev/null)
  # skip trivial prompts (slash commands, one-word replies)
  [[ ${#prompt} -ge 12 && "$prompt" != /* ]] || return 1
  limit="${CHUM_AUTO_RECALL_LIMIT:-5}"
  # Ask for a wider candidate pool than we show: the server's lexical path orders
  # partial matches by recency inside its LIMIT, so a 5-row request can miss a
  # relevant memory that is a few minutes older than unrelated chatter.
  local pool; pool="${CHUM_AUTO_RECALL_POOL:-20}"
  body=$(jq -n --arg q "${prompt:0:800}" --arg pid "${CHUM_MEM_PROJECT_ID:-}" --argjson n "$pool"     '{query:$q, mode:"hybrid", limit:$n, disclosureLevel:"overview"} + (if $pid != "" then {projectId:$pid} else {} end)')
  resp=$(curl -sf $AUTH_HEADER --max-time "${CHUM_AUTO_RECALL_TIMEOUT_SECS:-6}" -X POST -H 'Content-Type: application/json'     -d "$body" "${api_url}/api/search" 2>/dev/null) || return 1
  local pfx
  pfx=$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]' | cut -c1-60)
  # Content words of the prompt (>= 4 chars, lowercase) for the overlap check below.
  local words
  # Generic words carry no topic and are dropped before the overlap test.
  local stop='^(about|after|again|also|always|anyone|anything|around|because|been|before|being|both|could|does|doing|done|each|either|else|even|ever|every|files?|find|first|from|give|have|here|into|just|know|last|like|lines?|look|make|more|most|much|must|need|never|next|only|other|over|please|read|really|same|should|since|some|still|such|sure|take|tell|than|that|their|them|then|there|these|they|thing|think|this|those|through|under|until|very|want|were|what|when|where|whether|which|while|will|with|without|would|your)$'
  words=$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '\n' | awk -v stop="$stop" 'length($0) >= 4 && $0 !~ stop' | sort -u | tr '\n' ' ')
  md=$(printf '%s' "$resp" | jq -r --arg gate "${CHUM_AUTO_RECALL_MIN_SEMANTIC:-0.7}" --arg pfx "$pfx" --arg words "$words" --arg limit "$limit" '
    ($words | split(" ") | map(select(length > 0))) as $w |
    [.hits[]? | select(.verificationStatus != "contradicted")
       # Relevance gate: the ranker has no floor, so without this the block is just the
       # newest memories in the store (observed overnight: 0/32 relevant under load).
       # Three ways in: semantic score, a full lexical match, or plain word overlap with
       # the prompt (a memory minutes old has no embedding yet on a worker-indexed
       # store, and a partial lexical match reports 0.0 — both would otherwise be hidden).
       | (((.title // "") + " " + (.summary // "") + " " + (.content // "")) | ascii_downcase) as $text
       | ([$w[] | select(. as $x | $text | contains($x))] | length) as $overlap
       | select((((.semanticScore // 0) >= ($gate | tonumber)) and ($overlap >= 1 or ($w | length) == 0))
                or (((.lexicalScore // 0) > 0) and ($overlap >= 1 or ($w | length) == 0))
                or ($overlap >= 2 and ($overlap * 10) >= (($w | length) * 3)))
       # Drop echoes: a stored copy of the same question is not knowledge.
       | select(((.title // "") | ascii_downcase | contains($pfx)) | not)] | .[0:($limit | tonumber)] |
    if length == 0 then "" else
      "--- Team memory (auto-recall for this prompt; hits from chum-memory, newest first within rank) ---\n" +
      (map("- [" + (.memoryType // .type // "memory" | tostring) + "] "
           + ((.title // "") | gsub("\n"; " ") | .[0:220])
           + " (by " + (.authorEmail // "unknown") + ", " + ((.createdAt // "")[0:16]) + ", session " + ((.sessionIds[0] // "") | tostring | .[0:8]) + ", " + (if ((.semanticScore // 0) > 0 or (.lexicalScore // 0) > 0) then ("match " + ((([(.semanticScore // 0), (.lexicalScore // 0), 1] | min) as $m | ([(.semanticScore // 0), (.lexicalScore // 0)] | max | if . > 1 then 1 else . end) * 100 | floor) | tostring) + "%") else "word overlap" end) + ")"
          ) | join("\n"))
      + "\nIf any of these bears on the request, use it and say who recorded it; call mem_search for details."
    end' 2>/dev/null)
  [[ -n "$md" ]] || return 1
  printf '%s' "${md:0:3000}" | jq -Rs '.' 2>/dev/null | sed 's/^"//;s/"$//'
}

# ── Fetch knowledge report on session start for codebase context ──
# Returns a JSON-safe string (newlines escaped) suitable for embedding in
# the additionalContext field. Empty string on failure.
fetch_knowledge_report_escaped() {
  local api_url="${CHUM_MEMORY_API_URL:-http://localhost:63001}"
  local qs="layer=unified"
  [[ -n "${CHUM_MEM_PROJECT_ID:-}" ]] && qs="${qs}&projectId=${CHUM_MEM_PROJECT_ID}"
  local report=""
  report=$(curl -sf $AUTH_HEADER --max-time 5 "${api_url}/api/knowledge/report?${qs}" 2>/dev/null) || return 1
  [[ -z "$report" ]] && return 1
  if echo "$report" | jq -e '.report.markdown? // empty' >/dev/null 2>&1; then
    report=$(printf '%s' "$report" | jq -r '.report.markdown')
  fi
  printf '%s' "${report:0:2000}" | jq -Rs '.' 2>/dev/null | sed 's/^"//;s/"$//' || echo ""
}

case "$HOOK_EVENT" in
  UserPromptSubmit)
    RECALL=$(fetch_prompt_memory_escaped 2>/dev/null || echo "")
    __tlog auto_recall 2>/dev/null || true
    if [[ -n "$RECALL" ]]; then
      PROMPT_MSG="${USER_PROMPT_MSG}\\n\\n${RECALL}"
    else
      PROMPT_MSG="$USER_PROMPT_MSG"
    fi
    if [[ "$PROVIDER" == "codex" ]]; then
      emit_codex "$PROMPT_MSG"
    else
      emit_claude "UserPromptSubmit" "$PROMPT_MSG"
    fi
    ;;
  SessionStart)
    # Fetch repository knowledge report to prime the session
    KB_REPORT=$(fetch_knowledge_report_escaped 2>/dev/null || echo "")
    if [[ -n "$KB_REPORT" ]]; then
      SESSION_START_MSG="${SESSION_START_BASE}\\n\\n--- Unified Knowledge Report ---\\n${KB_REPORT}"
    else
      SESSION_START_MSG="$SESSION_START_BASE"
    fi
    if [[ "$PROVIDER" == "codex" ]]; then
      emit_codex "$SESSION_START_MSG"
    else
      emit_claude "SessionStart" "$SESSION_START_MSG"
    fi
    ;;
  PostToolUse|Stop)
    # No context on these events (a Stop context keeps the session running);
    # a quarantine notice is a plain warning to the user and is safe here.
    [[ -n "${SYSTEM_MSG:-}" ]] && printf '{"systemMessage":"%s"}\n' "$SYSTEM_MSG"
    ;;
esac

__tlog done
exit 0
