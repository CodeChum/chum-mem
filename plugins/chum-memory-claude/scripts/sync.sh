#!/usr/bin/env bash
# sync.sh — Client-side incremental repository sync for chum-memory.
# Called by the plugin hook on every user prompt. Detects changed files,
# sends them in bounded chunks (the API rejects bodies over 32 MB), and
# reconciles the local manifest after EVERY chunk so progress survives a
# hook timeout mid-sync.
#
# Usage: sync.sh [ROOT_DIR] [API_URL]
#
# Env:
#   CHUM_MEM_PROJECT_ID     project scope (required for per-project graphs)
#   CHUM_SYNC_CHUNK_BYTES   max raw bytes of file content per request (default 8 MB)
#   CHUM_SYNC_CHUNK_FILES   max files per request (default 1000) — server parse time scales with files
#   CHUM_SYNC_TIMEOUT_SECS  per-request timeout (default 120)
#   CHUM_SYNC_LOG           optional path; one JSON line per chunk is appended

set -uo pipefail

ROOT_DIR="${1:-$PWD}"
API_URL="${2:-${CHUM_MEMORY_API_URL:-http://localhost:63001}}"
CACHE_DIR="${ROOT_DIR}/.chum-cache"
RULES_FILE="${CACHE_DIR}/sync-rules.json"
PROJECT_ID="${CHUM_MEM_PROJECT_ID:-}"

mkdir -p "$CACHE_DIR"

if [[ ! -f "$RULES_FILE" ]]; then
  curl -sf --max-time 5 "${API_URL}/api/knowledge/sync-rules" > "$RULES_FILE" 2>/dev/null || {
    cat > "$RULES_FILE" <<'RULES'
{"codeExtensions":["ts","tsx","js","jsx","mjs","cjs","py","go","rs","java","c","cc","cpp","h","hpp","cxx","hxx","rb","cs","kt","kts","scala","php","swift","lua","zig","ps1","sh","sql","css","scss","sass","less","vue","svelte","astro","m","mm","jl","dart"],"docExtensions":["md","mdx","html","htm","txt","rst","yaml","yml","json","jsonc","docx","xlsx","pptx","pdf","png","jpg","jpeg","webp","gif","mp4","mov","m4v","mp3","wav"],"binaryExtensions":["docx","xlsx","pptx","pdf","png","jpg","jpeg","webp","gif","mp4","mov","m4v","mp3","wav"],"ignoreDirs":[".git","node_modules","dist","build","out","target","__pycache__","venv",".venv",".next",".nuxt","coverage",".turbo",".cache","graphify-out"],"ignoreFiles":[".DS_Store","package-lock.json","pnpm-lock.yaml","yarn.lock","bun.lockb","Cargo.lock"],"ignorePatterns":[".env*","*.pem","*.key","*.crt","*.min.js","*.min.css","*.map","*.d.ts","*.generated.ts","*.generated.js"],"maxFileSizeBytes":262144,"maxBinaryFileSizeBytes":16777216}
RULES
  }
fi

cd "$ROOT_DIR" || exit 1

python3 -s - "$CACHE_DIR" "$RULES_FILE" "$PROJECT_ID" "$API_URL" <<'PYTHON'
import base64, fnmatch, hashlib, json, mimetypes, os, sys, time, urllib.request, urllib.error

cache_dir, rules_file, project_id, api_url = sys.argv[1:5]
manifest_file = os.path.join(cache_dir, "manifest.tsv")
rejected_file = os.path.join(cache_dir, "rejected.tsv")
chunk_bytes = int(os.environ.get("CHUM_SYNC_CHUNK_BYTES", str(8 * 1024 * 1024)))
chunk_files = int(os.environ.get("CHUM_SYNC_CHUNK_FILES", "1000"))
timeout_secs = int(os.environ.get("CHUM_SYNC_TIMEOUT_SECS", "120"))
sync_log = os.environ.get("CHUM_SYNC_LOG", "")

with open(rules_file) as f:
    rules = json.load(f)

valid_exts = set(rules.get("codeExtensions", []) + rules.get("docExtensions", []))
binary_exts = set(rules.get("binaryExtensions", []))
ignore_dirs = set(rules.get("ignoreDirs", []))
ignore_dirs.add(".chum-cache")
ignore_files = set(rules.get("ignoreFiles", []))
ignore_patterns = rules.get("ignorePatterns", [])
max_size = rules.get("maxFileSizeBytes", 262144)
max_binary_size = rules.get("maxBinaryFileSizeBytes", 16 * 1024 * 1024)

def load_tsv(path):
    result = {}
    if os.path.isfile(path):
        with open(path) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t", 1)
                if len(parts) == 2:
                    result[parts[0]] = parts[1]
    return result

def write_tsv(path, mapping):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        for key in sorted(mapping):
            f.write(f"{key}\t{mapping[key]}\n")
    os.replace(tmp, path)

