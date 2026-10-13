#!/usr/bin/env bash
# deploy-vm.sh — create the chum-mem VM on GCP. No public ingress: SSH and the API
# are reached through IAP TCP forwarding only (Google IAM is the access control).
#
# Usage: deploy-vm.sh [create|deploy <ref>|status|tunnel|ssh|logs|add-user <email>|remove-user <email>|users|
#                      enable-backups|backup-now|backups|delete]
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
BACKUP_BUCKET="${CHUM_BACKUP_BUCKET:-$PROJECT-chum-mem-backups}"
SNAPSHOT_POLICY="${CHUM_SNAPSHOT_POLICY:-default-schedule-1}"
VM_SA="chum-mem-vm@$PROJECT.iam.gserviceaccount.com"
VM_SCOPES="https://www.googleapis.com/auth/devstorage.read_write,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write"

valid_ref() { [[ "$1" =~ ^[A-Za-z0-9._/-]+$ && "$1" != -* && "$1" != *..* ]]; }
resolve_ref() {  # branch/tag -> commit SHA (a SHA passes through)
  local ref="$1" sha
  if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then printf '%s' "$ref"; return; fi
  sha=$(git ls-remote "$REPO_URL" "refs/heads/$ref" "refs/tags/$ref^{}" "refs/tags/$ref" | awk 'NR==1 {print $1}')
  [[ -n "$sha" ]] || { echo "cannot resolve $ref on $REPO_URL" >&2; exit 1; }
  printf '%s' "$sha"
}
# Engineers: company Google accounts only (CHUM_USER_DOMAINS, space-separated).
user_email() {
  local email domain
  email="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  [[ "$email" =~ ^[a-z0-9._%+-]+@([a-z0-9.-]+\.[a-z]+)$ ]] || { echo "usage: $0 add-user|remove-user <email>" >&2; exit 2; }
  domain="${BASH_REMATCH[1]}"
  [[ " ${CHUM_USER_DOMAINS:-codechum.com gradechum.com} " == *" $domain "* ]] || { echo "$email is not a company account (CHUM_USER_DOMAINS)" >&2; exit 2; }
  printf '%s' "$email"
}
# Same naming as setup-engineer.sh: juan.dc@codechum.com -> chum-mem-token-juan-dc-at-codechum-com
secret_name() { printf 'chum-mem-token-%s' "$(printf '%s' "$1" | sed -e 's/@/-at-/' -e 's/[^a-z0-9-]/-/g')"; }
# IAP-secured Tunnel User on THIS instance only (what the Console's "IAP > SSH
# and TCP resources" does). gcloud has no command for instance-level tunnel IAM,
# so this is read-modify-write on the IAP API with the policy etag. Binding at
# the instance keeps the project policy untouched: no conditional binding there
# (which would make other non-interactive `projects add-iam-policy-binding`
# calls fail), and revoking never touches grants for other VMs.
iap_tunnel_binding() {  # $1 add|remove, $2 email
  local num url at policy new
  num="$($G projects describe "$PROJECT" --format='value(projectNumber)')"
  url="https://iap.googleapis.com/v1/projects/$num/iap_tunnel/zones/$ZONE/instances/$NAME"
  at="$(gcloud auth print-access-token)"
  policy="$(curl -sf -X POST "$url:getIamPolicy" -H @/dev/fd/9 -H 'Content-Type: application/json' -d '{}' 9<<<"Authorization: Bearer $at")" \
    || { echo "could not read the IAP tunnel policy of $NAME" >&2; return 1; }
  new="$(printf '%s' "$policy" | jq -c --arg m "user:$2" --arg op "$1" '
    .bindings = ((.bindings // []) as $b
      | if $op == "add" then
          (if any($b[]; .role == "roles/iap.tunnelResourceAccessor") then $b
           else $b + [{role: "roles/iap.tunnelResourceAccessor", members: []}] end)
          | map(if .role == "roles/iap.tunnelResourceAccessor" then .members = ((.members + [$m]) | unique) else . end)
        else
          $b | map(if .role == "roles/iap.tunnelResourceAccessor" then .members -= [$m] else . end)
             | map(select((.members | length) > 0))
        end)
    | {policy: .}')"
  curl -sf -o /dev/null -X POST "$url:setIamPolicy" -H @/dev/fd/9 -H 'Content-Type: application/json' -d "$new" 9<<<"Authorization: Bearer $at" \
    || { echo "could not update the IAP tunnel policy of $NAME" >&2; return 1; }
  unset at
}
# Backups: a nightly pg_dump to $BACKUP_BUCKET (30-day lifecycle) plus a daily
# snapshot of the boot disk ($SNAPSHOT_POLICY, 14 days). The VM runs as its own
# service account, which holds only log/metric writing and create-only access
# to that bucket; the default compute account has project-wide Editor.
ensure_backup_infra() {
  local region="${ZONE%-*}" lifecycle
  if ! $G storage buckets describe "gs://$BACKUP_BUCKET" >/dev/null 2>&1; then
    $G storage buckets create "gs://$BACKUP_BUCKET" --location="$region" \
      --uniform-bucket-level-access --public-access-prevention
  fi
  lifecycle="$(mktemp)"
  printf '%s' '{"rule":[{"action":{"type":"Delete"},"condition":{"age":30}}]}' > "$lifecycle"
  $G storage buckets update "gs://$BACKUP_BUCKET" --lifecycle-file="$lifecycle" \
    --update-labels=app=chum-mem,env=pilot >/dev/null
  rm -f "$lifecycle"
  if ! $G iam service-accounts describe "$VM_SA" >/dev/null 2>&1; then
    $G iam service-accounts create "${VM_SA%%@*}" --display-name="chum-mem VM" \
      --description="Runtime identity of $NAME: logs, metrics, and create-only writes to gs://$BACKUP_BUCKET"
  fi
  for role in roles/logging.logWriter roles/monitoring.metricWriter; do
    $G projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$VM_SA" \
      --role="$role" --condition=None --quiet >/dev/null
  done
  $G storage buckets add-iam-policy-binding "gs://$BACKUP_BUCKET" --member="serviceAccount:$VM_SA" \
    --role=roles/storage.objectCreator >/dev/null
  if ! $G compute resource-policies describe "$SNAPSHOT_POLICY" --region="$region" >/dev/null 2>&1; then
    $G compute resource-policies create snapshot-schedule "$SNAPSHOT_POLICY" --region="$region" \
      --daily-schedule --start-time=22:00 --max-retention-days=14 \
      --on-source-disk-delete=keep-auto-snapshots
  fi
}
attach_snapshot_policy() {
  $G compute disks describe "$NAME" --zone="$ZONE" --format='value(resourcePolicies)' | grep -q "/$SNAPSHOT_POLICY\$" \
    || $G compute disks add-resource-policies "$NAME" --zone="$ZONE" --resource-policies="$SNAPSHOT_POLICY"
}
require_secret_manager() {
  $G services list --enabled --filter=config.name=secretmanager.googleapis.com --format='value(config.name)' | grep -q . \
    || { echo "Secret Manager API is not enabled on $PROJECT: gcloud services enable secretmanager.googleapis.com --project $PROJECT" >&2; exit 1; }
}

case "${1:-create}" in
  create)
    # Firewall: IAP's range only, tagged instances only. Two rules, each named for
    # what breaks without it: on 2026-10-13 the old combined rule, named
    # "...-allow-iap-ssh", was deleted as a duplicate SSH rule and every
    # engineer's tunnel failed with IAP 4003. Priority 900 beats
    # chum-mem-deny-api-non-iap (950).
    if ! $G compute firewall-rules describe chum-mem-allow-iap-api >/dev/null 2>&1; then
      $G compute firewall-rules create chum-mem-allow-iap-api \
        --direction=INGRESS --action=ALLOW --rules=tcp:63001 --priority=900 \
        --source-ranges=35.235.240.0/20 --target-tags=chum-mem \
        --description="IAP TCP forwarding to chum-mem API (63001). Required by every engineer's tunnel; do not delete."
    fi
    if ! $G compute firewall-rules describe chum-mem-allow-iap-ssh >/dev/null 2>&1; then
      $G compute firewall-rules create chum-mem-allow-iap-ssh \
        --direction=INGRESS --action=ALLOW --rules=tcp:22 --priority=900 \
        --source-ranges=35.235.240.0/20 --target-tags=chum-mem \
        --description="IAP SSH to chum-mem, used by deploy-vm.sh deploy/add-user/users"
    fi
    ensure_backup_infra
    REF="$(resolve_ref "${CHUM_MEM_REF:-main}")"
    echo "Pinning the VM to chum-mem commit $REF"
    $G compute instances create "$NAME" \
      --zone="$ZONE" --machine-type="$MACHINE" \
      --image-family=debian-12 --image-project=debian-cloud \
      --boot-disk-size="${DISK_GB}GB" --boot-disk-type=pd-balanced \
      --tags=chum-mem \
      --service-account="$VM_SA" --scopes="$VM_SCOPES" \
      --metadata=enable-oslogin=TRUE,chum-mem-ref="$REF",chum-mem-backup-bucket="$BACKUP_BUCKET" \
      --metadata-from-file=startup-script="$HERE/startup.sh" \
      --labels=app=chum-mem,env=pilot,owner=cymmer
    attach_snapshot_policy
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
  add-user)
    # One token per engineer. The token is generated here, stored only in the
    # engineer's own Secret Manager secret (readable by them alone), and never
    # printed; the VM gets its SHA-256. Also grants what the tunnel needs:
    # IAP-secured Tunnel User and read access on this
    # one instance (GA `start-iap-tunnel` looks the instance up first).
    # Re-running for the same email rotates their token.
    EMAIL="$(user_email "${2:-}")"
    SECRET="$(secret_name "$EMAIL")"
    require_secret_manager
    if $G secrets describe "$SECRET" >/dev/null 2>&1; then
      echo "rotating the token of $EMAIL ($SECRET)"
    else
      $G secrets create "$SECRET" --replication-policy=automatic \
        --labels=app=chum-mem --quiet >/dev/null
    fi
    TOKEN="$(openssl rand -hex 32)"
    printf '%s' "$TOKEN" | $G secrets versions add "$SECRET" --data-file=- --quiet >/dev/null
    HASH="$(printf '%s' "$TOKEN" | shasum -a 256 | cut -c1-64)"
    unset TOKEN
    # Older versions of a rotated secret must stop working: disable them.
    for v in $($G secrets versions list "$SECRET" --filter='state=ENABLED' --sort-by='~createTime' --format='value(name.basename())' | tail -n +2); do
      $G secrets versions disable "$v" --secret="$SECRET" --quiet >/dev/null
    done
    $G secrets add-iam-policy-binding "$SECRET" --member="user:$EMAIL" \
      --role=roles/secretmanager.secretAccessor --quiet >/dev/null
    iap_tunnel_binding add "$EMAIL"
    $G compute instances add-iam-policy-binding "$NAME" --zone="$ZONE" --member="user:$EMAIL" \
      --role=roles/compute.viewer --quiet >/dev/null
    $G compute ssh "$NAME" --zone="$ZONE" --tunnel-through-iap -- "sudo bash -s -- add $EMAIL $HASH" < "$HERE/vm-users.sh"
    echo "added $EMAIL. They run, in Claude Code at the monorepo root:"
    echo "  ! bash .claude/chum-mem/scripts/setup-engineer.sh"
    ;;
  remove-user)
    # Revokes one engineer: token entry on the VM, their secret, and the IAM
    # grants add-user made. Nobody else is affected.
    EMAIL="$(user_email "${2:-}")"
    SECRET="$(secret_name "$EMAIL")"
    $G compute ssh "$NAME" --zone="$ZONE" --tunnel-through-iap -- "sudo bash -s -- remove $EMAIL" < "$HERE/vm-users.sh"
    $G secrets delete "$SECRET" --quiet >/dev/null 2>&1 && echo "deleted $SECRET" || echo "no secret $SECRET"
    iap_tunnel_binding remove "$EMAIL" || true
    $G compute instances remove-iam-policy-binding "$NAME" --zone="$ZONE" --member="user:$EMAIL" \
      --role=roles/compute.viewer --quiet >/dev/null 2>&1 || true
    echo "removed $EMAIL"
    ;;
  users)
    $G compute ssh "$NAME" --zone="$ZONE" --tunnel-through-iap -- "sudo bash -s -- list" < "$HERE/vm-users.sh"
    ;;
  enable-backups)
    # For a VM created before backups existed. Switching the service account
    # needs the VM stopped: chum-mem is down for 1-2 minutes, and the hooks
    # spool sessions locally meanwhile.
    ensure_backup_infra
    attach_snapshot_policy
    $G compute instances add-metadata "$NAME" --zone="$ZONE" \
      --metadata=chum-mem-backup-bucket="$BACKUP_BUCKET" --metadata-from-file=startup-script="$HERE/startup.sh"
    if [[ "$($G compute instances describe "$NAME" --zone="$ZONE" --format='value(serviceAccounts[0].email)')" != "$VM_SA" ]]; then
      echo "Restarting $NAME to run as $VM_SA (chum-mem is down for 1-2 minutes)"
      $G compute instances stop "$NAME" --zone="$ZONE"
      $G compute instances set-service-account "$NAME" --zone="$ZONE" --service-account="$VM_SA" --scopes="$VM_SCOPES"
      $G compute instances start "$NAME" --zone="$ZONE"
    else
      # Already the right identity: install the timer without a restart.
      $G compute ssh "$NAME" --zone="$ZONE" --tunnel-through-iap -- 'sudo google_metadata_script_runner startup'
    fi
    echo "Backups on: nightly dump to gs://$BACKUP_BUCKET/postgres/, daily disk snapshot ($SNAPSHOT_POLICY). Test with: $0 backup-now"
    ;;
  backup-now)
    $G compute ssh "$NAME" --zone="$ZONE" --tunnel-through-iap -- \
      'sudo systemctl start chum-mem-backup.service; sudo journalctl -u chum-mem-backup.service -n 3 --no-pager -o cat'
    ;;
  backups)
    $G storage ls -l "gs://$BACKUP_BUCKET/postgres/" | tail -n 8
    $G compute snapshots list --filter="sourceDisk~/$NAME\$" --sort-by=~creationTimestamp --limit=5 \
      --format='table(name,creationTimestamp,storageBytes)'
    ;;
  delete)
    $G compute instances delete "$NAME" --zone="$ZONE"
    ;;
  *) echo "usage: $0 [create|deploy <ref>|status|logs|ssh|tunnel|add-user <email>|remove-user <email>|users|enable-backups|backup-now|backups|delete]"; exit 2 ;;
esac
