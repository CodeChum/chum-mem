#!/usr/bin/env bash
# sync.sh — repository docs sync for chum-memory (sync protocol 2).
# Called by the plugin hook on UserPromptSubmit / SessionStart. bash 3.2 + git
# + jq only (no python3: the team's laptops do not have it).
#
# What it uploads: the files of the repository's DEFAULT BRANCH as of the last
# fetch (origin/HEAD, e.g. origin/main), read from git objects — never the
# working copy, the checked-out branch, or uncommitted edits. Every engineer
# therefore describes the same tree, whatever branch they are on. The server
# keeps one shared snapshot per project that only moves forward in commit time:
#   - each sync sends the complete filtered manifest (path -> git blob id) of
#     that tree; the server deletes snapshot files that are not in it (so a
#     file is removed only once it is gone from the default branch) and
#     answers with the paths whose content it does not hold yet;
#   - a sync from an older commit than the snapshot's gets 409 and changes
#     nothing (an engineer who has not fetched cannot revert docs).
# Steady state costs one `git rev-parse`: nothing is sent while origin/HEAD and
# the rules are unchanged since the last complete sync.
#
# Usage: sync.sh [ROOT_DIR] [API_URL]
# Env:
#   CHUM_MEM_PROJECT_ID     project scope (required for per-project graphs)
#   CHUM_SYNC_REF           override the canonical ref (default origin/HEAD)
#   CHUM_SYNC_CHUNK_BYTES   max raw bytes of file content per request (default 8 MB)
#   CHUM_SYNC_CHUNK_FILES   max files per request (default 1000)
#   CHUM_SYNC_TIMEOUT_SECS  per-request timeout (default 120)
#   CHUM_SYNC_BUDGET_SECS   start no new request after this many seconds (default 15);
#                           an unfinished sync resumes on the next prompt
#   CHUM_SYNC_LOG           optional path; one JSON line per request is appended

set -uo pipefail

ROOT_DIR="${1:-$PWD}"
API_URL="${2:-${CHUM_MEMORY_API_URL:-http://localhost:63001}}"
PROJECT_ID="${CHUM_MEM_PROJECT_ID:-}"
CHUNK_BYTES="${CHUM_SYNC_CHUNK_BYTES:-8388608}"
CHUNK_FILES="${CHUM_SYNC_CHUNK_FILES:-1000}"
TIMEOUT="${CHUM_SYNC_TIMEOUT_SECS:-120}"
BUDGET="${CHUM_SYNC_BUDGET_SECS:-15}"
SYNC_LOG="${CHUM_SYNC_LOG:-}"
for v in CHUNK_BYTES CHUNK_FILES TIMEOUT BUDGET; do
  eval "[[ \"\${$v}\" =~ ^[0-9]+\$ ]]" || { echo "sync.sh: $v must be a number" >&2; exit 2; }
done

out() { printf '%s\n' "$1"; }
fail() {  # $1 message: loud on stderr and as JSON on stdout
  echo "chum-mem sync.sh: $1" >&2
  out "$(jq -nc --arg e "$1" '{status:"ERROR", error:$e}' 2>/dev/null || printf '{"status":"ERROR"}')"
  exit 2
}
command -v jq >/dev/null 2>&1 || { echo "chum-mem sync.sh: jq is required (brew install jq)" >&2; echo '{"status":"ERROR","error":"jq not found"}'; exit 2; }
command -v git >/dev/null 2>&1 || fail "git is required"

# ── API token: sent as X-Chum-Token from a here-string on fd 9 (curl -H @file),
# so it never appears in a process argument list.
if [[ -z "${CHUM_MEMORY_API_TOKEN:-}" && -r "${HOME}/.config/chum-mem/token" ]]; then
  CHUM_MEMORY_API_TOKEN="$(tr -d '[:space:]' < "${HOME}/.config/chum-mem/token")"; export CHUM_MEMORY_API_TOKEN
