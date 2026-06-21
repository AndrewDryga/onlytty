#!/bin/sh
# OnlyTTY installer. Downloads a prebuilt `onlytty` runner binary from the GitHub
# release, verifies its SHA-256, and installs it. Nothing else — no telemetry, no
# config files, no sudo. You are piping this to a shell, so it says what it does.
#
#   curl -fsSL https://onlytty.com/install.sh | sh
#   curl -fsSL https://onlytty.com/install.sh | sh -s -- --version 0.1.0
#
# Manual / audited path (don't trust a pipe): download the matching
# onlytty-<version>-<os>-<arch>.tar.gz and SHA256SUMS from the Releases page,
# verify with `shasum -a 256 -c SHA256SUMS`, then extract and move `onlytty` onto
# your PATH yourself.
set -eu

REPO="AndrewDryga/onlytty"
BIN="onlytty"
PREFIX="${PREFIX:-$HOME/.local/bin}"
VERSION=""

say() { printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
OnlyTTY installer

Usage: install.sh [--version X.Y.Z] [--prefix DIR]

  --version   install a specific release (default: the latest)
  --prefix    install directory (default: \$PREFIX or ~/.local/bin)
  -h, --help  show this help

It downloads onlytty-<version>-<os>-<arch>.tar.gz from
https://github.com/$REPO/releases, verifies its SHA-256 against the release's
SHA256SUMS, and installs the binary to the prefix. It never uses sudo; if the
prefix is not writable it tells you and stops.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || err "--version needs a value"; VERSION="$2"; shift 2;;
    --version=*) VERSION="${1#*=}"; shift;;
    --prefix) [ $# -ge 2 ] || err "--prefix needs a value"; PREFIX="$2"; shift 2;;
    --prefix=*) PREFIX="${1#*=}"; shift;;
    -h|--help) usage; exit 0;;
    *) err "unknown option: $1 (see --help)";;
  esac
done

command -v curl >/dev/null 2>&1 || err "curl is required but not found"
command -v tar >/dev/null 2>&1 || err "tar is required but not found"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    err "need sha256sum or shasum to verify the download"
  fi
}

# Detect platform and map it to the release asset naming.
os=$(uname -s)
arch=$(uname -m)
case "$os" in
  Linux) os="linux";;
  Darwin) os="darwin";;
  *) err "unsupported OS: $os (prebuilt binaries are linux and darwin only)";;
esac
case "$arch" in
  x86_64|amd64) arch="amd64";;
  aarch64|arm64) arch="arm64";;
  *) err "unsupported architecture: $arch (only amd64 and arm64)";;
esac

# Resolve the latest version from the releases/latest redirect (no API token, no jq).
VERSION="${VERSION#v}"
if [ -z "$VERSION" ]; then
  effective=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
    "https://github.com/$REPO/releases/latest") || err "could not reach GitHub releases"
  VERSION="${effective##*/tag/v}"
  case "$VERSION" in
    "" | */*) err "could not resolve the latest release (no published release yet?)";;
  esac
fi

asset="$BIN-$VERSION-$os-$arch.tar.gz"
base="https://github.com/$REPO/releases/download/v$VERSION"

say "OnlyTTY installer"
say "  download $asset + SHA256SUMS from github.com/$REPO"
say "  verify its SHA-256, then install to $PREFIX/$BIN"
say ""

tmp=$(mktemp -d) || err "could not create a temp dir"
trap 'rm -rf "$tmp"' EXIT INT TERM

say "Downloading $asset …"
curl -fsSL "$base/$asset" -o "$tmp/$asset" || err "download failed: $base/$asset"
curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS" || err "download failed: $base/SHA256SUMS"

expected=$(awk -v f="$asset" '$2 == f {print $1}' "$tmp/SHA256SUMS")
[ -n "$expected" ] || err "no checksum for $asset in SHA256SUMS"
actual=$(sha256 "$tmp/$asset")
if [ "$expected" != "$actual" ]; then
  err "checksum mismatch for $asset — refusing to install
  expected $expected
  actual   $actual"
fi
say "Checksum OK ($expected)."

tar -xzf "$tmp/$asset" -C "$tmp" || err "could not extract $asset"
[ -f "$tmp/$BIN" ] || err "archive did not contain a '$BIN' binary"

mkdir -p "$PREFIX" || err "could not create $PREFIX"
mv "$tmp/$BIN" "$PREFIX/$BIN" 2>/dev/null ||
  err "could not write to $PREFIX (set PREFIX=... to a writable dir, or use sudo yourself)"
chmod 0755 "$PREFIX/$BIN"

say "Installed $BIN $VERSION → $PREFIX/$BIN"
case ":$PATH:" in
  *":$PREFIX:"*) say "Run: $BIN -- claude" ;;
  *) say "Note: $PREFIX is not on your PATH. Add it, e.g.:"
     say "  export PATH=\"$PREFIX:\$PATH\"" ;;
esac
