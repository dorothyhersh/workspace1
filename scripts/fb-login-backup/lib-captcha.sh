#!/usr/bin/env bash
# lib-captcha.sh - text-captcha handling (sourced, not run directly)
# When Facebook shows "Enter the characters you see": screenshot it, tap "play audio", and RECORD
#   1) the audio only      -> artifacts/<acc>-captchaN-audio.wav  and  .mp3
#   2) the screen + audio  -> artifacts/<acc>-captchaN-screen-with-audio.mp4
# plus screenshots (touch dots visible), an audio-state log, and a UI dump.
# Audio comes from the emulator's virtual sound card (PulseAudio null sink set up by run-with-emulator.sh).
# Needs from the caller: log, screenshot, ui_dump, ui_query, ui_texts (lib-ui.sh), $UI_XML, $ARTIFACTS.

CAPTURE_CAPTCHA_AUDIO="${CAPTURE_CAPTCHA_AUDIO:-0}"      # 0 (default) = only screenshot, no audio/video
CAPTCHA_AUDIO_SECONDS="${CAPTCHA_AUDIO_SECONDS:-20}"     # how long to record after tapping play
CAPTCHA_AUDIO_TAP="${CAPTCHA_AUDIO_TAP:-727 837}"        # fallback "x y" (inside the play button on both known layouts)
CAPTCHA_PLAY_REGEX="${CAPTCHA_PLAY_REGEX:-}"             # optional: your own regex for the play button text
CAPTCHA_TAP_TRIES="${CAPTCHA_TAP_TRIES:-3}"              # how many times to press play if no audio starts
CAPTCHA_REGEX="${CAPTCHA_REGEX:-Enter the characters you see|characters you see|real human behind this login|type the (characters|text|code) (you see|shown|below)|enter the (text|code) (you see|shown)}"
CAPTCHA_N=0

# prints "x y" of the play-audio button. Only the EXACT button text is searched: the PARENT node
# "Can't read this? Generate new or play audio" would give the centre of "Generate new".
captcha_find_play() {
  local xy="" r
  for r in "$CAPTCHA_PLAY_REGEX" '^play audio$' '^Play audio$'; do
    [[ -n "$r" ]] || continue
    xy="$(ui_query text "$r" 0 || true)"
    [[ -n "$xy" ]] && { printf '%s' "$xy"; return 0; }
  done
  return 1
}

# press at "x y". mode "swipe" = a 120ms press (links inside text often ignore the instant `input tap`)
captcha_press() {
  local mode="$1" x y; read -r x y <<<"$2"
  if [[ "$mode" == "swipe" ]]; then adb shell input swipe "$x" "$y" "$x" "$y" 120
  else adb shell input tap "$x" "$y"; fi
}

# is any app audio player in state "started"? (the captcha audio is playing)
captcha_audio_started() {
  adb shell dumpsys audio 2>/dev/null | tr -d '\r' | grep -qiE 'state:started'
}