t0 = time.time()
eligible = []
for root, dirs, files in os.walk(".", topdown=True):
    dirs[:] = [
        d for d in dirs
        if d not in ignore_dirs and not any(fnmatch.fnmatch(d, pat) for pat in ignore_patterns)
    ]
    rel_root = os.path.relpath(root, ".")
    for filename in files:
        filepath = filename if rel_root == "." else os.path.join(rel_root, filename)
        filepath = filepath.replace(os.sep, "/")
        basename = os.path.basename(filepath)
        ext = filepath.rsplit(".", 1)[-1].lower() if "." in filepath else ""
        if ext not in valid_exts or basename in ignore_files:
            continue
        if any(fnmatch.fnmatch(basename, pat) or fnmatch.fnmatch(filepath, pat) for pat in ignore_patterns):
            continue
        if not os.path.isfile(filepath):
            continue
        try:
            size = os.path.getsize(filepath)
            limit = max_binary_size if ext in binary_exts else max_size
            if size > limit:
                continue
        except OSError:
            continue
        eligible.append((filepath, size))

current = {}
for filepath, _ in eligible:
    try:
        with open(filepath, "rb") as f:
            current[filepath] = hashlib.sha256(f.read()).hexdigest()
    except Exception:
        pass

manifest = load_tsv(manifest_file)
rejected = load_tsv(rejected_file)
sizes = dict(eligible)

to_send = [p for p, h in current.items() if manifest.get(p) != h and rejected.get(p) != h]
removed = [p for p in manifest if p not in current]
walk_ms = int((time.time() - t0) * 1000)

if not to_send and not removed:
    print(json.dumps({"status": "NO_CHANGES", "filesAdded": 0, "filesRemoved": 0,
                      "filesUnchanged": len(current), "walkMs": walk_ms}))
    sys.exit(0)

def file_entry(p):
    ext = p.rsplit(".", 1)[-1].lower() if "." in p else ""
    size = sizes.get(p, 0)
    if ext in binary_exts:
        with open(p, "rb") as f:
            encoded = base64.b64encode(f.read()).decode("ascii")
        return {"path": p, "hash": current[p], "bytesBase64": encoded,
                "mediaType": mimetypes.guess_type(p)[0], "sizeBytes": size}, len(encoded)
    with open(p, "r", errors="replace") as f:
        content = f.read()
    return {"path": p, "hash": current[p], "content": content, "sizeBytes": size}, len(content.encode("utf-8", "replace"))

# Build chunks by raw payload bytes. Removed paths ride on the first chunk.
chunks, cur, cur_bytes = [], [], 0
for p in to_send:
    try:
        entry, nbytes = file_entry(p)
    except Exception:
        continue
    if cur and (cur_bytes + nbytes > chunk_bytes or len(cur) >= chunk_files):
        chunks.append(cur); cur, cur_bytes = [], 0
    cur.append(entry); cur_bytes += nbytes
if cur or removed:
    chunks.append(cur)

accepted_total, missing_total, failed_chunks, status = 0, 0, 0, "SUCCESSFUL"
for i, files in enumerate(chunks):
    payload = {"files": files, "removedPaths": removed if i == 0 else [],
               "manifest": current, "mergeWithExisting": True}
    if project_id:
        payload["projectId"] = project_id
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(f"{api_url}/api/knowledge/repository-sync", data=body,
                                 headers={"Content-Type": "application/json"}, method="POST")
    t1 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout_secs) as resp:
            response = json.loads(resp.read().decode("utf-8") or "{}")
            http = resp.status
    except urllib.error.HTTPError as e:
        response, http = {}, e.code
    except Exception as e:
        response, http = {"error": str(e)}, 0
    ms = int((time.time() - t1) * 1000)
    ok = http == 200 and response.get("status") == "SUCCESSFUL"
    if ok:
        sent = {f["path"] for f in files}
        if "acceptedPaths" in response:
            accepted = set(response.get("acceptedPaths") or [])
            missing = set(response.get("missingPaths") or [])
        else:
            accepted, missing = sent, set()
        # Reconcile NOW so a hook timeout after this point loses nothing.
        if i == 0:
            for p in removed:
                manifest.pop(p, None)
        for p in accepted:
            if p in current:
                manifest[p] = current[p]
                rejected.pop(p, None)
        for p in missing & sent:
            manifest.pop(p, None)
            rejected[p] = current[p]
        write_tsv(manifest_file, manifest)
        write_tsv(rejected_file, {p: h for p, h in rejected.items() if current.get(p) == h})
        accepted_total += len(accepted); missing_total += len(missing)
    else:
        failed_chunks += 1
        status = "PARTIAL"
    if sync_log:
        with open(sync_log, "a") as lf:
            lf.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "chunk": i + 1,
                                 "chunks": len(chunks), "files": len(files), "bytes": len(body),
                                 "http": http, "ms": ms, "ok": ok,
                                 "serverStatus": response.get("status"), "error": response.get("error")}) + "\n")

print(json.dumps({"status": status, "chunks": len(chunks), "failedChunks": failed_chunks,
                  "filesSent": len(to_send), "filesAccepted": accepted_total, "filesMissing": missing_total,
                  "filesRemoved": len(removed), "filesUnchanged": len(current) - len(to_send), "walkMs": walk_ms}))
sys.exit(0 if failed_chunks == 0 else 1)
PYTHON
