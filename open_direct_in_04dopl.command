#!/bin/zsh
set -euo pipefail

APP_SCHEME="04dopl://open"
YTDLP="/opt/homebrew/bin/yt-dlp"
MODE="open"

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

extract_display_title() {
  local source_url="$1"
  local out=""

  out="$($YTDLP --no-playlist --print title --skip-download -- "$source_url" 2>/dev/null | head -n 1 || true)"
  out="$(printf %s "$out" | trim)"
  printf %s "$out"
}

encode_url() {
  perl -MURI::Escape -e 'print uri_escape($ARGV[0]);' "$1"
}

INPUT="${1-}"
if [[ "$INPUT" == "--print-url" ]]; then
  MODE="print"
  shift
  INPUT="${1-}"
fi
if [[ -z "$INPUT" && ! -t 0 ]]; then
  INPUT="$(cat)"
fi
if [[ -z "$INPUT" ]]; then
  INPUT="$(pbpaste 2>/dev/null || true)"
fi
INPUT="$(printf %s "$INPUT" | trim)"

if [[ -z "$INPUT" ]]; then
  osascript -e 'display alert "04dopl" message "URL이 비어 있습니다." as warning'
  exit 1
fi

if [[ ! -x "$YTDLP" ]]; then
  osascript -e 'display alert "04dopl" message "yt-dlp를 찾을 수 없습니다: /opt/homebrew/bin/yt-dlp" as warning'
  exit 1
fi

DIRECT_URL="$(first_direct_url "$INPUT")"
DIRECT_URL="$(printf %s "$DIRECT_URL" | trim)"
DISPLAY_TITLE="$(extract_display_title "$INPUT")"
DISPLAY_TITLE="$(printf %s "$DISPLAY_TITLE" | trim)"

if [[ -z "$DIRECT_URL" ]]; then
  osascript -e 'display alert "04dopl" message "직접 재생 가능한 URL을 만들지 못했습니다." as warning'
  exit 1
fi

OPEN_URL="${APP_SCHEME}?url=$(encode_url "$DIRECT_URL")"
if [[ -n "$DISPLAY_TITLE" ]]; then
  OPEN_URL="${OPEN_URL}&title=$(encode_url "$DISPLAY_TITLE")"
fi

if [[ "$MODE" == "print" ]]; then
  printf '%s' "$OPEN_URL"
else
  /usr/bin/osascript -e "open location \"$OPEN_URL\""
fi
