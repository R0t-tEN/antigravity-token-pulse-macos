import SwiftUI

struct HeatmapCellModel: Identifiable {
    let col: Int
    let row: Int
    let dateKey: String
    let isFuture: Bool
    let monthLabel: String?
    var id: String { "\(col)-\(row)" }
}

struct HeatmapMonthMark: Identifiable {
    let col: Int
    let label: String
    var id: String { "\(col)-\(label)" }
}

struct HeatmapView: View {
    let stats: ActivityStats
    let theme: PulseTheme
    @Binding var selectedDateKey: String?
    var weekCount: Int = 53
    var cellSize: CGFloat = 11
    var cellGap: CGFloat = 3
    var showHeader: Bool = true
    var onSelectDate: ((String) -> Void)? = nil

    @State private var hoveredCell: HeatmapCellModel? = nil

    private var gridWidth: CGFloat {
        CGFloat(weekCount) * cellSize + CGFloat(max(0, weekCount - 1)) * cellGap
    }

    private var gridData: (columns: [[HeatmapCellModel]], monthMarks: [HeatmapMonthMark], bounds: HeatScaleBounds) {
        let cal = Calendar.current
        let todayKey = stats.todayKey
        let todayDt = TokenDateHelper.parseDateKeyLocal(todayKey, calendar: cal)
        let monIdx = TokenDateHelper.mondayBasedWeekdayIndex(todayDt, calendar: cal)
        let thisWeekMonday = TokenDateHelper.addDays(todayDt, days: -monIdx, calendar: cal)
        let startMonday = TokenDateHelper.addDays(thisWeekMonday, days: -(weekCount - 1) * 7, calendar: cal)

        var columns: [[HeatmapCellModel]] = []
        columns.reserveCapacity(weekCount)
        var monthMarks: [HeatmapMonthMark] = []
        var seenMonths = Set<String>()
        var visibleTotals: [Double] = []

        for col in 0..<weekCount {
            var rows: [HeatmapCellModel] = []
            rows.reserveCapacity(7)
            for row in 0..<7 {
                let cellDt = TokenDateHelper.addDays(startMonday, days: col * 7 + row, calendar: cal)
                let cellKey = TokenDateHelper.formatDateKey(cellDt, calendar: cal)
                let isFuture = cellKey > todayKey
                if !isFuture {
                    let tot = stats.days[cellKey]?.totalTokens ?? 0
                    if tot > 0 {
                        visibleTotals.append(tot)
                    }
                }
                let comps = cal.dateComponents([.year, .month, .day], from: cellDt)
                var monthLbl: String? = nil
                if !isFuture && comps.day == 1 {
                    let ym = "\(comps.year ?? 0)-\(comps.month ?? 0)"
                    if !seenMonths.contains(ym) {
                        seenMonths.insert(ym)
                        let lbl = "\(comps.month ?? 1)月"
                        monthLbl = lbl
                        monthMarks.append(HeatmapMonthMark(col: col, label: lbl))
                    }
                }
                rows.append(HeatmapCellModel(col: col, row: row, dateKey: cellKey, isFuture: isFuture, monthLabel: monthLbl))
            }
            columns.append(rows)
        }
        return (columns, monthMarks, HeatScaleBounds.compute(from: visibleTotals))
    }

