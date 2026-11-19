#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MOD_CACHE="/tmp/swift-mod-cache-26"
mkdir -p "$MOD_CACHE"

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  ARCH="arm64"
fi
TARGET_TRIPLE="${ARCH}-apple-macosx14.0"

SDK_PATH=""
if [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]] && [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" ]]; then
  SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
else
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
fi

SDK_FLAGS=()
if [[ -n "$SDK_PATH" ]]; then
  SDK_FLAGS=(-sdk "$SDK_PATH")
fi

echo "[1/3] 运行 Swift 核心单元测试..."
TEST_BIN="/tmp/agy_swift_core_tests"
swiftc \
  -swift-version 5 \
  -parse-as-library \
  "${SDK_FLAGS[@]}" \
  -module-cache-path "$MOD_CACHE" \
  -target "$TARGET_TRIPLE" \
  -lsqlite3 \
  "${REPO_ROOT}/macos/Sources/Models.swift" \
  "${REPO_ROOT}/macos/Sources/ProtoModelScanner.swift" \
  "${REPO_ROOT}/macos/Sources/TelemetryService.swift" \
  "${REPO_ROOT}/tests/SwiftCoreTests.swift" \
  -o "$TEST_BIN"
"$TEST_BIN"
rm -f "$TEST_BIN"

echo "[2/3] 运行 Python CLI 状态栏单元测试..."
/usr/bin/python3 -m unittest -v "${REPO_ROOT}/tests/test_cli_statusline.py"

echo "[3/3] 验证 CLI 安装与还原脚本 (临时目录)..."
TMP_CLI_HOME="$(mktemp -d /tmp/agy_cli_install_test.XXXXXX)"
trap 'rm -rf "$TMP_CLI_HOME"' EXIT
INSTALL_OUT="$(ANTIGRAVITY_CLI_HOME="$TMP_CLI_HOME" bash "${REPO_ROOT}/scripts/install-cli.sh" --python)"
printf '%s\n' "$INSTALL_OUT"
printf '%s\n' "$INSTALL_OUT" | grep -q "/ 1M 0%"
test -f "${TMP_CLI_HOME}/agy-statusline.py"
test -f "${TMP_CLI_HOME}/settings.json"
grep -q "agy-statusline.py" "${TMP_CLI_HOME}/settings.json"
ANTIGRAVITY_CLI_HOME="$TMP_CLI_HOME" bash "${REPO_ROOT}/scripts/install-cli.sh" --restore
test ! -f "${TMP_CLI_HOME}/agy-statusline.py"

echo "[PASS] 全部测试通过！"
