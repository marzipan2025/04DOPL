#!/bin/zsh
set -euo pipefail

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

DIRECT_URL="$(first_direct_url "$INPUT")"
DIRECT_URL="$(printf %s "$DIRECT_URL" | trim)"

if [[ -z "$DIRECT_URL" ]]; then
  echo "Failed to resolve a directly playable URL" >&2
  exit 1
fi

printf '%s' "$DIRECT_URL"
