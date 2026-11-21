#!/usr/bin/env bash
# restore-session.sh - restores the saved Facebook login of ONE OR MANY accounts (from the Mega backups)
# into the snapshot emulator, one account at a time, never mixed:
#   - only accounts with STATUS=active and a backup name in the Mega sheet are restored (decided by
#     scripts/shared/load-config-from-mega.py --only-active, top to bottom); suspended / failed rows are skipped
#   - ALL backups are downloaded first, on the runner's own fast IP (before the phone exit node is on)
#   - then the phone exit node is switched on and every account is restored on the phone IP
#   - before every account after the first, the emulator is reset to the clean snapshot (fb_ready), so each
#     restore starts from a Facebook app with NO account in it (one account per app state)
#   - after each restore the app must show the logged-in feed, and the profile name is logged as proof
# Accounts come from $ACCOUNTS_JSON (written by load-config-from-mega.py from the Mega sheet).
# Run by the "FB - Restore saved Facebook login" workflow inside run-with-emulator.sh. Needs adb root.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../shared/config.sh"
exec > >(tee -a "$ARTIFACTS/run.log") 2>&1
for f in lib-ui lib-mega; do source "$DIR/../shared/$f.sh"; done

ACCOUNTS_JSON="${ACCOUNTS_JSON:-}"
SNAPSHOT_NAME="${SNAPSHOT_NAME:-fb_ready}"
TMPD="${RUNNER_TEMP:-/tmp}"
BACKUP_DIR="$TMPD/restore-backups"
MEGA_DIR="${MEGA_REMOTE}:${MEGA_FOLDER}"
SUSPENDED_REGEX="confirm you.{1,6}re human|(account|profile).{0,40}(suspended|disabled|locked)|(suspended|disabled|locked).{0,30}(your|the) account|we suspended your|your account (has been|was|is) (suspended|disabled|locked|restricted)"
mkdir -p "$BACKUP_DIR"

# single-account fallback: build a one-entry list from FB_IDENTIFIER / MEGA_FILE
if [[ -z "$ACCOUNTS_JSON" || ! -s "$ACCOUNTS_JSON" ]]; then
  [[ -n "${FB_IDENTIFIER:-}" ]] || { log "ERROR: no accounts (ACCOUNTS_JSON missing/empty)"; exit 1; }
  ACCOUNTS_JSON="$TMPD/accounts.json"
  python3 -c 'import json,os;print(json.dumps([{"FB_IDENTIFIER":os.environ["FB_IDENTIFIER"],"MEGA_FILE":os.environ.get("MEGA_FILE","")}]))' > "$ACCOUNTS_JSON"
fi

SHOT_PREFIX=""
shot() { screenshot "${SHOT_PREFIX}$1"; }

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
  FB_IDENTIFIER="${FB_IDENTIFIER:-}"; FB_PAGE_NAME="${FB_PAGE_NAME:-}"; MEGA_FILE="${MEGA_FILE:-}"
}

# ---------- restore of ONE account ----------
need_root() {
  adb root >/dev/null 2>&1; sleep 2; adb wait-for-device
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
    log "WARNING: snapshot load failed -> fallback 'pm clear' (wipes the app data of the previous account)"
    adb shell am force-stop "$PACKAGE_NAME"; adb shell pm clear "$PACKAGE_NAME" >/dev/null 2>&1 || true
  fi
  settle_device; sleep 2
  dismiss_system_dialogs
  adb shell pm list packages 2>&1 | grep -qF "$PACKAGE_NAME" || { log "ERROR: $PACKAGE_NAME missing after reset"; return 1; }
}

restore_session() {
  [[ -s "$BACKUP_FILE" ]] || { log "restore failed: no backup file"; return 1; }
  [[ -n "$BACKUP_PASSPHRASE" ]] || { log "restore failed: BACKUP_PASSPHRASE empty"; return 1; }
  need_root || { log "restore failed: adb root not available"; return 1; }
  openssl enc -d -aes-256-cbc -pbkdf2 -in "$BACKUP_FILE" -out "$SESSION_TMP" -pass env:BACKUP_PASSPHRASE \
    || { log "restore failed: decryption error (wrong BACKUP_PASSPHRASE?)"; return 1; }
  tar -tzf "$SESSION_TMP" >/dev/null 2>&1 || { log "restore failed: corrupt archive"; return 1; }
  local uid; uid="$(adb_sh stat -c %u "/data/data/$PACKAGE_NAME" 2>/dev/null | tail -1)"
  [[ "$uid" =~ ^[0-9]+$ ]] || { log "restore failed: Facebook is not installed in this emulator"; return 1; }
  local remote=/data/local/tmp/fb-session.tgz
  adb shell am force-stop "$PACKAGE_NAME"
  adb push "$SESSION_TMP" "$remote" >/dev/null 2>&1 || { log "restore failed: push error"; return 1; }
  adb shell "find /data/data/$PACKAGE_NAME -mindepth 1 -maxdepth 1 ! -name cache ! -name code_cache -exec rm -rf {} +"
  adb shell "tar -xzf $remote -C /data/data" || { log "restore failed: extract error"; return 1; }
  adb shell "chown -R $uid:$uid /data/data/$PACKAGE_NAME"
  adb shell "restorecon -R /data/data/$PACKAGE_NAME" 2>/dev/null || true
  adb shell setenforce 0 2>/dev/null || true
  adb shell "rm -f $remote"; rm -f "$SESSION_TMP" "$BACKUP_FILE"
  log "session data restored"
}