fi
AUTH_HEADER=""; AUTH_LINE=""
if [[ -n "${CHUM_MEMORY_API_TOKEN:-}" ]]; then AUTH_HEADER="-H@/dev/fd/9"; AUTH_LINE="X-Chum-Token: ${CHUM_MEMORY_API_TOKEN}"; fi

cd "$ROOT_DIR" 2>/dev/null || fail "cannot cd to $ROOT_DIR"
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || { out '{"status":"SKIPPED","reason":"not a git checkout"}'; exit 0; }
cd "$TOP" || fail "cannot cd to $TOP"
CACHE_DIR="${ROOT_DIR%/}/.chum-cache"
mkdir -p "$CACHE_DIR" || fail "cannot create $CACHE_DIR"
STATE_FILE="$CACHE_DIR/sync-state"
REJECTED_FILE="$CACHE_DIR/sync-rejected.tsv"
SERVER_RULES="$CACHE_DIR/sync-rules.json"

# ── Canonical ref: origin/HEAD (the remote's default branch), as last fetched.
REF="${CHUM_SYNC_REF:-}"
if [[ -z "$REF" ]]; then
  REF="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -z "$REF" ]]; then
    for cand in origin/main origin/master; do
      if git rev-parse -q --verify "refs/remotes/$cand" >/dev/null 2>&1; then REF="$cand"; break; fi
    done
  fi
fi
[[ -n "$REF" ]] || { out '{"status":"SKIPPED","reason":"no default branch (origin/HEAD) to sync from; set CHUM_SYNC_REF"}'; exit 0; }
COMMIT="$(git rev-parse -q --verify "${REF}^{commit}" 2>/dev/null)" || fail "cannot resolve $REF"
COMMIT_TIME="$(git log -1 --format=%ct "$COMMIT")"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chum-sync.XXXXXX")" || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

# ── Rules: the committed .chum-sync-rules.json AT THAT COMMIT (team-wide,
# versioned, identical for everyone), else the server's rules, else a default.
if git cat-file -e "${COMMIT}:.chum-sync-rules.json" 2>/dev/null; then
  git show "${COMMIT}:.chum-sync-rules.json" > "$TMP/rules.json"
else
  if [[ ! -s "$SERVER_RULES" ]]; then
    curl -sf $AUTH_HEADER 9<<<"$AUTH_LINE" --max-time 5 "${API_URL}/api/knowledge/sync-rules" > "$SERVER_RULES.tmp" 2>/dev/null \
      && jq -e 'type == "object"' "$SERVER_RULES.tmp" >/dev/null 2>&1 && mv -f "$SERVER_RULES.tmp" "$SERVER_RULES"
    rm -f "$SERVER_RULES.tmp"
  fi
  if [[ -s "$SERVER_RULES" ]]; then cp "$SERVER_RULES" "$TMP/rules.json"; else
    cat > "$TMP/rules.json" <<'RULES'
{"codeExtensions":["ts","tsx","js","jsx","mjs","cjs","py","go","rs","java","c","cc","cpp","h","hpp","cxx","hxx","rb","cs","kt","kts","scala","php","swift","lua","zig","ps1","sh","sql","css","scss","sass","less","vue","svelte","astro","m","mm","jl","dart"],"docExtensions":["md","mdx","html","htm","txt","rst","yaml","yml","json","jsonc","docx","xlsx","pptx","pdf","png","jpg","jpeg","webp","gif","mp4","mov","m4v","mp3","wav"],"binaryExtensions":["docx","xlsx","pptx","pdf","png","jpg","jpeg","webp","gif","mp4","mov","m4v","mp3","wav"],"ignoreDirs":[".git","node_modules","dist","build","out","target","__pycache__","venv",".venv",".next",".nuxt","coverage",".turbo",".cache","graphify-out"],"ignoreFiles":[".DS_Store","package-lock.json","pnpm-lock.yaml","yarn.lock","bun.lockb","Cargo.lock"],"ignorePatterns":[".env*","*.pem","*.key","*.crt","*.min.js","*.min.css","*.map","*.d.ts","*.generated.ts","*.generated.js"],"maxFileSizeBytes":262144,"maxBinaryFileSizeBytes":16777216}
RULES
  fi
