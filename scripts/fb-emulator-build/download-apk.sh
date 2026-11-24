#!/usr/bin/env bash
# Runs INSIDE the emulator-runner step: install Facebook, then save + VERIFY a named snapshot "fb_ready".
# Input: $RUNNER_TEMP/fb.apk (a single APK, or a zip containing one or more APKs)
#
# THE FIX: the old version waited for sys.boot_completed==1, installed, then did a blind `sleep 25`
# and saved the snapshot - trusting that the system was fully ready without ever re-checking.
# sys.boot_completed can read 1 before PackageManagerService is actually answering binder calls.
# That is exactly the state captured in your logcat ("iorapd: Reconnect to package manager service:
# 17 times" / "Waiting for service 'package_native'..." as the LAST lines ever logged - the snapshot
# froze that exact broken moment). Every restore of a snapshot saved mid-race resumes the SAME
# broken, frozen state forever - which is why login-backup.sh failed 3/3 times, every single run.
#
# This version never trusts a boot flag or a sleep alone: it actively polls `pm list packages`
# until the package manager genuinely answers (same check login-backup.sh's wait_for_boot uses),
# both before installing and again before saving. Then - the critical new step - after saving the
# snapshot it immediately RELOADS it in place and re-runs the same checks from scratch, so a broken
# snapshot is caught and retried right here, never silently uploaded as if it were good.
set -uo pipefail   # not -e: this script makes its own pass/fail decisions around retries

PKG="${PACKAGE_NAME:-com.facebook.katana}"
SRC="${RUNNER_TEMP:-/tmp}/fb.apk"
WORK="$(mktemp -d)"
MAX_SAVE_TRIES="${MAX_SAVE_TRIES:-3}"
PM_WAIT_SECS="${PM_WAIT_SECS:-90}"     # matches login-backup.sh's own wait_for_boot timeout
BOOT_WAIT_SECS="${BOOT_WAIT_SECS:-420}"

log() { echo "[install $(date -u +%H:%M:%S)] $*"; }

boot_completed() { [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; }

wait_boot_completed() {
  local t0=$SECONDS
  until boot_completed; do
    (( SECONDS - t0 > BOOT_WAIT_SECS )) && return 1
    sleep 2
  done
  return 0
}

# The actual fix: don't trust sys.boot_completed alone. Poll pm until it genuinely answers.
wait_pm() {
  local tries=0
  until adb shell pm list packages 2>&1 | grep -q '^package:'; do
    tries=$((tries + 1))
    (( tries >= PM_WAIT_SECS )) && return 1
    sleep 1
  done
  return 0
}

adb wait-for-device
wait_boot_completed || { log "ERROR: emulator never reached sys.boot_completed=1"; exit 1; }
log "emulator booted (boot_completed=1)"
wait_pm || { log "ERROR: package manager service never responded after boot (waited ${PM_WAIT_SECS}s)"; exit 1; }
log "package manager service confirmed responding"

unzip -l "$SRC" > "$WORK/list.txt"
if grep -q 'AndroidManifest.xml' "$WORK/list.txt"; then
  APKS=("$SRC")                                   # the file itself is an APK
else
  unzip -q "$SRC" -d "$WORK/x"                    # zip / split-APK bundle
  mapfile -t APKS < <(find "$WORK/x" -name '*.apk' | sort)
fi
[ "${#APKS[@]}" -gt 0 ] || { log "ERROR: no APK found"; exit 1; }
log "installing ${#APKS[@]} apk file(s)"

if [ "${#APKS[@]}" -eq 1 ]; then
  adb install -r -g "${APKS[0]}" || { log "ERROR: adb install failed"; exit 1; }
else
  adb install-multiple -r -g "${APKS[@]}" || { log "ERROR: adb install-multiple failed"; exit 1; }
fi

adb shell pm list packages | grep -q "package:$PKG" || { log "ERROR: $PKG not installed"; exit 1; }
log "$PKG installed (not launched, not logged in)"

adb shell input keyevent KEYCODE_HOME
# don't just sleep blind: confirm pm is STILL responsive after install/dexopt, then add a safety margin
wait_pm || { log "ERROR: package manager stopped responding after install"; exit 1; }
sleep 15   # safety margin: let dexopt / disk settle before freezing the snapshot

# Saves the snapshot, then immediately reloads it IN PLACE and re-checks it from scratch - the exact
# same check login-backup.sh will do in production, weeks later. If this fails here, it's caught now,
# not after it's already been shipped as "the" working snapshot.
save_and_verify() {
  local attempt="$1"
  log "saving snapshot fb_ready (attempt $attempt/$MAX_SAVE_TRIES)"
  adb emu avd snapshot save fb_ready
  adb emu avd snapshot list | grep -q fb_ready || { log "snapshot save did not register in 'snapshot list'"; return 1; }

  log "verifying: reloading fb_ready fresh and re-checking from scratch"
  adb emu avd snapshot load fb_ready
  sleep 3
  adb wait-for-device
  wait_boot_completed || { log "VERIFY FAILED: reloaded snapshot never reached boot_completed=1"; return 1; }
  wait_pm || { log "VERIFY FAILED: reloaded snapshot's package manager never responded (this is the exact bug we're preventing)"; return 1; }
  adb shell pm list packages | grep -q "package:$PKG" || { log "VERIFY FAILED: $PKG missing after reload"; return 1; }
  log "VERIFIED: fb_ready reloads cleanly and $PKG is present"
  return 0
}

ok=0
for attempt in $(seq 1 "$MAX_SAVE_TRIES"); do
  if save_and_verify "$attempt"; then ok=1; break; fi
  (( attempt < MAX_SAVE_TRIES )) || break
  log "attempt $attempt failed verification - rebooting the guest fresh and trying again"
  adb reboot
  adb wait-for-device
  wait_boot_completed || { log "guest did not come back after reboot, aborting"; break; }
  wait_pm || log "WARNING: pm slow after reboot, continuing anyway"
  sleep 5
done

if [ "$ok" -ne 1 ]; then
  log "FATAL: could not produce a WORKING fb_ready snapshot after $MAX_SAVE_TRIES tries - failing the build on purpose"
  log "(uploading a snapshot that fails its own reload check would just move this failure downstream to every future login run)"
  exit 1
fi
log "DONE: fb_ready snapshot saved and verified good"
