#!/usr/bin/env bash
# lib-mega.sh - rclone + Mega download of the login backup (sourced, not run directly)

rclone_has_mega() { rclone help backends 2>/dev/null | grep -qiE '(^|[[:space:]])mega([[:space:]]|$)'; }

# The distro rclone has no mega backend, so download the official build (with retries + fallback).
install_official_rclone() {
  local tmp url attempt bin ok=1 pinned="v1.68.2"
  tmp="$(mktemp -d)"
  for url in \
    "https://downloads.rclone.org/rclone-current-linux-amd64.zip" \
    "https://downloads.rclone.org/${pinned}/rclone-${pinned}-linux-amd64.zip" \
    "https://github.com/rclone/rclone/releases/download/${pinned}/rclone-${pinned}-linux-amd64.zip"; do
    for attempt in 1 2 3; do
      rm -rf "$tmp"/*
      if curl -fSL --retry 3 --connect-timeout 20 --max-time 180 -o "$tmp/rclone.zip" "$url" 2>"$tmp/curl.err" \
         && unzip -q -o "$tmp/rclone.zip" -d "$tmp" 2>"$tmp/unzip.err"; then
        bin="$(find "$tmp" -type f -name rclone | head -1)"
        if [[ -n "$bin" ]] && sudo install -m 0755 "$bin" /usr/local/bin/rclone; then ok=0; break 2; fi
      fi
      log "rclone download failed ($url, attempt $attempt): $(cat "$tmp/curl.err" "$tmp/unzip.err" 2>/dev/null | tr '\n' ' ' | head -c 300)"
      sleep 4
    done
  done
  rm -rf "$tmp"
  export PATH="/usr/local/bin:$PATH"; hash -r
  return $ok
}

setup_rclone() {
  export PATH="/usr/local/bin:$PATH"
  if ! command -v rclone >/dev/null 2>&1 || ! rclone_has_mega; then
    log "installing official rclone"
    install_official_rclone || log "WARNING: could not download official rclone"
  fi
  rclone_has_mega || { log "rclone has no mega backend"; return 1; }
  if [[ ! -s "$RCLONE_CFG" ]]; then
    [[ -n "$RCLONE_CONF_CONTENT" ]] || { log "RCLONE_CONF secret is empty"; return 1; }
    mkdir -p "$(dirname "$RCLONE_CFG")"
    printf '%s\n' "$RCLONE_CONF_CONTENT" > "$RCLONE_CFG"; chmod 600 "$RCLONE_CFG"
  fi
  rclone listremotes 2>/dev/null | grep -qx "${MEGA_REMOTE}:" || { log "remote '${MEGA_REMOTE}' not in rclone config"; return 1; }
}

# Downloads the encrypted Facebook login backup to $BACKUP_FILE
mega_download_backup() {
  setup_rclone || return 1
  local src="${MEGA_REMOTE}:${MEGA_FOLDER}/${MEGA_FILE}"
  [[ -n "$(rclone lsf "$src" 2>/dev/null)" ]] || { log "$src not found. Create the login backup first."; return 1; }
  rclone copyto "$src" "$BACKUP_FILE" --retries 5 -q || return 1
  [[ -s "$BACKUP_FILE" ]] || { log "downloaded backup is empty"; return 1; }
  log "MEGA DOWNLOAD OK ($(stat -c%s "$BACKUP_FILE") bytes)"
}
