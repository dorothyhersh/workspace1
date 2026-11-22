#!/usr/bin/env bash
# run-with-emulator.sh <command...>
# Boots the restored AVD (snapshot fb_ready) headless WITHOUT android-emulator-runner, so the emulator's
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

# --- SDK pieces: restored from the artifact by restore-emulator.sh; sdkmanager is only a fallback. ---
if [ -x "$SDK/emulator/emulator" ] && [ -x "$SDK/platform-tools/adb" ] \
   && [ -d "$SDK/system-images/android-30/google_apis/x86_64" ]; then
  say "emulator + platform-tools + system image already present (from artifact), skipping sdkmanager"
else
  yes | sdkmanager --licenses >/dev/null 2>&1 || true
  say "installing emulator + platform-tools"
  sdkmanager --install emulator platform-tools --channel=0 >/dev/null 2>&1 || say "WARNING: sdkmanager install returned non-zero"
  if [ ! -d "$SDK/system-images/android-30/google_apis/x86_64" ]; then
    say "system image missing, installing"
    sdkmanager --install 'system-images;android-30;google_apis;x86_64' --channel=0 >/dev/null 2>&1 || true
  fi
fi
say "emulator: $(emulator -version 2>&1 | grep -i 'version' | head -1)"
say "AVDs: $(emulator -list-avds | tr '\n' ' ')"
emulator -list-avds | grep -qx "$AVD" || { say "ERROR: AVD '$AVD' not found (artifact restore problem?)"; ls -la ~/.android/avd/ || true; exit 1; }
say "snapshots on disk: $(ls ~/.android/avd/$AVD.avd/snapshots/ 2>/dev/null | tr '\n' ' ')"
df -h / | tail -1; free -m | sed -n 2p

# --- virtual sound card, so the emulator's audio (captcha "play audio") can be recorded ---
# PulseAudio null sink "emu_out": the emulator plays into it, login-backup.sh records emu_out.monitor.
# Switch off with CAPTURE_CAPTCHA_AUDIO=0 (then the emulator starts with -noaudio exactly as before).
AUDIO_OK=0; AUDIO_SINK="emu_out"; AUDIO_ARGS=(-noaudio)
setup_audio() {
  if ! command -v pulseaudio >/dev/null 2>&1 || ! command -v parecord >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1; then
    say "installing pulseaudio + ffmpeg"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends pulseaudio pulseaudio-utils ffmpeg >/dev/null 2>&1 \
      || { say "WARNING: could not install pulseaudio/ffmpeg"; return 1; }
  fi
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-$(id -u)}"
  mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
  pulseaudio --check 2>/dev/null || pulseaudio -D --exit-idle-time=-1 --log-target="file:$ART/pulseaudio.log" || { say "WARNING: pulseaudio did not start"; return 1; }
  sleep 2
  pactl load-module module-null-sink sink_name="$AUDIO_SINK" sink_properties=device.description="$AUDIO_SINK" >/dev/null 2>&1 || true
  pactl set-default-sink "$AUDIO_SINK" >/dev/null 2>&1 || true
  pactl list short sinks 2>/dev/null | grep -q "$AUDIO_SINK" || { say "WARNING: null sink '$AUDIO_SINK' missing"; return 1; }
  say "virtual sound card ready: $AUDIO_SINK"
}
if [ "${CAPTURE_CAPTCHA_AUDIO:-0}" = "1" ] && setup_audio; then
  AUDIO_OK=1; AUDIO_ARGS=()
  export QEMU_AUDIO_DRV=pa
  # headless emulators may need this flag to use host audio; only added if this emulator build knows it
  emulator -help 2>&1 | grep -q -- '-allow-host-audio' && AUDIO_ARGS=(-allow-host-audio)
fi
export AUDIO_OK AUDIO_SINK

# --- start emulator ---
adb kill-server >/dev/null 2>&1; adb start-server >/dev/null 2>&1
say "starting emulator (snapshot $SNAP)"
setsid nohup emulator -avd "$AVD" -no-window -gpu swiftshader_indirect "${AUDIO_ARGS[@]}" -no-boot-anim \
  -camera-back none -no-metrics -snapshot "$SNAP" -no-snapshot-save -verbose >"$ELOG" 2>&1 &
EPID=$!

# quiet emulator-log line (the verbose log is mostly render-thread noise)
elog_last() { grep -viE 'RenderThread|ColorBuffer|ShareGroup|^\s*$' "$ELOG" 2>/dev/null | tail -n 1 | cut -c1-160; }

# Heartbeat: every 20s prints what the job is doing right now, so a slow/stuck step is never silent.
HBPID=""
heartbeat() {
  local t0=$SECONDS
  while sleep 20; do
    say "heartbeat +$((SECONDS - t0))s | doing: $(cat "$ART/phase" 2>/dev/null | cut -c1-110) | adb: $(timeout 5 adb get-state 2>&1 | tr -d '\r') | app/focus: $(timeout 8 adb shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus | tr -d '\r' | cut -c1-110)"
  done
}

stop_emulator() {
  [ -n "$HBPID" ] && kill "$HBPID" >/dev/null 2>&1
  adb emu kill >/dev/null 2>&1 || true
  sleep 3
  kill "$EPID" >/dev/null 2>&1 || true
}
dump_log() { say "---- last 60 lines of emulator.log ----"; tail -n 60 "$ELOG" | cut -c1-300; say "---- end ----"; }

# --- wait for boot ---
start=$SECONDS; lastp=0
say "waiting for the emulator to boot (snapshot resume is usually 5-30s, max ${BOOT_TIMEOUT}s)"
while :; do
  if ! kill -0 "$EPID" 2>/dev/null; then
    say "ERROR: emulator process exited during boot"; dump_log; exit 1
  fi
  if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then break; fi
  if (( SECONDS - start > BOOT_TIMEOUT )); then
    say "ERROR: not booted after ${BOOT_TIMEOUT}s (adb: $(adb devices | tr '\n' ' '))"; dump_log; stop_emulator; exit 1
  fi
  if (( SECONDS - lastp >= 10 )); then
    lastp=$SECONDS
    say "booting... $((SECONDS - start))s | adb: $(adb get-state 2>&1 | tr -d '\r') | sys.boot_completed='$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')' | emulator log: $(elog_last)"
  fi
  sleep 2
done
say "booted in $((SECONDS - start))s"
grep -iE 'snapshot' "$ELOG" | grep -iE 'load|fail|incompat|cold|boot' | head -n 8 | cut -c1-250 | sed 's/^/[emu] log: /'
adb devices -l

# --- run the real work ---
trap 'stop_emulator' EXIT
heartbeat & HBPID=$!
say "running: $*"
"$@"
code=$?
say "command finished with exit code $code"
[ "$code" -eq 0 ] || dump_log
exit "$code"
