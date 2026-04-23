#!/bin/zsh
set -euo pipefail

YTDLP="/opt/homebrew/bin/yt-dlp"

trim() {
  perl -0pe 's/^\s+|\s+$//g'
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

TITLE="$($YTDLP --no-playlist --print title --skip-download -- "$INPUT" 2>/dev/null | head -n 1 || true)"
TITLE="$(printf %s "$TITLE" | trim)"

if [[ -z "$TITLE" ]]; then
  echo "Failed to resolve a display title" >&2
  exit 1
fi

printf '%s' "$TITLE"
