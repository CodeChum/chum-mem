# chum-mem pilot — findings log

Local stack: fork `CodeChum/chum-mem` @ 44f4337, Docker Desktop (8 GB VM, 8 CPUs), monorepo `~/gradechum/gradechum`.
Decisions in memory file `chum-mem-pilot.md`.

## F1 — First sync of the monorepo cannot succeed with the stock client (code review, confirmed by design)
- `sync.sh` sends every changed file in ONE POST with `curl --max-time 20`; API has `DefaultBodyLimit 32 MB`.
- Monorepo eligible set: 23,305 files / 924 MB with stock rules; 18,388 files / 256 MB with tightened rules.
- Effect: 413/timeout every prompt, manifest never advances, every prompt retries the whole upload.
- Fix applied locally: chunked upload with per-chunk manifest reconcile (`CHUM_SYNC_CHUNK_BYTES`, `CHUM_SYNC_CHUNK_FILES`).
- Measured with the stock script on the monorepo: 8.1 s wall per prompt (walk + hash + failed POST), result `{"status":"ERROR","error":"Failed to reach API"}`. The server drops the connection on an over-limit body (broken pipe, no 413), so the client cannot even tell why. A direct 40 MB probe reproduces the broken pipe.

## F2 — API OOM-killed during cold sync (observed 2026-10-08 08:10 UTC)
- Cold sync v1 (code + DOCX/PDF/PPTX, 20 MB chunks): 16 chunks, 5 ok, then API exit 137 `OOMKilled=true`.
- API RSS reached 3.6 GB; Postgres 2.3 GB at 101% CPU; no `mem_limit` on any compose service.
- Server time per chunk: 4,454 files → 6.2 s; 4,819 files → 35.5 s; 3,552 files → 101.8 s; 44 binary files (23 MB) → 45 s.
- Walk + sha256 of 18,388 files on the client: 3.7 s.
- Consequence for a shared box: one engineer's first sync can take the service down for everyone.
- Fix direction: smaller chunks (8 MB / 1,000 files, applied), compose memory limits, stream parsing server-side; binaries excluded in v1 (decision).

## F3 — Hook health gate drops events whenever the API is busy (observed)
- `hook-dispatch.sh` does `curl --max-time 2 /health`; during the cold sync the API did not answer in 2 s.
- All four smoke events (SessionStart, UserPromptSubmit, PostToolUse, Stop) printed "API unreachable" and NOTHING was captured for that session, no retry, no spool.
- Consequence: on a shared server, any concurrent heavy ingest silently loses other engineers' sessions.
- Fix direction: spool events to `.chum-cache/outbox` when the API is slow and flush on the next hook; make `/health` independent of the ingest path; run ingest in the worker, not the API request.

## F4 — Repository-sync is synchronous inside the API request path (code review)
- `/api/knowledge/repository-sync` parses with tree-sitter and re-clusters inside the request. This is why health stalls (F3) and memory spikes (F2).

## F5 — No auth, fixed tenant (code review)
- Only `X-Chum-Project-Id` header is read. `CHUM_MEM_{ORGANIZATION,TEAM,USER}_ID` are server env vars; every client is the same system admin actor. `api_tokens` table and `token_create` tool exist but nothing enforces them.

## F6 — Identity (patched locally)
- `session-sync.sh` now sends `metadata.userEmail` (git `user.email` of the checkout) and `metadata.userName` on `session_start`. Server mapping to `app_users` still missing.

## F7 — "Semantic" search is hashed bag-of-words (code review)
- `embed_text` = FNV-1a token hashing into 1536 buckets, L2-normalised. Chroma receives these vectors. Paraphrase recall will be weak; README's "Chroma ML embeddings" is inaccurate.

## F8 — API memory grows without bound across sync requests (observed, cold sync v2)
- Code + text only, 8 MB / 1,000-file chunks, fresh DB. API RSS by 10 s sample: 0.75 → 1.95 → 2.67 → 3.17 → 3.57 → 3.78 GB, then OOM kill (exit 137) at chunk 7, ~6,000 files in, 93 s elapsed.
- Server time per 1,000-file chunk rose 7.1 → 5.6 → 8.4 → 17.3 → 11.5 → 22.1 s: each request re-clusters the whole growing project graph.
- Conclusion: the monorepo (18k files) cannot be indexed by the stock server inside 8 GB regardless of chunking. A single-POST stock client would need all of it in one request and would fail at the 32 MB body limit first (F1).
- Fix direction: stream files into Postgres without holding the whole graph in the request, cluster in the worker as a background job, cap memory per compose service.