    var body: some View {
        let data = gridData
        let legendHelp = data.bounds.maxPositive > 0
            ? "当前热力图相对色阶：最暗 \(TokenFormatter.activity(data.bounds.minPositive)) ～ 最亮 \(TokenFormatter.activity(data.bounds.maxPositive))"
            : "当前热力图暂无消耗数据"

        VStack(alignment: .leading, spacing: 6) {
            if showHeader {
                HStack(alignment: .center) {
                    Text("近 \(weekCount) 周活动热力图")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("少")
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.mutedText)
                        ForEach(0..<5, id: \.self) { idx in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(theme.heatmapLevels[idx])
                                .frame(width: 9, height: 9)
                        }
                        Text("多")
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.mutedText)
                    }
                    .help(legendHelp)
                }
            }

            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: cellGap) {
                        ForEach(0..<data.columns.count, id: \.self) { col in
                            VStack(spacing: cellGap) {
                                ForEach(data.columns[col]) { cell in
                                    if cell.isFuture {
                                        Color.clear
                                            .frame(width: cellSize, height: cellSize)
                                    } else {
                                        let day = stats.days[cell.dateKey] ?? DailyBucket()
                                        let isHovered = hoveredCell?.dateKey == cell.dateKey
                                        let isSelected = selectedDateKey == cell.dateKey
                                        RoundedRectangle(cornerRadius: max(2.5, cellSize * 0.22), style: .continuous)
                                            .fill(theme.heatmapColor(for: day.totalTokens, bounds: data.bounds))
                                            .frame(width: cellSize, height: cellSize)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: max(2.5, cellSize * 0.22), style: .continuous)
                                                    .strokeBorder(
                                                        isSelected ? theme.accent : (isHovered ? theme.cellHoverOutline : Color.clear),
                                                        lineWidth: isSelected ? 1.6 : 1.0
                                                    )
                                            )
                                            .contentShape(Rectangle())
                                            .onHover { hovering in
                                                if hovering {
                                                    hoveredCell = cell
                                                } else if hoveredCell?.dateKey == cell.dateKey {
                                                    hoveredCell = nil
                                                }
                                            }
                                            .onTapGesture {
                                                if selectedDateKey == cell.dateKey {
                                                    selectedDateKey = nil
                                                } else {
                                                    selectedDateKey = cell.dateKey
                                                    onSelectDate?(cell.dateKey)
                                                }
                                            }
                                    }
                                }
                            }
                            .frame(width: cellSize)
                        }
                    }

                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(width: gridWidth, height: 14)
                        ForEach(data.monthMarks) { mark in
                            let xPos = min(CGFloat(mark.col) * (cellSize + cellGap), max(0, gridWidth - 26))
                            Text(mark.label)
                                .font(.system(size: 10.5))
                                .foregroundColor(theme.mutedText)
                                .offset(x: xPos, y: 0)
                        }
                    }
                    .frame(width: gridWidth, height: 14, alignment: .topLeading)
                }

                if let cell = hoveredCell {
                    heatmapTooltip(for: cell)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: gridWidth, alignment: .leading)
        }
    }

    @ViewBuilder
    private func heatmapTooltip(for cell: HeatmapCellModel) -> some View {
        let day = stats.days[cell.dateKey] ?? DailyBucket()
        let parts = cell.dateKey.split(separator: "-")
        let dateLabel = parts.count == 3
            ? "\(Int(parts[1]) ?? 1)月\(Int(parts[2]) ?? 1)日 · \(TokenDateHelper.weekdayShortCN(cell.dateKey))"
            : cell.dateKey

        let stepDist = cellSize + cellGap
        let cellCenterX = CGFloat(cell.col) * stepDist + cellSize / 2.0
        let cellTopY = CGFloat(cell.row) * stepDist
        let showBelow = cell.row <= 2
        let tooltipWidth: CGFloat = 216
        let clampedLeft = max(0, min(max(0, gridWidth - tooltipWidth), cellCenterX - tooltipWidth / 2.0))
        let yOffset = showBelow ? (cellTopY + cellSize + 8) : max(0, cellTopY - 64)

        VStack(alignment: .leading, spacing: 2) {
            Text(dateLabel)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Text("\(TokenFormatter.activity(day.totalTokens)) Tokens")
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundColor(theme.title)
            Text("Desktop \(TokenFormatter.activity(day.desktop)) · CLI \(TokenFormatter.activity(day.cli)) · 缓存 \(day.cacheHitRate)%")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundColor(theme.mutedText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: tooltipWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.tooltipBg)
                .shadow(color: Color.black.opacity(theme.isLight ? 0.14 : 0.45), radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(theme.tooltipBorder, lineWidth: 1)
        )
        .offset(x: clampedLeft, y: yOffset)
    }
}
