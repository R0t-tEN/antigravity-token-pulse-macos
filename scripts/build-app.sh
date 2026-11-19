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

UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --universal|-u)
      UNIVERSAL=1
      ;;
    --help|-h)
      echo "用法: ./scripts/build-app.sh [--universal]"
      echo "  --universal, -u   构建同时支持 arm64 与 x86_64 的 Universal Binary"
      exit 0
      ;;
    *)
      echo "[错误] 未知参数: $arg" >&2
      exit 1
      ;;
  esac
done

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  ARCH="arm64"
fi

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

SWIFT_SOURCES=(
  "${REPO_ROOT}/macos/Sources/Models.swift"
  "${REPO_ROOT}/macos/Sources/ProtoModelScanner.swift"
  "${REPO_ROOT}/macos/Sources/TelemetryService.swift"
  "${REPO_ROOT}/macos/Sources/Theme.swift"
  "${REPO_ROOT}/macos/Sources/HeatmapView.swift"
  "${REPO_ROOT}/macos/Sources/TrendSectionView.swift"
  "${REPO_ROOT}/macos/Sources/CompositionSectionView.swift"
  "${REPO_ROOT}/macos/Sources/TelemetryViewModel.swift"
  "${REPO_ROOT}/macos/Sources/SettingsView.swift"
  "${REPO_ROOT}/macos/Sources/DashboardView.swift"
  "${REPO_ROOT}/macos/Sources/FloatingPanelController.swift"
  "${REPO_ROOT}/macos/Sources/AppMain.swift"
)

compile_arch() {
  local target_arch="$1"
  local out_bin="$2"
  swiftc \
    -O \
    -swift-version 5 \
    -parse-as-library \
    "${SDK_FLAGS[@]}" \
    -module-cache-path "$MOD_CACHE" \
    -target "${target_arch}-apple-macosx14.0" \
    -framework SwiftUI \
    -framework AppKit \
    -framework ServiceManagement \
    -lsqlite3 \
    "${SWIFT_SOURCES[@]}" \
    -o "$out_bin"
}

if [[ "$UNIVERSAL" -eq 1 ]]; then
  echo "[1/4] 准备构建目录 (Universal: arm64 + x86_64, macOS 14.0+)..."
else
  echo "[1/4] 准备构建目录 (${ARCH}-apple-macosx14.0)..."
fi
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MOD_CACHE"

echo "[2/4] 编译 Swift 源码..."
if [[ "$UNIVERSAL" -eq 1 ]]; then
  compile_arch "arm64" "${MACOS_DIR}/${APP_NAME}.arm64"
  compile_arch "x86_64" "${MACOS_DIR}/${APP_NAME}.x86_64"
  lipo -create "${MACOS_DIR}/${APP_NAME}.arm64" "${MACOS_DIR}/${APP_NAME}.x86_64" -output "${MACOS_DIR}/${APP_NAME}"
  rm -f "${MACOS_DIR}/${APP_NAME}.arm64" "${MACOS_DIR}/${APP_NAME}.x86_64"
else
  compile_arch "$ARCH" "${MACOS_DIR}/${APP_NAME}"
fi

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
