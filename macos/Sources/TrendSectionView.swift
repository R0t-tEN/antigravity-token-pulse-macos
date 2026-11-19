import SwiftUI

struct TrendSectionView: View {
    let stats: ActivityStats
    let theme: PulseTheme
    @Binding var granularity: TrendGranularity
    @Binding var heatmapRange: HeatmapRangeMode
    @Binding var mode: BreakdownMode
    @Binding var selectedDateKey: String?

    @State private var selectedWeekKey: String? = nil
    @State private var viewedMonthYm: String = ""
    @State private var hoveredWeekKey: String? = nil

    private struct DailyRowItem: Identifiable {
        let dateKey: String
        let bucket: DailyBucket
        var id: String { dateKey }
    }

    private struct WeeklyRowItem: Identifiable {
        let key: String
        let shortLabel: String
        let range: String
        let startKey: String
        var inTokens: Double = 0
        var cacheTokens: Double = 0
        var outTokens: Double = 0
        var totalTokens: Double = 0
        var desktop: Double = 0
        var cli: Double = 0
        var activeDays: Int = 0
        var steps: Int = 0
        var models: [String: ModelUsage] = [:]
        var id: String { key }
        var cacheHitRate: Int {
            let d = inTokens + cacheTokens
            return d > 0 ? Int((cacheTokens / d * 100.0).rounded()) : 0
        }
    }

    private struct MonthlyRowItem: Identifiable {
        let ym: String
        var inTokens: Double = 0
        var cacheTokens: Double = 0
        var outTokens: Double = 0
        var totalTokens: Double = 0
        var desktop: Double = 0
        var cli: Double = 0
        var activeDays: Int = 0
        var steps: Int = 0
        var models: [String: ModelUsage] = [:]
        var id: String { ym }
        var cacheHitRate: Int {
            let d = inTokens + cacheTokens
            return d > 0 ? Int((cacheTokens / d * 100.0).rounded()) : 0
        }
    }

    private var activeMonthYm: String {
        if viewedMonthYm.count == 7 { return viewedMonthYm }
        return String(stats.todayKey.prefix(7))
    }

