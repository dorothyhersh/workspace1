#!/usr/bin/env bash
# login-backup.sh - login + encrypted backup for ONE OR MANY Facebook accounts on the same
# snapshot emulator, one account at a time, never mixed:
#   - before every account after the first (so also right after a failed/suspended one), the emulator is
#     reset with 'adb emu avd snapshot load fb_ready' (retried 3x, never pm clear),
#     so each login starts from a Facebook app with NO account in it (one account per app state)
#   - if Facebook still shows a logged-in feed after the reset, that account is refused (no backup)
#   - all logins happen on the phone IP; at the end the phone exit node is switched OFF, every
#     backup is uploaded to Mega, and the Mega sheet gets the backup names (BACKUP_FILE_NAME + BackupLog)
# Every account ends with a STATUS (written to the sheet): active | suspended | wrong_password |
# needs_attention | login_failed.  A suspended account ("Confirm you're human to use your account",
# "account suspended/disabled/locked") is detected the moment the screen shows, gets NO backup, an EMPTY
# BACKUP_FILE_NAME and STATUS=suspended.  Only accounts that really logged in are backed up + uploaded, and
# a suspended / failed account never makes the workflow fail or blocks the other accounts' upload.
# Accounts come from $ACCOUNTS_JSON (written by scripts/load-config-from-mega.py from the Mega sheet).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../shared/config.sh"
exec > >(tee -a "$ARTIFACTS/run.log") 2>&1
for f in lib-ui lib-mega; do source "$DIR/../shared/$f.sh"; done

ACCOUNTS_JSON="${ACCOUNTS_JSON:-}"
MEGA_KEEP="${MEGA_KEEP:-10}"
MEGA_CONF_FOLDER="${MEGA_CONF_FOLDER:-Fbworkflow}"
MEGA_CONF_FILE="${MEGA_CONF_FILE:-login_Setup_Setting_workflow_conf.xlsx}"
SNAPSHOT_NAME="${SNAPSHOT_NAME:-fb_ready}"
MEGA_DIR="${MEGA_REMOTE}:${MEGA_FOLDER}"
TMPD="${RUNNER_TEMP:-/tmp}"
PENDING_DIR="$TMPD/pending-backups"
PENDING_LIST="$TMPD/pending-list.tsv"
RESULTS_TSV="$TMPD/backup-results.tsv"
STATUS_TSV="$TMPD/account-status.tsv"       # <email> TAB <status>, one line per account that was tried
mkdir -p "$PENDING_DIR"; : > "$PENDING_LIST"; : > "$RESULTS_TSV"; : > "$STATUS_TSV"
LOGIN_RESULT=""                              # set by login_account: active|suspended|wrong_password|needs_attention|login_failed
# Facebook screens that mean "this account is suspended / locked / must prove it is human"
SUSPENDED_REGEX="confirm you.{1,6}re human|(account|profile).{0,40}(suspended|disabled|locked)|(suspended|disabled|locked).{0,30}(your|the) account|we suspended your|your account (has been|was|is) (suspended|disabled|locked|restricted)"

# single-account fallback: build a one-entry list from FB_IDENTIFIER / FB_PASSWORD
if [[ -z "$ACCOUNTS_JSON" || ! -s "$ACCOUNTS_JSON" ]]; then
  [[ -n "${FB_IDENTIFIER:-}" && -n "${FB_PASSWORD:-}" ]] || { log "ERROR: no accounts (ACCOUNTS_JSON missing/empty)"; exit 1; }
  ACCOUNTS_JSON="$TMPD/accounts.json"
  python3 -c 'import json,os;print(json.dumps([{"FB_IDENTIFIER":os.environ["FB_IDENTIFIER"],"FB_PASSWORD":os.environ["FB_PASSWORD"],"MEGA_FILE":os.environ.get("MEGA_FILE","")}]))' > "$ACCOUNTS_JSON"
fi

SHOT_PREFIX=""
shot() { screenshot "${SHOT_PREFIX}$1"; }

finish() {
  local code=$?
  log "exiting with code $code"
  screenshot "99-final-state.png"
  adb logcat -d > "$ARTIFACTS/logcat.txt" 2>/dev/null
  rm -rf "$PENDING_DIR" "$PENDING_LIST" "$ACCOUNTS_JSON" "$SESSION_TMP" "$BACKUP_FILE" "$STATUS_TSV" "$RESULTS_TSV"
  exit "$code"
}
trap finish EXIT

