#!/usr/bin/env bash
# deploy-vm.sh — create the chum-mem VM on GCP. No public ingress: SSH and the API
# are reached through IAP TCP forwarding only (Google IAM is the access control).
#
# Usage: deploy-vm.sh [create|status|tunnel|ssh|logs|delete]
set -euo pipefail
PROJECT="${CHUM_GCP_PROJECT:-gradechum}"
ZONE="${CHUM_GCP_ZONE:-asia-east1-b}"
NAME="${CHUM_GCP_VM:-gradechum-chum-mem}"
MACHINE="${CHUM_GCP_MACHINE:-e2-standard-4}"     # 4 vCPU / 16 GB (API peaked at 3.8 GB on syncs; re-embed + graph builds want headroom)
DISK_GB="${CHUM_GCP_DISK_GB:-60}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
G="gcloud --project $PROJECT"

case "${1:-create}" in
  create)
    # Firewall: allow SSH only from Google's IAP range, tagged instances only.
    if ! $G compute firewall-rules describe chum-mem-allow-iap-ssh >/dev/null 2>&1; then
      $G compute firewall-rules create chum-mem-allow-iap-ssh \
        --direction=INGRESS --action=ALLOW --rules=tcp:22 \
        --source-ranges=35.235.240.0/20 --target-tags=chum-mem \
        --description="IAP TCP forwarding (SSH + API tunnel) to chum-mem"
    fi
    $G compute instances create "$NAME" \
      --zone="$ZONE" --machine-type="$MACHINE" \
      --image-family=debian-12 --image-project=debian-cloud \
      --boot-disk-size="${DISK_GB}GB" --boot-disk-type=pd-balanced \
      --tags=chum-mem \
      --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write \
      --metadata=enable-oslogin=TRUE \
      --metadata-from-file=startup-script="$HERE/startup.sh" \
      --labels=app=chum-mem,env=pilot,owner=cymmer
    echo "Created $NAME. The startup script builds the Rust images (20-30 min). Follow with: $0 logs"
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
  *) echo "usage: $0 [create|status|logs|ssh|tunnel|delete]"; exit 2 ;;
esac
