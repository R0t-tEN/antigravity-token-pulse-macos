import SwiftUI

struct CompositionSectionView: View {
    let stats: ActivityStats
    let theme: PulseTheme
    @Binding var timeRange: TimeRangeFilter
    @Binding var sourceFilter: SourceFilter
    var activeLiveConvId: String? = nil
    var pinnedConvId: String? = nil
    var onInspectLive: ((String?) -> Void)? = nil

    @State private var searchText: String = ""

    private static let dateTimeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df
    }()

    var body: some View {
        let palette = ModelColorPalette(stats: stats)
        let filtered = stats.filteredComposition(range: timeRange, sourceFilter: sourceFilter)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visibleConversations = query.isEmpty
            ? filtered.conversations
            : filtered.conversations.filter { conv in
                conv.title.lowercased().contains(query) ||
                conv.primaryModel.lowercased().contains(query) ||
                conv.convId.lowercased().contains(query) ||
                conv.agentName.lowercased().contains(query) ||
                conv.statusText.lowercased().contains(query)
            }

        VStack(alignment: .leading, spacing: 10) {
            filterHeaderBar(totalCount: filtered.conversations.count, summary: filtered.summary)

            // Upper 2-column structural breakdown
            HStack(alignment: .top, spacing: 10) {
                tokenAndSourcePanel(summary: filtered.summary)
                modelsPanel(summary: filtered.summary, palette: palette)
            }

            // Lower full conversations list sorted highest -> lowest
            conversationsHeader(shownCount: visibleConversations.count, totalCount: filtered.conversations.count)

            ScrollView(.vertical, showsIndicators: true) {
                if visibleConversations.isEmpty {
                    Text(filtered.conversations.isEmpty ? "当前时间范围内暂无对话消耗记录" : "没有匹配「\(searchText)」的对话")
                        .font(.system(size: 12))
                        .foregroundColor(theme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                } else {
                    let maxConvTotal = max(1.0, visibleConversations.first?.totalTokens ?? 1.0)
                    LazyVStack(spacing: 6) {
                        ForEach(Array(visibleConversations.enumerated()), id: \.element.id) { index, conv in
                            conversationRow(rank: index + 1, conv: conv, maxTotal: maxConvTotal, palette: palette)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
            .frame(height: 205)
        }
    }

    // MARK: - Top Filter Bar

    private func filterHeaderBar(totalCount: Int, summary: PeriodSummary) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(SourceFilter.allCases) { sf in
                    Button {
                        sourceFilter = sf
                    } label: {
                        Text(sf.title)
                            .font(.system(size: 11, weight: sourceFilter == sf ? .medium : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(sourceFilter == sf ? theme.accentBg : Color.clear)
                            .foregroundColor(sourceFilter == sf ? theme.accent : theme.secondaryText)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(theme.elevatedBg)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text("共 \(totalCount) 个会话 · \(summary.activeDays) 活跃天 · \(summary.steps) 步")
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(theme.secondaryText)

            Spacer()

            HStack(spacing: 2) {
                ForEach(TimeRangeFilter.allCases) { tf in
                    Button {
                        timeRange = tf
                    } label: {
                        Text(tf.title)
                            .font(.system(size: 11.5, weight: timeRange == tf ? .medium : .regular))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(timeRange == tf ? theme.accentBg : Color.clear)
                            .foregroundColor(timeRange == tf ? theme.accent : theme.secondaryText)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                    .strokeBorder(timeRange == tf ? theme.accentBorder : Color.clear, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2.5)
            .background(theme.elevatedBg)
            .overlay(RoundedRectangle(cornerRadius: 7.5, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
        }
    }

    // MARK: - Upper Panels

    private func tokenAndSourcePanel(summary: PeriodSummary) -> some View {
        let compSum = max(1.0, summary.inTokens + summary.cacheTokens + summary.outTokens)
        let hasComp = summary.totalTokens > 0
        let inPct = hasComp ? (summary.inTokens / compSum) * 100.0 : 0
        let cachePct = hasComp ? (summary.cacheTokens / compSum) * 100.0 : 0
        let outPct = hasComp ? (summary.outTokens / compSum) * 100.0 : 0

        let srcSum = max(1.0, summary.desktop + summary.cli)
        let dPct = hasComp ? (summary.desktop / srcSum) * 100.0 : 0
        let cPct = hasComp ? max(0, 100.0 - dPct) : 0

        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Token 与端侧构成")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text("共 \(TokenFormatter.activity(summary.totalTokens))")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundColor(theme.title)
            }

            miniCompositionBar(label: "输入 (Input)", value: summary.inTokens, pct: inPct, color: theme.inputTokenColor)
            miniCompositionBar(label: "缓存读取 (Cache)", value: summary.cacheTokens, pct: cachePct, color: theme.desktopColor)
            miniCompositionBar(label: "输出 (Output)", value: summary.outTokens, pct: outPct, color: theme.outputTokenColor)

            Divider().overlay(theme.divider)

            HStack(spacing: 8) {
                Text("Desktop \(TokenFormatter.activity(summary.desktop)) (\(String(format: "%.0f", dPct))%)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(theme.desktopColor)
                Spacer()
                Text("CLI \(TokenFormatter.activity(summary.cli)) (\(String(format: "%.0f", cPct))%)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(theme.cliColor)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .background(theme.elevatedBg)
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func miniCompositionBar(label: String, value: Double, pct: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            HStack {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                Text("\(TokenFormatter.activity(value)) (\(String(format: "%.1f", pct))%)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundColor(theme.primaryText)
            }
            GeometryReader { geo in
                let w = max(0, geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.trackBg)
                    Capsule().fill(color).frame(width: value > 0 ? max(3, w * CGFloat(pct / 100.0)) : 0)
                }
            }
            .frame(height: 5)
        }
    }

    private func modelsPanel(summary: PeriodSummary, palette: ModelColorPalette) -> some View {
        let entries = TokenAggregator.sortedModelEntries(summary.models)
        let sum = max(1.0, max(summary.totalTokens, entries.reduce(0.0) { $0 + $1.usage.totalTokens }))

        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("模型消耗分布")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text("\(entries.count) 个模型")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(theme.mutedText)
            }

            if entries.isEmpty {
                Text("当前筛选范围内暂无模型消耗")
                    .font(.system(size: 11))
                    .foregroundColor(theme.mutedText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                GeometryReader { geo in
                    let w = max(0, geo.size.width)
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.trackBg)
                        HStack(spacing: 0) {
                            ForEach(entries, id: \.name) { entry in
                                Rectangle()
                                    .fill(palette.color(for: entry.name))
                                    .frame(width: w * CGFloat(entry.usage.totalTokens / sum))
                            }
                        }
                        .clipShape(Capsule())
                    }
                }
                .frame(height: 7)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 5) {
                        ForEach(entries, id: \.name) { entry in
                            let pct = (entry.usage.totalTokens / sum) * 100.0
                            let col = palette.color(for: entry.name)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    HStack(spacing: 5) {
                                        Circle().fill(col).frame(width: 6, height: 6)
                                        Text(entry.name)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(theme.primaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text("\(TokenFormatter.activity(entry.usage.totalTokens)) (\(String(format: "%.1f", pct))%)")
                                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                        .foregroundColor(theme.primaryText)
                                }
                                Text("输入 \(TokenFormatter.activity(entry.usage.inTokens)) · 缓存 \(TokenFormatter.activity(entry.usage.cacheTokens)) · 输出 \(TokenFormatter.activity(entry.usage.outTokens)) · \(entry.usage.steps) 步")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(theme.mutedText)
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(height: 98)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 148, maxHeight: 148, alignment: .topLeading)
        .background(theme.elevatedBg)
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Conversations List (All Conversations Sorted High -> Low)

    private func conversationsHeader(shownCount: Int, totalCount: Int) -> some View {
        HStack(spacing: 8) {
            Text(shownCount == totalCount
                 ? "全部对话消耗明细（共 \(totalCount) 个，按总量从高到低）"
                 : "全部对话消耗明细（匹配 \(shownCount) / \(totalCount) 个，按总量从高到低）")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(theme.secondaryText)

            Spacer()

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(theme.mutedText)
                TextField("筛选对话或模型", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 135)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(theme.mutedText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(theme.elevatedBg)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func conversationRow(rank: Int, conv: ConversationSummary, maxTotal: Double, palette: ModelColorPalette) -> some View {
        let modelEntries = TokenAggregator.sortedModelEntries(conv.models)
        let dateStr = Self.dateTimeFormatter.string(from: conv.lastActiveDate)
        let isCli = conv.source == "cli"
        let isObserved = (activeLiveConvId == conv.convId)
        let isPinned = (pinnedConvId == conv.convId)
        var tooltipLines = [
            "会话 ID: \(conv.convId)",
            "标题: \(conv.title)",
            "状态: \(conv.statusText)",
        ]
        if !conv.agentName.isEmpty {
            tooltipLines.append("子代理: \(conv.agentName)")
        }
        tooltipLines.append("总计: \(TokenFormatter.activity(conv.totalTokens)) Tokens (\(conv.steps) 步)")
        tooltipLines.append(contentsOf: modelEntries.map { "• \($0.name): \(TokenFormatter.activity($0.usage.totalTokens))" })

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("#\(rank)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundColor(rank <= 3 ? theme.accent : theme.mutedText)
                    .frame(minWidth: 22, alignment: .leading)

                Text(isCli ? "CLI" : "Desktop")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(isCli ? theme.cliColor.opacity(0.18) : theme.desktopColor.opacity(0.18))
                    .foregroundColor(isCli ? theme.cliColor : theme.desktopColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                if conv.isRunning {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(theme.outputTokenColor)
                            .frame(width: 5, height: 5)
                        Text("运行中")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(theme.outputTokenColor.opacity(0.14))
                    .foregroundColor(theme.outputTokenColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                if !conv.agentName.isEmpty {
                    Text(conv.agentName)
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(theme.inputTokenColor.opacity(0.16))
                        .foregroundColor(theme.inputTokenColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                Text(conv.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if let onInspectLive = onInspectLive {
                    Button {
                        onInspectLive(isPinned ? nil : conv.convId)
                    } label: {
                        HStack(spacing: 3) {
                            if isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 8.5))
                            }
                            Text(isPinned ? "已锁定" : (isObserved ? "观测中" : "盯盘"))
                                .font(.system(size: 9.5, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isObserved ? theme.accentBg : theme.elevatedBg)
                        .foregroundColor(isObserved ? theme.accent : theme.secondaryText)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(isObserved ? theme.accentBorder : theme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(isPinned ? "取消锁定，恢复自动跟随最新会话" : "切换顶部实时遥测条跟踪此会话")
                }

                Text(TokenFormatter.activity(conv.totalTokens))
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundColor(theme.title)
            }

            GeometryReader { geo in
                let fullW = max(0, geo.size.width)
                let fillW = maxTotal > 0 ? max(4, min(fullW, fullW * CGFloat(conv.totalTokens / maxTotal))) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.trackBg)
                    if !modelEntries.isEmpty {
                        let mSum = max(1.0, modelEntries.reduce(0.0) { $0 + $1.usage.totalTokens })
                        HStack(spacing: 0) {
                            ForEach(modelEntries, id: \.name) { e in
                                Rectangle()
                                    .fill(palette.color(for: e.name))
                                    .frame(width: fillW * CGFloat(e.usage.totalTokens / mSum))
                            }
                        }
                        .frame(width: fillW)
                        .clipShape(Capsule())
                    } else {
                        Capsule()
                            .fill(isCli ? theme.cliColor : theme.desktopColor)
                            .frame(width: fillW)
                    }
                }
            }
            .frame(height: 5)

            HStack(spacing: 8) {
                Text("\(conv.primaryModel) · \(dateStr) · \(conv.steps) 步")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                Spacer()
                Text("输入 \(TokenFormatter.activity(conv.inTokens)) · 缓存 \(TokenFormatter.activity(conv.cacheTokens)) (\(conv.cacheHitRate)%) · 输出 \(TokenFormatter.activity(conv.outTokens))")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(theme.mutedText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(theme.rowBg)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isObserved ? theme.accentBorder : theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(tooltipLines.joined(separator: "\n"))
    }
}