# ---------- accounts ----------
ACC_VARS=()
acc_count() { python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$ACCOUNTS_JSON"; }
acc_vars() {
  python3 - "$ACCOUNTS_JSON" "$1" <<'PY'
import base64, json, sys
a = json.load(open(sys.argv[1]))[int(sys.argv[2])]
for k, v in a.items():
    print(k, base64.b64encode(v.encode()).decode())
PY
}
# Exports every column of account #$1 as an environment variable (and forgets the previous account's).
load_account() {
  local k v
  for k in "${ACC_VARS[@]:-}"; do [[ -n "$k" ]] && unset "$k"; done
  ACC_VARS=()
  while read -r k v; do
    export "$k=$(printf '%s' "$v" | base64 -d)"; ACC_VARS+=("$k")
  done < <(acc_vars "$1")
  if [[ -z "${MEGA_FILE:-}" || "$MEGA_FILE" == "fb-session.tgz.enc" ]]; then
    MEGA_FILE="fb-session-$(printf '%s' "${FB_IDENTIFIER:-}" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9._@-]/_/g').tgz.enc"
  fi
}

# ---------- helpers ----------
phone_guard() {
  [[ -n "${PHONE_IP:-}" ]] || { log "ABORT: PHONE_IP not set; refusing to log in without the phone exit node"; return 1; }
  bash "$DIR/assert-phone-ip.sh" || { log "ABORT: not on the phone IP, refusing to continue"; return 1; }
}

tap_field() {
  local xy="" i
  for i in 1 2 3 4; do
    xy="$(ui_find class 'EditText' "$1" || true)"; [[ -n "$xy" ]] && break; sleep 2
  done
  [[ -z "$xy" ]] && { log "text field #$1 not found"; return 1; }
  log "tap text field #$1 at $xy"; adb shell input tap $xy
}

type_text() {
  local s="$1" q="'"
  s="${s//$q/$q\\$q$q}"; s="${s// /%s}"
  adb shell "input text '$s'" >/dev/null 2>&1
}

post_login_prompts() {
  local rounds="${1:-12}" i xy handled
  for ((i=0; i<rounds; i++)); do
    dismiss_system_dialogs
    if is_logged_in; then log "feed detected"; return 0; fi
    handled=0
    xy="$(ui_query text '^Continue in English' 0 || true)"
    if grep -qiE "$NOTICE_REGEX" "$UI_XML"; then
      dismiss_notices; handled=1
    elif [[ -n "$xy" ]]; then
      log "tapping 'Continue in English' at $xy"; adb shell input tap $xy; handled=1; sleep 5
    else
      xy="$(ui_query text '^Skip$' 0 || true)"
      if [[ -n "$xy" ]]; then log "tapping 'Skip' at $xy"; adb shell input tap $xy; handled=1; sleep 5
      else
        xy="$(ui_query text "$DISMISS_REGEX" 0 || true)"
        if [[ -n "$xy" ]]; then log "popup, tapping dismiss at $xy"; adb shell input tap $xy; handled=1; sleep 4; fi
      fi
    fi
    [[ "$handled" == "0" ]] && { log "no prompt to tap (round $((i+1))/$rounds), waiting"; sleep 2; }
  done
  return 1
}

need_root() {
  adb root >/dev/null 2>&1; sleep 3; adb wait-for-device
  [[ "$(adb_sh id -u 2>/dev/null)" == "0" ]]
}

# Back to the clean snapshot = Facebook installed, nobody logged in, no leftovers of the last account.
# ONLY "adb emu avd snapshot load" is used (no pm clear). If a load fails it is retried; if all tries fail
# the function returns 1 and the run stops, so accounts are never mixed.
# Loads the clean snapshot into the RUNNING emulator and waits until Android answers again.
# Retried 3x; only "adb emu avd snapshot load" is used (never pm clear).
load_snapshot() {
  local out try
  [[ "${COLD_BOOT:-0}" == "1" ]] && { log "cold-boot mode: there is no usable snapshot to load"; return 1; }
  for try in 1 2 3; do
    out="$(timeout 180 adb emu avd snapshot load "$SNAPSHOT_NAME" 2>&1 | tr -d '\r')"
    log "snapshot load (try $try/3): $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
    if grep -q '^OK' <<<"$out"; then
      sleep 3; timeout 20 adb reconnect >/dev/null 2>&1; adb wait-for-device
      if wait_for_boot; then settle_device; sleep 2; dismiss_system_dialogs; return 0; fi
      log "emulator not ready after snapshot load (try $try/3)"
    fi
    sleep 5
  done
  log "ERROR: snapshot '$SNAPSHOT_NAME' could not be loaded into a working emulator (3 tries)"
  return 1
}

# Back to the clean snapshot = Facebook installed, nobody logged in, no leftovers of the last account.
reset_clean_state() {
  log "loading the clean '$SNAPSHOT_NAME' snapshot"
  load_snapshot || return 1
  adb shell pm list packages 2>&1 | grep -qF "$PACKAGE_NAME" || { log "ERROR: $PACKAGE_NAME missing after reset"; return 1; }
}

# Waits until Facebook shows up in the package list. If it does not (package service half-dead after a
# snapshot resume), prints what Android reports and loads the snapshot again, up to 3 rounds.
ensure_facebook() {
  local round i
  for round in 1 2 3; do
    for i in $(seq 1 20); do
      adb shell pm list packages 2>&1 | grep -qF "$PACKAGE_NAME" && return 0
      sleep 3
    done
    log "diag: packages listed=$(adb shell pm list packages 2>&1 | grep -c '^package:'), facebook-like=[$(adb shell pm list packages 2>&1 | grep -i facebook | tr '\n' ' ')], boot_completed=$(adb_sh getprop sys.boot_completed), uptime=$(adb_sh cat /proc/uptime | cut -d' ' -f1)s"
    screenshot "diag-no-facebook-round$round.png"
    (( round < 3 )) || break
    log "Facebook not in the package list (round $round/3), loading snapshot '$SNAPSHOT_NAME' again"
    load_snapshot || return 1
  done
  return 1
}

# Encrypts this account's Facebook app data and parks it in $PENDING_DIR (uploaded at the end).
backup_session() {
  [[ -n "${BACKUP_PASSPHRASE:-}" ]] || { log "backup failed: BACKUP_PASSPHRASE empty"; return 1; }
  need_root || { log "backup failed: adb root not available"; return 1; }
  adb shell am force-stop "$PACKAGE_NAME"; sleep 2; adb shell sync
  # speed: the emulator CPU is slow at gzip, so pack WITHOUT compression there and compress on the runner
  local remote=/data/local/tmp/fb-session.tar raw="$TMPD/fb-session.raw.tar"
  adb shell "rm -f $remote; tar -cf $remote --exclude='*/cache/*' --exclude='*/code_cache/*' -C /data/data $PACKAGE_NAME" \
    || { log "backup failed: tar error"; return 1; }
  adb pull "$remote" "$raw" >/dev/null 2>&1 || { log "backup failed: pull error"; return 1; }
  adb shell "rm -f $remote"
  gzip -1 -c "$raw" > "$SESSION_TMP" || { log "backup failed: gzip error"; rm -f "$raw" "$SESSION_TMP"; return 1; }
  rm -f "$raw"
  local size; size="$(stat -c%s "$SESSION_TMP" 2>/dev/null || echo 0)"
  (( size < 10000 )) && { log "backup failed: archive too small ($size)"; rm -f "$SESSION_TMP"; return 1; }
  openssl enc -aes-256-cbc -pbkdf2 -salt -in "$SESSION_TMP" -out "$BACKUP_FILE" -pass env:BACKUP_PASSPHRASE \
    || { log "backup failed: encryption error"; rm -f "$SESSION_TMP"; return 1; }
  rm -f "$SESSION_TMP"
  mv "$BACKUP_FILE" "$PENDING_DIR/$MEGA_FILE" || return 1
  printf '%s\t%s\n' "$FB_IDENTIFIER" "$MEGA_FILE" >> "$PENDING_LIST"
  log "encrypted backup ready for upload: $MEGA_FILE ($(stat -c%s "$PENDING_DIR/$MEGA_FILE") bytes)"
}

# ---------- account notices ("What happened" / restrictions / removed content) ----------
# Facebook shows these full-screen pages right after login. The account IS logged in; the page only has to be
# closed (X button, content-desc "Close"). Handled in the login loop and in post_login_prompts.
NOTICE_REGEX='What happened|We added restrictions|We removed some content|We removed|Your account (has )?restrictions|Review (your )?(account )?status'
dismiss_notices() {
  local xy
  xy="$(ui_query text '^Close$' 0 || true)"
  if [[ -n "$xy" ]]; then
    log "account notice on screen, tapping Close at $xy"; adb shell input tap $xy
  else
    log "account notice on screen, no Close button found -> Back key"; adb shell input keyevent 4
  fi
  sleep 3
}

# ---------- text captcha: wait until it has loaded, then (optionally) tap "play audio" and record ----------
CAPTCHA_REGEX="${CAPTCHA_REGEX:-Enter the characters you see|characters you see|real human behind this login|type the (characters|text|code) (you see|shown|below)|enter the (text|code) (you see|shown)}"
CAPTURE_CAPTCHA_AUDIO="${CAPTURE_CAPTCHA_AUDIO:-0}"       # 1 = also record the audio (needs a snapshot/emulator started WITH audio)
CAPTCHA_LOAD_WAIT="${CAPTCHA_LOAD_WAIT:-60}"              # seconds to wait for the captcha picture to appear
CAPTCHA_IMG_STD_MIN="${CAPTCHA_IMG_STD_MIN:-6}"           # picture counts as loaded when the grey-level variation of its area is >= this
CAPTCHA_AUDIO_SECONDS="${CAPTCHA_AUDIO_SECONDS:-20}"
CAPTCHA_N=0

# grey-level variation of the area where the captcha picture appears (blank gradient ~1-2, real picture much higher)
captcha_image_std() {
  local png="$TMPD/captcha-probe.png"
  adb exec-out screencap -p > "$png" 2>/dev/null || return 1
  python3 - "$png" <<'PY' 2>/dev/null
import sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert('L'); w, h = im.size
box = (int(w*0.05), int(h*0.205), int(w*0.95), int(h*0.325))
print(round(ImageStat.Stat(im.crop(box)).stddev[0], 1))
PY
}

captcha_wait_loaded() {
  local t0=$SECONDS std xy gen=0
  while (( SECONDS - t0 < CAPTCHA_LOAD_WAIT )); do
    std="$(captcha_image_std || true)"
    if [[ -z "$std" ]]; then log "captcha: cannot measure the picture (python Pillow missing?), waiting 20s instead"; sleep 20; return 0; fi
    log "captcha picture check: variation=$std (loaded when >= $CAPTCHA_IMG_STD_MIN), waited $((SECONDS - t0))s"
    awk -v s="$std" -v m="$CAPTCHA_IMG_STD_MIN" 'BEGIN{exit !(s>=m)}' && { log "captcha picture is loaded"; return 0; }
    # still blank after 25s -> ask Facebook for a new one (once)
    if (( ! gen && SECONDS - t0 >= 25 )); then
      gen=1
      if ui_dump; then
        xy="$(ui_query text 'generate new' 0 || true)"
        [[ -n "$xy" ]] && { log "captcha still blank, tapping 'Generate new' at $xy"; adb shell input tap $xy; }
      fi
    fi
    sleep 4
  done
  log "WARNING: captcha picture did not load within ${CAPTCHA_LOAD_WAIT}s"
  return 1
}

capture_captcha_audio() {
  CAPTCHA_N=$((CAPTCHA_N + 1))
  local tag="${SHOT_PREFIX:-}captcha${CAPTCHA_N}" secs="$CAPTCHA_AUDIO_SECONDS" xy="" i apid="" vpid="" have_audio=0
  local wav="$ARTIFACTS/${tag}-audio.wav" mp3="$ARTIFACTS/${tag}-audio.mp3"
  local vraw="$TMPD/${tag}-screen.mp4" vout="$ARTIFACTS/${tag}-screen-with-audio.mp4"

  log "CAPTCHA detected ($tag): waiting for the picture to load"
  screenshot "${tag}-0-first-seen.png"
  captcha_wait_loaded || true
  screenshot "${tag}-1-screen.png"
  ui_dump && cp "$UI_XML" "$ARTIFACTS/${tag}-ui.xml" 2>/dev/null || true

  if [[ "$CAPTURE_CAPTCHA_AUDIO" != "1" ]]; then log "captcha audio recording is off (CAPTURE_CAPTCHA_AUDIO=0), screenshot saved"; return 0; fi
  if [[ "${AUDIO_OK:-0}" != "1" ]]; then log "WARNING: emulator runs without audio (AUDIO_OK=0), cannot record the captcha audio"; return 1; fi

  for i in 1 2 3; do
    xy="$(ui_query text 'play.{0,3}audio' 0 || true)"; [[ -n "$xy" ]] && break
    sleep 2; ui_dump || true
  done
  [[ -n "$xy" ]] || { log "WARNING: 'play audio' not found on the captcha screen (see ${tag}-ui.xml)"; return 1; }

  adb shell cmd media_session volume --stream 3 --set 15 >/dev/null 2>&1 || true
  command -v parecord >/dev/null 2>&1 && { have_audio=1; timeout -s TERM "$secs" parecord --device="${AUDIO_SINK:-emu_out}.monitor" --file-format=wav "$wav" 2>/dev/null & apid=$!; }
  adb shell "rm -f /sdcard/captcha.mp4" >/dev/null 2>&1
  timeout -k 3 $((secs + 15)) adb shell screenrecord --time-limit $((secs + 3)) --bit-rate 3000000 /sdcard/captcha.mp4 >/dev/null 2>&1 & vpid=$!
  sleep 2
  log "tap play audio at $xy, recording ${secs}s"; adb shell input tap $xy
  sleep $((secs / 2)); screenshot "${tag}-2-playing.png"
  [[ -n "$apid" ]] && wait "$apid" 2>/dev/null
  wait "$vpid" 2>/dev/null; sleep 1
  adb pull /sdcard/captcha.mp4 "$vraw" >/dev/null 2>&1; adb shell "rm -f /sdcard/captcha.mp4" >/dev/null 2>&1
  if (( have_audio )) && [[ -s "$wav" ]]; then
    log "AUDIO SAVED: ${tag}-audio.wav ($(stat -c%s "$wav") bytes)"
    if command -v ffmpeg >/dev/null 2>&1; then
      ffmpeg -y -loglevel error -i "$wav" -c:a libmp3lame -q:a 2 "$mp3" && log "AUDIO SAVED: ${tag}-audio.mp3"
      log "audio level: $(ffmpeg -hide_banner -i "$wav" -af volumedetect -f null - 2>&1 | grep -E 'mean_volume|max_volume' | sed 's/.*\] //' | tr '\n' ' ')"
      [[ -s "$vraw" ]] && ffmpeg -y -loglevel error -i "$vraw" -i "$wav" -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -shortest "$vout" && log "VIDEO SAVED: ${tag}-screen-with-audio.mp4"
    fi
  fi
  if [[ -s "$vraw" && ! -s "$vout" ]]; then cp "$vraw" "$ARTIFACTS/${tag}-screen.mp4"; log "VIDEO SAVED (no audio): ${tag}-screen.mp4"; fi
  rm -f "$vraw"; return 0
}

# ---------- login of ONE account ----------
# What Facebook really sees: the public IP as seen FROM INSIDE the emulator (the phone_guard above only
# checks the runner host). Logged for every account; if it equals the runner's own IP the login is refused.
emu_ip_probe() {
  local ip
  ip="$(timeout 25 adb shell "printf 'GET / HTTP/1.0\\r\\nHost: ifconfig.me\\r\\nUser-Agent: curl/8.0\\r\\nAccept: */*\\r\\n\\r\\n' | toybox nc -w 10 ifconfig.me 80" 2>/dev/null | tr -d '\r' | tail -n 1)"
  [[ "$ip" =~ ^[0-9a-fA-F:.]{3,45}$ ]] || ip=""
  log "emulator-side public IP (what Facebook sees): ${ip:-could not be read}  (runner IP without phone: ${BASELINE_IP:-unknown})"
  if [[ -n "$ip" && -n "${BASELINE_IP:-}" && "$ip" == "$BASELINE_IP" ]]; then
    log "ABORT: the emulator itself leaves through the RUNNER IP, not the phone - refusing to log in"; return 1
  fi
  return 0
}

login_account() {
  LOGIN_RESULT="login_failed"
  phone_guard || return 1
  emu_ip_probe || return 1

  launch_app
  # wait only as long as needed (was: fixed 12s) - up to 25s for the login form or the feed
  local w=$SECONDS
  while (( SECONDS - w < 25 )); do
    sleep 2
    ui_dump || continue
    grep -q 'EditText' "$UI_XML" && break
    is_logged_in && break
  done
  dismiss_system_dialogs
  shot "02-after-launch.png"
  if [[ -z "$(ui_query class 'EditText' 0 2>/dev/null || true)" ]]; then dismiss_popups 2; fi
  shot "03-before-login.png"

  if [[ -z "$(ui_find class 'EditText' 0 || true)" ]]; then
    if is_logged_in; then
      log "ERROR: Facebook is already logged in although the app was reset - refusing, so accounts are never mixed"
      return 1
    fi
    tap_text '^Log ?in$' "" 3 || true
    sleep 4
  fi

  tap_field 0 || { shot "04-no-form.png"; log "ERROR: login form not found"; return 1; }
  sleep 0.5; type_text "$FB_IDENTIFIER"; sleep 0.5
  tap_field 1 || { log "ERROR: password field not found"; return 1; }
  sleep 0.5; type_text "$FB_PASSWORD"; sleep 0.5
  shot "06-password-entered.png"   # password is masked
  adb shell input keyevent 4 >/dev/null 2>&1; sleep 0.5

  phone_guard || return 1   # still on the phone IP right before submitting?
  tap_text '^Log ?in$' "" 3 || adb shell input keyevent 66
  # poll (was: fixed 15s + 10s + 3s sleeps): stop as soon as the feed, a security check or a wrong password shows
  local t=$SECONDS bad="" xy feed=0
  sleep 3
  while (( SECONDS - t < 50 )); do
    if ! ui_dump; then sleep 1; continue; fi
    if grep -qiE 'responding|keeps stopping|has stopped' "$UI_XML"; then dismiss_system_dialogs; continue; fi
    # suspended / "confirm you're human" -> stop right now (was: wait 50s + 6 popup rounds, then fail)
    if ! logged_in_xml && grep -qiE "$SUSPENDED_REGEX" "$UI_XML"; then
      log "ACCOUNT SUSPENDED: Facebook shows '$(ui_texts | cut -d' ' -f3- | grep -iE "$SUSPENDED_REGEX" | head -1)'"
      bad="suspended"; break
    fi
    if grep -qiE "couldn.t find an account|find an account that matches|no account (found|matches)" "$UI_XML"; then
      log "WARNING: Facebook does not know this email/phone (account not found or wrong login)"; bad="wrong_password"; break
    fi
    if grep -qiE "$CAPTCHA_REGEX" "$UI_XML"; then
      log "WARNING: Facebook shows a text captcha - recording the audio version, needs manual attention"
      capture_captcha_audio || log "WARNING: captcha audio capture did not work"
      bad="needs_attention"; break
    fi
    if grep -qiE 'incorrect|wrong password|invalid (username|password|email)|doesn.t match|password you.ve entered' "$UI_XML"; then
      log "WARNING: credentials look wrong"; bad="wrong_password"; break
    fi
    if grep -qiE 'two-factor|authentication app|confirm it.s you|checkpoint|suspicious|secure your account' "$UI_XML"; then
      log "WARNING: Facebook is asking for a security check / 2FA code (needs manual attention)"; bad="needs_attention"; break
    fi
    if grep -qiE "$NOTICE_REGEX" "$UI_XML"; then dismiss_notices; continue; fi     # "What happened" / restrictions page
    xy="$(ui_query text '^(Save|OK)$' 0 || true)"     # "Save your login info?"
    if [[ -n "$xy" ]]; then log "tapping Save/OK at $xy"; adb shell input tap $xy; sleep 1; continue; fi
    logged_in_xml && { log "feed detected after $((SECONDS - t))s"; feed=1; break; }
    sleep 0.5
  done
  shot "07-after-login.png"
  if [[ -n "$bad" ]]; then
    LOGIN_RESULT="$bad"; log "RESULT: $bad - not creating a backup"; return 1
  fi
  # feed already seen in the loop -> one quick confirmation dump instead of the old 6-round popup wait
  if (( feed )); then sleep 1; ui_dump && logged_in_xml || feed=0; fi
  (( feed )) || { post_login_prompts 6 || true; shot "08-after-popups.png"; }

  if (( feed )) || is_logged_in; then
    log "LOGIN OK (feed is visible)"
    shot "09-feed.png"
    LOGIN_RESULT="active"      # logged in = active, even if the backup step then has a problem
    backup_session || { log "ERROR: backup not created"; return 1; }
    return 0
  fi
  if ui_dump; then
    log "screen texts at failure: $(ui_texts | cut -d' ' -f3- | head -30 | tr '\n' '|' | cut -c1-600)"
    cp "$UI_XML" "$ARTIFACTS/${SHOT_PREFIX}ui-failure.xml" 2>/dev/null || true
    if grep -qiE "$SUSPENDED_REGEX" "$UI_XML"; then
      LOGIN_RESULT="suspended"; log "ACCOUNT SUSPENDED (found on the final screen)"; return 1
    fi
  fi
  log "WARNING: feed not detected, NOT creating a backup (a good old backup is never replaced by a bad one)"
  return 1
}

# ---------- Mega: switch off phone link, upload all backups, update the sheet ----------
switch_to_runner_ip() {
  log "switching OFF the phone exit node for the Mega uploads"
  timeout -k 3 30 sudo tailscale set --exit-node= || { log "WARNING: could not clear the exit node"; return 1; }
  sleep 2
  log "public IP now: $(curl -s --max-time 15 https://ifconfig.me || echo unknown)  (runner baseline: ${BASELINE_IP:-unknown})"
}

# Uploads EVERY pending backup (main name + dated copy) in ONE parallel rclone call (was: sequential,
# 2 uploads + 2 listings per account), verifies with ONE listing, prunes old dated copies once.
upload_all() {
  local stage="$TMPD/upload-stage" stamp email name base dated listing
  rm -rf "$stage"; mkdir -p "$stage"
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  declare -gA DATED_OF=()
  while IFS=$'\t' read -r email name; do
    base="${name%.tgz.enc}"; dated="${base}.${stamp}.tgz.enc"
    ln "$PENDING_DIR/$name" "$stage/$name" 2>/dev/null || cp "$PENDING_DIR/$name" "$stage/$name"
    ln "$PENDING_DIR/$name" "$stage/$dated" 2>/dev/null || cp "$PENDING_DIR/$name" "$stage/$dated"
    DATED_OF["$name"]="$dated"
  done < "$PENDING_LIST"
  log "uploading $(ls "$stage" | wc -l) files to Mega in parallel"
  rclone copy "$stage" "$MEGA_DIR" --transfers 8 --checkers 8 --ignore-times --retries 5 --low-level-retries 10 -q </dev/null \
    || log "WARNING: rclone reported errors (checking which files arrived)"
  listing="$(rclone lsf "$MEGA_DIR" 2>/dev/null </dev/null)"
  while IFS=$'\t' read -r email name; do
    if grep -qxF "$name" <<<"$listing"; then
      log "MEGA UPLOAD OK ($email): ${MEGA_FOLDER}/${name}"
      grep -qxF "${DATED_OF[$name]}" <<<"$listing" || DATED_OF["$name"]=""
      printf '%s\t%s\t%s\n' "$email" "$name" "${DATED_OF[$name]}" >> "$RESULTS_TSV"
      if [[ "$MEGA_KEEP" =~ ^[0-9]+$ ]]; then   # prune only THIS account's dated copies
        base="${name%.tgz.enc}"
        while IFS= read -r f; do
          [[ -n "$f" ]] && rclone deletefile "${MEGA_DIR}/${f}" --mega-hard-delete 2>/dev/null </dev/null || true
        done < <(grep -E "^${base//./\\.}\.2[0-9]{7}-[0-9]{6}\.tgz\.enc$" <<<"$listing" | sort | head -n -"$MEGA_KEEP")
      fi
    else
      log "ERROR: upload to Mega failed for $email"; UPLOAD_FAILED+=("$email")
    fi
  done < "$PENDING_LIST"
  rm -rf "$stage"
}

# Downloads the sheet again (fresh), writes the backup names into it, uploads it back (old copy kept as .bak.xlsx)
update_sheet() {
  [[ -s "$RESULTS_TSV" || -s "$STATUS_TSV" ]] || return 0
  local x="$TMPD/conf-update.xlsx" remote="${MEGA_REMOTE}:${MEGA_CONF_FOLDER}/${MEGA_CONF_FILE}"
  rclone copyto "$remote" "$x" --retries 5 -q </dev/null || { log "WARNING: cannot download the sheet from Mega"; return 1; }
  cp "$x" "$x.bak"
  rclone copyto "$x.bak" "${MEGA_REMOTE}:${MEGA_CONF_FOLDER}/${MEGA_CONF_FILE%.xlsx}.bak.xlsx" --retries 5 -q </dev/null &
  local bakpid=$!
  python3 "$DIR/update-sheet-backup-names.py" "$x" "$RESULTS_TSV" "$STATUS_TSV" || { log "WARNING: sheet update script failed"; kill $bakpid 2>/dev/null; rm -f "$x" "$x.bak"; return 1; }
  wait $bakpid || log "WARNING: .bak copy of the sheet not uploaded"; rm -f "$x.bak"
  rclone copyto "$x" "$remote" --retries 5 -q </dev/null || { log "WARNING: cannot upload the updated sheet"; rm -f "$x"; return 1; }
  rm -f "$x"
  log "Mega sheet updated: STATUS + BACKUP_FILE_NAME + BackupLog"
}

UPLOAD_FAILED=()
upload_pending() {
  [[ -s "$PENDING_LIST" || -s "$STATUS_TSV" ]] || { log "nothing to upload and no status to record"; return 0; }
  switch_to_runner_ip || log "WARNING: still on the phone link, uploads may be slow"
  setup_rclone || return 1
  if [[ -s "$PENDING_LIST" ]]; then
    rclone mkdir "$MEGA_DIR" --retries 5 </dev/null || return 1
    upload_all
  else
    log "no backups to upload (no account logged in), only the statuses go to the sheet"
  fi
  update_sheet || log "WARNING: backups are in Mega but the sheet was not updated"
}

# ===================== MAIN =====================
[[ -n "${BACKUP_PASSPHRASE:-}" ]] || { log "ERROR: BACKUP_PASSPHRASE secret is empty"; exit 1; }
python3 -c "import PIL" 2>/dev/null || python3 -m pip install -q pillow 2>/dev/null || python3 -m pip install -q --break-system-packages pillow 2>/dev/null || true
adb devices -l
if ! wait_for_boot; then
  # snapshot resume sometimes comes up with a dead package service (seen: "package manager service not
  # responding after boot"): same fix as between accounts, load the clean snapshot again
  log "emulator not ready after the first boot, loading snapshot '$SNAPSHOT_NAME' again"
  reset_clean_state || exit 1
fi
settle_device
sleep 2
dismiss_system_dialogs
shot "00-home-screen.png"

ensure_facebook || { log "ERROR: $PACKAGE_NAME is not installed in this emulator snapshot (or the package service never came up), see diag-* screenshots"; exit 1; }
log "Facebook is already installed in the restored emulator (no APK install needed)"

COUNT="$(acc_count)"
LOGIN_OK=(); LOGIN_SUSPENDED=(); LOGIN_FAILED=(); INFRA_FAIL=0
if (( COUNT == 0 )); then
  log "Nothing to do: no account to log in (every row already has a STATUS (checked) or has no password). Set the workflow input retry_checked=true to try them again."
  exit 0
fi
for ((n=0; n<COUNT; n++)); do
  load_account "$n"
  SHOT_PREFIX="acc$((n+1))-"
  log "===== account $((n+1))/$COUNT: $FB_IDENTIFIER  ->  backup file: ${MEGA_FOLDER}/${MEGA_FILE} ====="
  if [[ -z "${FB_IDENTIFIER:-}" || -z "${FB_PASSWORD:-}" ]]; then
    log "ERROR: FB_IDENTIFIER / FB_PASSWORD empty for this row, skipping"; LOGIN_FAILED+=("row $((n+1))"); continue
  fi
  if (( n > 0 )) && [[ "${COLD_BOOT:-0}" == "1" ]]; then
    log "WARNING: emulator was cold-booted (snapshot broken), cannot reset to a clean app state - leaving the remaining accounts for the next run"; break
  fi
  if (( n > 0 )); then
    reset_clean_state || { log "ERROR: cannot reset the emulator, stopping so accounts are not mixed"; LOGIN_FAILED+=("$FB_IDENTIFIER"); INFRA_FAIL=1; break; }
  fi
  if login_account; then
    LOGIN_OK+=("$FB_IDENTIFIER")
  elif [[ "$LOGIN_RESULT" == "suspended" ]]; then
    LOGIN_SUSPENDED+=("$FB_IDENTIFIER")
  else
    LOGIN_FAILED+=("$FB_IDENTIFIER")
  fi
  printf '%s\t%s\n' "$FB_IDENTIFIER" "${LOGIN_RESULT:-login_failed}" >> "$STATUS_TSV"
  log "ACCOUNT RESULT: $FB_IDENTIFIER => ${LOGIN_RESULT:-login_failed}"
done

upload_pending

log "SUMMARY: active+backup: ${LOGIN_OK[*]:-none} | SUSPENDED: ${LOGIN_SUSPENDED[*]:-none} | other login problems: ${LOGIN_FAILED[*]:-none} | upload FAILED: ${UPLOAD_FAILED[*]:-none}"
for a in "${LOGIN_SUSPENDED[@]:-}"; do [[ -n "$a" ]] && echo "::warning title=Account suspended::$a is suspended (sheet STATUS=suspended, no backup)"; done
for a in "${LOGIN_FAILED[@]:-}"; do [[ -n "$a" ]] && echo "::warning title=Login problem::$a could not log in (see screenshots)"; done

# The workflow only FAILS when something that worked could not be saved (a Mega upload) or the emulator broke.
# Suspended / wrong-password accounts are reported (warning + sheet STATUS) but never fail the run.
if (( ${#UPLOAD_FAILED[@]} > 0 )); then log "ERROR: some backups were not uploaded"; exit 1; fi
if (( INFRA_FAIL )); then log "ERROR: emulator problem, some accounts were not processed"; exit 1; fi
log "Done! ${#LOGIN_OK[@]} account(s) backed up to Mega, ${#LOGIN_SUSPENDED[@]} suspended, ${#LOGIN_FAILED[@]} with other login problems; sheet updated."
exit 0