## F9 — Headless sessions capture no prompt (observed, baseline run 1)
- `claude -p` fires SessionStart and Stop but not UserPromptSubmit for the initial prompt, so the stored session has only the response event. Anyone running Claude Code non-interactively (scripts, CI, the overnight regression command) leaves prompt-less sessions in the store. Interactive sessions are unaffected (smoke-2 captured prompt + tool_result + response via synthetic payloads).

## F10 — Backfill works and is cheap (observed)
- 8,079 transcript files from the monorepo project folders → 7,870 sessions, 96,264 events in 262 s, 0 failures; API stayed at ~70 MB. Derivation is the slow part: worker ~1,250 jobs/min, 12.5k jobs queued after import (derive-session-memories, build-knowledge-graph, sync-chroma-index per session).

## F11 — Baseline series: 20 real headless sessions, stock plugin (2026-10-08 08:24–08:40 UTC)
- 20/20 sessions completed and stored; 20/20 responses captured; prompt captured in 14/20 (UserPromptSubmit hook did not fire in 6 runs, see F9); tool results captured in the 2 runs that used tools (5/5 PostToolUse events).
- Hook cost per event, p50 / max: SessionStart 10.8 s / 15.1 s; UserPromptSubmit 10.9 s / 18.4 s; Stop 0.48 s / 2.2 s; PostToolUse 0.30 s / 0.37 s; SessionEnd 0.20 s / 0.74 s.
- The ~10 s on SessionStart and on every prompt is the stock repository sync walking and hashing 18k files and then failing the single POST (F1). Repository layer stayed empty for all 20 runs.
- Model never called the memory MCP tools in any run (0/20) despite the injected instruction; it answered from CLAUDE.md. Answers spot-checked correct (run 1 verified by hand against the stored response event).
- Wall time p50 27.5 s, max 53.8 s. Cost $19.23 for 20 one-line questions (p50 $0.94/run), dominated by the monorepo's context, not the plugin.
- Verification method: each run's claude session_id looked up in `sessions.external_session_id`, status and per-type event counts read from `session_events`.

## F12 — Single worker; a batch-merged graph build blocks all other derivation (observed)
- After the backfill the worker batch-merged 7,713 `build-knowledge-graph` jobs into one (`batch_size=7713`) and ran it for 25+ min at ~100% CPU. `WORKER_CONCURRENCY=1` (kept serial because TurboVec partition writes use a lock file), so every `derive-session-memories` for a NEW session waits behind it. On a shared server, one engineer's backfill delays every other engineer's fresh memories by the length of the graph build.
- API RSS sat at 3.27 GB while idle after the derivation callbacks: memory is retained after work completes, same shape as F8.
- Fix direction: separate queues (graph build vs per-session derivation), bound graph builds by time or size, and a second worker for non-vector jobs.

## F13 — Lexical search ANDs every word, so question-shaped queries return nothing (observed + code)
- `load_memory_search_rows` filters with `m.search_vector @@ websearch_to_tsquery('english', $query)`. websearch semantics AND all terms. Single words hit ("hotfix" → 5, "production-patch" → 3, "rubrics" → 4) but every golden question (natural language) → `lexicalCount: 0` on all 32. The skill tells the model to pass natural-language queries to `mem_search`, so the lexical third of "three-way hybrid" is dead in normal use.
- Fix direction: OR-semantics (`to_tsquery` with `|`), or `plainto_tsquery` on extracted keywords, plus `ts_rank_cd` ranking; keep AND as a boost, not a gate.

## F14 — Backfill derived 14,220 memories but only 11 decisions (observed)
- Type mix (non-superseded): open_question 2,479; fix 1,473; bug 609; task 283; constraint 246; fact 160; implementation_detail 42; decision 11. 8,916 of 14,220 are marked superseded (same claimKey across sessions). The rule-based extractor labels most user prompts as "open_question" and tool paths as "implementation_detail"; real decisions are almost never recognised.

