#!/usr/bin/env bash
# login-backup.sh - login + encrypted backup for ONE OR MANY Facebook accounts on the same
# snapshot emulator, one account at a time, never mixed:
#   - before every account after the first, the emulator is reset to the clean snapshot (fb_ready),
#     so each login starts from a Facebook app with NO account in it (one account per app state)
#   - if Facebook still shows a logged-in feed after the reset, that account is refused (no backup)
#   - all logins happen on the phone IP; at the end the phone exit node is switched OFF, every
#     backup is uploaded to Mega, and the Mega sheet gets the backup names (BACKUP_FILE_NAME + BackupLog)
# Accounts come from $ACCOUNTS_JSON (written by scripts/load-config-from-mega.py from the Mega sheet).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/config.sh"
exec > >(tee -a "$ARTIFACTS/run.log") 2>&1
for f in lib-ui lib-mega; do source "$DIR/$f.sh"; done

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
mkdir -p "$PENDING_DIR"; : > "$PENDING_LIST"; : > "$RESULTS_TSV"

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
  rm -rf "$PENDING_DIR" "$PENDING_LIST" "$ACCOUNTS_JSON" "$SESSION_TMP" "$BACKUP_FILE"
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
  bash "${ROOT}/scripts/assert-phone-ip.sh" || { log "ABORT: not on the phone IP, refusing to continue"; return 1; }
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

need_root() {
  adb root >/dev/null 2>&1; sleep 3; adb wait-for-device
  [[ "$(adb_sh id -u 2>/dev/null)" == "0" ]]
}

