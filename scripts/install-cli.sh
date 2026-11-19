#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLI_HOME="${ANTIGRAVITY_CLI_HOME:-$HOME/.gemini/antigravity-cli}"
MODE="install"
RUNTIME="auto"

for arg in "$@"; do
  case "$arg" in
    --restore|--uninstall|-r)
      MODE="restore"
      ;;
    --python)
      RUNTIME="python"
      ;;
    --node)
      RUNTIME="node"
      ;;
    --help|-h)
      cat << 'EOF'
用法: ./scripts/install-cli.sh [选项]

选项:
  --python      强制使用 macOS 原生 python3 部署 agy-statusline.py
  --node        强制使用 Node.js (>= 18) 部署 agy-statusline.js
  --restore     卸载托管的 statusLine 配置并删除部署脚本
  -h, --help    显示帮助信息

环境变量:
  ANTIGRAVITY_CLI_HOME   自定义 CLI 配置目录 (默认 ~/.gemini/antigravity-cli)
EOF
      exit 0
      ;;
    *)
      echo "[错误] 未知参数: $arg" >&2
      exit 1
      ;;
  esac
done

SETTINGS_PATH="${CLI_HOME}/settings.json"
TARGET_PY="${CLI_HOME}/agy-statusline.py"
TARGET_JS="${CLI_HOME}/agy-statusline.js"

if [[ "$MODE" == "restore" ]]; then
  echo "[CLI] 正在卸载 agy statusLine 托管配置 (${CLI_HOME})..."
  rm -f "$TARGET_PY" "$TARGET_JS"
  if [[ -f "$SETTINGS_PATH" ]]; then
    /usr/bin/python3 - "$SETTINGS_PATH" << 'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
raw = p.read_text(encoding="utf-8-sig").strip()
if not raw:
    sys.exit(0)
data = json.loads(raw)
if isinstance(data, dict) and "statusLine" in data:
    cmd = str((data.get("statusLine") or {}).get("command") or "")
    if "agy-statusline" in cmd:
        del data["statusLine"]
        p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"[OK] 已从 {p} 移除托管的 statusLine 配置。")
    else:
        print(f"[跳过] 检测到非本工具托管的 statusLine ({cmd})，已保留。")
else:
    print("[跳过] settings.json 中未包含 statusLine 配置。")
PY
  fi
  echo "[完成] CLI 状态栏已还原。"
  exit 0
fi

# Detect runtime
CHOSEN_RUNTIME=""
if [[ "$RUNTIME" == "python" ]]; then
  CHOSEN_RUNTIME="python"
elif [[ "$RUNTIME" == "node" ]]; then
  if command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if [[ "$NODE_MAJOR" -ge 18 ]]; then
      CHOSEN_RUNTIME="node"
    else
      echo "[错误] 当前 node 版本过低 (< 18)，请升级 Node.js 或改用 --python。" >&2
      exit 1
    fi
  else
    echo "[错误] 未检测到 node 命令，请先安装 Node.js >= 18 或改用 --python。" >&2
    exit 1
  fi
else
  if command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if [[ "$NODE_MAJOR" -ge 18 ]]; then
      CHOSEN_RUNTIME="node"
    fi
  fi
  if [[ -z "$CHOSEN_RUNTIME" ]]; then
    if command -v python3 >/dev/null 2>&1 || [[ -x "/usr/bin/python3" ]]; then
      CHOSEN_RUNTIME="python"
    else
      echo "[错误] 未找到可用的 python3 或 Node.js >= 18。" >&2
      exit 1
    fi
  fi
fi

mkdir -p "$CLI_HOME"

if [[ "$CHOSEN_RUNTIME" == "node" ]]; then
  cp "${REPO_ROOT}/cli/agy-statusline.js" "$TARGET_JS"
  chmod +x "$TARGET_JS"
  NODE_BIN="$(command -v node)"
  if [[ "$TARGET_JS" == *" "* ]]; then
    STATUS_CMD="\"${NODE_BIN}\" \"${TARGET_JS}\""
  else
    STATUS_CMD="${NODE_BIN} ${TARGET_JS}"
  fi
  echo "[CLI] 已部署 Node.js 状态栏脚本: $TARGET_JS"
else
  cp "${REPO_ROOT}/cli/agy-statusline.py" "$TARGET_PY"
  chmod +x "$TARGET_PY"
  if [[ -x "/usr/bin/python3" ]]; then
    PY_BIN="/usr/bin/python3"
  else
    PY_BIN="$(command -v python3)"
  fi
  if [[ "$TARGET_PY" == *" "* ]]; then
    STATUS_CMD="\"${PY_BIN}\" \"${TARGET_PY}\""
  else
    STATUS_CMD="${PY_BIN} ${TARGET_PY}"
  fi
  echo "[CLI] 已部署 Python3 状态栏脚本 (零外部依赖): $TARGET_PY"
fi

/usr/bin/python3 - "$SETTINGS_PATH" "$STATUS_CMD" << 'PY'
import json, pathlib, sys
settings_path = pathlib.Path(sys.argv[1])
cmd = sys.argv[2]
data = {}
if settings_path.is_file():
    raw = settings_path.read_text(encoding="utf-8-sig").strip()
    if raw:
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise SystemExit(f"[错误] {settings_path} 不是有效 JSON 对象")
data["statusLine"] = {
    "type": "command",
    "command": cmd,
    "enabled": True,
}
tmp = settings_path.with_name(settings_path.name + ".tmp")
tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
tmp.replace(settings_path)
print(f"[OK] 已更新配置: {settings_path}")
PY

echo "[完成] agy CLI 状态栏已启用，命令行运行效果预览:"
"${SHELL:-/bin/zsh}" -c "$STATUS_CMD" < /dev/null || true
