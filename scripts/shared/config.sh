#!/usr/bin/env bash
# config.sh - every setting in one place. All can be overridden by workflow env vars.
# (No changes needed here for the live-logging fix - that fix lives in login-backup.sh's
# exec line. This file is reproduced as-is so you have all four in sync.)

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
ARTIFACTS="${ROOT}/artifacts"
DOPOST_DIR="${ROOT}/dopost"
mkdir -p "$ARTIFACTS"

PACKAGE_NAME="${PACKAGE_NAME:-com.facebook.katana}"
FB_PAGE_NAME="${FB_PAGE_NAME:-}"            # optional: exact Page name, only used to log a check

# --- Mega (rclone) ---
RCLONE_CONF_CONTENT="${RCLONE_CONF_CONTENT:-}"
RCLONE_CFG="${HOME}/.config/rclone/rclone.conf"
MEGA_REMOTE="${MEGA_REMOTE:-mega}"
MEGA_FOLDER="${MEGA_FOLDER:-facebook-android-backup}"   # where the login backup lives
MEGA_FILE="${MEGA_FILE:-fb-session.tgz.enc}"
BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:-}"

# --- Reels ---
REEL_COUNT="${REEL_COUNT:-1}"
MEGA_REELS_SRC="${MEGA_REELS_SRC:-FB_Reels}"     # videos waiting to be posted
MEGA_REELS_DONE="${MEGA_REELS_DONE:-FB_Reels2}"  # posted videos are moved here
CAPTION_FILE="${CAPTION_FILE:-${DOPOST_DIR}/caption.txt}"
REENCODE_REELS="${REENCODE_REELS:-1}"            # 1 = convert to emulator-friendly H.264
MAX_PLAYBACK_FAILS="${MAX_PLAYBACK_FAILS:-2}"
REELS_LOCAL_DIR="${RUNNER_TEMP:-/tmp}/reels"

# --- ADBKeyboard (types emoji / hashtags) ---
ADBKEYBOARD_APK_URL="${ADBKEYBOARD_APK_URL:-https://github.com/senzhk/ADBKeyBoard/raw/master/ADBKeyboard.apk}"
ADBKEYBOARD_PKG="com.android.adbkeyboard"
ADBKEYBOARD_APK="${RUNNER_TEMP:-/tmp}/ADBKeyboard.apk"

# --- temp files ---
UI_XML="${RUNNER_TEMP:-/tmp}/ui.xml"
SESSION_TMP="${RUNNER_TEMP:-/tmp}/fb-session.tgz"
BACKUP_FILE="${RUNNER_TEMP:-/tmp}/fb-session.tgz.enc"
