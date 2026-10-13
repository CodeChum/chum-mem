#!/bin/bash
# tunnel-auth-check.sh — run every 5 minutes by launchd (setup-engineer.sh copies
# it to ~/.config/chum-mem/ and installs com.codechum.chum-mem-auth-check).
#
# Workspace Cloud session control expires every engineer's gcloud login every
# 24 h. The tunnel agent keeps running but IAP refuses each connection (4033 in
# its log), so team memory silently stops. This asks the engineer to sign in
# again and, on "Sign in", runs the browser login. The tunnel loads credentials
# per connection, so it recovers without a restart. A 4003 (firewall or VM down)
# is not the engineer's to fix and is left to the hook notice.
#
# Env: CHUM_LOCAL_PORT, CHUM_TUNNEL_LOG, CHUM_GCLOUD (set in the launchd plist)
set -u
PORT="${CHUM_LOCAL_PORT:-63001}"
LOG="${CHUM_TUNNEL_LOG:-$HOME/Library/Logs/com.codechum.chum-mem-tunnel.log}"
GCLOUD="${CHUM_GCLOUD:-gcloud}"
SNOOZE="$HOME/.config/chum-mem/.auth-snooze"

if curl -sf --max-time 10 "http://localhost:$PORT/health" >/dev/null 2>&1; then
  rm -f "$SNOOZE"; exit 0
fi
sleep 1  # the failed /health above is what makes the tunnel log the IAP error
[[ -n "$(find "$LOG" -mmin -10 2>/dev/null)" ]] || exit 0
case "$(tail -n 60 "$LOG" 2>/dev/null | grep -oE '\[40(03|33):|invalid_grant|[Rr]eauthentication' | tail -1)" in
  "[4033:"|invalid_grant|[Rr]eauthentication) ;;
  *) exit 0 ;;
esac
[[ -n "$(find "$SNOOZE" -mmin -60 2>/dev/null)" ]] && exit 0

CFG="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}"
ACCOUNT="$(sed -n 's/^account *= *//p' "$CFG/configurations/config_$(cat "$CFG/active_config" 2>/dev/null || echo default)" 2>/dev/null | head -1)"

ANSWER="$(osascript - "$ACCOUNT" <<'EOF' 2>/dev/null
on run argv
  set acct to item 1 of argv
  if acct is "" then set acct to "your @codechum.com account"
  display dialog "Your Google Cloud sign-in has expired, so team memory (chum-mem) is disconnected." & return & return & "Sign in again as " & acct & "? A browser window opens." with title "chum-mem" buttons {"Later", "Sign in"} default button "Sign in" with icon caution giving up after 900
  return button returned of result
end run
EOF
)"
if [[ "$ANSWER" != "Sign in" ]]; then
  mkdir -p "$(dirname "$SNOOZE")" && : > "$SNOOZE"  # Later, or no answer: ask again in an hour
  exit 0
fi

# gcloud waits for the browser callback forever; give up after 10 minutes so
# launchd can run this check again.
"$GCLOUD" auth login ${ACCOUNT:+"$ACCOUNT"} --brief >/dev/null 2>&1 &
LOGIN_PID=$!
for _ in $(seq 1 600); do kill -0 "$LOGIN_PID" 2>/dev/null || break; sleep 1; done
kill "$LOGIN_PID" 2>/dev/null

for _ in 1 2 3 4 5; do
  curl -sf --max-time 5 "http://localhost:$PORT/health" >/dev/null 2>&1 && {
    osascript -e 'display notification "Signed in. Team memory is connected again." with title "chum-mem"' 2>/dev/null
    exit 0
  }
  sleep 3
done
osascript -e 'display notification "Sign-in did not complete. You will be asked again in 5 minutes." with title "chum-mem"' 2>/dev/null
exit 0
