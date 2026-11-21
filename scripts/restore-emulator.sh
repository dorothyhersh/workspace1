#!/usr/bin/env bash
# restore-emulator.sh - NO GitHub cache. Restores the clean emulator (AVD + snapshot fb_ready, and the SDK
# emulator + system image) from the 90-day artifact "emulator-backup" of the newest successful run of
# "FB - Build emulator + install Facebook". Needs GH_TOKEN and GITHUB_REPOSITORY (set by the workflow).
set -uo pipefail
say() { echo "[$(date -u +%H:%M:%S)] [restore-emu] $*"; }
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/usr/local/lib/android/sdk}}"
TMP="${RUNNER_TEMP:-/tmp}/emu"

ok=0
for RUN_ID in $(gh run list --repo "$GITHUB_REPOSITORY" --workflow fb-emulator-build.yml --status success --limit 10 --json databaseId --jq '.[].databaseId'); do
  rm -rf "$TMP"
  say "downloading artifact emulator-backup from build run $RUN_ID"
  if gh run download "$RUN_ID" --repo "$GITHUB_REPOSITORY" -n emulator-backup -D "$TMP" 2>/dev/null && [ -s "$TMP/avd.tar.zst" ]; then ok=1; break; fi
  say "run $RUN_ID has no usable artifact (expired or built without it), trying an older one"
done
[ "$ok" = 1 ] || { say "ERROR: no emulator artifact found. Run 'FB - Build emulator + install Facebook' first (artifact is kept 90 days)."; exit 1; }

mkdir -p "$HOME"
# AVD and SDK parts extract in parallel
( zstd -d -T0 -c "$TMP/avd.tar.zst" | tar -C "$HOME" -xf - ) & p1=$!
p2=""
if [ -s "$TMP/sdk.tar.zst" ]; then
  sudo mkdir -p "$SDK"
  ( zstd -d -T0 -c "$TMP/sdk.tar.zst" | sudo tar -C "$SDK" -xf - ) & p2=$!
else
  say "artifact has no sdk.tar.zst (older build) - run-with-emulator.sh will install emulator + system image with sdkmanager"
fi
wait $p1 || { say "ERROR: AVD extract failed"; exit 1; }
[ -z "$p2" ] || wait $p2 || { say "ERROR: SDK extract failed"; exit 1; }
rm -rf "$TMP"

ls -la ~/.android/avd/fb-base.avd/snapshots/
test -d ~/.android/avd/fb-base.avd/snapshots/fb_ready || { say "ERROR: snapshot fb_ready missing"; exit 1; }
say "OK: clean emulator restored"
