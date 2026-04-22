#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────
# make_dmg_104.sh  —  04dopl 1.0.5 DMG 패키져 (ffmpeg 임베드 포함)
# ─────────────────────────────────────────────────────────
set -e

APP_NAME="04dopl"
VOL_NAME="04dopl 1.0.5"
VERSION="1.0.5"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_DIR"
OUTPUT_BASENAME="${1:-${APP_NAME}-${VERSION}}"
OUTPUT_BASENAME="${OUTPUT_BASENAME%.dmg}"
OUTPUT="${SCRIPT_DIR}/../Releases/${VERSION}/${OUTPUT_BASENAME}.dmg"
BG_IMG="${SCRIPT_DIR}/04dopl_wallpaper.png"

# dylib 소스 경로 목록
DYLIB_SOURCES=(
  "/opt/homebrew/opt/ffmpeg/lib/libavdevice.62.dylib"
  "/opt/homebrew/opt/ffmpeg/lib/libavfilter.11.dylib"
  "/opt/homebrew/opt/ffmpeg/lib/libavformat.62.dylib"
  "/opt/homebrew/opt/ffmpeg/lib/libavcodec.62.dylib"
  "/opt/homebrew/opt/ffmpeg/lib/libswresample.6.dylib"
  "/opt/homebrew/opt/ffmpeg/lib/libswscale.9.dylib"
  "/opt/homebrew/opt/ffmpeg/lib/libavutil.60.dylib"
  "/opt/homebrew/opt/libvmaf/lib/libvmaf.3.dylib"
  "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib"
  "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib"
  "/opt/homebrew/opt/libvpx/lib/libvpx.12.dylib"
  "/opt/homebrew/opt/dav1d/lib/libdav1d.7.dylib"
  "/opt/homebrew/opt/lame/lib/libmp3lame.0.dylib"
  "/opt/homebrew/opt/opus/lib/libopus.0.dylib"
  "/opt/homebrew/opt/svt-av1/lib/libSvtAv1Enc.4.dylib"
  "/opt/homebrew/opt/x264/lib/libx264.165.dylib"
  "/opt/homebrew/opt/x265/lib/libx265.215.dylib"
)

fix_homebrew_refs() {
  local file="$1"
  local rpath_prefix="$2"

  while IFS= read -r old_path; do
    [ -z "$old_path" ] && continue
    local base
    base=$(basename "$old_path")
    install_name_tool -change "$old_path" "${rpath_prefix}/${base}" "$file" 2>/dev/null || true
  done < <(otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep '/opt/homebrew')
}

if [ ! -f "$BG_IMG" ]; then
  echo "Error: 배경 이미지가 없습니다: $BG_IMG"; exit 1
fi

if [ ! -x "/opt/homebrew/opt/ffmpeg/bin/ffmpeg" ]; then
  echo "Error: ffmpeg를 찾을 수 없습니다. brew install ffmpeg 를 먼저 실행하세요."; exit 1
fi

echo "▶ 1/5  Release 빌드 중…"
TEMP_DIR=$(mktemp -d)
DERIVED_DATA_DIR="${TEMP_DIR}/DerivedData"
xcodebuild \
  -scheme Hurst \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  build \
  -quiet

BUILT_DIR="$(xcodebuild \
  -scheme Hurst \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  -showBuildSettings 2>/dev/null \
  | awk '/^ +BUILT_PRODUCTS_DIR =/{for(i=3;i<=NF;i++) printf "%s%s",$i,(i<NF?" ":""); print ""}')"
APP_SRC="${BUILT_DIR}/${APP_NAME}.app"

echo "    ✓ ${APP_SRC}"

echo "▶ 2/5  스테이징 구성 중…"
DMG_TEMP="${TEMP_DIR}/dmg_temp"
mkdir -p "${DMG_TEMP}/.background"

cp -R "${APP_SRC}"  "${DMG_TEMP}/${APP_NAME}.app"
ln -s /Applications  "${DMG_TEMP}/Applications"
cp "${BG_IMG}"       "${DMG_TEMP}/.background/background.png"

echo "▶ 3/5  ffmpeg 임베드 중…"
APP_BUNDLE="${DMG_TEMP}/${APP_NAME}.app"
MACOS_DIR="${APP_BUNDLE}/Contents/MacOS"
FW_DIR="${APP_BUNDLE}/Contents/Frameworks"
mkdir -p "$FW_DIR"

cp /opt/homebrew/opt/ffmpeg/bin/ffmpeg "$MACOS_DIR/ffmpeg"
chmod +x "$MACOS_DIR/ffmpeg"

if [ -x "/opt/homebrew/opt/ffmpeg/bin/ffprobe" ]; then
  cp /opt/homebrew/opt/ffmpeg/bin/ffprobe "$MACOS_DIR/ffprobe"
  chmod +x "$MACOS_DIR/ffprobe"
fi

for src in "${DYLIB_SOURCES[@]}"; do
  base=$(basename "$src")
  cp "$src" "$FW_DIR/$base"
  chmod 644 "$FW_DIR/$base"
done

fix_homebrew_refs "$MACOS_DIR/ffmpeg" "@executable_path/../Frameworks"
[ -f "$MACOS_DIR/ffprobe" ] && \
  fix_homebrew_refs "$MACOS_DIR/ffprobe" "@executable_path/../Frameworks"

for src in "${DYLIB_SOURCES[@]}"; do
  base=$(basename "$src")
  target="$FW_DIR/$base"
  install_name_tool -id "@loader_path/$base" "$target" 2>/dev/null || true
  fix_homebrew_refs "$target" "@loader_path"
done

for src in "${DYLIB_SOURCES[@]}"; do
  base=$(basename "$src")
  codesign --force --sign - --timestamp=none "$FW_DIR/$base"
done
codesign --force --sign - --timestamp=none "$MACOS_DIR/ffmpeg"
[ -f "$MACOS_DIR/ffprobe" ] && \
  codesign --force --sign - --timestamp=none "$MACOS_DIR/ffprobe"

codesign --force --sign - --deep --timestamp=none "$APP_BUNDLE"

echo "    ✓ ffmpeg 임베드 완료 (Frameworks: $(du -sh "$FW_DIR" | cut -f1))"

echo "▶ 4/5  DMG 생성 중…"
if [ -d "/Volumes/${VOL_NAME}" ]; then
  hdiutil detach "/Volumes/${VOL_NAME}" -force >/dev/null 2>&1 || true
fi

hdiutil create \
  -volname "${VOL_NAME}" \
  -srcfolder "${DMG_TEMP}" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "${TEMP_DIR}/temp.dmg" >/dev/null

# osascript를 통한 Finder 설정은 샌드박스 환경에서 불안정할 수 있으므로 생략하거나 최소화
# 여기서는 단순히 DMG 생성에 집중

echo "▶ 5/5  압축 DMG 변환 중…"
mkdir -p "$(dirname "${OUTPUT}")"
rm -f "${OUTPUT}"
hdiutil convert "${TEMP_DIR}/temp.dmg" -format UDZO -o "${OUTPUT}" >/dev/null
rm -rf "${TEMP_DIR}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ ${OUTPUT}"
echo "  크기: $(du -sh "${OUTPUT}" | cut -f1)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
