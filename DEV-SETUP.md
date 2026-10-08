# chum-mem for GradeChum engineers — setup

Status 2026-10-08: the memory logic is verified (see FINDINGS.md) and a shared
server is deployed on GCP (step 1). Do step 2 once as a team, then every
engineer does step 3.

## 1. Server (deployed 2026-10-08: GCP VM `gradechum-chum-mem`)

Project `gradechum`, zone `asia-east1-b`, e2-standard-4, Debian 12, built from
`deploy/gcp/startup.sh`. **Nothing is exposed to the internet**: the firewall
admits only Google's IAP range on tcp/22, and the API, Postgres and dashboard
bind to the VM's loopback. Access control is Google IAM on the project.

Operate it with `deploy/gcp/deploy-vm.sh` (`status`, `logs`, `ssh`, `tunnel`):

```bash
export CHUM_GCP_ZONE=asia-east1-b CHUM_GCP_VM=gradechum-chum-mem
deploy/gcp/deploy-vm.sh logs     # startup/build log
deploy/gcp/deploy-vm.sh ssh      # IAP SSH; the stack lives in /opt/chum-mem/src
```

Engineers need the IAM role **IAP-secured Tunnel User** (`roles/iap.tunnelResourceAccessor`)
plus `compute.instances.get` on the project (Compute Viewer is enough).

If you ever want to re-create it: `deploy/gcp/deploy-vm.sh create` (same env vars).

## 2. Monorepo (once)

Merge branch `chum-mem-pilot/shared-project-id` in `CodeChum/gradechum`. It adds:

- `.chum-mem` — the shared project id (every checkout joins one graph)
- `.chum-sync-rules.json` — docs-only sync rules (the server cannot index the
  18k-file monorepo yet, FINDINGS F8); the plugin prefers this file
- `docs-mirror/` — memory notes mirrored as repository docs
- `.gitignore` — `.chum-cache/`

Backfill history once per engineer. Do it **on the VM over SSH**, not through
the IAP tunnel: a tunnel reset mid-import leaves sessions partial and the
bulk-import indexes dropped (FINDINGS F31). Copy the transcript folders up, then:

```bash
# on your laptop: copy your monorepo session folders to the VM
gcloud compute scp --recurse --tunnel-through-iap --zone=asia-east1-b --project=gradechum \
  ~/.claude/projects/-Users-<you>-gradechum-gradechum* gradechum-chum-mem:/tmp/sessions/
# on the VM (deploy/gcp/deploy-vm.sh ssh), from /opt/chum-mem/src:
pnpm sessions:import --roots /tmp/sessions --server http://10.140.0.9:63001 \
  --project $(jq -r .projectId <monorepo>/.chum-mem) --yes
curl -s -X POST -H 'Content-Type: application/json' -d '{"projectId":"<id>"}' http://10.140.0.9:63001/v1/ingest/bulk/create-indexes
```

Embeddings are computed on ingest with the local model, so no re-embed step is
needed on the VM (`POST /api/admin/reembed` exists for model changes).

## 3. Each engineer (one-time, about 5 minutes)

Prerequisites: Claude Code, `gh`, the Google Cloud SDK, and an admin has given
your @codechum.com account **IAP-secured Tunnel User** + **Compute Viewer** on
project `gradechum`.

```bash
gcloud auth login                                   # once; tokens refresh on their own
gh repo clone CodeChum/chum-mem ~/chum-mem && cd ~/chum-mem
deploy/gcp/install-tunnel-agent.sh install          # launchd agent: tunnel to the VM, auto-restarts, survives reboots
echo 'export CHUM_MEMORY_API_URL=http://localhost:63001' >> ~/.zshrc && export CHUM_MEMORY_API_URL=http://localhost:63001
./plugin-install.sh claude production               # registers the plugin + MCP server in Claude Code
```

That is the whole setup. From then on, every Claude Code session you start from
the **monorepo root** is captured and auto-searched. Nothing to run per session.

Check it works:

- `deploy/gcp/install-tunnel-agent.sh status` shows the tunnel up and `/ready`
- in Claude Code, `/mcp` shows `chum-memory` connected
- ask "is anyone working on the bonus toggle?" and the answer cites team memory with an author email
- `.chum-cache/` appears in the repo root (ignored); if the tunnel is down,
  events spool to `.chum-cache/outbox/` and replay on the next prompt

Identity is your git `user.email` in that checkout — make sure it is your work
address. Updates: `git -C ~/chum-mem pull` then `/reload-plugins` in Claude Code.

## What you get, and what you do not (yet)

- Every prompt is auto-searched against team memory; hits are injected with
  author, time and session (FINDINGS F29). Decisions, fixes and open questions
  from any engineer's sessions are findable within seconds of their session
  ending (F20, F28).
- Repository docs (CLAUDE files, rules, notes) are searchable; the code graph of
  the monorepo is **not** indexed until F8 is fixed server-side.
- Transcripts are stored raw with no redaction (team decision); the server's
  access control is the only gate.
- Headless `claude -p` runs capture no prompt on some Claude Code versions (F9).
