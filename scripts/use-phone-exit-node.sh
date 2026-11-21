#!/usr/bin/env bash
# Route this runner's traffic (and so the whole emulator) through the phone exit node,
# print everything that happens, and refuse to continue if it doesn't work.
# Expects: PHONE_IP, BASELINE_IP in the environment. Tailscale must already be connected.
set -uo pipefail

ts() { date -u '+%H:%M:%S'; }
say() { echo "[$(ts)] [exitnode] $*"; }

say "BASELINE_IP=${BASELINE_IP:-unknown}  PHONE_IP=${PHONE_IP:-unset}"
say "tailscale status BEFORE:"
tailscale status || true

say "setting exit node to $PHONE_IP"
sudo tailscale set --exit-node="$PHONE_IP" --exit-node-allow-lan-access=true || { say "ERROR: tailscale set failed"; exit 1; }
sleep 8

say "tailscale status AFTER:"
tailscale status || true

say "ping to phone (5 tries):"
tailscale ping -c 5 "$PHONE_IP" || true

say "network check (DERP / direct path):"
tailscale netcheck 2>&1 | head -n 25 || true

say "routes:"
ip route show | head -n 20 || true
ip -6 route show | head -n 10 || true

say "fetching public IP through the phone (up to 3 tries, 30s each)"
NEW_IP=""
for i in 1 2 3; do
  NEW_IP=$(curl -s --max-time 30 https://ifconfig.me || true)
  say "try $i -> ${NEW_IP:-nothing}"
  [ -n "$NEW_IP" ] && break
  sleep 3
done
say "Baseline IP: ${BASELINE_IP:-unknown}"
say "Phone IP:    ${NEW_IP:-none}"
say "Provider:    $(curl -s --max-time 20 "https://ipinfo.io/${NEW_IP}/org" || echo unknown)"

if [ -z "$NEW_IP" ] || [ "$NEW_IP" = "${BASELINE_IP:-}" ]; then
  say "ERROR: traffic is NOT going through the phone"
  exit 1
fi

say "small speed check through the phone (2 MB, 40s max)"
curl -s -o /dev/null --max-time 40 -w '[exitnode] download %{speed_download} bytes/s, total %{time_total}s\n' \
  "https://speed.cloudflare.com/__down?bytes=2000000" || say "speed check failed or timed out"

say "OK: everything from here on uses the phone IP $NEW_IP"
