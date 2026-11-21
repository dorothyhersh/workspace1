#!/usr/bin/env bash
# Runs INSIDE the emulator-runner step: install Facebook, then save a named snapshot "fb_ready".
# Input: $RUNNER_TEMP/fb.apk (a single APK, or a zip containing one or more APKs)
set -euo pipefail
PKG="${PACKAGE_NAME:-com.facebook.katana}"
SRC="${RUNNER_TEMP:-/tmp}/fb.apk"
WORK="$(mktemp -d)"

adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 2; done
echo "[install] emulator booted"

unzip -l "$SRC" > "$WORK/list.txt"
if grep -q 'AndroidManifest.xml' "$WORK/list.txt"; then
  APKS=("$SRC")                                   # the file itself is an APK
else
  unzip -q "$SRC" -d "$WORK/x"                    # zip / split-APK bundle
  mapfile -t APKS < <(find "$WORK/x" -name '*.apk' | sort)
fi
[ "${#APKS[@]}" -gt 0 ] || { echo "[install] ERROR: no APK found"; exit 1; }
echo "[install] installing ${#APKS[@]} apk file(s)"

if [ "${#APKS[@]}" -eq 1 ]; then
  adb install -r -g "${APKS[0]}"
else
  adb install-multiple -r -g "${APKS[@]}"
fi

adb shell pm list packages | grep -q "package:$PKG" || { echo "[install] ERROR: $PKG not installed"; exit 1; }
echo "[install] $PKG installed (not launched, not logged in)"

adb shell input keyevent KEYCODE_HOME
sleep 25                                          # let package manager / dexopt settle

adb emu avd snapshot save fb_ready
adb emu avd snapshot list
adb emu avd snapshot list | grep -q fb_ready || { echo "[install] ERROR: snapshot not saved"; exit 1; }
echo "[install] snapshot fb_ready saved"
