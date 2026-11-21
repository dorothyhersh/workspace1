#!/usr/bin/env bash
# restore-session.sh - restores the Facebook login (from the Mega backup) into the emulator and verifies it.
# Run by the "FB - Restore saved Facebook login" workflow inside the emulator-runner step. Needs adb root.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/config.sh"
exec > >(tee -a "$ARTIFACTS/run.log") 2>&1
for f in lib-ui lib-mega; do source "$DIR/$f.sh"; done

# an explicit backup name typed into the workflow (e.g. fb-session-<email>.20261121-003351.tgz.enc) wins
if [[ -n "${RESTORE_FILE:-}" ]]; then
  MEGA_FILE="$RESTORE_FILE"
  log "using backup file from workflow input: $MEGA_FILE"
fi

need_root() {
  adb root >/dev/null 2>&1; sleep 2; adb wait-for-device
  [[ "$(adb_sh id -u 2>/dev/null)" == "0" ]]
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
    sleep 3; save_ui "restored-menu"; screenshot "12-restored-menu.png"
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

# Restore (from an already-downloaded backup) -> launch -> verify logged in. Returns 0 only when the feed is visible.
restore_flow() {
  restore_session || return 1
  launch_app; sleep 8; dismiss_system_dialogs
  screenshot "10-restored-launch.png"
  dismiss_popups 3; sleep 1
  screenshot "11-restored-after-dismiss.png"
  if is_logged_in; then
    log "RESTORE OK: Facebook opened already logged in"
    log_restored_profile
    return_to_feed
    return 0
  fi
  log "RESTORE FAILED: not logged in (see screenshots 10 and 11)"
  return 1
}

# ===================== MAIN =====================
finish() {
  local code=$?
  log "exiting with code $code"
  screenshot "99-final-state.png"
  adb logcat -d -t 1000 > "$ARTIFACTS/logcat.txt" 2>/dev/null
  rm -f "$SESSION_TMP" "$BACKUP_FILE"
  exit "$code"
}
trap finish EXIT

[[ -n "${BACKUP_PASSPHRASE:-}" ]] || { log "ERROR: BACKUP_PASSPHRASE secret is empty"; exit 1; }
adb devices -l
wait_for_boot || exit 1
settle_device
sleep 2
screenshot "00-home-screen.png"

adb shell pm list packages | grep -F "$PACKAGE_NAME" \
  || { log "ERROR: $PACKAGE_NAME is not installed in this emulator snapshot"; exit 1; }

log "downloading ${MEGA_FOLDER}/${MEGA_FILE} on the runner's own IP (fast)"
mega_download_backup || exit 1

log "switching to the phone IP before touching Facebook"
timeout 300 bash "$DIR/use-phone-exit-node.sh" || { log "ERROR: could not switch to the phone IP, aborting (refusing to restore on the runner IP)"; exit 1; }

log "restoring the session into the emulator"
restore_flow || exit 1
log "Done! Saved Facebook login restored."
