#!/usr/bin/env bash
# deploy-vm.sh — create the chum-mem VM on GCP. No public ingress: SSH and the API
# are reached through IAP TCP forwarding only (Google IAM is the access control).
#
# Usage: deploy-vm.sh [create|deploy <ref>|status|tunnel|ssh|logs|delete]
#
# The VM runs exactly the commit it was created or last deployed with: its
# startup script clones once (at metadata `chum-mem-ref`) and never pulls on a
# reboot. `create` pins `chum-mem-ref` to a commit (CHUM_MEM_REF, default the
# current tip of main resolved to a SHA); `deploy <ref>` rolls the VM to a
# reviewed ref and rebuilds.
set -euo pipefail
PROJECT="${CHUM_GCP_PROJECT:-gradechum}"
ZONE="${CHUM_GCP_ZONE:-asia-east1-b}"
NAME="${CHUM_GCP_VM:-gradechum-chum-mem}"
MACHINE="${CHUM_GCP_MACHINE:-e2-standard-4}"     # 4 vCPU / 16 GB (API peaked at 3.8 GB on syncs; re-embed + graph builds want headroom)
DISK_GB="${CHUM_GCP_DISK_GB:-60}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
G="gcloud --project $PROJECT"
REPO_URL="https://github.com/CodeChum/chum-mem.git"

valid_ref() { [[ "$1" =~ ^[A-Za-z0-9._/-]+$ && "$1" != -* && "$1" != *..* ]]; }
resolve_ref() {  # branch/tag -> commit SHA (a SHA passes through)
  local ref="$1" sha
  if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then printf '%s' "$ref"; return; fi
  sha=$(git ls-remote "$REPO_URL" "refs/heads/$ref" "refs/tags/$ref^{}" "refs/tags/$ref" | awk 'NR==1 {print $1}')
  [[ -n "$sha" ]] || { echo "cannot resolve $ref on $REPO_URL" >&2; exit 1; }
  printf '%s' "$sha"
}

case "${1:-create}" in
  create)
    # Firewall: allow SSH only from Google's IAP range, tagged instances only.
    if ! $G compute firewall-rules describe chum-mem-allow-iap-ssh >/dev/null 2>&1; then
      $G compute firewall-rules create chum-mem-allow-iap-ssh \
        --direction=INGRESS --action=ALLOW --rules=tcp:22,tcp:63001 \
        --source-ranges=35.235.240.0/20 --target-tags=chum-mem \
        --description="IAP TCP forwarding (SSH + API tunnel) to chum-mem"
    fi
    REF="$(resolve_ref "${CHUM_MEM_REF:-main}")"
    echo "Pinning the VM to chum-mem commit $REF"
    $G compute instances create "$NAME" \
      --zone="$ZONE" --machine-type="$MACHINE" \
      --image-family=debian-12 --image-project=debian-cloud \
      --boot-disk-size="${DISK_GB}GB" --boot-disk-type=pd-balanced \
      --tags=chum-mem \
      --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write \
      --metadata=enable-oslogin=TRUE,chum-mem-ref="$REF" \
      --metadata-from-file=startup-script="$HERE/startup.sh" \
      --labels=app=chum-mem,env=pilot,owner=cymmer
    echo "Created $NAME. The startup script builds the Rust images (20-30 min). Follow with: $0 logs"
    echo "It generates the team and admin API tokens into /opt/chum-mem/src/.env (mode 600); read them over '$0 ssh'."
    ;;
  deploy)
    # Roll the VM to a reviewed ref: record it in metadata (so a re-created
    # disk clones the same commit), refresh the startup script from this
    # checkout, then run it with --deploy over IAP SSH (fetch, checkout, rebuild).
    REF_IN="${2:-}"
    [[ -n "$REF_IN" ]] && valid_ref "$REF_IN" || { echo "usage: $0 deploy <commit|tag|branch>"; exit 2; }
    REF="$(resolve_ref "$REF_IN")"
    echo "Deploying chum-mem commit $REF to $NAME"
    $G compute instances add-metadata "$NAME" --zone="$ZONE" \
      --metadata=chum-mem-ref="$REF" --metadata-from-file=startup-script="$HERE/startup.sh"
    $G compute ssh "$NAME" --zone="$ZONE" --tunnel-through-iap -- "sudo bash -s -- --deploy $REF" < "$HERE/startup.sh"
    ;;
  status)
    $G compute instances describe "$NAME" --zone="$ZONE" --format='value(status,machineType.basename(),networkInterfaces[0].networkIP)'
    ;;
  logs)
    $G compute ssh "$NAME" --zone="$ZONE" --tunnel-through-iap -- 'sudo tail -n 40 /var/log/chum-mem-startup.log'
    ;;
  ssh)
    $G compute ssh "$NAME" --zone="$ZONE" --tunnel-through-iap
    ;;
  tunnel)
    # Each engineer runs this (or a launchd/systemd service): the plugin then talks to localhost:63001.
    echo "Forwarding localhost:63001 -> $NAME:63001 through IAP (Ctrl-C to stop)"
    $G compute start-iap-tunnel "$NAME" 63001 --local-host-port=localhost:63001 --zone="$ZONE"
    ;;
  delete)
    $G compute instances delete "$NAME" --zone="$ZONE"
    ;;
  *) echo "usage: $0 [create|deploy <ref>|status|logs|ssh|tunnel|delete]"; exit 2 ;;
esac
