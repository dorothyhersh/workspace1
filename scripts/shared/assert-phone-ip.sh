#!/usr/bin/env bash
# Fail-closed guard: succeeds only if traffic currently leaves through the phone exit node.
# Call right before any Facebook login. Needs BASELINE_IP and PHONE_IP in the environment.
set -uo pipefail

ARTIFACTS="${GITHUB_WORKSPACE:-$(pwd)}/artifacts"
mkdir -p "$ARTIFACTS"

# 1) Tailscale must still have the phone selected as exit node (captured first: no SIGPIPE, with timeout)
TSJSON="$(timeout -k 3 15 tailscale status --json 2>/dev/null || true)"
if ! grep -q '"ExitNodeStatus"' <<<"$TSJSON"; then
  echo "[guard] ABORT: no exit node is active in Tailscale"
  exit 1
fi

# 2) Public IP must differ from the runner's own IP
CUR_IP=""
for i in 1 2 3; do
  CUR_IP=$(curl -s --max-time 10 https://ifconfig.me || true)
  [ -n "$CUR_IP" ] && break
done
echo "[guard] baseline IP: ${BASELINE_IP:-unknown}"
echo "[guard] current IP:  ${CUR_IP:-none}"
if [ -z "$CUR_IP" ] || [ "$CUR_IP" = "${BASELINE_IP:-}" ]; then
  echo "[guard] ABORT: traffic is not leaving through the phone"
  exit 1
fi

# 3) Optional: if you set EXPECTED_PHONE_IP, it must match exactly
if [ -n "${EXPECTED_PHONE_IP:-}" ] && [ "$CUR_IP" != "$EXPECTED_PHONE_IP" ]; then
  echo "[guard] ABORT: IP $CUR_IP is not the expected phone IP $EXPECTED_PHONE_IP"
  exit 1
fi

echo "[guard] OK: login may proceed through the phone IP $CUR_IP"
