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

Backfill history once from each engineer's machine, with the IAP tunnel running (cheap, FINDINGS F10):

```bash
cd chum-mem && pnpm install
pnpm sessions:import --roots ~/.claude/projects/<your-monorepo-folders> \
  --server http://localhost:63001 --project $(jq -r .projectId <monorepo>/.chum-mem) --yes
```

Then call `POST /api/admin/reembed {"projectId": ...}` once.

## 3. Each engineer (5 minutes)

The plugin talks to `localhost:63001`; an IAP tunnel forwards that to the VM.

```bash
gcloud auth login                                 # your @codechum.com account
gh repo clone CodeChum/chum-mem ~/chum-mem
cd ~/chum-mem && export CHUM_MEMORY_API_URL=http://localhost:63001
./plugin-install.sh claude production

# keep this running (a second terminal, or wrap it in a launchd agent):
gcloud compute start-iap-tunnel gradechum-chum-mem 63001 \
  --local-host-port=localhost:63001 --zone=asia-east1-b --project=gradechum
```

Then start Claude Code from the **monorepo root** (the hooks resolve the project
id from `.chum-mem` there). Check it works:

- `/mcp` shows `chum-memory` connected
- a prompt such as "is anyone working on the bonus toggle?" answers from team
  memory with the author's email
- `.chum-cache/` appears in the repo root (ignored); if the tunnel is down,
  events spool to `.chum-cache/outbox/` and replay on the next prompt

Identity is your git `user.email` in that checkout — make sure it is your work
address.

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