capture_captcha_audio() {
  CAPTCHA_N=$((CAPTCHA_N + 1))
  local tag="${SHOT_PREFIX:-}captcha${CAPTCHA_N}" secs="$CAPTCHA_AUDIO_SECONDS" tmp="${RUNNER_TEMP:-/tmp}"
  local wav="$ARTIFACTS/${tag}-audio.wav" mp3="$ARTIFACTS/${tag}-audio.mp3"
  local vraw="$tmp/${tag}-screen.mp4" vout="$ARTIFACTS/${tag}-screen-with-audio.mp4"
  local astate="$ARTIFACTS/${tag}-audio-state.txt"
  local xy="" i have_audio=0 apid="" vpid="" try mode started=0 t_start

  log "CAPTCHA detected ($tag): saving screenshot + UI dump"
  screenshot "${tag}-1-screen.png"
  if ui_dump; then
    cp "$UI_XML" "$ARTIFACTS/${tag}-ui.xml" 2>/dev/null || true
    log "captcha screen texts: $(ui_texts | cut -d' ' -f3- | head -30 | tr '\n' '|' | cut -c1-500)"
  fi
  [[ "$CAPTURE_CAPTCHA_AUDIO" == "1" ]] || { log "captcha audio capture is switched off (CAPTURE_CAPTCHA_AUDIO=0)"; return 0; }

  # find the play-audio button (UI dump of the screen we just saved)
  for i in 1 2 3; do
    xy="$(captcha_find_play || true)"; [[ -n "$xy" ]] && break
    sleep 2; ui_dump || true
  done
  if [[ -n "$xy" ]]; then log "play audio button found in the UI at: $xy"
  elif [[ -n "$CAPTCHA_AUDIO_TAP" ]]; then log "play-audio button not found in the UI, using CAPTCHA_AUDIO_TAP=$CAPTCHA_AUDIO_TAP"; xy="$CAPTCHA_AUDIO_TAP"
  else
    log "WARNING: no play-audio button found on the captcha screen - see ${tag}-ui.xml / ${tag}-1-screen.png, then set CAPTCHA_PLAY_REGEX or CAPTCHA_AUDIO_TAP"
    return 1
  fi

  # media volume to max + show a dot where the screen is touched (visible in the screenshots and the video)
  adb shell cmd media_session volume --stream 3 --set 15 >/dev/null 2>&1 \
    || adb shell media volume --show --stream 3 --set 15 >/dev/null 2>&1 || true
  adb shell settings put system show_touches 1 >/dev/null 2>&1 || true

  # ---- start the recorders BEFORE tapping play ----
  if [[ "${AUDIO_OK:-0}" == "1" ]] && command -v parecord >/dev/null 2>&1; then
    have_audio=1
    timeout -s TERM "$secs" parecord --device="${AUDIO_SINK:-emu_out}.monitor" --file-format=wav "$wav" 2>/dev/null &
    apid=$!
  else
    log "WARNING: no virtual sound card (AUDIO_OK=${AUDIO_OK:-0}) - only the screen will be recorded, no audio"
  fi
  adb shell "rm -f /sdcard/captcha.mp4" >/dev/null 2>&1
  timeout -k 3 $((secs + 15)) adb shell screenrecord --time-limit $((secs + 3)) --bit-rate 3000000 /sdcard/captcha.mp4 >/dev/null 2>&1 &
  vpid=$!
  sleep 2
  t_start=$SECONDS
  : > "$astate"

  # ---- press play (up to CAPTCHA_TAP_TRIES times: long press first, then plain tap, ...) until audio starts ----
  for ((try=1; try<=CAPTCHA_TAP_TRIES; try++)); do
    if (( try % 2 == 1 )); then mode=swipe; else mode=tap; fi
    log "press play audio at $xy (try $try/$CAPTCHA_TAP_TRIES, mode=$mode), recording ${secs}s"
    captcha_press "$mode" "$xy"
    sleep 1
    screenshot "${tag}-2-after-press${try}.png"       # touch dot visible = the press really reached the screen
    sleep 3
    { echo "=== try $try ($mode) +$((SECONDS - t_start))s ==="; adb shell dumpsys audio 2>/dev/null | tr -d '\r' | grep -iE 'state:|piid|usage' | head -20; } >> "$astate"
    if captcha_audio_started; then started=1; log "AUDIO IS PLAYING (a player is in state started) after try $try"; break; fi
    log "no audio player started after try $try"
  done
  (( started )) || log "WARNING: no audio player ever reached state 'started' - the press may not have hit the button, or Facebook plays audio some other way; check ${tag}-audio-state.txt and the ${tag}-2-after-press*.png screenshots"

  screenshot "${tag}-3-playing.png"
  local left=$(( secs / 2 - (SECONDS - t_start) )); (( left > 0 )) && sleep "$left"
  screenshot "${tag}-4-playing-mid.png"
  [[ -n "$apid" ]] && wait "$apid" 2>/dev/null     # parecord stops by itself after $secs
  wait "$vpid" 2>/dev/null
  sleep 1
  adb shell settings put system show_touches 0 >/dev/null 2>&1 || true

  # ---- collect + convert ----
  adb pull /sdcard/captcha.mp4 "$vraw" >/dev/null 2>&1
  adb shell "rm -f /sdcard/captcha.mp4" >/dev/null 2>&1
  if (( have_audio )) && [[ -s "$wav" ]]; then
    log "AUDIO SAVED: ${tag}-audio.wav ($(stat -c%s "$wav") bytes)"
    if command -v ffmpeg >/dev/null 2>&1; then
      ffmpeg -y -loglevel error -i "$wav" -c:a libmp3lame -q:a 2 "$mp3" && log "AUDIO SAVED: ${tag}-audio.mp3"
      log "audio level: $(ffmpeg -hide_banner -i "$wav" -af volumedetect -f null - 2>&1 | grep -E 'mean_volume|max_volume' | sed 's/.*\] //' | tr '\n' ' ')"
      if [[ -s "$vraw" ]]; then
        ffmpeg -y -loglevel error -i "$vraw" -i "$wav" -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -shortest "$vout" \
          && log "VIDEO SAVED: ${tag}-screen-with-audio.mp4"
      fi
    fi
  elif (( have_audio )); then
    log "WARNING: audio recording is empty (${tag}) - check pulseaudio.log and emulator.log"
  fi
  if [[ -s "$vraw" && ! -s "$vout" ]]; then cp "$vraw" "$ARTIFACTS/${tag}-screen.mp4"; log "VIDEO SAVED (no audio): ${tag}-screen.mp4"; fi
  [[ -s "$vraw" ]] || log "WARNING: screen recording failed (screenrecord produced no file)"
  rm -f "$vraw"
  screenshot "${tag}-5-after.png"
  return 0
}
