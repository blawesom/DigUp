#!/bin/bash
# Fetches pdfium (BSD, Chrome's PDF engine) as a prebuilt library into Vendor/pdfium (out of git), pinned to a
# release of bblanchon/pdfium-binaries. Does nothing when that build is already there; the C glue in
# Sources/CLinuxMedia links it from there (Package.swift adds the include and library paths).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=chromium/8086
OUT=Vendor/pdfium
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ASSET=x64 ;;
  aarch64) ASSET=arm64 ;;
  *) echo "pdfium has no prebuilt for $ARCH" >&2; exit 1 ;;
esac
STAMP="$VERSION $ARCH"

if [[ -f "$OUT/lib/libpdfium.so" && "$(cat "$OUT/BUILD" 2>/dev/null)" == "$STAMP" ]]; then
  exit 0
fi

rm -rf "$OUT"
mkdir -p "$OUT"
URL="https://github.com/bblanchon/pdfium-binaries/releases/download/${VERSION//\//%2F}/pdfium-linux-$ASSET.tgz"
echo "fetching pdfium $VERSION ($ARCH)…"
curl -sL "$URL" | tar xz -C "$OUT"
[[ -f "$OUT/lib/libpdfium.so" ]] || { echo "the archive had no libpdfium.so" >&2; exit 1; }
echo "$STAMP" > "$OUT/BUILD"
echo "fetched pdfium $VERSION into $OUT"