## F15 — With the default TurboVec backend, semantic search depends entirely on a worker job queue (code + observed)
- `perform_search`: `else if vector_store_backend == TurboVec { Vec::new() }` — pgvector semantic search is skipped. Only TurboVec results count, and TurboVec is filled by `sync-chroma-index` jobs (one per session) on the single worker.
- After the backfill, all 7,717 of those jobs sat behind the batch-merged graph build (F12). Every query, any mode, any limit, any sessionId filter, returned the same two memories: the only two vectors in TurboVec (from the smoke session). Recall passes 1–2: 2/32, identical top hits for all 32 questions.
- Even the `sessionId` filter is not applied to TurboVec hits (a search filtered to session X returned memories from session Y).
- Compose default is `VECTOR_STORE_BACKEND=turbovec`; README says Chroma is the default. The docs and the shipped config disagree.
- Consequence for the team: after any backfill or busy period, "memory" silently answers from a stale, tiny index with no error.
- Workaround verified: setting `VECTOR_STORE_BACKEND=chroma` on the API only (Chroma service absent → `chromaEnabled:false`, vector store skipped, no errors) re-enables the pgvector path: the same query immediately returns 5 semantic hits from the 14,220 embeddings in 53 ms.

## F16 — HNSW index misses closer rows than a sequential scan on the hashed vectors (observed in SQL)
- Same query vector, same table: `ORDER BY embedding <=> q LIMIT 5` via `embeddings_hnsw_idx` returned best distance 0.744; with the index disabled the best row was "what about the production-patch?" at 0.562, which the index never surfaced. Sparse sign-hashed vectors are a poor fit for HNSW with default `ef_search`. Real embeddings would fix both this and the paraphrase problem (F7).

## F17 — Vector-index jobs bulk-complete their siblings without indexing them (code + observed)
- Worker `sync_chroma_index` syncs ONE session's memories (fast path, scoped to the job's session) and then calls `bulk_complete_sibling_jobs(..., "sync-chroma-index")`, marking every other pending index job for the project complete. After the backfill: 7,717 jobs "completed" in 0.25 s; `/data/turbovec` still holds the two smoke vectors (files dated 08:14, 13 KB). Recall pass 21 on the stock backend after the full drain: identical to before, 2 hits for all 32 questions.
- So on the stock stack, backfilled history is NEVER semantically searchable. Only sessions that end while the worker is idle get indexed, one at a time.

## F18 — Graph build and drain timing (observed)
- The batch-merged `build-knowledge-graph` job ran 35 min 30 s for 7,717 sessions (08:33:05 → 09:08:35). `reconcile-claim-state` jobs waited the same 35 min. Everything else then drained in seconds (because of F17).

## F19 — Cross-user rounds 1–3: session stored with the right identity, zero memories derived (observed)
- Three rounds: engineer2's session arrived with `userEmail=engineer2@codechum.com`, `prompt` + `response` events stored, status completed. No `derive-session-memories` job exists for live sessions (derivation runs inline at `session_end`), and inline derivation produced 0 memories for a prompt of the form "Decision X: for the chum-mem pilot we will run … Please note it." The smoke session's question-shaped prompt did yield an `open_question`. The rule-based classifier does not recognise a plainly stated decision (see F14: 11 decisions in 7.7k sessions). Retrieval from the other identity therefore had nothing to find: 0/3.

## F20 — Cross-user sharing works once the text carries the classifier's marker (observed, rounds 4–6)
- Same test as F19 with the prompt phrased "Decision: we decided (…) that …". Three rounds: 1 memory derived in ≤1 s after session end, indexed by the per-session TurboVec job, and found at rank 1 by a search from the main identity, with the engineer2 session as the proof source. 3/3 pass. Rounds 7–20 running.
- So the pipeline is sound for live sessions; what fails is recognition (F14/F19) and backfill indexing (F17), not transport or scoping.
- Full 20 rounds on the stock stack: 14 pass. Rounds 1–3 failed on phrasing (F19). Rounds 10, 14 and 19 derived the memory (≤1 s) but the newest decision was not in the top 5: by then 17 near-identical "Colima" decisions existed (16 marked superseded shortly after), and the 4-bit quantised TurboVec shortlist returned an older copy instead. Identity was correct in 20/20. Rounds 21+ use a distinct decision per round so the test stops measuring duplicate handling.

