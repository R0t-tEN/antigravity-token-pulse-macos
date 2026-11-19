import SwiftUI
import AppKit

struct DashboardView: View {
    @ObservedObject var vm: TelemetryViewModel
    var onTogglePin: (() -> Void)? = nil
    var onToggleAlwaysOnTop: (() -> Void)? = nil
    var onClosePanel: (() -> Void)? = nil

    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("heatmapRangeMode") private var heatmapRangeRaw: String = HeatmapRangeMode.weeks16.rawValue
    @State private var activeTab: MainWorkspaceTab = .trend
    @State private var trendGranularity: TrendGranularity = .day
    @State private var breakdownMode: BreakdownMode = .source
    @State private var selectedDateKey: String? = nil
    @State private var compositionRange: TimeRangeFilter = .all
    @State private var sourceFilter: SourceFilter = .all
    @State private var showSettings: Bool = false

    private var heatmapRangeBinding: Binding<HeatmapRangeMode> {
        Binding(
            get: { HeatmapRangeMode(rawValue: heatmapRangeRaw) ?? .weeks16 },
            set: { heatmapRangeRaw = $0.rawValue }
        )
    }

    private var theme: PulseTheme {
        PulseTheme.resolve(preference: vm.themePreference, systemColorScheme: systemColorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showSettings {
                SettingsView(vm: vm, theme: theme) {
                    showSettings = false
                }
            } else {
                headerBar

                if vm.showLiveSessionStrip, let live = vm.liveSession {
                    VStack(alignment: .leading, spacing: 6) {
                        liveTelemetryStrip(live)
                        if vm.runningSessions.count >= 2 {
                            parallelRunningStrip(active: live)
                        }
                    }
                }

                kpiGrid

                Divider().overlay(theme.divider)

                if activeTab == .trend {
                    TrendSectionView(
                        stats: vm.stats,
                        theme: theme,
                        granularity: $trendGranularity,
                        heatmapRange: heatmapRangeBinding,
                        mode: $breakdownMode,
                        selectedDateKey: $selectedDateKey
                    )
                } else {
                    CompositionSectionView(
                        stats: vm.stats,
                        theme: theme,
                        timeRange: $compositionRange,
                        sourceFilter: $sourceFilter,
                        activeLiveConvId: vm.liveSession?.conversationId,
                        pinnedConvId: vm.pinnedConversationId,
                        onInspectLive: { convId in
                            vm.selectLiveSession(convId)
                        }
                    )
                }
            }
        }
        .padding(20)
        .frame(width: 800)
        .frame(minHeight: showSettings ? 480 : 620)
        .background {
            ZStack {
                theme.cardBg
                WindowDragArea()
            }
        }
        .preferredColorScheme(preferredScheme)
    }

    private var preferredScheme: ColorScheme? {
        switch vm.themePreference {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 8) {
                Text("Token 活动")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.title)

                HStack(spacing: 5) {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 6, height: 6)
                    Text("Desktop + CLI 同步")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accent)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(theme.accentBg)
                .overlay(Capsule().strokeBorder(theme.accentBorder, lineWidth: 1))
                .clipShape(Capsule())

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay(WindowDragArea())

