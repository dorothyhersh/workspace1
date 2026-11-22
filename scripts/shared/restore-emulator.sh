#!/usr/bin/env bash
# restore-emulator.sh - restores the clean emulator (AVD + snapshot fb_ready, SDK emulator + system image)
# from the 90-day artifacts of the newest successful run of "FB - Build emulator + install Facebook".
# New builds have two artifacts (emulator-avd, emulator-sdk) that are downloaded AND unpacked in parallel;
# older builds have one artifact (emulator-backup) which is still supported.
# Needs GH_TOKEN and GITHUB_REPOSITORY (set by the workflow).
set -uo pipefail
say() { echo "[$(date -u +%H:%M:%S)] [restore-emu] $*"; }
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/usr/local/lib/android/sdk}}"
TMP="${RUNNER_TEMP:-/tmp}/emu"
mkdir -p "$HOME"

dl() { gh run download "$1" --repo "$GITHUB_REPOSITORY" -n "$2" -D "$3" >/dev/null 2>&1; }
unpack_avd() { zstd -d -T0 -c "$1" | tar -C "$HOME" -xf -; }
unpack_sdk() { sudo mkdir -p "$SDK"; zstd -d -T0 -c "$1" | sudo tar -C "$SDK" -xf -; }

ok=0
for RUN_ID in $(gh run list --repo "$GITHUB_REPOSITORY" --workflow fb-emulator-build.yml --status success --limit 10 --json databaseId --jq '.[].databaseId'); do
  case " ${SKIP_RUNS:-} " in *" $RUN_ID "*) say "skipping build run $RUN_ID (snapshot was broken)"; continue;; esac
  rm -rf "$TMP"; mkdir -p "$TMP/avd" "$TMP/sdk"
  say "build run $RUN_ID: downloading emulator-avd + emulator-sdk in parallel"
  dl "$RUN_ID" emulator-avd "$TMP/avd" & d1=$!
  dl "$RUN_ID" emulator-sdk "$TMP/sdk" & d2=$!
  wait $d1; wait $d2
  if [ -s "$TMP/avd/avd.tar.zst" ]; then ok=1; break; fi
  say "no emulator-avd artifact, trying the older single artifact emulator-backup"
  if dl "$RUN_ID" emulator-backup "$TMP/avd" && [ -s "$TMP/avd/avd.tar.zst" ]; then
    [ -s "$TMP/avd/sdk.tar.zst" ] && mv "$TMP/avd/sdk.tar.zst" "$TMP/sdk/sdk.tar.zst"
    ok=1; break
  fi
  say "run $RUN_ID has no usable artifact (expired or built without it), trying an older one"
done
[ "$ok" = 1 ] || { say "ERROR: no emulator artifact found. Run 'FB - Build emulator + install Facebook' first (kept 90 days)."; exit 1; }
say "download done (build run $RUN_ID), unpacking"
mkdir -p "${RUNNER_TEMP:-/tmp}"; echo "$RUN_ID" > "${RUNNER_TEMP:-/tmp}/restored-run-id"

unpack_avd "$TMP/avd/avd.tar.zst" & p1=$!
p2=""
if [ -s "$TMP/sdk/sdk.tar.zst" ]; then unpack_sdk "$TMP/sdk/sdk.tar.zst" & p2=$!
else say "no sdk archive - run-with-emulator.sh will install emulator + system image with sdkmanager"; fi
wait $p1 || { say "ERROR: AVD extract failed"; exit 1; }
[ -z "$p2" ] || wait $p2 || { say "ERROR: SDK extract failed"; exit 1; }
rm -rf "$TMP"

ls -la ~/.android/avd/fb-base.avd/snapshots/
test -d ~/.android/avd/fb-base.avd/snapshots/fb_ready || { say "ERROR: snapshot fb_ready missing"; exit 1; }
say "OK: clean emulator restored"
