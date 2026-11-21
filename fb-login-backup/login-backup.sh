#!/usr/bin/env bash
# login-backup.sh - ENTRY POINT for "login only + backup".
# Runs inside the emulator step. The emulator was restored from the cached snapshot (fb_ready),
# Facebook is ALREADY installed in it, so there is no APK download / install here.
#   1. wait for the snapshot-booted emulator, check Facebook is installed
#   2. check traffic leaves through the phone exit node (Telenor IP), refuse otherwise
#   3. launch Facebook (app data is NOT cleared), type id + password, log in
#   4. when the feed is visible: encrypted backup of the Facebook app data
#   5. switch exit node OFF (fast runner internet) and upload the backup to Mega
# No Page switch, no reels.
#
# FB_IDENTIFIER / FB_PASSWORD / MEGA_FILE now come from the Mega sheet
# (Fbworkflow/login_Setup_Setting_workflow_conf.xlsx), loaded by the workflow's first step.
# Backup file name = fb-session-<email>.tgz.enc (one backup per account).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../shared/config.sh"
exec > >(tee -a "$ARTIFACTS/run.log") 2>&1
for f in lib-ui lib-mega; do source "$DIR/../shared/$f.sh"; done

FB_IDENTIFIER="${FB_IDENTIFIER:-}"
FB_PASSWORD="${FB_PASSWORD:-}"
MEGA_KEEP="${MEGA_KEEP:-10}"

# Safety net: if the workflow did not pass a per-account name, derive it from the email
# so different accounts never overwrite each other's backup.
if [[ -n "$FB_IDENTIFIER" && ( -z "${MEGA_FILE:-}" || "${MEGA_FILE:-}" == "fb-session.tgz.enc" ) ]]; then
  _safe="$(printf '%s' "$FB_IDENTIFIER" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9._@-]/_/g')"
  MEGA_FILE="fb-session-${_safe}.tgz.enc"
fi
MEGA_DIR="${MEGA_REMOTE}:${MEGA_FOLDER}"

finish() {
  local code=$?
  log "exiting with code $code"
  screenshot "99-final-state.png"
  adb logcat -d > "$ARTIFACTS/logcat.txt" 2>/dev/null
  exit "$code"
}
trap finish EXIT

# ---------- helpers that lib-ui.sh does not have ----------
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

# "Continue in English (US)" -> "Skip" / "Not now" ... until the feed shows
post_login_prompts() {
  local rounds="${1:-12}" i xy handled
  for ((i=0; i<rounds; i++)); do
    dismiss_system_dialogs
    if is_logged_in; then log "feed detected"; return 0; fi
    handled=0
    xy="$(ui_query text '^Continue in English' 0 || true)"
    if [[ -n "$xy" ]]; then
      log "tapping 'Continue in English' at $xy"; adb shell input tap $xy; handled=1; sleep 5
    else
      xy="$(ui_query text '^Skip$' 0 || true)"
      if [[ -n "$xy" ]]; then log "tapping 'Skip' at $xy"; adb shell input tap $xy; handled=1; sleep 5
      else
        xy="$(ui_query text "$DISMISS_REGEX" 0 || true)"
        if [[ -n "$xy" ]]; then log "popup, tapping dismiss at $xy"; adb shell input tap $xy; handled=1; sleep 4; fi
      fi
    fi
    [[ "$handled" == "0" ]] && { log "no prompt to tap (round $((i+1))/$rounds), waiting"; sleep 4; }
  done
  return 1
}

# ---------- Mega upload (per-account file name) ----------
mega_upload() {
  setup_rclone || return 1
  [[ -s "$BACKUP_FILE" ]] || { log "no local backup file"; return 1; }
  local stamp base
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  base="${MEGA_FILE%.tgz.enc}"            # fb-session-<email>
  rclone mkdir "$MEGA_DIR" --retries 5 || return 1
  rclone copyto "$BACKUP_FILE" "${MEGA_DIR}/${MEGA_FILE}" --retries 5 -q || return 1
  rclone copyto "$BACKUP_FILE" "${MEGA_DIR}/${base}.${stamp}.tgz.enc" --retries 5 -q || log "WARNING: dated copy not uploaded"
  [[ -n "$(rclone lsf "${MEGA_DIR}/${MEGA_FILE}" 2>/dev/null)" ]] || { log "upload not verified"; return 1; }
  log "MEGA UPLOAD OK: ${MEGA_FOLDER}/${MEGA_FILE}"
  if [[ "$MEGA_KEEP" =~ ^[0-9]+$ ]]; then
    local f
    # only THIS account's dated copies are pruned; other accounts are never touched
    while IFS= read -r f; do
      [[ -n "$f" ]] && rclone deletefile "${MEGA_DIR}/${f}" --mega-hard-delete 2>/dev/null || true
    done < <(rclone lsf "$MEGA_DIR" --include "${base}.2*.tgz.enc" 2>/dev/null | sort | head -n -"$MEGA_KEEP")
  fi
}

# ---------- backup (needs adb root) ----------
need_root() {
  adb root >/dev/null 2>&1; sleep 3; adb wait-for-device
  [[ "$(adb_sh id -u 2>/dev/null)" == "0" ]]
}

