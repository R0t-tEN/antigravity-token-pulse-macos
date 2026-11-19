# Antigravity Token Pulse (macOS)

专为 Google Antigravity (**macOS**) 打造的 **零侵入原生菜单栏应用** 与 **`agy` CLI 状态栏** 套件，纯本地读取对话记录与会话元数据，实时可视化 Token 消耗热力图、会话构成与多任务运行状态。

- **零侵入 / 不破坏应用签名**：无需修改 `/Applications/Antigravity.app/Contents/Resources/app.asar`，不影响 Google 原厂苹果代码签名、公证、Keychain 权限记忆或客户端自动更新。
- **100% 纯本地读取**：仅读取 `~/.gemini/antigravity/...`、`~/.gemini/antigravity-cli/...` 与共享缓存 `~/.gemini/telemetry-activity-cache.json`，不上传任何数据。
- **零外部编译依赖**：仅使用 macOS 原生 SwiftUI / AppKit 与系统内置 Python 3，无需额外安装 Xcode 或 Node.js。

---

## 核心功能

### 1. macOS 原生菜单栏 + 可拖拽悬浮窗 (`AntigravityTokenPulse.app`)
- **菜单栏常驻**：顶部状态栏实时显示今日消耗总量（可切换为「当前会话上下文占用」或「仅图标」），多任务并行时自动附加当前运行数量。
- **多任务并行状态监控 & 实时遥测条**：自动识别 `conversation_summaries.db` 中正在运行的桌面主任务、`not_fully_idle` 子代理（如 `browser`）与活跃 CLI 会话；展示运行状态、标题、端侧与主模型、`⚡ t/s` 生成速率、1M 上下文环形进度条、`Cache%` 缓存命中率及 `∑`。支持通过下拉菜单或横向并行任务条 1 键切换并锁定遥测观察目标。
- **双视角无重复结构（`活动趋势` + `构成与会话`）**：
  - **活动趋势**：支持 `按天 · 热力图`（可切 16 周 / 53 周）、`按周 · 趋势柱`、`按月 · 数字日历` 三种粒度，上方图表与下方明细及 `[端侧 | 模型]` 视角同步联动，热力图色阶按当前视图非零极值动态相对归一化。
  - **构成与会话**：支持按 `今日 / 本周 / 本月 / 全部` 与端侧过滤，展示 Token 类型构成、模型分布，以及**全部历史对话消耗明细（按消耗从高到低排序，优先同步 `conversation_summaries.db` 官方重命名标题，标出 `运行中` / 子代理徽标，支持一键「盯盘」切换到顶部遥测条与标题/模型筛选）**；点击顶部 KPI 卡片也可一键直达对应周期。
- **深浅色主题自适应**：自动跟随 macOS 深色 / 浅色外观切换翡翠天青热力图色阶，也可在设置中手动锁定。
- **可拖拽分离独立窗口**：点击菜单栏直接展开看板；按住顶部或空白区域即可直接拖动，拖离菜单栏后自动成为普通层级独立窗口（默认不会锁在最上层，其他应用可正常覆盖；可点击右上角 `📌` 手动切换置顶，或点击吸附按钮回到菜单栏）。

### 2. Antigravity CLI (`agy`) 状态栏与多端聚合
- 提供零依赖的 Python 3 版 [`cli/agy-statusline.py`](cli/agy-statusline.py) 与 Node.js >= 18 版 [`cli/agy-statusline.js`](cli/agy-statusline.js)。
- 实时在终端底部输出 `⚡ t/s · ○ used / 1M pct% · ◈ cache% · ∑ total · model`，并将 CLI 会话记录原子同步到 `~/.gemini/telemetry-activity-cache.json`（v4），与桌面端热力图无缝合并。

---

## 快速开始

### 1. 构建并启动 macOS 菜单栏应用

```bash
./scripts/build-app.sh
open ./build/AntigravityTokenPulse.app
```

如需安装到系统「应用程序」目录：

```bash
cp -R ./build/AntigravityTokenPulse.app /Applications/
open /Applications/AntigravityTokenPulse.app
```

> 首次打开若提示设置「登录时自动启动」，建议先将 `.app` 移入 `/Applications` 目录后再在应用设置中开启。

### 2. 配置 `agy` CLI 状态栏（可选）

可直接通过菜单栏应用右上角 **设置 (`⚙`) -> 一键启用 agy 状态栏** 配置，或在终端执行：

```bash
./scripts/install-cli.sh
```

脚本会自动检测本机环境（如已安装 Node.js >= 18 可选 Node 版，否则自动使用 macOS 原生 `python3` 部署零依赖版本），并写入 `~/.gemini/antigravity-cli/settings.json`。

如需指定运行引擎或卸载还原：

```bash
./scripts/install-cli.sh --python     # 强制使用 Python3 版本
./scripts/install-cli.sh --node       # 强制使用 Node.js 版本
./scripts/install-cli.sh --restore    # 卸载托管配置并清理脚本
```

---

## 运行自动化测试

```bash
./scripts/run-tests.sh
```

---

## 目录结构

```text
.
├── cli/
│   ├── agy-statusline.py          # Python 3 零依赖版 agy CLI 状态栏 + 账本同步
│   └── agy-statusline.js          # Node.js >= 18 版 agy CLI 状态栏
├── macos/
│   ├── Info.plist                 # macOS App Bundle 元数据 (LSUIElement=true)
│   └── Sources/
│       ├── Models.swift           # 缓存 v4 数据结构、格式化、模型名规范化、ISO 周计算
│       ├── ProtoModelScanner.swift# SQLite/WAL (.db / .db-wal) 流式模型元数据提取
│       ├── TelemetryService.swift # transcript.jsonl 解析、conversation_summaries.db 标题同步与原子缓存聚合
│       ├── Theme.swift            # 深浅色主题与动态模型调色板
│       ├── HeatmapView.swift      # 16/53 周热力图网格与交互式悬停提示
│       ├── TrendSectionView.swift # 活动趋势视图 (热力图 / 周趋势柱 / 月数字日历)
│       ├── CompositionSectionView.swift # 构成与全部对话消耗明细 (从高到低排序)
│       ├── TelemetryViewModel.swift# 后台轮询与 CLI 配置管理
│       ├── SettingsView.swift     # 主题、刷新间隔、开机自启与数据源检测
│       ├── DashboardView.swift    # 主看板视图
│       ├── FloatingPanelController.swift # NSStatusItem 与可拖拽分离悬浮窗控制器
│       └── AppMain.swift          # 应用生命周期入口
├── scripts/
│   ├── generate-icon.swift        # 生成应用图标 AppIcon.icns
│   ├── build-app.sh               # 一键编译并 Ad-Hoc 签名 .app
│   ├── install-cli.sh             # 一键部署/还原 agy CLI 状态栏
│   └── run-tests.sh               # Swift 核心与 CLI 状态栏单元测试
└── tests/
    ├── SwiftCoreTests.swift
    └── test_cli_statusline.py
```