# Opens Menu and logs which profile the restored session is on (the Page, if backed up on the Page)
log_restored_profile() {
  local name
  if tap_text '^Menu' "" 3; then
    sleep 2; save_ui "${SHOT_PREFIX}restored-menu"; shot "12-restored-menu.png"
    name="$(menu_profile_name)"
    log "restored session profile: '${name:-unknown}'"
    if [[ -n "$FB_PAGE_NAME" ]]; then
      if [[ "${name,,}" == "${FB_PAGE_NAME,,}" ]]; then log "RESTORED AS PAGE OK ($name)"
      else log "WARNING: restored profile is '${name:-unknown}', expected Page '$FB_PAGE_NAME'"; fi
    fi
  else
    log "could not open Menu to check the restored profile"
  fi
}

RESTORE_RESULT=""   # restored | suspended | restore_failed
# Restore (from the already-downloaded backup) -> launch -> verify logged in. Returns 0 only when the feed is visible.
restore_flow() {
  RESTORE_RESULT="restore_failed"
  restore_session || return 1
  launch_app
  # poll instead of the old fixed 8s + popup rounds: stop as soon as the feed, a login form or a suspension shows
  local t=$SECONDS feed=0 xy
  sleep 4
  while (( SECONDS - t < 40 )); do
    ui_dump || { sleep 1; continue; }
    if grep -qiE 'responding|keeps stopping|has stopped' "$UI_XML"; then dismiss_system_dialogs; continue; fi
    if logged_in_xml; then feed=1; break; fi
    if grep -qiE "$SUSPENDED_REGEX" "$UI_XML"; then break; fi
    if grep -qiE 'Create new account|Forgot password|Log in to Facebook' "$UI_XML"; then break; fi   # session not accepted
    xy="$(ui_query text "$DISMISS_REGEX" 0 || true)"
    if [[ -n "$xy" ]]; then log "popup, tapping dismiss at $xy"; adb shell input tap $xy; sleep 2; continue; fi
    sleep 1
  done
  shot "10-restored-launch.png"
  if (( feed )); then
    log "RESTORE OK: Facebook opened already logged in ($((SECONDS - t))s)"
    RESTORE_RESULT="restored"
    log_restored_profile
    return_to_feed
    return 0
  fi
  if grep -qiE "$SUSPENDED_REGEX" "$UI_XML" 2>/dev/null; then
    RESTORE_RESULT="suspended"; log "ACCOUNT SUSPENDED: the restored session shows '$(ui_texts | cut -d' ' -f3- | grep -iE "$SUSPENDED_REGEX" | head -1)'"
    return 1
  fi
  dismiss_popups 2
  shot "11-restored-after-dismiss.png"
  if is_logged_in; then
    log "RESTORE OK: Facebook opened already logged in"
    RESTORE_RESULT="restored"; log_restored_profile; return_to_feed; return 0
  fi
  log "RESTORE FAILED: not logged in (see the screenshots)"
  return 1
}

# ---------- download ALL backups on the runner's own IP (one parallel rclone call) ----------
download_all() {
  setup_rclone || return 1
  local list="$TMPD/restore-files.txt" n i f
  : > "$list"
  n="$(acc_count)"
  for ((i=0; i<n; i++)); do load_account "$i"; [[ -n "${MEGA_FILE:-}" ]] && echo "$MEGA_FILE" >> "$list"; done
  sort -u "$list" -o "$list"
  log "downloading $(wc -l < "$list") backup file(s) from ${MEGA_DIR} on the runner's own IP (fast)"
  rclone copy "$MEGA_DIR" "$BACKUP_DIR" --files-from "$list" --transfers 8 --checkers 8 --retries 5 --low-level-retries 10 -q </dev/null \
    || log "WARNING: rclone reported errors (checking which files arrived)"
  while read -r f; do
    [[ -s "$BACKUP_DIR/$f" ]] && log "MEGA DOWNLOAD OK: $f ($(stat -c%s "$BACKUP_DIR/$f") bytes)" || log "backup NOT found in Mega: $f"
  done < "$list"
  rm -f "$list"
}

# ===================== MAIN =====================
finish() {
  local code=$?
  log "exiting with code $code"
  screenshot "99-final-state.png"
  adb logcat -d -t 1000 > "$ARTIFACTS/logcat.txt" 2>/dev/null
  rm -rf "$BACKUP_DIR" "$SESSION_TMP" "$BACKUP_FILE"
  exit "$code"
}
trap finish EXIT

