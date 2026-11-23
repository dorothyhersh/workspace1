#!/usr/bin/env bash
# lib-captcha.sh - text-captcha handling (sourced, not run directly)
# Debug mode (CAPTCHA_TAP_ONLY=1, default): find the "play audio" button with several independent
# methods, tap it with several independent tap methods, screenshot after EVERY attempt, and log
# whether audio actually started (dumpsys audio) after each - NO recording (no parecord/screenrecord).
# Once tapping is confirmed working, set CAPTCHA_TAP_ONLY=0 to also record wav/mp3/mp4.
# Needs from the caller: log, screenshot, ui_dump, ui_query, ui_texts (lib-ui.sh), $UI_XML, $ARTIFACTS.

CAPTURE_CAPTCHA_AUDIO="${CAPTURE_CAPTCHA_AUDIO:-0}"      # 0 = do nothing but screenshot the captcha (no button tapping at all)
CAPTCHA_TAP_ONLY="${CAPTCHA_TAP_ONLY:-1}"                # 1 (default) = tap + screenshot only, no recording. 0 = also record.
CAPTCHA_AUDIO_SECONDS="${CAPTCHA_AUDIO_SECONDS:-20}"     # only used when CAPTCHA_TAP_ONLY=0
CAPTCHA_AUDIO_TAP="${CAPTCHA_AUDIO_TAP:-727 837}"        # last-resort fallback "x y"
CAPTCHA_PLAY_REGEX="${CAPTCHA_PLAY_REGEX:-}"             # optional: your own regex for the play button text
CAPTCHA_REGEX="${CAPTCHA_REGEX:-Enter the characters you see|characters you see|real human behind this login|type the (characters|text|code) (you see|shown|below)|enter the (text|code) (you see|shown)}"
CAPTCHA_N=0

# ---- METHOD 1: via lib-ui.sh's ui_query, exact-anchored text (never matches the parent sentence) ----
captcha_find_play_ui() {
  local xy="" r
  for r in "$CAPTCHA_PLAY_REGEX" '^play audio$' '^Play audio$' '^PLAY AUDIO$'; do
    [[ -n "$r" ]] || continue
    xy="$(ui_query text "$r" 0 2>/dev/null || true)"
    [[ -n "$xy" ]] && { log "  [method=ui_query text] matched regex '$r' -> $xy"; printf '%s' "$xy"; return 0; }
  done
  return 1
}

# ---- METHOD 2: parse $UI_XML directly in python, independent of lib-ui.sh's own matching logic.
# Looks for the LEAF node (no children, usually class=android.widget.Button) whose text or
# content-desc is exactly "play audio" (case-insensitive), and returns the centre of ITS OWN bounds
# (never the parent "Can't read this? Generate new or play audio" sentence node).
captcha_find_play_xml() {
  [[ -f "$UI_XML" ]] || return 1
  python3 - "$UI_XML" <<'PY' 2>/dev/null
import re, sys
xml = open(sys.argv[1], encoding='utf-8', errors='ignore').read()
best = None
for m in re.finditer(r'<node\b[^>]*?/?>', xml):
    tag = m.group(0)
    def attr(name):
        mm = re.search(name + r'="([^"]*)"', tag)
        return mm.group(1) if mm else ''
    text = attr('text'); desc = attr('content-desc')
    if text.strip().lower() == 'play audio' or desc.strip().lower() == 'play audio':
        b = attr('bounds')
        mm = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
        if mm:
            x1,y1,x2,y2 = map(int, mm.groups())
            w = x2-x1
            if best is None or w < best[2]:   # smallest matching box = the leaf, not an ancestor
                best = ((x1+x2)//2, (y1+y2)//2, w)
if best:
    print(f"{best[0]} {best[1]}")
PY
}

# finds the button, trying every method, 3 rounds of re-dumping the UI if nothing matches yet
captcha_find_play() {
  local xy="" i
  for i in 1 2 3; do
    xy="$(captcha_find_play_ui || true)"
    [[ -n "$xy" ]] && { printf '%s' "$xy"; return 0; }
    xy="$(captcha_find_play_xml || true)"
    if [[ -n "$xy" ]]; then log "  [method=xml-parse] found leaf node 'play audio' -> $xy"; printf '%s' "$xy"; return 0; fi
    log "  no match on round $i/3, re-dumping UI and retrying"
    sleep 2; ui_dump || true
  done
  return 1
}

# is any app audio player in state "started"? (best-effort signal that the press worked)
captcha_audio_started() {
  adb shell dumpsys audio 2>/dev/null | tr -d '\r' | grep -qiE 'state:started'
}

# one tap attempt by a named method, with its own screenshot + audio-state log line
captcha_try_tap() {
  local tag="$1" method="$2" x y; read -r x y <<<"$3"
  case "$method" in
    tap)        log "  TAP METHOD '$method': adb shell input tap $x $y";        adb shell input tap "$x" "$y" ;;
    swipe120)   log "  TAP METHOD '$method': adb shell input swipe $x $y $x $y 120"; adb shell input swipe "$x" "$y" "$x" "$y" 120 ;;
    swipe300)   log "  TAP METHOD '$method': adb shell input swipe $x $y $x $y 300"; adb shell input swipe "$x" "$y" "$x" "$y" 300 ;;
    doubletap)  log "  TAP METHOD '$method': two quick taps";
                adb shell input tap "$x" "$y"; sleep 0.15; adb shell input tap "$x" "$y" ;;
    *)          log "  TAP METHOD '$method' unknown, skipping"; return 1 ;;
  esac
  sleep 1
  screenshot "${tag}-tap-${method}.png"
  sleep 2
  if captcha_audio_started; then
    log "  RESULT after '$method': AUDIO IS PLAYING (dumpsys audio shows state:started)"
    return 0
  else
    log "  RESULT after '$method': no audio player in state 'started' yet"
    return 1
  fi
}