fi
jq -e 'type == "object"' "$TMP/rules.json" >/dev/null 2>&1 || fail "sync rules are not a JSON object"
RULES_ID="$(git hash-object "$TMP/rules.json")"

# ── Nothing to do when this commit + rules were already synced (or refused).
STATE_KEY="${PROJECT_ID}	${COMMIT}	${RULES_ID}"
if [[ -f "$STATE_FILE" ]]; then
  IFS= read -r last < "$STATE_FILE" || last=""
  case "$last" in
    "$STATE_KEY	done")  out '{"status":"NO_CHANGES"}'; exit 0 ;;
    "$STATE_KEY	stale") out '{"status":"STALE","reason":"server snapshot is at a newer commit; fetch to catch up"}'; exit 0 ;;
  esac
fi

# ── Manifest of the commit's tree, filtered by the rules (same semantics as
# the old walk: ignoreDirs / ignorePatterns on any directory, extension
# allowlist, ignoreFiles, ignorePatterns on basename or path, size limits).
git ls-tree -r -z -l --full-tree "$COMMIT" > "$TMP/tree" || fail "git ls-tree failed"
jq -R -s --slurpfile rules "$TMP/rules.json" '
  def glob_re: "^" + (gsub("(?<c>[.+^${}()|\\\\])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; ".") | gsub("\\[!"; "[^")) + "$";
  ($rules[0]) as $r
  | (($r.codeExtensions // []) + ($r.docExtensions // [])) as $valid
  | ($r.binaryExtensions // []) as $bin
  | ($r.ignoreDirs // []) as $idirs
  | ($r.ignoreFiles // []) as $ifiles
  | [($r.ignorePatterns // [])[] | glob_re] as $pats
  | ($r.maxFileSizeBytes // 262144) as $max
  | ($r.maxBinaryFileSizeBytes // 16777216) as $maxbin
  | [ split("\u0000")[]
      | select(length > 0)
      | capture("^(?<mode>[0-9]+) (?<type>[a-z]+) (?<sha>[0-9a-f]+) +(?<size>[0-9-]+)\t(?<path>.*)$"; "s")
      | select(.type == "blob" and .mode != "120000" and (.path | test("[\t\n\\\\]") | not))
      | (.path | split("/")) as $parts
      | ($parts[-1]) as $base
      | (if ($base | contains(".")) then ($base | split(".")[-1] | ascii_downcase) else "" end) as $ext
      | select(($parts[:-1] | map(. as $d | ($idirs | index([$d])) != null or any($pats[]; . as $p | $d | test($p))) | any) | not)
      | select(($valid | index([$ext])) != null)
      | select(($ifiles | index([$base])) == null)
      | .path as $path
      | select(any($pats[]; . as $p | ($base | test($p)) or ($path | test($p))) | not)
      | (.size | tonumber) as $size
      | select($size <= (if ($bin | index([$ext])) != null then $maxbin else $max end))
      | {path, sha, size: $size, binary: (($bin | index([$ext])) != null), ext: $ext}
    ] as $files
  | {manifest: ($files | map({key: .path, value: .sha}) | from_entries),
     files: ($files | map({key: .path, value: {sha, size, binary, ext}}) | from_entries)}
' "$TMP/tree" > "$TMP/manifest-full.json" || fail "building the manifest failed (jq)"
jq -c '.manifest' "$TMP/manifest-full.json" > "$TMP/manifest.json"
FILE_COUNT="$(jq 'length' "$TMP/manifest.json")"

# ── Checkout identity for the server's remote pin (credentials stripped).
REMOTE="$(git remote get-url origin 2>/dev/null || true)"
case "$REMOTE" in
  *://*) REMOTE="$(printf '%s' "$REMOTE" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@#\1#')"; REMOTE="${REMOTE%%[?#]*}" ;;
esac
ROOT_HDR="$(printf '%s' "$TOP" | cut -c1-512)"

[[ -f "$REJECTED_FILE" ]] || : > "$REJECTED_FILE"
START=$SECONDS
REQUESTS=0; FILES_SENT=0; FAILED=0; NEEDED_LEFT=-1; STATUS="SUCCESSFUL"

# post <files.jsonl> : POST one request; sets HTTP and leaves the body in $TMP/resp.json
post() {
  jq -n --slurpfile files "$1" --slurpfile m "$TMP/manifest.json" \
     --arg p "$PROJECT_ID" --arg ref "$REF" --arg c "$COMMIT" --argjson t "$COMMIT_TIME" '
    {files: $files, manifest: $m[0], removedPaths: [], mergeWithExisting: true,
     manifestComplete: true, sourceRef: $ref, sourceCommit: $c, sourceCommitTime: $t}
    + (if $p != "" then {projectId: $p} else {} end)' > "$TMP/body.json" || return 1
  local t0=$SECONDS
  HTTP="$(curl -sS $AUTH_HEADER 9<<<"$AUTH_LINE" -o "$TMP/resp.json" -w '%{http_code}' --max-time "$TIMEOUT" \
    -X POST -H 'Content-Type: application/json' -H "X-Chum-Repo-Remote: ${REMOTE}" -H "X-Chum-Repo-Root: ${ROOT_HDR}" \
    --data-binary @"$TMP/body.json" "${API_URL}/api/knowledge/repository-sync" 2>/dev/null)" || HTTP="${HTTP:-000}"
  REQUESTS=$((REQUESTS + 1))
  if [[ -n "$SYNC_LOG" ]]; then
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg http "$HTTP" --argjson files "$(wc -l < "$1" | tr -d ' ')" \
      --argjson bytes "$(wc -c < "$TMP/body.json" | tr -d ' ')" --argjson secs $((SECONDS - t0)) --arg commit "$COMMIT" \
      '{ts:$ts, commit:$commit, files:$files, bytes:$bytes, http:($http|tonumber? // 0), secs:$secs}' >> "$SYNC_LOG" 2>/dev/null
  fi
  return 0
}

media_type() {  # $1 ext
  case "$1" in
    pdf) echo application/pdf ;; png) echo image/png ;; jpg|jpeg) echo image/jpeg ;; webp) echo image/webp ;;
    gif) echo image/gif ;; mp4|m4v) echo video/mp4 ;; mov) echo video/quicktime ;; mp3) echo audio/mpeg ;;
    wav) echo audio/wav ;;
    docx) echo application/vnd.openxmlformats-officedocument.wordprocessingml.document ;;
    xlsx) echo application/vnd.openxmlformats-officedocument.spreadsheetml.sheet ;;
    pptx) echo application/vnd.openxmlformats-officedocument.presentationml.presentation ;;
    *) echo "" ;;
  esac
}