[[ -n "${BACKUP_PASSPHRASE:-}" ]] || { log "ERROR: BACKUP_PASSPHRASE secret is empty"; exit 1; }
COUNT="$(acc_count)"
if (( COUNT == 0 )); then
  log "Nothing to restore: no account with STATUS=active and a backup in the sheet."
  exit 0
fi
# a backup name typed into the workflow only makes sense for ONE account
RESTORE_OVERRIDE=""
if [[ -n "${RESTORE_FILE:-}" ]]; then
  if (( COUNT == 1 )); then RESTORE_OVERRIDE="$RESTORE_FILE"; log "using backup file from workflow input: $RESTORE_FILE"
  else log "WARNING: backup_file input ignored because $COUNT accounts are selected (name ONE account to use it)"; fi
fi

adb devices -l
wait_for_boot || exit 1
settle_device
sleep 2
shot "00-home-screen.png"

PKG_FOUND=""
for _try in $(seq 1 30); do   # right after a snapshot resume the package service can need a few more seconds
  PKG_FOUND="$(adb shell pm list packages 2>&1 | grep -F "$PACKAGE_NAME" || true)"
  [[ -n "$PKG_FOUND" ]] && break
  sleep 2
done
[[ -n "$PKG_FOUND" ]] || { log "ERROR: $PACKAGE_NAME is not installed in this emulator snapshot (or the package service never came up)"; exit 1; }
log "$PKG_FOUND"

# 1) every backup, on the runner IP (before the phone exit node)
if [[ -n "$RESTORE_OVERRIDE" ]]; then
  python3 - "$ACCOUNTS_JSON" "$RESTORE_OVERRIDE" <<'PY'
import json, sys
a = json.load(open(sys.argv[1])); a[0]["MEGA_FILE"] = sys.argv[2]; json.dump(a, open(sys.argv[1], "w"))
PY
fi
download_all || { log "ERROR: cannot download the backups from Mega"; exit 1; }

# 2) phone IP for everything that touches Facebook
log "switching to the phone IP before touching Facebook"
timeout 300 bash "$DIR/../shared/use-phone-exit-node.sh" || { log "ERROR: could not switch to the phone IP, aborting (refusing to restore on the runner IP)"; exit 1; }

# 3) restore every account separately
RESTORED=(); SUSPENDED=(); FAILED=(); INFRA_FAIL=0; TRIED=0
for ((n=0; n<COUNT; n++)); do
  load_account "$n"
  SHOT_PREFIX="acc$((n+1))-"
  log "===== account $((n+1))/$COUNT: ${FB_IDENTIFIER:-?}  ->  backup: ${MEGA_FILE:-none} ====="
  if [[ -z "${FB_IDENTIFIER:-}" || -z "${MEGA_FILE:-}" ]]; then
    log "skipping this row: no FB_IDENTIFIER / backup name"; FAILED+=("row $((n+1))"); continue
  fi
  if [[ ! -s "$BACKUP_DIR/$MEGA_FILE" ]]; then
    log "ERROR: backup $MEGA_FILE was not downloaded, skipping $FB_IDENTIFIER"; FAILED+=("$FB_IDENTIFIER"); continue
  fi
  if (( TRIED > 0 )); then
    reset_clean_state || { log "ERROR: cannot reset the emulator, stopping so accounts are not mixed"; FAILED+=("$FB_IDENTIFIER"); INFRA_FAIL=1; break; }
  fi
  TRIED=$((TRIED+1))
  bash "$DIR/../shared/assert-phone-ip.sh" || { log "ABORT: not on the phone IP, refusing to restore $FB_IDENTIFIER"; FAILED+=("$FB_IDENTIFIER"); INFRA_FAIL=1; break; }
  cp "$BACKUP_DIR/$MEGA_FILE" "$BACKUP_FILE"
  if restore_flow; then RESTORED+=("$FB_IDENTIFIER")
  elif [[ "$RESTORE_RESULT" == "suspended" ]]; then SUSPENDED+=("$FB_IDENTIFIER")
  else FAILED+=("$FB_IDENTIFIER"); fi
  log "ACCOUNT RESULT: $FB_IDENTIFIER => $RESTORE_RESULT"
done

log "SUMMARY: restored OK: ${RESTORED[*]:-none} | SUSPENDED: ${SUSPENDED[*]:-none} | restore FAILED: ${FAILED[*]:-none}"
for a in "${SUSPENDED[@]:-}"; do [[ -n "$a" ]] && echo "::warning title=Account suspended::$a is suspended (update its STATUS in the sheet)"; done
for a in "${FAILED[@]:-}"; do [[ -n "$a" ]] && echo "::warning title=Restore failed::$a could not be restored (see screenshots)"; done

# One bad account never fails the run. It fails only when the emulator/phone link broke or NOTHING could be restored.
if (( INFRA_FAIL )); then log "ERROR: emulator / phone-IP problem, some accounts were not processed"; exit 1; fi
if (( TRIED > 0 && ${#RESTORED[@]} == 0 )); then log "ERROR: no account could be restored"; exit 1; fi
log "Done! ${#RESTORED[@]} account(s) restored, ${#SUSPENDED[@]} suspended, ${#FAILED[@]} failed."
exit 0
