#!/bin/zsh
set -euo pipefail

APP_SCHEME="04dopl://open?url="
YTDLP="/opt/homebrew/bin/yt-dlp"

trim() {
  perl -0pe 's/^\s+|\s+$//g'
}

first_direct_url() {
  local source_url="$1"
  local out=""

  out="$($YTDLP --no-playlist -f "b/best" -g -- "$source_url" 2>/dev/null | head -n 1 || true)"
  if [[ -z "$out" ]]; then
    out="$($YTDLP --no-playlist -g -- "$source_url" 2>/dev/null | head -n 1 || true)"
  fi

  printf %s "$out"
}

encode_url() {
  perl -MURI::Escape -e 'print uri_escape($ARGV[0]);' "$1"
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
  osascript -e 'display alert "04dopl" message "URL이 비어 있습니다." as warning'
  exit 1
fi

if [[ ! -x "$YTDLP" ]]; then
  osascript -e 'display alert "04dopl" message "yt-dlp를 찾을 수 없습니다: /opt/homebrew/bin/yt-dlp" as warning'
  exit 1
fi

DIRECT_URL="$(first_direct_url "$INPUT")"
DIRECT_URL="$(printf %s "$DIRECT_URL" | trim)"

if [[ -z "$DIRECT_URL" ]]; then
  osascript -e 'display alert "04dopl" message "직접 재생 가능한 URL을 만들지 못했습니다." as warning'
  exit 1
fi

open "${APP_SCHEME}$(encode_url "$DIRECT_URL")"