    var body: some View {
        let palette = ModelColorPalette(stats: stats)
        VStack(alignment: .leading, spacing: 10) {
            controlBar(palette: palette)

            // Dynamic Chart Area (changes completely with granularity)
            Group {
                switch granularity {
                case .day:
                    dailyChartSection(palette: palette)
                case .week:
                    weeklyChartSection(palette: palette)
                case .month:
                    monthlyChartSection(palette: palette)
                }
            }
            .padding(12)
            .background(theme.elevatedBg)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Synchronized Detail List
            detailListHeader(palette: palette)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 7) {
                    switch granularity {
                    case .day:
                        dailyListContent(palette: palette)
                    case .week:
                        weeklyListContent(palette: palette)
                    case .month:
                        monthlyListContent(palette: palette)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(height: 190)
        }
    }

    // MARK: - Control Bar

    private func controlBar(palette: ModelColorPalette) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(TrendGranularity.allCases) { g in
                    Button {
                        granularity = g
                    } label: {
                        Text(g.title)
                            .font(.system(size: 11.5, weight: granularity == g ? .medium : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(granularity == g ? theme.accentBg : Color.clear)
                            .foregroundColor(granularity == g ? theme.accent : theme.secondaryText)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                    .strokeBorder(granularity == g ? theme.accentBorder : Color.clear, lineWidth: 1)
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

            Spacer()

            if granularity == .day {
                HStack(spacing: 2) {
                    ForEach(HeatmapRangeMode.allCases) { r in
                        Button {
                            heatmapRange = r
                        } label: {
                            Text(r.title)
                                .font(.system(size: 11, weight: heatmapRange == r ? .medium : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(heatmapRange == r ? theme.accentBg : Color.clear)
                                .foregroundColor(heatmapRange == r ? theme.accent : theme.secondaryText)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(theme.elevatedBg)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            // [端侧 | 模型] switch
            HStack(spacing: 2) {
                ForEach(BreakdownMode.allCases) { m in
                    Button {
                        mode = m
                    } label: {
                        Text(m.title)
                            .font(.system(size: 11, weight: mode == m ? .medium : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(mode == m ? theme.accentBg : Color.clear)
                            .foregroundColor(mode == m ? theme.accent : theme.secondaryText)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(theme.elevatedBg)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    // MARK: - 1. Daily Chart (16w Heatmap + Spotlight OR 53w Panorama)

    @ViewBuilder
    private func dailyChartSection(palette: ModelColorPalette) -> some View {
        if heatmapRange == .weeks16 {
            HStack(alignment: .top, spacing: 16) {
                HeatmapView(
                    stats: stats,
                    theme: theme,
                    selectedDateKey: $selectedDateKey,
                    weekCount: 16,
                    cellSize: 16,
                    cellGap: 4.5,
                    showHeader: true
                )

                daySpotlightCard(dateKey: selectedDateKey ?? stats.todayKey, palette: palette)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HeatmapView(
                stats: stats,
                theme: theme,
                selectedDateKey: $selectedDateKey,
                weekCount: 53,
                cellSize: 10.6,
                cellGap: 3.0,
                showHeader: true
            )
        }
    }

    private func daySpotlightCard(dateKey: String, palette: ModelColorPalette) -> some View {
        let day = stats.days[dateKey] ?? DailyBucket()
        let isToday = dateKey == stats.todayKey
        let isPinned = selectedDateKey != nil
        let wd = TokenDateHelper.weekdayShortCN(dateKey)
        let modelEntries = TokenAggregator.sortedModelEntries(day.models)
        let compSum = max(day.totalTokens, day.inTokens + day.cacheTokens + day.outTokens)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Text("\(dateKey) · \(wd)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(theme.title)
                    if isToday {
                        tagBadge("今天")
                    } else if isPinned {
                        tagBadge("已选中")
                    }
                }
                Spacer()
                if isPinned {
                    Button {
                        selectedDateKey = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(theme.mutedText)
                    }
                    .buttonStyle(.plain)
                    .help("取消日期筛选")
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(TokenFormatter.activity(day.totalTokens))
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundColor(theme.title)
                Text("Tokens · \(day.steps) 步 · 缓存率 \(day.cacheHitRate)%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(theme.secondaryText)
            }

            // Token type micro stacked bar
            GeometryReader { geo in
                let w = max(0, geo.size.width)
                let inW = compSum > 0 ? w * CGFloat(day.inTokens / compSum) : 0
                let cacheW = compSum > 0 ? w * CGFloat(day.cacheTokens / compSum) : 0
                let outW = compSum > 0 ? max(0, w - inW - cacheW) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.trackBg)
                    if compSum > 0 {
                        HStack(spacing: 0) {
                            Rectangle().fill(theme.inputTokenColor).frame(width: inW)
                            Rectangle().fill(theme.desktopColor).frame(width: cacheW)
                            Rectangle().fill(theme.outputTokenColor).frame(width: outW)
                        }
                        .clipShape(Capsule())
                    }
                }
            }
            .frame(height: 6)

            Text("输入 \(TokenFormatter.activity(day.inTokens)) · 缓存 \(TokenFormatter.activity(day.cacheTokens)) · 输出 \(TokenFormatter.activity(day.outTokens))")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundColor(theme.mutedText)

            Divider().overlay(theme.divider)

            if modelEntries.isEmpty {
                Text("点击左侧热力图格子可查看任意日期明细")
                    .font(.system(size: 11))
                    .foregroundColor(theme.mutedText)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(modelEntries.prefix(3)), id: \.name) { entry in
                        let pct = day.totalTokens > 0 ? (entry.usage.totalTokens / day.totalTokens) * 100.0 : 0
                        HStack(spacing: 6) {
                            Circle().fill(palette.color(for: entry.name)).frame(width: 6, height: 6)
                            Text(entry.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)
                            Spacer()
                            Text("\(TokenFormatter.activity(entry.usage.totalTokens)) (\(String(format: "%.0f", pct))%)")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundColor(theme.secondaryText)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(theme.rowBg)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - 2. Weekly Stacked Bar Chart

    private func weeklyChartSection(palette: ModelColorPalette) -> some View {
        let weeks = buildChronologicalWeeks(limit: 10)
        let thisWeekKey = TokenDateHelper.isoWeekInfo(for: stats.todayKey).key
        let maxVal = max(1.0, weeks.reduce(0.0) { max($0, $1.totalTokens) })
        let barAreaHeight: CGFloat = 92

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("近 10 个 ISO 周消耗趋势（点击柱条筛选明细）")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                legendInline(palette: palette)
            }

            if weeks.allSatisfy({ $0.totalTokens <= 0 }) {
                Text("暂无周度消耗数据")
                    .font(.system(size: 12))
                    .foregroundColor(theme.mutedText)
                    .frame(maxWidth: .infinity, minHeight: 115, alignment: .center)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(weeks) { w in
                        let isCur = w.key == thisWeekKey
                        let isSel = w.key == selectedWeekKey
                        let isHovered = w.key == hoveredWeekKey
                        let totalH = w.totalTokens > 0 ? max(5, barAreaHeight * CGFloat(w.totalTokens / maxVal)) : 2

                        VStack(spacing: 4) {
                            Text(w.totalTokens > 0 ? TokenFormatter.compact(w.totalTokens) : "")
                                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                                .foregroundColor(isSel || isCur ? theme.accent : theme.mutedText)
                                .frame(height: 12)

                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(theme.trackBg.opacity(0.45))
                                    .frame(width: 28, height: barAreaHeight)

                                stackedVerticalBar(week: w, height: totalH, width: 28, palette: palette)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .strokeBorder(
                                                isSel ? theme.accent : (isHovered ? theme.cellHoverOutline : Color.clear),
                                                lineWidth: isSel ? 1.5 : 1.0
                                            )
                                    )
                            }
                            .frame(height: barAreaHeight, alignment: .bottom)

                            Text(isCur ? "本周" : w.shortLabel)
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundColor(isCur || isSel ? theme.accent : theme.mutedText)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onHover { h in
                            if h { hoveredWeekKey = w.key }
                            else if hoveredWeekKey == w.key { hoveredWeekKey = nil }
                        }
                        .onTapGesture {
                            selectedWeekKey = (selectedWeekKey == w.key) ? nil : w.key
                        }
                        .help("\(w.key) (\(w.range))\n总计: \(TokenFormatter.activity(w.totalTokens))\nDesktop \(TokenFormatter.activity(w.desktop)) · CLI \(TokenFormatter.activity(w.cli)) · 缓存率 \(w.cacheHitRate)%")
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func stackedVerticalBar(week: WeeklyRowItem, height: CGFloat, width: CGFloat, palette: ModelColorPalette) -> some View {
        if week.totalTokens <= 0 {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(theme.trackBg)
                .frame(width: width, height: 2)
        } else if mode == .model {
            let entries = TokenAggregator.sortedModelEntries(week.models)
            let sum = max(1.0, entries.reduce(0.0) { $0 + $1.usage.totalTokens })
            VStack(spacing: 0) {
                ForEach(entries.reversed(), id: \.name) { e in
                    Rectangle()
                        .fill(palette.color(for: e.name))
                        .frame(width: width, height: height * CGFloat(e.usage.totalTokens / sum))
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            let sum = max(1.0, week.desktop + week.cli)
            let dH = height * CGFloat(week.desktop / sum)
            let cH = max(0, height - dH)
            VStack(spacing: 0) {
                Rectangle().fill(theme.cliColor).frame(width: width, height: cH)
                Rectangle().fill(theme.desktopColor).frame(width: width, height: dH)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    private func buildChronologicalWeeks(limit: Int) -> [WeeklyRowItem] {
        let cal = Calendar.current
        let todayNoon = TokenDateHelper.parseDateKeyLocal(stats.todayKey, calendar: cal)
        let monIdx = TokenDateHelper.mondayBasedWeekdayIndex(todayNoon, calendar: cal)
        let thisWeekMon = TokenDateHelper.addDays(todayNoon, days: -monIdx, calendar: cal)

        var weekBuckets: [String: WeeklyRowItem] = [:]
        for (dateStr, d) in stats.days where d.totalTokens > 0 {
            let info = TokenDateHelper.isoWeekInfo(for: dateStr, calendar: cal)
            let shortLbl = String(info.key.split(separator: "-").last ?? Substring(info.key))
            var w = weekBuckets[info.key] ?? WeeklyRowItem(key: info.key, shortLabel: shortLbl, range: info.range, startKey: info.startKey)
            w.inTokens += d.inTokens
            w.cacheTokens += d.cacheTokens
            w.outTokens += d.outTokens
            w.totalTokens += d.totalTokens
            w.desktop += d.desktop
            w.cli += d.cli
            w.activeDays += 1
            w.steps += d.steps
            TokenAggregator.mergeModels(&w.models, src: d.models)
            weekBuckets[info.key] = w
        }

        var result: [WeeklyRowItem] = []
        for offset in stride(from: limit - 1, through: 0, by: -1) {
            let mon = TokenDateHelper.addDays(thisWeekMon, days: -offset * 7, calendar: cal)
            let keyStr = TokenDateHelper.formatDateKey(mon, calendar: cal)
            let info = TokenDateHelper.isoWeekInfo(for: keyStr, calendar: cal)
            let shortLbl = String(info.key.split(separator: "-").last ?? Substring(info.key))
            result.append(weekBuckets[info.key] ?? WeeklyRowItem(key: info.key, shortLabel: shortLbl, range: info.range, startKey: info.startKey))
        }
        return result
    }

    // MARK: - 3. Monthly Digital Calendar + Month Comparison

    private func monthlyChartSection(palette: ModelColorPalette) -> some View {
        let ym = activeMonthYm
        let months = buildMonthlyRows()
        let maxMonthTot = max(1.0, months.reduce(0.0) { max($0, $1.totalTokens) })

        return HStack(alignment: .top, spacing: 14) {
            // Left: Digital Calendar
            monthCalendarGrid(ym: ym)
                .frame(maxWidth: .infinity)

            // Right: Month Comparison Bars
            VStack(alignment: .leading, spacing: 7) {
                Text("月度总量对比（点击切换日历）")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                if months.isEmpty {
                    Text("暂无月度数据")
                        .font(.system(size: 11))
                        .foregroundColor(theme.mutedText)
                        .padding(.top, 18)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 6) {
                            ForEach(months.prefix(6)) { m in
                                let isActive = m.ym == ym
                                let parts = m.ym.split(separator: "-")
                                let lbl = parts.count == 2 ? "\(parts[0])/\(parts[1])" : m.ym
                                Button {
                                    viewedMonthYm = m.ym
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(lbl)
                                                .font(.system(size: 11, weight: isActive ? .semibold : .regular).monospacedDigit())
                                                .foregroundColor(isActive ? theme.accent : theme.primaryText)
                                            Spacer()
                                            Text(TokenFormatter.activity(m.totalTokens))
                                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                                .foregroundColor(theme.title)
                                        }
                                        GeometryReader { geo in
                                            let w = max(0, geo.size.width)
                                            let fillW = m.totalTokens > 0 ? max(4, w * CGFloat(m.totalTokens / maxMonthTot)) : 0
                                            ZStack(alignment: .leading) {
                                                Capsule().fill(theme.trackBg)
                                                Capsule().fill(isActive ? theme.accent : theme.desktopColor)
                                                    .frame(width: fillW)
                                            }
                                        }
                                        .frame(height: 5)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(isActive ? theme.accentBg : theme.rowBg)
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(isActive ? theme.accentBorder : theme.border, lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: 155)
                }
            }
            .frame(width: 245)
        }
    }

    private func monthCalendarGrid(ym: String) -> some View {
        let cal = Calendar.current
        let parts = ym.split(separator: "-")
        let year = Int(parts.first ?? "2026") ?? 2026
        let month = Int(parts.last ?? "1") ?? 1
        let firstDate = TokenDateHelper.parseDateKeyLocal(String(format: "%04d-%02d-01", year, month), calendar: cal)
        let daysInMonth = cal.range(of: .day, in: .month, for: firstDate)?.count ?? 30
        let leadingBlanks = TokenDateHelper.mondayBasedWeekdayIndex(firstDate, calendar: cal)
        let totalSlots = ((leadingBlanks + daysInMonth + 6) / 7) * 7
        let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
        let monthPrefix = String(format: "%04d-%02d-", year, month)
        let monthBounds = HeatScaleBounds.compute(
            from: stats.days
                .filter { $0.key.hasPrefix(monthPrefix) }
                .map { $0.value.totalTokens }
        )

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(year) 年 \(month) 月每日消费日历")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                HStack(spacing: 4) {
                    Button {
                        shiftViewedMonth(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .background(theme.rowBg)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        shiftViewedMonth(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .background(theme.rowBg)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundColor(theme.secondaryText)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                ForEach(weekdays, id: \.self) { wd in
                    Text(wd)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(theme.mutedText)
                        .frame(maxWidth: .infinity)
                }

                ForEach(0..<totalSlots, id: \.self) { slot in
                    let dayNum = slot - leadingBlanks + 1
                    if dayNum < 1 || dayNum > daysInMonth {
                        Color.clear.frame(height: 25)
                    } else {
                        let dateKey = String(format: "%04d-%02d-%02d", year, month, dayNum)
                        let dayBucket = stats.days[dateKey]
                        let tot = dayBucket?.totalTokens ?? 0
                        let isToday = dateKey == stats.todayKey
                        let level = monthBounds.level(for: tot)
                        let isHighHeat = level >= 3
                        let cellBg = tot > 0 ? theme.heatmapLevels[level] : theme.rowBg

                        VStack(spacing: 0) {
                            Text("\(dayNum)")
                                .font(.system(size: 8.5, weight: isToday ? .bold : .regular).monospacedDigit())
                                .foregroundColor(isHighHeat ? (theme.isLight ? .white : Color(hex: 0x042F2E)) : theme.mutedText)
                            Text(tot > 0 ? TokenFormatter.compact(tot) : "·")
                                .font(.system(size: 9.5, weight: tot > 0 ? .semibold : .regular).monospacedDigit())
                                .foregroundColor(isHighHeat ? (theme.isLight ? .white : Color(hex: 0x042F2E)) : (tot > 0 ? theme.title : theme.mutedText.opacity(0.45)))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 25)
                        .background(cellBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(isToday ? theme.accent : theme.border.opacity(0.5), lineWidth: isToday ? 1.2 : 0.6)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .onTapGesture {
                            if tot > 0 {
                                selectedDateKey = dateKey
                                granularity = .day
                            }
                        }
                        .help(tot > 0 ? "\(dateKey): \(TokenFormatter.activity(tot)) Tokens（点击下钻当天）" : dateKey)
                    }
                }
            }
        }
    }

    private func shiftViewedMonth(by delta: Int) {
        let cal = Calendar.current
        let parts = activeMonthYm.split(separator: "-")
        let y = Int(parts.first ?? "2026") ?? 2026
        let m = Int(parts.last ?? "1") ?? 1
        let dt = TokenDateHelper.parseDateKeyLocal(String(format: "%04d-%02d-01", y, m), calendar: cal)
        if let shifted = cal.date(byAdding: .month, value: delta, to: dt) {
            let comps = cal.dateComponents([.year, .month], from: shifted)
            viewedMonthYm = String(format: "%04d-%02d", comps.year ?? y, comps.month ?? m)
        }
    }

    // MARK: - Synchronized Detail List

    private func detailListHeader(palette: ModelColorPalette) -> some View {
        HStack {
            Text(detailTitle)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Spacer()
            legendInline(palette: palette)
        }
    }

    private var detailTitle: String {
        switch granularity {
        case .day:
            return selectedDateKey != nil ? "每日消耗明细（已高亮选中日）" : "每日消耗明细（最近 15 个活跃日）"
        case .week:
            return selectedWeekKey != nil ? "每周消耗对比（已高亮选中周）" : "每周消耗对比（最近 10 个 ISO 周）"
        case .month:
            return "每月消耗汇总"
        }
    }

    @ViewBuilder
    private func legendInline(palette: ModelColorPalette) -> some View {
        if mode == .source {
            HStack(spacing: 10) {
                legendDot(color: theme.desktopColor, label: "Desktop")
                legendDot(color: theme.cliColor, label: "CLI")
            }
        } else {
            let sorted = TokenAggregator.sortedModelEntries(stats.allTime.models)
            let top = sorted.filter { $0.name != "其他模型" && $0.name != "其他" }.prefix(3).map { $0.name }
            HStack(spacing: 8) {
                ForEach(top, id: \.self) { name in
                    legendDot(color: palette.color(for: name), label: name)
                }
                if sorted.count > top.count {
                    legendDot(color: palette.color(for: "其他"), label: "其他")
                }
            }
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 7.5, height: 7.5)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func dailyListContent(palette: ModelColorPalette) -> some View {
        let rows = buildDailyRows()
        if rows.isEmpty {
            emptyState("暂无 Token 消耗记录")
        } else {
            let maxTot = rows.reduce(0.0) { max($0, $1.bucket.totalTokens) }
            ForEach(rows) { item in
                let isToday = item.dateKey == stats.todayKey
                let isSel = item.dateKey == selectedDateKey
                let wd = TokenDateHelper.weekdayShortCN(item.dateKey)
                rowCard(
                    title: "\(item.dateKey) · \(wd)",
                    badge: isToday ? "今天" : (isSel ? "已选" : nil),
                    total: item.bucket.totalTokens,
                    maxTotal: maxTot,
                    desktop: item.bucket.desktop,
                    cli: item.bucket.cli,
                    models: item.bucket.models,
                    leftSub: "输入 \(TokenFormatter.activity(item.bucket.inTokens)) · 缓存 \(TokenFormatter.activity(item.bucket.cacheTokens)) (\(item.bucket.cacheHitRate)%) · 输出 \(TokenFormatter.activity(item.bucket.outTokens))",
                    palette: palette,
                    highlighted: isSel
                )
            }
        }
    }

    @ViewBuilder
    private func weeklyListContent(palette: ModelColorPalette) -> some View {
        let rows = buildWeeklyRowsDesc()
        if rows.isEmpty {
            emptyState("暂无每周消耗记录")
        } else {
            let thisWeekKey = TokenDateHelper.isoWeekInfo(for: stats.todayKey).key
            let maxTot = rows.reduce(0.0) { max($0, $1.totalTokens) }
            ForEach(rows) { w in
                let isCur = w.key == thisWeekKey
                let isSel = w.key == selectedWeekKey
                rowCard(
                    title: "\(w.key) (\(w.range))",
                    badge: isCur ? "本周" : (isSel ? "已选" : nil),
                    total: w.totalTokens,
                    maxTotal: maxTot,
                    desktop: w.desktop,
                    cli: w.cli,
                    models: w.models,
                    leftSub: "活跃 \(w.activeDays) 天 · 缓存率 \(w.cacheHitRate)% · 输出 \(TokenFormatter.activity(w.outTokens))",
                    palette: palette,
                    highlighted: isSel
                )
            }
        }
    }

    @ViewBuilder
    private func monthlyListContent(palette: ModelColorPalette) -> some View {
        let rows = buildMonthlyRows()
        if rows.isEmpty {
            emptyState("暂无每月消耗记录")
        } else {
            let curYm = String(stats.todayKey.prefix(7))
            let maxTot = rows.reduce(0.0) { max($0, $1.totalTokens) }
            ForEach(rows) { m in
                let parts = m.ym.split(separator: "-")
                let label = parts.count == 2 ? "\(parts[0])年\(parts[1])月" : m.ym
                let isSel = m.ym == activeMonthYm
                rowCard(
                    title: label,
                    badge: m.ym == curYm ? "本月" : nil,
                    total: m.totalTokens,
                    maxTotal: maxTot,
                    desktop: m.desktop,
                    cli: m.cli,
                    models: m.models,
                    leftSub: "输入 \(TokenFormatter.activity(m.inTokens)) · 缓存 \(TokenFormatter.activity(m.cacheTokens)) (\(m.cacheHitRate)%) · 输出 \(TokenFormatter.activity(m.outTokens)) · 活跃 \(m.activeDays) 天",
                    palette: palette,
                    highlighted: isSel
                )
            }
        }
    }

    private func buildDailyRows() -> [DailyRowItem] {
        var active = stats.days
            .filter { $0.value.totalTokens > 0 }
            .map { DailyRowItem(dateKey: $0.key, bucket: $0.value) }
            .sorted { $0.dateKey > $1.dateKey }
            .prefix(15)
            .map { $0 }

        if let sel = selectedDateKey {
            active.removeAll { $0.dateKey == sel }
            active.insert(DailyRowItem(dateKey: sel, bucket: stats.days[sel] ?? DailyBucket()), at: 0)
        }
        return active
    }

    private func buildWeeklyRowsDesc() -> [WeeklyRowItem] {
        var rows = buildChronologicalWeeks(limit: 10).filter { $0.totalTokens > 0 }.sorted { $0.startKey > $1.startKey }
        if let sel = selectedWeekKey, let idx = rows.firstIndex(where: { $0.key == sel }) {
            let item = rows.remove(at: idx)
            rows.insert(item, at: 0)
        }
        return rows
    }

    private func buildMonthlyRows() -> [MonthlyRowItem] {
        var map: [String: MonthlyRowItem] = [:]
        for (dateStr, d) in stats.days where d.totalTokens > 0 {
            let ym = String(dateStr.prefix(7))
            var m = map[ym] ?? MonthlyRowItem(ym: ym)
            m.inTokens += d.inTokens
            m.cacheTokens += d.cacheTokens
            m.outTokens += d.outTokens
            m.totalTokens += d.totalTokens
            m.desktop += d.desktop
            m.cli += d.cli
            m.activeDays += 1
            m.steps += d.steps
            TokenAggregator.mergeModels(&m.models, src: d.models)
            map[ym] = m
        }
        return Array(map.values.sorted { $0.ym > $1.ym }.prefix(12))
    }

    // MARK: - Shared Row Card

    private func rowCard(
        title: String,
        badge: String?,
        total: Double,
        maxTotal: Double,
        desktop: Double,
        cli: Double,
        models: [String: ModelUsage],
        leftSub: String,
        palette: ModelColorPalette,
        highlighted: Bool
    ) -> some View {
        let modelEntries = TokenAggregator.sortedModelEntries(models)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundColor(theme.primaryText)
                    if let badge = badge {
                        tagBadge(badge)
                    }
                }
                Spacer()
                Text(TokenFormatter.activity(total))
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundColor(theme.title)
            }

            GeometryReader { geo in
                let fullW = max(0, geo.size.width)
                let fillW = (maxTotal > 0 && total > 0) ? max(4, min(fullW, fullW * CGFloat(total / maxTotal))) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.trackBg)
                    if fillW > 0 {
                        if mode == .model && !modelEntries.isEmpty {
                            let modelSum = max(1.0, modelEntries.reduce(0.0) { $0 + $1.usage.totalTokens })
                            HStack(spacing: 0) {
                                ForEach(modelEntries, id: \.name) { entry in
                                    Rectangle()
                                        .fill(palette.color(for: entry.name))
                                        .frame(width: fillW * CGFloat(entry.usage.totalTokens / modelSum))
                                }
                            }
                            .frame(width: fillW)
                            .clipShape(Capsule())
                        } else {
                            let splitTotal = max(1.0, desktop + cli)
                            let dW = fillW * CGFloat(desktop / splitTotal)
                            let cW = max(0, fillW - dW)
                            HStack(spacing: 0) {
                                Rectangle().fill(theme.desktopColor).frame(width: dW)
                                Rectangle().fill(theme.cliColor).frame(width: cW)
                            }
                            .frame(width: fillW)
                            .clipShape(Capsule())
                        }
                    }
                }
            }
            .frame(height: 5.5)

            HStack(spacing: 8) {
                Text(leftSub)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(theme.mutedText)
                    .lineLimit(1)
                Spacer()
                if mode == .model {
                    modelSubSummary(entries: modelEntries, palette: palette)
                } else {
                    Text("Desktop \(TokenFormatter.activity(desktop)) · CLI \(TokenFormatter.activity(cli))")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundColor(theme.mutedText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(theme.rowBg)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(highlighted ? theme.accent : theme.border, lineWidth: highlighted ? 1.2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func modelSubSummary(entries: [(name: String, usage: ModelUsage)], palette: ModelColorPalette) -> some View {
        if entries.isEmpty {
            Text("暂无模型明细")
                .font(.system(size: 10.5))
                .foregroundColor(theme.mutedText)
        } else {
            HStack(spacing: 6) {
                ForEach(Array(entries.prefix(2)), id: \.name) { item in
                    HStack(spacing: 3) {
                        Circle().fill(palette.color(for: item.name)).frame(width: 5.5, height: 5.5)
                        Text("\(item.name) \(TokenFormatter.activity(item.usage.totalTokens))")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundColor(theme.mutedText)
                            .lineLimit(1)
                    }
                }
                if entries.count > 2 {
                    let rest = entries.dropFirst(2).reduce(0.0) { $0 + $1.usage.totalTokens }
                    Text("+\(entries.count - 2) (\(TokenFormatter.activity(rest)))")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundColor(theme.mutedText)
                }
            }
        }
    }

    private func tagBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 5.5)
            .padding(.vertical, 1.5)
            .background(theme.accentBg)
            .foregroundColor(theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(theme.mutedText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }
}
