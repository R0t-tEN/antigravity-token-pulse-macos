#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLIST_PATH="${REPO_ROOT}/macos/Info.plist"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST_PATH")"

SKIP_TESTS=0
RAW_TAG=""
for arg in "$@"; do
  case "$arg" in
    --skip-tests)
      SKIP_TESTS=1
      ;;
    --help|-h)
      echo "用法: ./scripts/package-release.sh [tag] [--skip-tests]"
      echo "  tag           发布版本标签，默认读取 macos/Info.plist (v${PLIST_VERSION})"
      echo "  --skip-tests  跳过自动化测试（默认打包前强制执行）"
      exit 0
      ;;
    *)
      if [[ -z "$RAW_TAG" ]]; then
        RAW_TAG="$arg"
      else
        echo "[错误] 未知参数: $arg" >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$RAW_TAG" ]]; then
  TAG="v${PLIST_VERSION}"
elif [[ "$RAW_TAG" == v* ]]; then
  TAG="$RAW_TAG"
else
  TAG="v${RAW_TAG}"
fi

BUILD_DIR="${REPO_ROOT}/build"
APP_BUNDLE="${BUILD_DIR}/AntigravityTokenPulse.app"
BIN_PATH="${APP_BUNDLE}/Contents/MacOS/AntigravityTokenPulse"
RELEASE_DIR="${BUILD_DIR}/release"
ZIP_NAME="AntigravityTokenPulse-${TAG}-macos-universal.zip"
ZIP_PATH="${RELEASE_DIR}/${ZIP_NAME}"
SHA_PATH="${RELEASE_DIR}/SHA256SUMS.txt"

if [[ "$SKIP_TESTS" -eq 0 ]]; then
  echo "[1/5] 运行全量单元测试..."
  bash "${REPO_ROOT}/scripts/run-tests.sh"
else
  echo "[1/5] 跳过测试 (--skip-tests)"
fi

echo "[2/5] 构建 Universal Binary (.app)..."
bash "${REPO_ROOT}/scripts/build-app.sh" --universal

echo "[3/5] 校验 Universal 架构与签名..."
ARCHS="$(lipo -archs "$BIN_PATH")"
echo "      二进制架构: ${ARCHS}"
if [[ "$ARCHS" != *"arm64"* || "$ARCHS" != *"x86_64"* ]]; then
  echo "[错误] Universal Binary 缺少 arm64 或 x86_64 架构: ${ARCHS}" >&2
  exit 1
fi
codesign -vvv "$APP_BUNDLE"

echo "[4/5] 使用 ditto 打包 macOS Release 压缩包..."
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "[5/5] 校验压缩包解压签名与 SHA256..."
VERIFY_DIR="$(mktemp -d /tmp/agy_release_verify.XXXXXX)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
codesign -vvv "${VERIFY_DIR}/AntigravityTokenPulse.app"

(cd "$RELEASE_DIR" && shasum -a 256 "$ZIP_NAME" > SHA256SUMS.txt)
SHA_LINE="$(cat "$SHA_PATH")"
NOTES_PATH="${RELEASE_DIR}/RELEASE_NOTES.md"
cat > "$NOTES_PATH" <<EOF
## Antigravity Token Pulse ${TAG} (macOS Universal)

专为 Google Antigravity（macOS 14+，同时原生支持 Apple Silicon \`arm64\` 与 Intel \`x86_64\`）打造的零侵入菜单栏 Token 看板与 \`agy\` CLI 状态栏套件。

### 主要特性
- **零侵入纯本地读取**：直接解析 \`~/.gemini/antigravity/...\`、\`~/.gemini/antigravity-cli/...\` 与 \`conversation_summaries.db\`（含 WAL 模式只读快照回退），不修改原版 Antigravity 应用，100% 离线运行。
- **菜单栏实时状态 & 多任务并行监控**：自动识别多个运行中的主对话及 \`not_fully_idle\` 子代理，支持顶部遥测条切换、锁定与横向并行任务条。
- **活动趋势 + 构成与会话双视角**：支持 16/53 周相对归一化热力图、周柱状图、月日历与全部历史对话消耗排行（同步官方重命名标题，支持一键盯盘）。
- **可拖拽独立窗口**：菜单栏下拉吸附 + 拖离后自动转为普通层级桌面窗（可被其他应用正常遮挡，支持右上角手动开关置顶）。
- **翡翠天青深浅色主题 & CLI 状态栏**：内置零依赖 Python 3 / Node.js 版 \`agy\` CLI 状态栏脚本，一键部署或还原。

### 安装说明
1. 下载下方 \`${ZIP_NAME}\` 并解压，将 \`AntigravityTokenPulse.app\` 拖入「应用程序 (\`/Applications\`)」。
2. 本应用当前采用本地 Ad-Hoc 签名（未经过 Apple 公证）。如首次双击提示「无法验证开发者」或「已损坏」，在终端执行一次解除隔离属性后即可正常打开：
   \`\`\`bash
   xattr -cr /Applications/AntigravityTokenPulse.app
   open /Applications/AntigravityTokenPulse.app
   \`\`\`

### 校验和 (\`SHA256SUMS.txt\`)
\`\`\`text
${SHA_LINE}
\`\`\`
EOF

echo "[完成] Release 产物已生成:"
ls -lh "$ZIP_PATH" "$SHA_PATH" "$NOTES_PATH"
cat "$SHA_PATH"