# Back to the clean snapshot = Facebook installed, nobody logged in, no leftovers of the last account.
reset_clean_state() {
  log "resetting the emulator to the clean '$SNAPSHOT_NAME' snapshot"
  local out; out="$(timeout 120 adb emu avd snapshot load "$SNAPSHOT_NAME" 2>&1 | tr -d '\r')"
  log "snapshot load: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
  if grep -q '^OK' <<<"$out"; then
    sleep 2; timeout 20 adb reconnect >/dev/null 2>&1; adb wait-for-device
    wait_for_boot || return 1
  else
    log "WARNING: snapshot load failed -> fallback 'pm clear' (the login-form guard still refuses a logged-in app)"
    adb shell am force-stop "$PACKAGE_NAME"; adb shell pm clear "$PACKAGE_NAME" >/dev/null 2>&1 || true
  fi
  settle_device; sleep 2
  dismiss_system_dialogs
  adb shell pm list packages | grep -qF "$PACKAGE_NAME" || { log "ERROR: $PACKAGE_NAME missing after reset"; return 1; }
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

# ---------- login of ONE account ----------
login_account() {
  phone_guard || return 1

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
  sleep 1; type_text "$FB_IDENTIFIER"; sleep 1
  shot "05-username-entered.png"
  tap_field 1 || { log "ERROR: password field not found"; return 1; }
  sleep 1; type_text "$FB_PASSWORD"; sleep 1
  shot "06-password-entered.png"   # password is masked
  adb shell input keyevent 4 >/dev/null 2>&1; sleep 1

  phone_guard || return 1   # still on the phone IP right before submitting?
  tap_text '^Log ?in$' "" 3 || adb shell input keyevent 66
  # poll (was: fixed 15s + 10s + 3s sleeps): stop as soon as the feed, a security check or a wrong password shows
  local t=$SECONDS bad=0 xy
  sleep 4
  while (( SECONDS - t < 50 )); do
    dismiss_system_dialogs
    if ! ui_dump; then sleep 2; continue; fi
    if grep -qiE 'incorrect|wrong|invalid|doesn.t match' "$UI_XML"; then
      log "WARNING: credentials look wrong"; bad=1; break
    fi
    if grep -qiE 'two-factor|authentication app|confirm it.s you|checkpoint|suspicious|secure your account' "$UI_XML"; then
      log "WARNING: Facebook is asking for a security check / 2FA code. Complete it manually; automation stops here."; bad=1; break
    fi
    xy="$(ui_query text '^(Save|OK)$' 0 || true)"     # "Save your login info?"
    if [[ -n "$xy" ]]; then log "tapping Save/OK at $xy"; adb shell input tap $xy; sleep 2; continue; fi
    is_logged_in && { log "feed detected after $((SECONDS - t))s"; break; }
    sleep 2
  done
  shot "07-after-login.png"
  if (( bad )); then log "WARNING: not creating a backup (login needs attention)"; return 1; fi
  post_login_prompts 6 || true
  shot "08-after-popups.png"

  if is_logged_in; then
    log "LOGIN OK (feed is visible)"
    shot "09-feed.png"
    backup_session || { log "ERROR: backup not created"; return 1; }
    return 0
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
  [[ -s "$RESULTS_TSV" ]] || return 0
  local x="$TMPD/conf-update.xlsx" remote="${MEGA_REMOTE}:${MEGA_CONF_FOLDER}/${MEGA_CONF_FILE}"
  rclone copyto "$remote" "$x" --retries 5 -q </dev/null || { log "WARNING: cannot download the sheet from Mega"; return 1; }
  cp "$x" "$x.bak"
  rclone copyto "$x.bak" "${MEGA_REMOTE}:${MEGA_CONF_FOLDER}/${MEGA_CONF_FILE%.xlsx}.bak.xlsx" --retries 5 -q </dev/null &
  local bakpid=$!
  python3 "$DIR/update-sheet-backup-names.py" "$x" "$RESULTS_TSV" || { log "WARNING: sheet update script failed"; kill $bakpid 2>/dev/null; rm -f "$x" "$x.bak"; return 1; }
  wait $bakpid || log "WARNING: .bak copy of the sheet not uploaded"; rm -f "$x.bak"
  rclone copyto "$x" "$remote" --retries 5 -q </dev/null || { log "WARNING: cannot upload the updated sheet"; rm -f "$x"; return 1; }
  rm -f "$x"
  log "Mega sheet updated: BACKUP_FILE_NAME + BackupLog"
}

UPLOAD_FAILED=()
upload_pending() {
  [[ -s "$PENDING_LIST" ]] || { log "no backups to upload"; return 0; }
  switch_to_runner_ip || log "WARNING: still on the phone link, uploads may be slow"
  setup_rclone || return 1
  rclone mkdir "$MEGA_DIR" --retries 5 </dev/null || return 1
  upload_all
  update_sheet || log "WARNING: backups are in Mega but the sheet was not updated"
}

# ===================== MAIN =====================
[[ -n "${BACKUP_PASSPHRASE:-}" ]] || { log "ERROR: BACKUP_PASSPHRASE secret is empty"; exit 1; }
adb devices -l
wait_for_boot || exit 1
settle_device
sleep 10
dismiss_system_dialogs
shot "00-home-screen.png"

adb shell pm list packages | grep -F "$PACKAGE_NAME" \
  || { log "ERROR: $PACKAGE_NAME is not installed in this emulator snapshot"; exit 1; }
log "Facebook is already installed in the restored emulator (no APK install needed)"

COUNT="$(acc_count)"
LOGIN_OK=(); LOGIN_FAILED=()
for ((n=0; n<COUNT; n++)); do
  load_account "$n"
  SHOT_PREFIX="acc$((n+1))-"
  log "===== account $((n+1))/$COUNT: $FB_IDENTIFIER  ->  backup file: ${MEGA_FOLDER}/${MEGA_FILE} ====="
  if [[ -z "${FB_IDENTIFIER:-}" || -z "${FB_PASSWORD:-}" ]]; then
    log "ERROR: FB_IDENTIFIER / FB_PASSWORD empty for this row, skipping"; LOGIN_FAILED+=("row $((n+1))"); continue
  fi
  if (( n > 0 )); then
    reset_clean_state || { log "ERROR: cannot reset the emulator, stopping so accounts are not mixed"; LOGIN_FAILED+=("$FB_IDENTIFIER"); break; }
  fi
  if login_account; then LOGIN_OK+=("$FB_IDENTIFIER"); else LOGIN_FAILED+=("$FB_IDENTIFIER"); fi
done

upload_pending

log "SUMMARY: login+backup OK: ${LOGIN_OK[*]:-none} | login FAILED: ${LOGIN_FAILED[*]:-none} | upload FAILED: ${UPLOAD_FAILED[*]:-none}"
(( ${#LOGIN_FAILED[@]} == 0 && ${#UPLOAD_FAILED[@]} == 0 && ${#LOGIN_OK[@]} > 0 )) || exit 1
log "Done! All accounts logged in separately, backups uploaded to Mega and the sheet updated."
