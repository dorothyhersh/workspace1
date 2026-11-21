#!/usr/bin/env bash
# run-with-emulator.sh <command...>
# Boots the cached AVD (snapshot fb_ready) headless WITHOUT android-emulator-runner, so the emulator's
# own log is kept (artifacts/emulator.log), runs <command...>, then shuts the emulator down.
# Exit code = exit code of <command...> (or 1 if the emulator never boots).
set -uo pipefail

AVD="${AVD_NAME:-fb-base}"
SNAP="${SNAPSHOT_NAME:-fb_ready}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-420}"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/usr/local/lib/android/sdk}}"
ART="${GITHUB_WORKSPACE:-$(pwd)}/artifacts"; mkdir -p "$ART"
ELOG="$ART/emulator.log"
export ANDROID_SDK_ROOT="$SDK" ANDROID_HOME="$SDK"
export PATH="$SDK/platform-tools:$SDK/emulator:$SDK/cmdline-tools/latest/bin:$PATH"

say() { echo "[$(date -u +%H:%M:%S)] [emu] $*"; }
[ "$#" -gt 0 ] || { say "usage: run-with-emulator.sh <command...>"; exit 2; }

# --- SDK pieces (the image + AVD come from the cache; emulator binary + adb are installed fresh) ---
yes | sdkmanager --licenses >/dev/null 2>&1 || true
say "installing emulator + platform-tools"
sdkmanager --install emulator platform-tools --channel=0 >/dev/null 2>&1 || say "WARNING: sdkmanager install returned non-zero"
if [ ! -d "$SDK/system-images/android-30/google_apis/x86_64" ]; then
  say "system image missing from cache, installing"
  sdkmanager --install 'system-images;android-30;google_apis;x86_64' --channel=0 >/dev/null 2>&1 || true
fi
say "emulator: $(emulator -version 2>&1 | grep -i 'version' | head -1)"
say "AVDs: $(emulator -list-avds | tr '\n' ' ')"
emulator -list-avds | grep -qx "$AVD" || { say "ERROR: AVD '$AVD' not found (cache restore problem?)"; ls -la ~/.android/avd/ || true; exit 1; }
say "snapshots on disk: $(ls ~/.android/avd/$AVD.avd/snapshots/ 2>/dev/null | tr '\n' ' ')"
df -h / | tail -1; free -m | sed -n 2p

# --- start emulator ---
adb kill-server >/dev/null 2>&1; adb start-server >/dev/null 2>&1
say "starting emulator (snapshot $SNAP)"
setsid nohup emulator -avd "$AVD" -no-window -gpu swiftshader_indirect -noaudio -no-boot-anim \
  -camera-back none -no-metrics -snapshot "$SNAP" -no-snapshot-save -verbose >"$ELOG" 2>&1 &
EPID=$!

stop_emulator() {
  adb emu kill >/dev/null 2>&1 || true
  sleep 3
  kill "$EPID" >/dev/null 2>&1 || true
}
dump_log() { say "---- last 60 lines of emulator.log ----"; tail -n 60 "$ELOG" | cut -c1-300; say "---- end ----"; }

# --- wait for boot ---
start=$SECONDS
while :; do
  if ! kill -0 "$EPID" 2>/dev/null; then
    say "ERROR: emulator process exited during boot"; dump_log; exit 1
  fi
  if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then break; fi
  if (( SECONDS - start > BOOT_TIMEOUT )); then
    say "ERROR: not booted after ${BOOT_TIMEOUT}s (adb: $(adb devices | tr '\n' ' '))"; dump_log; stop_emulator; exit 1
  fi
  sleep 2
done
say "booted in $((SECONDS - start))s"
grep -iE 'snapshot' "$ELOG" | grep -iE 'load|fail|incompat|cold|boot' | head -n 8 | cut -c1-250 | sed 's/^/[emu] log: /'
adb devices -l

# --- run the real work ---
trap 'stop_emulator' EXIT
"$@"
code=$?
say "command finished with exit code $code"
[ "$code" -eq 0 ] || dump_log
exit "$code"
