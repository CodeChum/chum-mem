#!/usr/bin/env bash
# vm-users.sh — runs ON the VM (as root, piped over IAP SSH by deploy-vm.sh):
# edits CHUM_MEM_USER_TOKENS in /opt/chum-mem/src/.env and recreates the api
# container so it reads the new list. Entries are `email:sha256hex`; the token
# itself never reaches the VM.
#
#   vm-users.sh add <email> <sha256hex>   add or replace that engineer's entry
#   vm-users.sh remove <email>            drop it
#   vm-users.sh list                      print the emails (no hashes)
set -euo pipefail
cd "${CHUM_APP_SRC:-/opt/chum-mem/src}"  # override for tests only
KEY=CHUM_MEM_USER_TOKENS

current() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$KEY="* ]]; then printf '%s' "${line#*=}"; return 0; fi
  done < .env
}
write() {  # $1 new value: replace or append KEY=..., keeping .env 0600 and its owner
  local line found=0 tmp owner
  owner="$(stat -c '%u:%g' .env)"
  tmp="$(mktemp .env.XXXXXX)"
  chmod 600 "$tmp"
  chown "$owner" "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$KEY="* ]]; then printf '%s=%s\n' "$KEY" "$1" >> "$tmp"; found=1
    else printf '%s\n' "$line" >> "$tmp"; fi
  done < .env
  [[ "$found" -eq 1 ]] || printf '%s=%s\n' "$KEY" "$1" >> "$tmp"
  mv -f "$tmp" .env
}
without() {  # $1 email -> current entries minus that email's
  local entry out=""
  IFS=',' read -ra entries <<< "$(current)"
  for entry in "${entries[@]}"; do
    [[ -z "$entry" || "${entry%:*}" == "$1" ]] && continue
    out="${out:+$out,}$entry"
  done
  printf '%s' "$out"
}
restart_api() {
  docker compose up -d api >/dev/null
  # The API listens on the internal IP only (startup.sh override); take it from
  # the metadata server like startup.sh does (hostname -I may list a Docker
  # bridge first).
  local ip
  ip="$(curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)"
  for _ in $(seq 1 60); do
    curl -sf --max-time 2 "http://$ip:63001/ready" >/dev/null 2>&1 && { echo "api restarted and ready"; return 0; }
    sleep 2
  done
  echo "the .env change is applied but the api is not ready yet; check: docker compose logs --tail 50 api" >&2
  return 1
}

EMAIL="$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z')"
case "${1:-}" in
  add)
    HASH="${3:-}"
    [[ "$EMAIL" =~ ^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]+$ && "$HASH" =~ ^[0-9a-f]{64}$ ]] || { echo "usage: vm-users.sh add <email> <sha256hex>" >&2; exit 2; }
    rest="$(without "$EMAIL")"
    write "${rest:+$rest,}$EMAIL:$HASH"
    restart_api
    ;;
  remove)
    [[ -n "$EMAIL" ]] || { echo "usage: vm-users.sh remove <email>" >&2; exit 2; }
    write "$(without "$EMAIL")"
    restart_api
    ;;
  list)
    IFS=',' read -ra entries <<< "$(current)"
    for entry in "${entries[@]}"; do [[ -n "$entry" ]] && printf '%s\n' "${entry%:*}"; done
    ;;
  *) echo "usage: vm-users.sh add <email> <sha256hex> | remove <email> | list" >&2; exit 2 ;;
esac
