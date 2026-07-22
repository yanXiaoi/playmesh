#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
SOURCE_DIR="$REPO_ROOT/dev-cli"
OUTPUT=${1:?"usage: build_dev_cli_macos.sh <output>"}
TEMP_ROOT=${TARGET_TEMP_DIR:-"${TMPDIR:-/tmp}/playmesh-cli-build"}
ARCH_LIST=${ARCHS:-$(uname -m)}

mkdir -p "$(dirname "$OUTPUT")" "$TEMP_ROOT"

build_arch() {
  xcode_arch=$1
  case "$xcode_arch" in
    arm64) go_arch=arm64 ;;
    x86_64) go_arch=amd64 ;;
    *) echo "Unsupported macOS architecture: $xcode_arch" >&2; exit 1 ;;
  esac
  artifact="$TEMP_ROOT/playmesh-cli-$xcode_arch"
  (
    cd "$SOURCE_DIR"
    CGO_ENABLED=0 GOOS=darwin GOARCH="$go_arch" \
      go build -buildvcs=false -trimpath -ldflags="-s -w" -o "$artifact" .
  )
}

artifacts=""
for arch in $ARCH_LIST; do
  build_arch "$arch"
  artifacts="$artifacts $TEMP_ROOT/playmesh-cli-$arch"
done

set -- $artifacts
if [ "$#" -eq 1 ]; then
  cp "$1" "$OUTPUT"
else
  xcrun lipo -create "$@" -output "$OUTPUT"
fi
chmod 755 "$OUTPUT"

