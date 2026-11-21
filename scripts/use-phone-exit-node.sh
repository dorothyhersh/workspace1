#!/usr/bin/env bash
# Route this runner's traffic (and so the whole emulator) through the phone exit node,
# print everything that happens, and refuse to continue if it doesn't work.
# Expects: PHONE_IP, BASELINE_IP in the environment. Tailscale must already be connected.
# EVERY tailscale/curl call has its own timeout: a hanging `tailscale status` used to freeze the whole
# run for 15+ minutes (timeout on the parent bash does not kill a child that holds the output pipe).
set -uo pipefail

ts() { date -u '+%H:%M:%S'; }
say() { echo "[$(ts)] [exitnode] $*"; }
TS() { timeout -k 3 "${TS_TIMEOUT:-20}" tailscale "$@"; }

say "BASELINE_IP=${BASELINE_IP:-unknown}  PHONE_IP=${PHONE_IP:-unset}"
say "tailscale status BEFORE:"
TS status || say "(tailscale status failed or timed out - continuing)"

say "setting exit node to $PHONE_IP"
ok=0
for i in 1 2 3; do
  if timeout -k 3 30 sudo tailscale set --exit-node="$PHONE_IP" --exit-node-allow-lan-access=true; then ok=1; break; fi
  say "tailscale set failed/timed out (try $i)"; sleep 2
done
[ "$ok" = 1 ] || { say "ERROR: tailscale set failed"; exit 1; }

say "tailscale status AFTER:"
TS status || say "(tailscale status failed or timed out - continuing)"

say "fetching public IP through the phone (up to 4 tries, 8s each)"
NEW_IP=""
for i in 1 2 3 4; do
  NEW_IP=$(curl -s --max-time 8 https://ifconfig.me || true)
  say "try $i -> ${NEW_IP:-nothing}"
  [ -n "$NEW_IP" ] && break
  sleep 1
done
say "Baseline IP: ${BASELINE_IP:-unknown}"
say "Phone IP:    ${NEW_IP:-none}"

if [ -z "$NEW_IP" ] || [ "$NEW_IP" = "${BASELINE_IP:-}" ]; then
  say "ERROR: traffic is NOT going through the phone (is the phone online in Tailscale and offering exit node?)"
  exit 1
fi

say "OK: everything from here on uses the phone IP $NEW_IP"