# First request: manifest only. The server removes files gone from the tree
# and answers with what it needs.
: > "$TMP/empty.jsonl"
post "$TMP/empty.jsonl"
while :; do
  if [[ "$HTTP" == "409" ]]; then
    printf '%s\tstale\n' "$STATE_KEY" > "$STATE_FILE"
    out "$(jq -nc --arg ref "$REF" --arg c "$COMMIT" --arg e "$(jq -r '.error // empty' "$TMP/resp.json" 2>/dev/null)" \
      '{status:"STALE", ref:$ref, commit:$c, error:$e}')"
    exit 0
  fi
  if [[ "$HTTP" != "200" ]] || [[ "$(jq -r '.status // empty' "$TMP/resp.json" 2>/dev/null)" != "SUCCESSFUL" ]]; then
    FAILED=1; STATUS="PARTIAL"; break
  fi
  if ! jq -e 'has("neededPaths")' "$TMP/resp.json" >/dev/null 2>&1; then
    echo "chum-mem sync.sh: the server at ${API_URL} does not speak sync protocol 2 (no neededPaths); nothing uploaded" >&2
    FAILED=1; STATUS="ERROR"; break
  fi
  # Park files the server could not parse at this blob id (never resent).
  jq -r '.missingPaths[]?' "$TMP/resp.json" | while IFS= read -r p; do
    sha="$(jq -r --arg p "$p" '.[$p] // empty' "$TMP/manifest.json")"
    [[ -n "$sha" ]] && printf '%s\t%s\n' "$p" "$sha" >> "$REJECTED_FILE"
  done
  # Still needed, minus parked entries (same path AND same blob id).
  jq -r --rawfile rej "$REJECTED_FILE" --slurpfile full "$TMP/manifest-full.json" '
    ($rej | split("\n") | map(select(length > 0)) | map(split("\t")) | map({key: .[0], value: .[1]}) | from_entries) as $parked
    | .neededPaths[]? | select(($full[0].files[.] // null) != null)
    | . as $p | select($parked[$p] != $full[0].files[$p].sha)
    | [$p, $full[0].files[$p].sha, ($full[0].files[$p].size | tostring), ($full[0].files[$p].binary | tostring), $full[0].files[$p].ext] | @tsv
  ' "$TMP/resp.json" > "$TMP/needed.tsv" 2>/dev/null || : > "$TMP/needed.tsv"
  NEEDED_LEFT="$(wc -l < "$TMP/needed.tsv" | tr -d ' ')"
  [[ "$NEEDED_LEFT" -eq 0 ]] && break
  if (( SECONDS - START >= BUDGET )); then STATUS="PARTIAL"; break; fi
  # Next chunk: up to CHUNK_FILES files / CHUNK_BYTES bytes, content from git objects.
  : > "$TMP/chunk.jsonl"; n=0; bytes=0
  while IFS=$'\t' read -r path sha size binary ext; do
    [[ -z "$path" ]] && continue
    est=$size; [[ "$binary" == "true" ]] && est=$(( size * 4 / 3 + 4 ))
    if (( n > 0 && (bytes + est > CHUNK_BYTES || n >= CHUNK_FILES) )); then break; fi
    if [[ "$binary" == "true" ]]; then
      git cat-file blob "$sha" | base64 | tr -d '\n\r' > "$TMP/blob" || continue
      jq -nc --arg path "$path" --arg hash "$sha" --rawfile b64 "$TMP/blob" --arg mt "$(media_type "$ext")" --argjson size "$size" \
        '{path:$path, hash:$hash, bytesBase64:$b64, mediaType:(if $mt == "" then null else $mt end), sizeBytes:$size}' >> "$TMP/chunk.jsonl" || continue
    else
      git cat-file blob "$sha" > "$TMP/blob" || continue
      jq -nc --arg path "$path" --arg hash "$sha" --rawfile content "$TMP/blob" --argjson size "$size" \
        '{path:$path, hash:$hash, content:$content, sizeBytes:$size}' >> "$TMP/chunk.jsonl" || continue
    fi
    n=$((n + 1)); bytes=$((bytes + est))
  done < "$TMP/needed.tsv"
  [[ "$n" -gt 0 ]] || { STATUS="PARTIAL"; break; }
  FILES_SENT=$((FILES_SENT + n))
  post "$TMP/chunk.jsonl"
done

if [[ "$FAILED" -eq 0 && "$NEEDED_LEFT" -eq 0 ]]; then
  printf '%s\tdone\n' "$STATE_KEY" > "$STATE_FILE"
fi
out "$(jq -nc --arg s "$STATUS" --arg ref "$REF" --arg c "$COMMIT" --argjson req "$REQUESTS" --argjson sent "$FILES_SENT" \
  --argjson files "$FILE_COUNT" --argjson left "$NEEDED_LEFT" --arg http "$HTTP" \
  '{status:$s, ref:$ref, commit:$c, requests:$req, filesSent:$sent, filesInTree:$files, neededLeft:$left, lastHttp:$http}')"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
