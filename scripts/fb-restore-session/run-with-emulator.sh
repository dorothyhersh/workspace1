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

# --- emulator start / boot / health helpers ---
say "host cpu: $(lscpu 2>/dev/null | grep -m1 'Model name' | sed 's/.*:[[:space:]]*//') | cores: $(nproc)"
HBPID=""; EPID=""
elog_last() { grep -viE 'RenderThread|ColorBuffer|ShareGroup|^\s*$' "$ELOG" 2>/dev/null | tail -n 1 | cut -c1-160; }
dump_log() { say "---- last 60 lines of emulator.log ----"; tail -n 60 "$ELOG" | cut -c1-300; say "---- end ----"; }

# Heartbeat: every 20s prints what the job is doing right now, so a slow/stuck step is never silent.
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
  [ -n "$EPID" ] && kill "$EPID" >/dev/null 2>&1 || true
  sleep 2
}

# start_emulator snapshot|cold
start_emulator() {
  local mode="$1" snaparg
  adb kill-server >/dev/null 2>&1; adb start-server >/dev/null 2>&1
  if [ "$mode" = cold ]; then snaparg=(-no-snapshot-load -no-snapshot-save); say "starting emulator COLD (no snapshot)"
  else snaparg=(-snapshot "$SNAP" -no-snapshot-save); say "starting emulator (snapshot $SNAP)"; fi
  setsid nohup emulator -avd "$AVD" -no-window -gpu swiftshader_indirect "${AUDIO_ARGS[@]}" -no-boot-anim \
    -camera-back none -no-metrics "${snaparg[@]}" -verbose >"$ELOG" 2>&1 &
  EPID=$!
}

# wait_boot -> 0 when sys.boot_completed=1, 1 on timeout / emulator exit
wait_boot() {
  local start=$SECONDS lastp=0
  say "waiting for the emulator to boot (snapshot resume is usually 5-30s, max ${BOOT_TIMEOUT}s)"
  while :; do
    if ! kill -0 "$EPID" 2>/dev/null; then say "ERROR: emulator process exited during boot"; dump_log; return 1; fi
    [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
    if (( SECONDS - start > BOOT_TIMEOUT )); then say "ERROR: not booted after ${BOOT_TIMEOUT}s (adb: $(adb devices | tr '\n' ' '))"; dump_log; return 1; fi
    if (( SECONDS - lastp >= 10 )); then
      lastp=$SECONDS
      say "booting... $((SECONDS - start))s | adb: $(adb get-state 2>&1 | tr -d '\r') | emulator log: $(elog_last)"
    fi
    sleep 2
  done
  say "booted in $((SECONDS - start))s"
  grep -iE 'snapshot' "$ELOG" | grep -iE 'load|fail|incompat|cold|boot' | head -n 8 | cut -c1-250 | sed 's/^/[emu] log: /'
  adb devices -l
}

# Package manager must answer, otherwise the guest is half-dead (this was the "package manager service not
# responding" failure: sys.boot_completed=1 but `pm list packages` empty, black screen, guest nearly frozen).
emu_healthy() {
  local max="${1:-75}" t0=$SECONDS
  while (( SECONDS - t0 < max )); do
    adb shell pm list packages 2>/dev/null | tr -d '\r' | grep -q '^package:' && { say "health: package manager OK after $((SECONDS - t0))s"; return 0; }
    sleep 3
  done
  say "health: package manager NOT answering after ${max}s"
  return 1
}

collect_diag() {   # evidence for later: what state is the guest in?
  local f="$ART/health-diag-$1.txt"
  {
    echo "== host: $(lscpu 2>/dev/null | grep -m1 'Model name')"
    echo "== restored build run: $(cat "${RUNNER_TEMP:-/tmp}/restored-run-id" 2>/dev/null)"
    echo "== guest uptime: $(timeout 8 adb shell cat /proc/uptime 2>&1)"
    echo "== guest date:   $(timeout 8 adb shell date 2>&1)  | host date: $(date)"
    echo "== props:"; timeout 10 adb shell getprop 2>/dev/null | grep -E 'boot_completed|bootanim|bootcomplete|init.svc.zygote|init.svc.bootanim' 
    echo "== processes:"; timeout 10 adb shell ps -A 2>/dev/null | grep -E 'zygote|system_server|surfaceflinger' 
    echo "== system_server log:"; timeout 20 adb logcat -d -b all 2>/dev/null | grep -E 'SystemServer|PackageManager|system_server' | tail -n 30
  } > "$f" 2>&1
  say "diag saved: $(basename "$f")"
}

# --- start, with self-healing ladder: (1) snapshot, (2) older build artifacts, (3) cold boot ---
MAX_RESTORE_TRIES="${MAX_RESTORE_TRIES:-3}"
RESTORE_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/restore-emulator.sh"
export SKIP_RUNS="${SKIP_RUNS:-}"
COLD_BOOT=0; attempt=1; healthy=0
while :; do
  start_emulator snapshot
  if wait_boot && emu_healthy 75; then healthy=1; break; fi
  collect_diag "$attempt"
  stop_emulator
  (( attempt >= MAX_RESTORE_TRIES )) && break
  [ -s "${RUNNER_TEMP:-/tmp}/restored-run-id" ] && SKIP_RUNS="$SKIP_RUNS $(cat "${RUNNER_TEMP:-/tmp}/restored-run-id")"
  say "snapshot from this build looks broken, trying the next older emulator build (skipping:${SKIP_RUNS:- none})"
  rm -rf "$HOME/.android/avd"
  bash "$RESTORE_SH" || { say "no older emulator build available"; break; }
  attempt=$((attempt+1))
done
if (( ! healthy )); then
  say "all snapshots failed -> COLD BOOT (Facebook state = whatever is on the AVD disk)"
  start_emulator cold; BOOT_TIMEOUT=600
  if wait_boot && emu_healthy 240; then healthy=1; COLD_BOOT=1; else collect_diag cold; dump_log; stop_emulator; exit 1; fi
fi
export COLD_BOOT

# --- run the real work ---
trap 'stop_emulator' EXIT
heartbeat & HBPID=$!
say "running: $*"
"$@"
code=$?
say "command finished with exit code $code"
[ "$code" -eq 0 ] || dump_log
exit "$code"