            HStack(spacing: 2) {
                ForEach(MainWorkspaceTab.allCases) { tab in
                    Button {
                        activeTab = tab
                    } label: {
                        Text(tab.title)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(activeTab == tab ? theme.accentBg : Color.clear)
                            .foregroundColor(activeTab == tab ? theme.accent : theme.secondaryText)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(activeTab == tab ? theme.accentBorder : Color.clear, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(theme.elevatedBg)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 4) {
                iconButton(systemName: "arrow.clockwise", tooltip: "立即刷新数据") {
                    vm.refreshNow()
                }
                if vm.isPanelDetached, let toggleAlwaysOnTop = onToggleAlwaysOnTop {
                    iconButton(
                        systemName: vm.isAlwaysOnTop ? "pin.fill" : "pin",
                        tooltip: vm.isAlwaysOnTop ? "已置顶在最上层（点击取消置顶，允许其他应用覆盖）" : "置顶窗口（当前可被其他应用覆盖，点击锁定在最上层）",
                        highlighted: vm.isAlwaysOnTop
                    ) {
                        toggleAlwaysOnTop()
                    }
                }
                if let togglePin = onTogglePin {
                    iconButton(
                        systemName: vm.isPanelDetached ? "menubar.arrow.up.rectangle" : "macwindow",
                        tooltip: vm.isPanelDetached ? "吸附回菜单栏位置（失焦自动收起）" : "转为独立窗口（可任意拖动，不会锁在最上层）"
                    ) {
                        togglePin()
                    }
                }
                iconButton(systemName: "gearshape", tooltip: "设置与 CLI 配置") {
                    showSettings = true
                }
                if vm.isPanelDetached, let closePanel = onClosePanel {
                    iconButton(systemName: "xmark", tooltip: "收起窗口（应用仍在菜单栏运行）") {
                        closePanel()
                    }
                }
                iconButton(systemName: "power", tooltip: "退出应用") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private func iconButton(systemName: String, tooltip: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(highlighted ? theme.accent : theme.secondaryText)
                .frame(width: 26, height: 26)
                .background(highlighted ? theme.accentBg : theme.elevatedBg)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(highlighted ? theme.accentBorder : theme.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Live Telemetry Strip

    private func liveTelemetryStrip(_ live: LiveSessionStats) -> some View {
        let pct = Double(live.contextPercent) / 100.0
        let speedStr = live.tokensPerSecond > 0 ? "\(live.tokensPerSecond)" : "--"
        let runningCount = vm.runningSessions.count
        let isPinned = vm.pinnedConversationId != nil
        let displayTitle = live.title.isEmpty ? "最近会话" : live.title
        let tooltipSuffix = isPinned ? "（已手动锁定，点击切换可恢复自动跟随）" : "（自动跟随最近活跃）"

        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(live.isRunning ? theme.outputTokenColor : theme.mutedText.opacity(0.65))
                    .frame(width: 6, height: 6)

                Text(live.source == "cli" ? "CLI" : "Desktop")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(live.source == "cli" ? theme.cliColor.opacity(0.18) : theme.desktopColor.opacity(0.18))
                    .foregroundColor(live.source == "cli" ? theme.cliColor : theme.desktopColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                if !live.agentName.isEmpty {
                    Text(live.agentName)
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(theme.inputTokenColor.opacity(0.16))
                        .foregroundColor(theme.inputTokenColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                Text(displayTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("· \(live.modelName)")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, alignment: .leading)

            liveSessionSwitcherMenu(runningCount: runningCount, isPinned: isPinned)

            Spacer(minLength: 4)

            HStack(spacing: 10) {
                // Speed
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10.5))
                    Text("\(speedStr) t/s")
                        .font(.system(size: 11.5).monospacedDigit())
                }
                .foregroundColor(theme.secondaryText)

                Text("·").foregroundColor(theme.mutedText)

                // Context Ring
                HStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .stroke(theme.trackBg, lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: pct)
                            .stroke(theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 12, height: 12)

                    Text("\(TokenFormatter.compact(live.latestContextUsed)) / 1M · \(live.contextPercent)%")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundColor(theme.secondaryText)
                }

                Text("·").foregroundColor(theme.mutedText)

                // Cache Hit
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 10.5))
                    Text("\(live.cacheHitRate)%")
                        .font(.system(size: 11.5).monospacedDigit())
                }
                .foregroundColor(theme.secondaryText)

                Text("·").foregroundColor(theme.mutedText)

                // Session Total
                HStack(spacing: 3) {
                    Text("∑")
                        .font(.system(size: 11.5, weight: .medium))
                    Text(TokenFormatter.compact(live.cumulativeTokens))
                        .font(.system(size: 11.5).monospacedDigit())
                }
                .foregroundColor(theme.primaryText)
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.elevatedBg)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(live.isRunning ? theme.accentBorder : theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help("会话 ID: \(live.conversationId)\n状态: \(live.statusText)\(tooltipSuffix)")
    }

    private func liveSessionSwitcherMenu(runningCount: Int, isPinned: Bool) -> some View {
        Menu {
            Button {
                vm.selectLiveSession(nil)
            } label: {
                Text(vm.pinnedConversationId == nil ? "✓ 自动跟随最新活跃" : "自动跟随最新活跃")
            }

            if !vm.runningSessions.isEmpty {
                Divider()
                Section("正在运行 (\(vm.runningSessions.count))") {
                    ForEach(vm.runningSessions) { session in
                        Button {
                            vm.selectLiveSession(session.conversationId)
                        } label: {
                            let mark = (vm.pinnedConversationId == session.conversationId) ? "✓ " : "● "
                            let src = session.source == "cli" ? "CLI" : "Desktop"
                            let agentTag = session.agentName.isEmpty ? "" : "[\(session.agentName)] "
                            Text("\(mark)\(src) · \(agentTag)\(session.title) (\(session.modelName))")
                        }
                    }
                }
            }

            let recentOnly = vm.recentSessions.filter { r in
                !vm.runningSessions.contains(where: { $0.id == r.id })
            }
            if !recentOnly.isEmpty {
                Divider()
                Section("最近会话") {
                    ForEach(recentOnly) { session in
                        Button {
                            vm.selectLiveSession(session.conversationId)
                        } label: {
                            let mark = (vm.pinnedConversationId == session.conversationId) ? "✓ " : ""
                            let src = session.source == "cli" ? "CLI" : "Desktop"
                            Text("\(mark)\(src) · \(session.title) (\(session.modelName))")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if runningCount >= 1 {
                    Circle()
                        .fill(theme.outputTokenColor)
                        .frame(width: 5, height: 5)
                    Text("\(runningCount) 运行中")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundColor(theme.accent)
                } else {
                    Text("切换")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8.5))
                        .foregroundColor(theme.accent)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(runningCount >= 1 ? theme.accent : theme.mutedText)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(runningCount >= 1 || isPinned ? theme.accentBg : theme.cardBg.opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(runningCount >= 1 || isPinned ? theme.accentBorder : theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换顶部遥测条正在观察的会话")
    }

    private func parallelRunningStrip(active: LiveSessionStats) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Circle()
                    .fill(theme.outputTokenColor)
                    .frame(width: 5, height: 5)
                Text("并行任务")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .fixedSize()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(vm.runningSessions) { session in
                        let isSelected = session.conversationId == active.conversationId && session.source == active.source
                        let isPinned = vm.pinnedConversationId == session.conversationId
                        Button {
                            vm.selectLiveSession(isPinned ? nil : session.conversationId)
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(theme.outputTokenColor)
                                    .frame(width: 5, height: 5)
                                if session.source == "cli" {
                                    Text("CLI")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(theme.cliColor)
                                }
                                if !session.agentName.isEmpty {
                                    Text(session.agentName)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(theme.inputTokenColor)
                                }
                                Text(session.title.isEmpty ? session.conversationId : session.title)
                                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                                    .foregroundColor(isSelected ? theme.accent : theme.primaryText)
                                    .lineLimit(1)
                                    .frame(maxWidth: 160, alignment: .leading)
                                if session.contextPercent > 0 {
                                    Text("\(session.contextPercent)%")
                                        .font(.system(size: 9.5).monospacedDigit())
                                        .foregroundColor(isSelected ? theme.accent : theme.mutedText)
                                }
                                if isPinned {
                                    Image(systemName: "pin.fill")
                                        .font(.system(size: 8.5))
                                        .foregroundColor(theme.accent)
                                }
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(isSelected ? theme.accentBg : theme.elevatedBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(isSelected ? theme.accentBorder : theme.border, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("\(session.statusText) · \(session.modelName) · 点击\(isPinned ? "恢复自动跟随" : "切换到顶部遥测条")")
                    }
                }
            }

            if vm.pinnedConversationId != nil {
                Button {
                    vm.selectLiveSession(nil)
                } label: {
                    Text("自动跟随")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(theme.elevatedBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(theme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
    }

    // MARK: - 4 KPI Cards

    private var kpiGrid: some View {
        HStack(spacing: 10) {
            kpiCard(
                label: "今日消耗",
                value: TokenFormatter.activity(vm.stats.today.totalTokens),
                sub: "Desktop \(TokenFormatter.activity(vm.stats.today.desktop)) · CLI \(TokenFormatter.activity(vm.stats.today.cli))",
                targetRange: .today
            )
            kpiCard(
                label: "本周消耗",
                value: TokenFormatter.activity(vm.stats.thisWeek.totalTokens),
                sub: "缓存率 \(vm.stats.thisWeek.cacheHitRate)% · 输出 \(TokenFormatter.activity(vm.stats.thisWeek.outTokens))",
                targetRange: .week
            )
            kpiCard(
                label: "本月消耗",
                value: TokenFormatter.activity(vm.stats.thisMonth.totalTokens),
                sub: "活跃 \(vm.stats.thisMonth.activeDays) 天 · Desktop \(TokenFormatter.activity(vm.stats.thisMonth.desktop)) · CLI \(TokenFormatter.activity(vm.stats.thisMonth.cli))",
                targetRange: .month
            )
            kpiCard(
                label: "累计总量",
                value: TokenFormatter.activity(vm.stats.allTime.totalTokens),
                sub: "共 \(vm.stats.totalConversations) 会话 · 缓存率 \(vm.stats.allTime.cacheHitRate)%",
                targetRange: .all
            )
        }
    }

    private func kpiCard(label: String, value: String, sub: String, targetRange: TimeRangeFilter) -> some View {
        let isFocused = activeTab == .composition && compositionRange == targetRange
        return Button {
            compositionRange = targetRange
            activeTab = .composition
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(theme.mutedText)
                Text(value)
                    .font(.system(size: 20, weight: .bold).monospacedDigit())
                    .foregroundColor(theme.title)
                    .lineLimit(1)
                Text(sub)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(theme.mutedText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isFocused ? theme.accentBg.opacity(0.55) : theme.elevatedBg)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isFocused ? theme.accentBorder : theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("点击查看「\(targetRange.title)」的模型构成与对话排行")
    }
}
