#!/usr/bin/env bash
# Download the Facebook APK/zip on the RUNNER's own internet (before the phone exit node is on).
# Env: APK_URL (optional), APK_MEGA_FILE, RCLONE_CONF_CONTENT, MEGA_REMOTE (default mega), RUNNER_TEMP
# (Unchanged - no bug found here. Reproduced as-is so all files you keep for this workflow are in sync.)
set -uo pipefail

ts() { date -u '+%H:%M:%S'; }
say() { echo "[$(ts)] [download] $*"; }

APK_OUT="${RUNNER_TEMP:-/tmp}/fb.apk"
MEGA_REMOTE="${MEGA_REMOTE:-mega}"

say "public IP during download (runner internet, NOT the phone): $(curl -s --max-time 20 https://ifconfig.me || echo unknown)"
say "baseline IP recorded earlier: ${BASELINE_IP:-unknown}"

if [ -n "${APK_URL:-}" ]; then
  say "downloading APK from URL: $APK_URL"
  curl -L --fail --retry 3 --connect-timeout 20 --max-time 900 \
    -w '[download] done: %{size_download} bytes in %{time_total}s (%{speed_download} bytes/s)\n' \
    -o "$APK_OUT" "$APK_URL" || { say "ERROR: URL download failed"; exit 1; }
else
  [ -n "${APK_MEGA_FILE:-}" ] || { say "ERROR: neither APK_URL nor APK_MEGA_FILE is set"; exit 1; }
  say "downloading from Mega: ${APK_MEGA_FILE}"

  if ! command -v rclone >/dev/null 2>&1 || ! rclone help backends 2>/dev/null | grep -qiE '(^|[[:space:]])mega([[:space:]]|$)'; then
    say "installing official rclone"
    tmp="$(mktemp -d)"
    curl -fsSL --max-time 120 -o "$tmp/rclone.zip" https://downloads.rclone.org/rclone-current-linux-amd64.zip \
      && unzip -q "$tmp/rclone.zip" -d "$tmp" \
      && sudo install -m 0755 "$tmp"/rclone-*-linux-amd64/rclone /usr/local/bin/rclone \
      || { say "ERROR: could not install rclone"; exit 1; }
    rm -rf "$tmp"; hash -r
  fi

  CFG="${HOME}/.config/rclone/rclone.conf"
  if [ ! -s "$CFG" ]; then
    [ -n "${RCLONE_CONF_CONTENT:-}" ] || { say "ERROR: RCLONE_CONF secret is empty"; exit 1; }
    mkdir -p "$(dirname "$CFG")"
    printf '%s\n' "$RCLONE_CONF_CONTENT" > "$CFG"; chmod 600 "$CFG"
  fi
  rclone listremotes 2>/dev/null | grep -qx "${MEGA_REMOTE}:" || { say "ERROR: remote '${MEGA_REMOTE}' not in rclone config"; exit 1; }

  say "rclone copy starting (progress every 10s, 15 min max)"
  timeout 900 rclone copyto "${MEGA_REMOTE}:${APK_MEGA_FILE}" "$APK_OUT" \
    --retries 5 -v --stats 10s --stats-one-line \
    || { say "ERROR: Mega download failed or timed out"; exit 1; }
fi

[ -s "$APK_OUT" ] || { say "ERROR: downloaded file is empty"; exit 1; }
say "downloaded file:"
ls -l "$APK_OUT"
[ "$(head -c 2 "$APK_OUT")" = "PK" ] || { say "ERROR: not an APK or zip (use a direct link)"; exit 1; }
say "OK: download finished, now the phone exit node can be switched on"
