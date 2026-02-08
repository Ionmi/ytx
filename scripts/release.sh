#!/usr/bin/env bash
set -euo pipefail

# release.sh — Build, package, and upload a pre-built ytx binary to GitHub Releases.
#
# Usage:
#   ./scripts/release.sh          # reads version from Sources/Transcribe.swift
#   ./scripts/release.sh 0.5.0    # uses the provided version

REPO="ionmi/ytx"
BINARY_NAME="ytx"
ARCH="arm64"
PLATFORM="macos"

# ── Resolve version ──────────────────────────────────────────────────
if [[ $# -ge 1 ]]; then
    VERSION="$1"
else
    VERSION=$(grep -m1 'version:' Sources/Transcribe.swift | sed 's/.*"\(.*\)".*/\1/')
    if [[ -z "$VERSION" ]]; then
        echo "Error: could not read version from Sources/Transcribe.swift" >&2
        exit 1
    fi
fi

TAG="v${VERSION}"
TARBALL="${BINARY_NAME}-${VERSION}-${ARCH}-${PLATFORM}.tar.gz"

echo "==> Version: ${VERSION}  Tag: ${TAG}"

# ── Check dependencies ───────────────────────────────────────────────
for cmd in gh swift shasum tar; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' not found in PATH" >&2
        exit 1
    fi
done

# ── Build release binary ────────────────────────────────────────────
echo "==> Building release binary…"
swift build -c release

BINARY=".build/release/${BINARY_NAME}"
if [[ ! -f "$BINARY" ]]; then
    echo "Error: binary not found at ${BINARY}" >&2
    exit 1
fi

# ── Package ──────────────────────────────────────────────────────────
echo "==> Packaging ${TARBALL}…"
tar -czf "${TARBALL}" -C .build/release "${BINARY_NAME}"

SHA256=$(shasum -a 256 "${TARBALL}" | awk '{print $1}')
echo "==> SHA256: ${SHA256}"

# ── Create GitHub Release (if needed) and upload asset ───────────────
if gh release view "${TAG}" --repo "${REPO}" &>/dev/null; then
    echo "==> Release ${TAG} exists, uploading asset…"
    gh release upload "${TAG}" "${TARBALL}" --repo "${REPO}" --clobber
else
    echo "==> Creating release ${TAG} and uploading asset…"
    gh release create "${TAG}" "${TARBALL}" \
        --repo "${REPO}" \
        --title "${TAG}" \
        --notes "Release ${VERSION}" \
        --latest
fi

# ── Clean up local tarball ───────────────────────────────────────────
rm -f "${TARBALL}"

# ── Print summary ────────────────────────────────────────────────────
ASSET_URL="https://github.com/${REPO}/releases/download/${TAG}/${TARBALL}"

echo ""
echo "===== Done ====="
echo "Asset URL:"
echo "  ${ASSET_URL}"
echo ""
echo "SHA256:"
echo "  ${SHA256}"
echo ""
echo "Homebrew formula snippet:"
echo "  url \"${ASSET_URL}\""
echo "  sha256 \"${SHA256}\""