backup_session() {
  [[ -n "$BACKUP_PASSPHRASE" ]] || { log "backup failed: BACKUP_PASSPHRASE empty"; return 1; }
  need_root || { log "backup failed: adb root not available"; return 1; }
  adb shell am force-stop "$PACKAGE_NAME"; sleep 2; adb shell sync
  local remote=/data/local/tmp/fb-session.tgz
  adb shell "rm -f $remote; tar -czf $remote --exclude='*/cache/*' --exclude='*/code_cache/*' -C /data/data $PACKAGE_NAME" \
    || { log "backup failed: tar error"; return 1; }
  adb pull "$remote" "$SESSION_TMP" >/dev/null 2>&1 || { log "backup failed: pull error"; return 1; }
  adb shell "rm -f $remote"
  local size; size="$(stat -c%s "$SESSION_TMP" 2>/dev/null || echo 0)"
  (( size < 10000 )) && { log "backup failed: archive too small ($size)"; rm -f "$SESSION_TMP"; return 1; }
  openssl enc -aes-256-cbc -pbkdf2 -salt -in "$SESSION_TMP" -out "$BACKUP_FILE" -pass env:BACKUP_PASSPHRASE \
    || { log "backup failed: encryption error"; rm -f "$SESSION_TMP"; return 1; }
  rm -f "$SESSION_TMP"
  log "encrypted backup created ($(stat -c%s "$BACKUP_FILE") bytes)"
}

# Phone link is only needed for the login. Switch it off so the upload is fast.
switch_to_runner_ip() {
  log "switching OFF the phone exit node for the Mega upload"
  sudo tailscale set --exit-node= || { log "WARNING: could not clear the exit node"; return 1; }
  sleep 5
  log "public IP now: $(curl -s --max-time 30 https://ifconfig.me || echo unknown)  (runner baseline: ${BASELINE_IP:-unknown})"
}

# ---------- login ----------
login_and_backup() {
  [[ -n "$FB_IDENTIFIER" && -n "$FB_PASSWORD" ]] || { log "FB_IDENTIFIER / FB_PASSWORD are empty (check the Mega sheet)"; return 1; }
  log "account: $FB_IDENTIFIER  ->  backup file: ${MEGA_FOLDER}/${MEGA_FILE}"
  phone_guard || return 1

  # App data and cache are left untouched (no pm clear).
  launch_app; sleep 12
  dismiss_system_dialogs
  screenshot "02-after-launch.png"
  dismiss_popups 2
  screenshot "03-before-login.png"

  if [[ -z "$(ui_find class 'EditText' 0 || true)" ]]; then
    if is_logged_in; then
      log "Facebook is already logged in (no login form): skipping typing, going to backup"
      backup_session || { log "ERROR: backup not created"; return 1; }
      switch_to_runner_ip || log "WARNING: still on the phone link, the upload may be slow"
      mega_upload || { log "ERROR: backup created but NOT uploaded to Mega"; return 1; }
      return 0
    fi
    tap_text '^Log ?in$' "" 3 || true
    sleep 4
  fi

  tap_field 0 || { screenshot "04-no-form.png"; log "ERROR: login form not found"; return 1; }
  sleep 1; type_text "$FB_IDENTIFIER"; sleep 1
  screenshot "05-username-entered.png"
  tap_field 1 || { log "ERROR: password field not found"; return 1; }
  sleep 1; type_text "$FB_PASSWORD"; sleep 1
  screenshot "06-password-entered.png"   # password is masked
  adb shell input keyevent 4 >/dev/null 2>&1; sleep 1

  phone_guard || return 1   # still on the phone IP right before submitting?
  tap_text '^Log ?in$' "" 3 || adb shell input keyevent 66
  sleep 15
  dismiss_system_dialogs
  screenshot "07-after-login-15s.png"

  if ui_dump; then
    grep -qiE 'incorrect|wrong|invalid|doesn.t match' "$UI_XML" && log "WARNING: credentials look wrong"
    grep -qiE 'two-factor|authentication app|confirm it.s you|checkpoint|suspicious|secure your account' "$UI_XML" \
      && log "WARNING: Facebook is asking for a security check / 2FA code. Complete it manually; automation stops here."
  fi

  sleep 10
  tap_text '^(Save|OK)$' "" 1 || true     # "Save your login info?"
  sleep 3
  post_login_prompts 12 || true
  screenshot "08-after-popups.png"

  if is_logged_in; then
    log "LOGIN OK (feed is visible)"
    screenshot "09-feed.png"
    backup_session || { log "ERROR: backup not created"; return 1; }
    switch_to_runner_ip || log "WARNING: still on the phone link, the upload may be slow"
    mega_upload || { log "ERROR: backup created but NOT uploaded to Mega"; return 1; }
    return 0
  fi
  log "WARNING: feed not detected, NOT creating a backup (a good old backup is never replaced by a bad one)"
  return 1
}

# ===================== MAIN =====================
adb devices -l
wait_for_boot || exit 1
settle_device
sleep 10
dismiss_system_dialogs
screenshot "00-home-screen.png"

adb shell pm list packages | grep -F "$PACKAGE_NAME" \
  || { log "ERROR: $PACKAGE_NAME is not installed in this emulator snapshot"; exit 1; }
log "Facebook is already installed in the restored emulator (no APK install needed)"

login_and_backup || { log "ERROR: login/backup failed"; exit 1; }
log "Done! Login OK and backup uploaded to Mega."