## Fixes applied in the fork working copy (not yet pushed)
- **Client, chunked repository sync** (F1): `sync.sh` uploads in ≤8 MB / ≤1,000-file chunks and reconciles the manifest after every chunk; progress survives a hook timeout.
- **Client, identity** (F6): `session-sync.sh` sends `metadata.userEmail` (git `user.email`) and `userName` on `session_start`.
- **Client, outbox spool** (F3): `hook-dispatch.sh` no longer drops events when `/health` is slow; `session-sync.sh` writes one compact line per event/end to `.chum-cache/outbox/<provider>-<session>.jsonl` with the session-start payload embedded, and any later healthy hook replays all outbox files (session_start is idempotent, then event/end with the real id). Verified: 3 events spooled with the API pointed at a dead port, replayed by an unrelated session's hook, session stored with `engineer2@codechum.com`, prompt + response present, 1 decision derived.
- **Server, real embeddings** (F7/F16): `fastembed` (bge-small-en-v1.5, 384-dim, ONNX, CPU) replaces the FNV hash in `embed_text`; batch `embed_texts`; eager warm-up at API/worker start; migration `0023` drops the 1536-dim column and recreates `vector(384)` + HNSW; `POST /api/admin/reembed {projectId}` re-embeds every memory; compose gets a `fastembed_cache` volume and `FASTEMBED_CACHE_DIR`; Dockerfile adds OpenSSL. `cargo check` passes; Docker image rebuilding.
- **Server, F17**: `sync_chroma_index` now syncs the whole project (`session_id = None`) whenever it bulk-completed sibling jobs.
- **Server, F13**: lexical filter ORs the query's lexemes (`to_tsquery` joined with `|`) and keeps `ts_rank_cd` on the full websearch query for ranking.
- **Server, attribution (F27)**: search hits now carry `authorEmail` (the session's git email) in both the lexical and semantic queries and in `RankedMemory`, so a teammate's decision comes back with who made it.
- **Server, false contradictions (F27)**: `reconcile_single_claim` no longer matches candidates on the default subject `global` (14,275 of 14,2xx claims had it); a candidate must share the claim key, or share a specific subject AND the claim type. Claim extraction splits at sentence boundaries ("Decision: … . Do not change code." → one decision + one constraint instead of a negative-polarity blob), treats any segment containing "?" as an open question, and checks decision markers before constraint markers. Pipeline unit tests: 97 passed, 0 failed.
- **Build note**: first Docker build on bookworm failed at link time (`undefined symbol: __cxa_call_terminate`, `_M_replace_cold` from onnxruntime_c_api.cc): the prebuilt ONNX Runtime needs libstdc++ ≥ GCC 13. Images moved to Debian trixie (`libssl3t64`).

## F21 — Fixed build: recall on the session layer, auto 5/32, manual strict 1/32 (observed, pass 22)
- Real embeddings + OR-lexical: hits per question went from 2 (always the same two) to 4–10, p50 87 ms. Auto-score 5/32 (was 3/32 with hashed vectors, 2/32 on the stock stack).
- Manual verification of every top-5 list against the strict rule (right fact AND a proof excerpt pointing at a real source): **1/32** — q12 "push via gh when git push is denied" at rank 1, from a real session. The other four auto-passes were keyword coincidences inside user questions (q04 "flash lite", q10 "65", q14 "97", q18). q11 surfaced the FIX for the October upload failures ("#20 bounded retries, #21 developer-API fallback … rescued via developer API") but not the cause. q01 surfaced an older hotfix convention ("hotfix/* with PRs to both main and staging") that contradicts the current one (production-patch) and the contradiction engine did not flag it.
- Why it is this low: the PCKC belief gate keeps only user prompts, tool outputs and user-confirmed statements as durable claims. Nearly every golden fact lives in an assistant explanation or a memory/workspace note, which the gate rejects as model prose. The store therefore answers "what did the user ask/paste/decide" well and "what did we learn" almost never. Real embeddings cannot fix a corpus that does not contain the answers.
- Deployment caveat found on the way: API and worker both download the model on first start; starting them together corrupted the worker's copy ("Failed to retrieve model file"), the worker exited and nobody noticed for 18 min. Start the API first or pre-download.

## F22 — Fixed series: 20 real headless sessions, fixed plugin + rebuilt server, docs-only sync (2026-10-08 10:11–10:24 UTC)
| Measure | Baseline (stock) | Fixed |
|---|---|---|
| Sessions stored, completed | 20/20 | 20/20 |
| Prompts captured | 14/20 | **20/20** |
| Responses captured | 20/20 | 20/20 |
| Tool results captured (sessions that used tools) | 5/5 (2 sessions) | 12/12 (3 sessions) |
| Model called memory tools on its own | 0/20 | 0/20 |
| SessionStart hook p50 / max | 10.8 s / 15.1 s | **1.7 s / 3.1 s** |
| UserPromptSubmit hook p50 / max | 10.9 s / 18.4 s | **0.39 s / 0.75 s** |
| PostToolUse hook p50 | 0.30 s | 0.32 s |
| Stop hook p50 | 0.48 s | 0.73 s |
| Wall time per session p50 | 27.5 s | **10.6 s** |
| Claude usage for the series | $19.23 | $19.56 |
- The remaining 1.7 s at session start is the knowledge-report fetch plus the docs walk; the stock 10 s was the doomed monorepo upload (F1). Prompts are now captured every time because the SessionStart hook finishes before the prompt hook fires (the baseline's 6 misses correlate with 15 s SessionStart hooks).
- Same caveat as before: the model never calls `mem_search`/`knowledge_query` unprompted, in either series. The injected instruction and the skill text do not change its behaviour on short questions it can answer from CLAUDE.md. Memory is only consulted if the user or a workflow asks for it.
- Recall on the fixed build: 20 passes (22–41), 5/32 auto on every pass, p50 96 ms; strict manual 1/32 (F21). Cross-user on the fixed build: 20/20 (rounds 21–40, distinct decisions), 19 at rank 1.

## F23 — TurboVec keeps dimension-specific index files without a dimension in their name (observed)
- After migration 0023 the full-project sync failed 3× with `turbovec add failed: vector buffer length 5476224 not a …` (14,261 × 384): the worker reused the old 1536-dim partition files (`memories_project_<id>_all.tvim`, no dimension suffix). Each failed attempt re-embedded all 14k memories first (~5 min). Fix: move/reset the TurboVec directory whenever the embedding dimension changes (documented in migration 0023 notes); better, suffix partition files with the dimension.

## F24 — REST `POST /api/knowledge/query` ignores `layer` (code + observed)
- Handler calls `perform_knowledge_query(&state, input, None)`; `KnowledgeQueryRequest` has no `layer` field and the query string is not read. With `layer` unset the newest snapshot of ANY type is served, so a repository-layer query returns session memories as soon as a session graph has been built. `limit` is ignored too (10 nodes for limit 3). The MCP `tools/call` path reads `args.layer` and behaves correctly (`file:docs-mirror/memory/hotfix-branch-target.md` at rank 1 for "hotfix branch production-patch"). Only REST clients (dashboards, scripts, this harness before the fix) are affected.

## F25 — Repository (docs) layer answers half the golden set; the session layer answers almost none (observed)
- Docs synced: CLAUDE files, `.claude/` rules/agents/commands/workspaces, mirrored memory notes and the global CLAUDE (`docs-mirror/`), 76 files, 13 s to sync. Queried through MCP `knowledge_query(search, layer=repository)` (pass = the document holding the answer is in the top 5 nodes, which under the strict rule is the proof itself):
  - natural-language question: **15/32**, 8 at rank 1, p50 17 ms
  - 4-keyword query (how the skill tells the model to query this layer): **17/32**, 10 at rank 1, p50 16 ms
- Misses are mostly questions whose answer sits in a long file with many competing sections (root CLAUDE.md, global CLAUDE.md, cost.md) where a sibling section outranks the right one, plus q15 (date buried in a memory note).
- Compared with the session layer (1/32 strict), this says where the team's durable knowledge actually is: in written notes, not in transcripts. The "all docs" direction is the right one; the Confluence/Jira/Drive mirror would extend this directly.

## F26 — Verified: full-project TurboVec sync after the F17 fix and an index reset (observed)
- With the worker on the TurboVec backend, old 1536-dim files moved aside, one full-project job: completed, `/data/turbovec` grew from 172 KB to 84 MB (`memories_project_<id>_all.json` 18.9 MB), all 14,2xx memories indexed. Docs-recall stability: 20 passes each mode, identical results every pass (15/32 question, 17/32 keywords, p50 15–16 ms).

## Mac Studio proof-of-concept runbook (nothing executed; needs your approval per step)
Target: `gemma-box` (Mac Studio, 32 cores, 96 GB, macOS 26.5, 710 GB free). Today it has only the `com.gradechum.cloudflared` tunnel (`3b013c11-…`) with ingress for `gemma-box.gradechum.com`→8000, `mac-studio-1.gradechum.com`→8070, SSH. No Homebrew, Docker, Colima, Rust or pnpm.
1. **Pause rule**: do not run steps 2–6 while the llama server (port 8090) or the GCIB worker is busy; check `launchctl list | grep gradechum` and `lsof -i :8090` first.
2. **Runtime**: install Homebrew, then `brew install colima docker docker-compose jq`; `colima start --cpu 8 --memory 16 --disk 100` (16 GB cap per decision; raise only if the cold sync needs it).
3. **Code**: `gh repo clone CodeChum/chum-mem ~/chum-mem` (after the push), `cp .env.example .env`, set `VECTOR_STORE_BACKEND=chroma` (pgvector path; TurboVec optional), `FASTEMBED_CACHE_DIR=/data/fastembed`, change `POSTGRES_PASSWORD` and `DATABASE_URL`, keep ports 63000/63001/65432 bound to 127.0.0.1 only.
4. **Start order**: `docker compose up -d postgres` → `up -d api` (downloads the model, ~1 min) → only then `up -d worker` (F21 caveat: concurrent first-run downloads corrupt the model copy).
5. **Backfill**: run `pnpm sessions:import` from each engineer's machine against the box (import is cheap, F10); expect a 35-min graph build per ~8k sessions (F18); call `POST /api/admin/reembed` once.
6. **Exposure**: add an ingress rule `chum-mem.gradechum.com` → `http://localhost:63001` in `~/.cloudflared/config.yml`, restart `com.gradechum.cloudflared`, create a Cloudflare Access application for that hostname restricted to the engineers' emails, and verify an unauthenticated `curl` gets the Access login page before anyone installs the plugin. The API itself still has no auth (F5); Access is the only gate.
7. **Clients**: each engineer installs the plugin from the fork (`./plugin-install.sh claude production` with the Access-protected URL; the hooks need `cloudflared access` token headers or a WARP client, which is the open item), commits nothing but uses the shared `.chum-mem` in the monorepo.
8. **Operate**: nightly `pnpm volumes:backup`, watch `docker stats` memory on the API (F8/F12 retention), and keep repository sync docs-only until F8 is fixed server-side.

## F27 — Two-actor scenarios with REAL sessions (fixed build, 2026-10-08 10:55–11:01 UTC)
Actor 1 = real headless Claude Code session on the monorepo checkout (git email cymmer@codechum.com). Actor 2 = real session on the second checkout (engineer2@codechum.com), run twice: "neutral" (never mentions memory) and "explicit" (asked to use chum-memory). Nine sessions, runs 50–58.

| TC | Actor 1 did | Actor 2 asked | Neutral | Explicit |
|---|---|---|---|---|
| 1 | Decided: raise `RUBRICS_REQUEST_TIMEOUT_SECONDS` 45→60 because Vertex p99 is 107 s | "About to change the rubrics timeout, anything recent from teammates?" | **Found**: cited the decision, value, reason, time, and linked it to PR #2692 (called `mem_search` + `knowledge_query` on its own) | **Found**: decision + reason + session id 794d7a93; "no person name stored" |
| 2 | Decided (CODECHUM-99901): bonus toggle in `TaskSettingsModal`, field `is_bonus_enabled`; "starting this now" | "Need to add a bonus toggle; is anyone already on it, any naming decision?" | **Found**: "a teammate … said they are starting the work now", widget + field names, session id | **Found**: same, session id f2d3f4d1 |
| 3 | Confirmed fix: answer-sheet 502 on 40+ pages = Puppeteer 30 s timeout → `PUPPETEER_TIMEOUT_MS=90000`, deployed | "Teacher reports 502 downloading long-exam answer sheets; known fix?" | **Missed**: did not consult memory, guessed a Cloud Run timeout | **Found**: cause + fix + session id 400932d1 |

- 5/6 Actor-2 sessions knew Actor 1's session within a minute of it ending. Captured `tool_result` events prove the retrieval path: runs 51, 52, 54, 55, 58 called `mcp__plugin_chum-memory_chum-memory__mem_search`; run 57 called nothing.
- The model consults memory unprompted when the question is about *people* ("teammates", "anyone working on this") and not for plain factual questions (0/40 in the series, 0/1 here). The skill text does not change that; prompt wording does.
- Attribution gap: `mem_search` hits carry the session id but not the session's `userEmail`, so Actor 2 says "a teammate" / "no person name stored" even though the store knows it was cymmer@codechum.com. One-line server fix (join session metadata into hits).
- False "contradicted" flags: all three fresh decisions were marked contradicted/superseded within a minute. The contradiction engine linked them to unrelated claims, e.g. the baseline prompt "Which production database host pattern must never receive a session-level SET…" (a question captured as a *constraint* because it contains "must never"). Actor 2 relayed the warning each time ("confirm with the team"), which is wrong but at least visible.
- One hour later the TC1 decision (stored as a *constraint*, because "do not change any code" in the same prompt made the constraint check win over "we decided") was `contradicted` + superseded, and the default search filter hides contradicted claims: the decision had become unfindable. On the stock reconcile logic every fresh decision decays this way within minutes. Both causes are fixed in the round-two server changes (sentence-level segmentation, decision-before-constraint, no `global`-subject matching); the five scenario repetitions below run on that build.

## F28 — Two-actor scenarios ×5 on the round-two build (attribution + contradiction fixes), 45 real sessions, runs 60–148
| TC | Actor 2 variant | Found Actor 1's fact | Named cymmer@codechum.com | Consulted memory | False "contradicted" warnings |
|---|---|---|---|---|---|
| 1 rubrics timeout decision | neutral | 5/5 | 5/5 | 5/5 | 0 |
| 1 | explicit | 5/5 | 5/5 | 5/5 | 0 |
| 2 bonus toggle, work started | neutral | 5/5 | 5/5 | 5/5 | 0 |
| 2 | explicit | 5/5 | 5/5 | 5/5 | 0 |
| 3 answer-sheet 502 fix | neutral | 1/5 | 0/5 | 1/5 | 0 |
| 3 | explicit | 5/5 | 5/5 | 5/5 | 0 |
- 26/30 Actor-2 sessions knew Actor 1's session; 25/30 named the person. All 15 Actor-1 sessions stored under cymmer@codechum.com, all 30 Actor-2 sessions under engineer2@codechum.com. Zero false contradiction warnings (was 6/6 in round one).
- Sample answer (TC2, run 145): "a teammate (cymmer@codechum.com) already started this: under CODECHUM-99901 they decided the toggle lives in the TaskSettingsModal widget … came from session a83095c4-…, so coordinate with them before starting rather than duplicating the work."
- The one systematic miss is TC3-neutral: a bug report phrased as "is this a known problem?" does not make the model consult memory (1/5); "is anyone working on this / anything from teammates" does (10/10). The fix is in the skill or system prompt wording ("check chum-memory before answering any 'is this known' question"), not in the server.

## F29 — Automatic recall on every prompt removes the phrasing dependency (observed, runs 160–169)
- User ask: do not make engineers phrase questions in a special way; the system should always search. Change: the UserPromptSubmit hook now runs `mem_search` itself (REST, hybrid, top 5, contradicted claims filtered) on the prompt text and injects the hits as context: type, title, author email, time, session id, plus one line telling the model to use and attribute them and to call `mem_search` for details. One bounded call per prompt (6 s cap, 3,000-char cap); skipped for slash commands and prompts under 12 chars. The model is no longer required to decide to search.
- TC3 with the neutral phrasing ("is this a known problem with a known fix?"), five fresh Actor-1/Actor-2 pairs: **5/5 found the fix, 5/5 named cymmer@codechum.com** (was 1/5 found, 0/5 named). Every Actor-2 answer opened with "Yes, this is a known problem. Team memory recorded by cymmer@codechum.com …" and still called `mem_search` on its own for details.
- Cost: UserPromptSubmit hook p50 ≈1.2 s (search + injection) versus 0.39 s without; roughly 400–900 extra input tokens per prompt when hits exist. Tunable via `CHUM_AUTO_RECALL_LIMIT` and `CHUM_AUTO_RECALL_TIMEOUT_SECS`.

## Measurements table (updated as runs complete)
| Run | What | Result |
|---|---|---|
| cold-sync v1 | 18,388 files incl. binaries, 20 MB chunks | PARTIAL: 5/16 chunks, API OOM at chunk 6, 230 s elapsed |
| smoke-1 | 4 synthetic hook events during cold sync v1 (20 MB chunks) | 0/4 captured (health gate) |
| smoke-2 | same, during cold sync v2 (8 MB / 1,000-file chunks), engineer2 checkout | 4/4 captured; session `completed`; metadata.userEmail=engineer2@codechum.com; hook ms: SessionStart 14,264 (own 75-file sync 11,040 server-side), UserPromptSubmit 685, PostToolUse 2,138, Stop 1,428 |
