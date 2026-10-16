#!/usr/bin/env bash
# Install the pinned go-containerregistry crane binary after verifying its upstream SHA-256.
set -euo pipefail

VERSION=0.22.1
BASE_URL="https://github.com/google/go-containerregistry/releases/download/v$VERSION"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/.tools/bin"

os="$(uname -s)"
arch="$(uname -m)"
case "$os/$arch" in
  Linux/x86_64)
      asset="go-containerregistry_${VERSION}_Linux_x86_64.tar.gz"
    checksum=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0
    ;;
  Linux/aarch64 | Linux/arm64)
      asset="go-containerregistry_${VERSION}_Linux_arm64.tar.gz"
    checksum=898c0cff975f898a33e8c4580bdafb0e7c02c7faa33374e946762f97c4ab7110
    ;;
  Darwin/arm64)
      asset="go-containerregistry_${VERSION}_Darwin_arm64.tar.gz"
    checksum=2231fc8df8806d20d680ff1225db44e095a55dd6ac1ae8eced4faf4b278b78fb
    ;;
  *)
    echo "unsupported platform for pinned crane $VERSION: $os/$arch" >&2
    exit 1
    ;;
esac

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
if command -v sha256sum >/dev/null; then
  hash() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null; then
  hash() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  echo "sha256sum or shasum is required" >&2
  exit 1
fi

curl --fail --location --silent --show-error "$BASE_URL/$asset" -o "$tmp/$asset"
actual="$(hash "$tmp/$asset")"
[[ "$actual" == "$checksum" ]] || {
  echo "crane archive SHA-256 mismatch: expected $checksum, got $actual" >&2
  exit 1
}
tar -xzf "$tmp/$asset" -C "$tmp" crane
mkdir -p "$BIN_DIR"
install -m 0755 "$tmp/crane" "$BIN_DIR/crane"
"$BIN_DIR/crane" version | grep -F "$VERSION" >/dev/null || {
  echo "installed crane did not report version $VERSION" >&2
  exit 1
}
printf 'crane %s installed at %s\n' "$VERSION" "$BIN_DIR/crane"
