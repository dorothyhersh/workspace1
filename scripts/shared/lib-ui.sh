#!/usr/bin/env bash
# lib-ui.sh - generic adb / UI helpers (sourced, not run directly)
# (No logic changes needed here for the live-logging fix - log() already writes with bash's
# own printf builtin, which is unbuffered. The buffering problem was entirely in login-backup.sh's
# `exec > >(tee ...)` line, now fixed there with `stdbuf -oL`. Reproduced as-is for completeness.)

log() { printf '[fb %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; printf '%s' "$*" > "${ARTIFACTS:-/tmp}/phase" 2>/dev/null || true; }
adb_sh() { adb shell "$@" | tr -d '\r'; }

# ---- logged input wrappers: every adb tap / keypress / text entry prints BEFORE it runs,
# so progress is visible live in the workflow log, not just inferred afterward from screenshots ----
adb_tap() {
  local x="$1" y="$2" label="${3:-tap}"
  log "ACTION: $label -> input tap $x $y"
  adb shell input tap "$x" "$y"
}
adb_key() {
  local code="$1" label="${2:-keyevent $1}"
  log "ACTION: $label -> input keyevent $code"
  adb shell input keyevent "$code" >/dev/null 2>&1
}
# mask=1 logs '********' instead of the real text (use for passwords / anything sensitive)
adb_text() {
  local s="$1" label="${2:-type text}" mask="${3:-0}" q="'"
  if [[ "$mask" == "1" ]]; then log "ACTION: $label -> input text '********'"; else log "ACTION: $label -> input text '$s'"; fi
  s="${s//$q/$q\\$q$q}"; s="${s// /%s}"
  adb shell "input text '$s'" >/dev/null 2>&1
}

screenshot() {
  local f="$ARTIFACTS/$1"
  adb exec-out screencap -p > "$f" 2>/dev/null
  if [[ -s "$f" ]]; then log "screenshot: $1"; else log "screenshot FAILED: $1"; rm -f "$f"; fi
}

settle_device() {
  adb shell svc power stayon true >/dev/null 2>&1 || true
  adb shell settings put global hide_error_dialogs 1 >/dev/null 2>&1 || true
  adb shell settings put secure lockscreen.disabled 1 >/dev/null 2>&1 || true
  adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
}

wait_for_boot() {
  adb wait-for-device
  local i=0
  while (( i < 180 )); do
    [[ "$(adb_sh getprop sys.boot_completed 2>/dev/null || true)" == "1" ]] && break
    sleep 2; i=$((i+1))
  done
  (( i < 180 )) || { log "timed out waiting for boot"; return 1; }
  # sys.boot_completed can read 1 right after a snapshot resume before the package
  # manager service is actually answering ("Can't find service: package"), so confirm
  # it responds before moving on. Usually instant; only slow if it's genuinely not ready.
  local j=0
  while (( j < 90 )); do
    # adb_sh ends in a pipe, so its exit code is useless: look at the OUTPUT (must list packages, not "Can't find service")
    adb_sh pm list packages 2>&1 | grep -q '^package:' && return 0
    sleep 1; j=$((j+1))
  done
  log "package manager service not responding after boot"; return 1
}

# Full dump (retries). Use ui_dump_fast on screens where a video plays.
ui_dump() {
  local i
  for i in 1 2 3; do
    if timeout 20 adb shell uiautomator dump /sdcard/ui.xml 2>&1 | grep -q "dumped to"; then
      adb pull /sdcard/ui.xml "$UI_XML" >/dev/null 2>&1 && return 0
    fi
    sleep 1
  done
  return 1
}

# Single attempt with a hard timeout (uiautomator hangs while a video is playing)
ui_dump_fast() {
  local out
  out="$(timeout 15 adb shell uiautomator dump /sdcard/ui.xml 2>&1 | tr -d '\r')"
  if grep -q "dumped to" <<<"$out"; then
    adb pull /sdcard/ui.xml "$UI_XML" >/dev/null 2>&1 && return 0
  fi
  log "ui dump failed (screen busy?): $(printf '%s' "$out" | head -c 120 | tr '\n' ' ')"
  return 1
}

# ui_query <class|text> <regex> <index> -> "x y"
ui_query() {
  python3 - "$UI_XML" "$1" "$2" "$3" <<'PY'
import re, sys, xml.etree.ElementTree as ET
path, mode, pat, idx = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
rx = re.compile(pat, re.I)
hits = []
for n in ET.parse(path).getroot().iter('node'):
    a = n.attrib
    t, d = a.get('text', ''), a.get('content-desc', '')
    ok = rx.search(a.get('class', '')) if mode == 'class' else (rx.search(t) or rx.search(d))
    if ok:
        m = re.findall(r'\d+', a.get('bounds', ''))
        if len(m) == 4:
            x1, y1, x2, y2 = map(int, m)
            hits.append(((x1 + x2) // 2, (y1 + y2) // 2))
if len(hits) > idx:
    print(hits[idx][0], hits[idx][1])
PY
}
ui_find() { ui_dump || return 1; ui_query "$@"; }

# prints "x y text" for every visible node with text
ui_texts() {
  python3 - "$UI_XML" <<'PY'
import re, sys, xml.etree.ElementTree as ET
for n in ET.parse(sys.argv[1]).getroot().iter('node'):
    a = n.attrib
    t = (a.get('text') or a.get('content-desc') or '').strip()
    m = re.findall(r'\d+', a.get('bounds', ''))
    if t and len(m) == 4:
        x1, y1, x2, y2 = map(int, m)
        print(f"{(x1 + x2) // 2} {(y1 + y2) // 2} {t}")
PY
}

save_ui() { ui_dump && cp "$UI_XML" "$ARTIFACTS/ui-$1.xml" 2>/dev/null || true; }

tap_text() {
  local pat="$1" fallback="${2:-}" tries="${3:-5}" xy="" i
  for ((i=0; i<tries; i++)); do
    xy="$(ui_find text "$pat" 0 || true)"; [[ -n "$xy" ]] && break; sleep 2
  done
  [[ -z "$xy" && -n "$fallback" ]] && { log "'$pat' not found, fallback tap $fallback"; xy="$fallback"; }
  [[ -z "$xy" ]] && { log "'$pat' not found"; return 1; }
  adb_tap $xy "tap '$pat'"
}

focus_line() { adb shell dumpsys window 2>/dev/null | grep -E 'mCurrentFocus' | head -1 | tr -d '\r'; }

DISMISS_REGEX='^(Not now|Not Now|Maybe later|No thanks|Skip|Later|Dismiss|Got it|Cancel|Don.t allow|DENY)\b'

dismiss_system_dialogs() {
  local i xy
  for ((i=0; i<4; i++)); do
    xy=""
    if ui_dump; then
      if grep -qiE 'responding' "$UI_XML"; then xy="$(ui_query text '^Wait$' 0 || true)"
      elif grep -qiE 'keeps stopping|has stopped' "$UI_XML"; then xy="$(ui_query text '^(Close app|OK)$' 0 || true)"
      fi
    fi
    [[ -z "$xy" ]] && break
    adb_tap $xy "system dialog"; sleep 3
  done
  return 0
}

dismiss_popups() {
  local rounds="${1:-5}" i xy hit
  for ((i=0; i<rounds; i++)); do
    dismiss_system_dialogs
    hit=0
    if ui_dump; then
      xy="$(ui_query text "$DISMISS_REGEX" 0 || true)"
      if [[ -n "$xy" ]]; then adb_tap $xy "dismiss popup"; hit=1; sleep 3; fi
    fi
    if [[ "$hit" == "0" ]]; then (( i >= 1 )) && break; sleep 3; fi
  done
}

launch_app() {
  log "launching $PACKAGE_NAME"
  adb shell input keyevent KEYCODE_WAKEUP
  adb shell wm dismiss-keyguard
  adb shell monkey -p "$PACKAGE_NAME" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || {
    local act; act="$(adb_sh cmd package resolve-activity --brief "$PACKAGE_NAME" | tail -1)"
    adb shell am start -n "$act"
  }
}

# Menu header text, e.g. "Hollie Wells, see your profile" -> "Hollie Wells"
menu_profile_name() {
  ui_texts | sed -n 's/^[0-9]* [0-9]* \(.*\), see your profile$/\1/p' | head -1
}

switcher_open() { grep -qiE 'Create Facebook Page|Open Accounts Center' "$UI_XML"; }

# pure check on the already-dumped $UI_XML (no new dump)
logged_in_xml() {
  ! grep -qiE 'Create new account|Forgot password|Log in to Facebook' "$UI_XML" \
    && ! switcher_open \
    && grep -qiE 'Home|What.s on your mind|Notifications|Menu' "$UI_XML"
}
is_logged_in() { ui_dump || return 1; logged_in_xml; }

# Closes the Menu screen so the feed (with the + button) is showing
return_to_feed() {
  local i
  for i in 1 2 3; do
    ui_dump || true
    if grep -qiE 'Your shortcuts|Settings and privacy' "$UI_XML" 2>/dev/null; then
      log "closing Menu to get back to the feed (attempt $i)"
      adb shell input keyevent 4 >/dev/null 2>&1; sleep 3
    else
      break
    fi
  done
  dismiss_system_dialogs
}

# After a failed reel: get back to the plain feed. Last resort: force-stop + relaunch
# (the logged-in session is on disk, no new login needed).
recover_to_feed() {
  local i xy
  for i in 1 2 3 4 5; do
    ui_dump || true
    if grep -qiE "Couldn.t play video" "$UI_XML"; then
      xy="$(ui_query text '^OK$' 0 || true)"
      [[ -n "$xy" ]] && { log "recover: dismissing 'Couldn't play video'"; adb shell input tap $xy; sleep 2; }
      ui_dump || true
    fi
    if grep -qiE "What.s on your mind" "$UI_XML" \
       && ! grep -qiE 'Add audio|Select multiple|Camera roll settings|Describe your reel|Share now' "$UI_XML"; then
      return 0
    fi
    xy="$(ui_query text '^(Discard|Discard reel|Discard edits|Delete|Leave|Exit|Leave and discard)$' 0 || true)"
    if [[ -n "$xy" ]]; then log "recover: confirming discard at $xy"; adb shell input tap $xy
    else adb shell input keyevent 4 >/dev/null 2>&1; fi
    sleep 3
  done
  log "recover_to_feed: force-stop + relaunch"
  adb shell am force-stop "$PACKAGE_NAME"; sleep 2
  launch_app; sleep 20
  dismiss_system_dialogs
  dismiss_popups 3
  return 0
}