capture_captcha_audio() {
  CAPTCHA_N=$((CAPTCHA_N + 1))
  local tag="${SHOT_PREFIX:-}captcha${CAPTCHA_N}"
  local xy="" started=0 m

  log "CAPTCHA detected ($tag): saving screenshot + UI dump"
  screenshot "${tag}-1-screen.png"
  if ui_dump; then
    cp "$UI_XML" "$ARTIFACTS/${tag}-ui.xml" 2>/dev/null || true
    log "captcha screen texts: $(ui_texts | cut -d' ' -f3- | head -30 | tr '\n' '|' | cut -c1-500)"
  fi
  [[ "$CAPTURE_CAPTCHA_AUDIO" == "1" ]] || { log "captcha audio capture is switched off (CAPTURE_CAPTCHA_AUDIO=0)"; return 0; }

  log "looking for the 'play audio' button (multiple detection methods)..."
  xy="$(captcha_find_play || true)"
  if [[ -n "$xy" ]]; then
    log "play-audio button LOCATED at: $xy"
  elif [[ -n "$CAPTCHA_AUDIO_TAP" ]]; then
    log "play-audio button NOT found by any detection method - falling back to CAPTCHA_AUDIO_TAP=$CAPTCHA_AUDIO_TAP"
    xy="$CAPTCHA_AUDIO_TAP"
  else
    log "WARNING: no play-audio button found and no fallback coordinates set - see ${tag}-ui.xml / ${tag}-1-screen.png"
    return 1
  fi

  adb shell cmd media_session volume --stream 3 --set 15 >/dev/null 2>&1 \
    || adb shell media volume --show --stream 3 --set 15 >/dev/null 2>&1 || true
  adb shell settings put system show_touches 1 >/dev/null 2>&1 || true

  log "=== tapping play audio: trying every method in sequence until audio starts ==="
  for m in swipe120 tap doubletap swipe300; do
    if captcha_try_tap "$tag" "$m" "$xy"; then started=1; break; fi
  done

  if (( started )); then
    log "CONFIRMED: play audio was successfully tapped and audio started"
  else
    log "WARNING: tried ALL tap methods (swipe120, tap, doubletap, swipe300) at $xy - audio never reached state 'started'."
    log "WARNING: check ${tag}-ui.xml and the ${tag}-tap-*.png screenshots to see exactly what was on screen for each attempt."
  fi

  adb shell settings put system show_touches 0 >/dev/null 2>&1 || true
  screenshot "${tag}-9-final.png"

  if [[ "$CAPTCHA_TAP_ONLY" == "1" ]]; then
    log "CAPTCHA_TAP_ONLY=1: tap-only debug mode, skipping audio/video recording"
    return 0
  fi

  # ---- full recording (only runs when CAPTCHA_TAP_ONLY=0) ----
  local secs="$CAPTCHA_AUDIO_SECONDS" tmp="${RUNNER_TEMP:-/tmp}"
  local wav="$ARTIFACTS/${tag}-audio.wav" mp3="$ARTIFACTS/${tag}-audio.mp3"
  local vraw="$tmp/${tag}-screen.mp4" vout="$ARTIFACTS/${tag}-screen-with-audio.mp4"
  local have_audio=0 apid="" vpid=""
  if [[ "${AUDIO_OK:-0}" == "1" ]] && command -v parecord >/dev/null 2>&1; then
    have_audio=1
    timeout -s TERM "$secs" parecord --device="${AUDIO_SINK:-emu_out}.monitor" --file-format=wav "$wav" 2>/dev/null &
    apid=$!
  fi
  adb shell "rm -f /sdcard/captcha.mp4" >/dev/null 2>&1
  timeout -k 3 $((secs + 15)) adb shell screenrecord --time-limit $((secs + 3)) --bit-rate 3000000 /sdcard/captcha.mp4 >/dev/null 2>&1 &
  vpid=$!
  (( started )) || captcha_try_tap "$tag" tap "$xy" || true   # one more press to (re)trigger playback for the recording window
  sleep "$secs"
  [[ -n "$apid" ]] && wait "$apid" 2>/dev/null
  wait "$vpid" 2>/dev/null
  adb pull /sdcard/captcha.mp4 "$vraw" >/dev/null 2>&1
  adb shell "rm -f /sdcard/captcha.mp4" >/dev/null 2>&1
  if (( have_audio )) && [[ -s "$wav" ]]; then
    log "AUDIO SAVED: ${tag}-audio.wav ($(stat -c%s "$wav") bytes)"
    if command -v ffmpeg >/dev/null 2>&1; then
      ffmpeg -y -loglevel error -i "$wav" -c:a libmp3lame -q:a 2 "$mp3" && log "AUDIO SAVED: ${tag}-audio.mp3"
      [[ -s "$vraw" ]] && ffmpeg -y -loglevel error -i "$vraw" -i "$wav" -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -shortest "$vout" \
        && log "VIDEO SAVED: ${tag}-screen-with-audio.mp4"
    fi
  fi
  if [[ -s "$vraw" && ! -s "$vout" ]]; then cp "$vraw" "$ARTIFACTS/${tag}-screen.mp4"; fi
  rm -f "$vraw"
  return 0
}
