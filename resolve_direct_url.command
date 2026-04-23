#!/bin/zsh
set -euo pipefail

YTDLP="/opt/homebrew/bin/yt-dlp"
APP_DEFAULTS_DOMAIN="com.hurst.app"
PENDING_TITLE_KEY="04dopl.pendingExternalMediaOpen.title"
PENDING_TITLE_FILE="/tmp/04dopl.pendingExternalMediaOpen.title"

trim() {
  perl -0pe 's/^\s+|\s+$//g'
}

is_manifest_url() {
  local url="${1:l}"
  [[ "$url" == *".m3u8"* || "$url" == *"/manifest/"* || "$url" == *"manifest.googlevideo.com"* ]]
}

first_direct_url() {
  local source_url="$1"
  local out=""
  local fallback=""
  local selectors=(
    "best[ext=mp4][vcodec!=none][acodec!=none][protocol=https]"
    "best[ext=mp4][vcodec!=none][acodec!=none][protocol=http]"
    "18"
    "best[ext=mp4][vcodec!=none][acodec!=none]"
    "b/best"
    "best"
  )

  for selector in "${selectors[@]}"; do
    out="$($YTDLP --no-playlist -f "$selector" -g -- "$source_url" 2>/dev/null | head -n 1 || true)"
    out="$(printf %s "$out" | trim)"
    [[ -z "$out" ]] && continue

    if ! is_manifest_url "$out"; then
      printf %s "$out"
      return
    fi

    [[ -z "$fallback" ]] && fallback="$out"
  done

  printf %s "$fallback"
}

resolve_title() {
  local source_url="$1"
  local out=""
  out="$($YTDLP --no-playlist --print title --skip-download -- "$source_url" 2>/dev/null | head -n 1 || true)"
  printf %s "$out" | trim
}

INPUT="${1-}"
if [[ -z "$INPUT" && ! -t 0 ]]; then
  INPUT="$(cat)"
fi
if [[ -z "$INPUT" ]]; then
  INPUT="$(pbpaste 2>/dev/null || true)"
fi
INPUT="$(printf %s "$INPUT" | trim)"

if [[ -z "$INPUT" ]]; then
  echo "URL is empty" >&2
  exit 1
fi

if [[ ! -x "$YTDLP" ]]; then
  echo "yt-dlp not found: /opt/homebrew/bin/yt-dlp" >&2
  exit 1
fi

TITLE="$(resolve_title "$INPUT")"
TITLE="$(printf %s "$TITLE" | trim)"
if [[ -n "$TITLE" ]]; then
  /usr/bin/defaults write "$APP_DEFAULTS_DOMAIN" "$PENDING_TITLE_KEY" "$TITLE" >/dev/null 2>&1 || true
  printf '%s' "$TITLE" > "$PENDING_TITLE_FILE" 2>/dev/null || true
else
  /usr/bin/defaults delete "$APP_DEFAULTS_DOMAIN" "$PENDING_TITLE_KEY" >/dev/null 2>&1 || true
  rm -f "$PENDING_TITLE_FILE" 2>/dev/null || true
fi

DIRECT_URL="$(first_direct_url "$INPUT")"
DIRECT_URL="$(printf %s "$DIRECT_URL" | trim)"

if [[ -z "$DIRECT_URL" ]]; then
  echo "Failed to resolve a directly playable URL" >&2
  exit 1
fi

printf '%s' "$DIRECT_URL"
