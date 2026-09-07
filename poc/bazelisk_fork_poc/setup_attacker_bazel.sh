#!/usr/bin/env bash
set -euo pipefail

OWNER="${OWNER:-SwayZGl1tZyyy}"
REPO="${OWNER}/bazel"
TAG="0.0.1"
ASSET_NAME="bazel-0.0.1-linux-x86_64"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSET="${SCRIPT_DIR}/${ASSET_NAME}"

command -v gh >/dev/null || { echo "gh CLI is required" >&2; exit 1; }
gh auth status >/dev/null

if ! gh repo view "${REPO}" >/dev/null 2>&1; then
  echo "[+] Creating ${REPO}"
  gh repo create "${REPO}" --public --description "Harmless Bazelisk fork-resolution PoC" --add-readme
else
  echo "[+] ${REPO} already exists"
fi

if gh release view "${TAG}" --repo "${REPO}" >/dev/null 2>&1; then
  echo "[+] Updating release asset on ${TAG}"
  gh release upload "${TAG}" "${ASSET}" --repo "${REPO}" --clobber
else
  echo "[+] Creating release ${TAG}"
  gh release create "${TAG}" "${ASSET}" --repo "${REPO}" --title "PoC ${TAG}" --notes "Harmless marker release for Bazelisk fork-resolution testing."
fi

echo "[+] Ready: https://github.com/${REPO}/releases/tag/${TAG}"
