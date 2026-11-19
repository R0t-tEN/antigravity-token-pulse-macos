#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="AntigravityTokenPulse"
BUILD_DIR="${REPO_ROOT}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
MOD_CACHE="/tmp/swift-mod-cache-26"

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

echo "[1/4] 准备构建目录 (${TARGET_TRIPLE})..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MOD_CACHE"

echo "[2/4] 编译 Swift 源码..."
swiftc \
  -O \
  -swift-version 5 \
  -parse-as-library \
  "${SDK_FLAGS[@]}" \
  -module-cache-path "$MOD_CACHE" \
  -target "$TARGET_TRIPLE" \
  -framework SwiftUI \
  -framework AppKit \
  -framework ServiceManagement \
  -lsqlite3 \
  "${REPO_ROOT}/macos/Sources/Models.swift" \
  "${REPO_ROOT}/macos/Sources/ProtoModelScanner.swift" \
  "${REPO_ROOT}/macos/Sources/TelemetryService.swift" \
  "${REPO_ROOT}/macos/Sources/Theme.swift" \
  "${REPO_ROOT}/macos/Sources/HeatmapView.swift" \
  "${REPO_ROOT}/macos/Sources/TrendSectionView.swift" \
  "${REPO_ROOT}/macos/Sources/CompositionSectionView.swift" \
  "${REPO_ROOT}/macos/Sources/TelemetryViewModel.swift" \
  "${REPO_ROOT}/macos/Sources/SettingsView.swift" \
  "${REPO_ROOT}/macos/Sources/DashboardView.swift" \
  "${REPO_ROOT}/macos/Sources/FloatingPanelController.swift" \
  "${REPO_ROOT}/macos/Sources/AppMain.swift" \
  -o "${MACOS_DIR}/${APP_NAME}"

echo "[3/4] 生成应用图标与内置资源..."
cp "${REPO_ROOT}/macos/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp "${REPO_ROOT}/cli/agy-statusline.py" "${RESOURCES_DIR}/agy-statusline.py"
cp "${REPO_ROOT}/cli/agy-statusline.js" "${RESOURCES_DIR}/agy-statusline.js"
chmod +x "${RESOURCES_DIR}/agy-statusline.py" "${RESOURCES_DIR}/agy-statusline.js"

swift "${SDK_FLAGS[@]}" -module-cache-path "$MOD_CACHE" "${REPO_ROOT}/scripts/generate-icon.swift" "${RESOURCES_DIR}/AppIcon.icns"

echo "[4/4] 执行 Ad-Hoc 本地签名..."
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

echo "[完成] 已生成 macOS 应用: ${APP_BUNDLE}"
echo "       可直接运行: open \"${APP_BUNDLE}\""
echo "       或安装到应用目录: cp -R \"${APP_BUNDLE}\" /Applications/"
