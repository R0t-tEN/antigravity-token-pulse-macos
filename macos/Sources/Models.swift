import Foundation

// MARK: - Activity Cache v4 Schema

struct ModelUsage: Codable, Equatable {
    var inTokens: Double
    var cacheTokens: Double
    var outTokens: Double
    var totalTokens: Double
    var steps: Int

    enum CodingKeys: String, CodingKey {
        case inTokens = "in"
        case cacheTokens = "cache"
        case outTokens = "out"
        case totalTokens = "total"
        case steps
    }

    init(inTokens: Double = 0, cacheTokens: Double = 0, outTokens: Double = 0, totalTokens: Double = 0, steps: Int = 0) {
        self.inTokens = inTokens
        self.cacheTokens = cacheTokens
        self.outTokens = outTokens
        self.totalTokens = totalTokens
        self.steps = steps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.inTokens = (try? c.decode(Double.self, forKey: .inTokens)) ?? 0
        self.cacheTokens = (try? c.decode(Double.self, forKey: .cacheTokens)) ?? 0
        self.outTokens = (try? c.decode(Double.self, forKey: .outTokens)) ?? 0
        self.totalTokens = (try? c.decode(Double.self, forKey: .totalTokens)) ?? 0
        self.steps = (try? c.decode(Int.self, forKey: .steps)) ?? 0
    }

    mutating func add(_ other: ModelUsage) {
        inTokens += other.inTokens
        cacheTokens += other.cacheTokens
        outTokens += other.outTokens
        totalTokens += other.totalTokens
        steps += other.steps
    }
}

struct CacheDailyBucket: Codable, Equatable {
    var inTokens: Double
    var cacheTokens: Double
    var outTokens: Double
    var totalTokens: Double
    var steps: Int
    var models: [String: ModelUsage]?

    enum CodingKeys: String, CodingKey {
        case inTokens = "in"
        case cacheTokens = "cache"
        case outTokens = "out"
        case totalTokens = "total"
        case steps
        case models
    }

    init(inTokens: Double = 0, cacheTokens: Double = 0, outTokens: Double = 0, totalTokens: Double = 0, steps: Int = 0, models: [String: ModelUsage]? = [:]) {
        self.inTokens = inTokens
        self.cacheTokens = cacheTokens
        self.outTokens = outTokens
        self.totalTokens = totalTokens
        self.steps = steps
        self.models = models
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.inTokens = (try? c.decode(Double.self, forKey: .inTokens)) ?? 0
        self.cacheTokens = (try? c.decode(Double.self, forKey: .cacheTokens)) ?? 0
        self.outTokens = (try? c.decode(Double.self, forKey: .outTokens)) ?? 0
        self.totalTokens = (try? c.decode(Double.self, forKey: .totalTokens)) ?? (self.inTokens + self.cacheTokens + self.outTokens)
        self.steps = (try? c.decode(Int.self, forKey: .steps)) ?? 0
        self.models = try? c.decode([String: ModelUsage].self, forKey: .models)
    }
}

struct CacheConversationEntry: Codable, Equatable {
    var mtimeMs: Double
    var size: Int64
    var dbSize: Int64?
    var source: String?
    var title: String?
    var lastActiveMs: Double?
    var daily: [String: CacheDailyBucket]?

    init(
        mtimeMs: Double,
        size: Int64,
        dbSize: Int64? = 0,
        source: String? = "desktop",
        title: String? = nil,
        lastActiveMs: Double? = nil,
        daily: [String: CacheDailyBucket]? = [:]
    ) {
        self.mtimeMs = mtimeMs
        self.size = size
        self.dbSize = dbSize
        self.source = source
        self.title = title
        self.lastActiveMs = lastActiveMs
        self.daily = daily
    }
}

struct ActivityCacheFile: Codable, Equatable {
    var version: Int
    var conversations: [String: CacheConversationEntry]

    init(version: Int = 4, conversations: [String: CacheConversationEntry] = [:]) {
        self.version = version
        self.conversations = conversations
    }
}

// MARK: - Aggregated Dashboard Models

struct DailyBucket: Equatable {
    var inTokens: Double = 0
    var cacheTokens: Double = 0
    var outTokens: Double = 0
    var totalTokens: Double = 0
    var desktop: Double = 0
    var cli: Double = 0
    var steps: Int = 0
    var models: [String: ModelUsage] = [:]

    var cacheHitRate: Int {
        let denom = inTokens + cacheTokens
        return denom > 0 ? Int((cacheTokens / denom * 100.0).rounded()) : 0
    }
}

struct PeriodSummary: Equatable {
    var inTokens: Double = 0
    var cacheTokens: Double = 0
    var outTokens: Double = 0
    var totalTokens: Double = 0
    var desktop: Double = 0
    var cli: Double = 0
    var steps: Int = 0
    var activeDays: Int = 0
    var models: [String: ModelUsage] = [:]

    var cacheHitRate: Int {
        let denom = inTokens + cacheTokens
        return denom > 0 ? Int((cacheTokens / denom * 100.0).rounded()) : 0
    }

    mutating func add(day bucket: DailyBucket) {
        inTokens += bucket.inTokens
        cacheTokens += bucket.cacheTokens
        outTokens += bucket.outTokens
        totalTokens += bucket.totalTokens
        desktop += bucket.desktop
        cli += bucket.cli
        steps += bucket.steps
        if bucket.totalTokens > 0 {
            activeDays += 1
        }
        TokenAggregator.mergeModels(&models, src: bucket.models, fallbackIn: bucket.inTokens, fallbackCache: bucket.cacheTokens, fallbackOut: bucket.outTokens, fallbackTotal: bucket.totalTokens, fallbackSteps: bucket.steps)
    }
}

struct ConversationRecord: Identifiable, Equatable {
    let id: String // "desktop:<convId>" or "cli:<convId>"
    let convId: String
    let source: String // "desktop" or "cli"
    let title: String
    let lastActiveMs: Double
    let isRunning: Bool
    let statusText: String
    let agentName: String
    let daily: [String: CacheDailyBucket]
}

struct ConversationSummary: Identifiable, Equatable {
    let id: String
    let convId: String
    let source: String
    let title: String
    let lastActiveDate: Date
    let isRunning: Bool
    let statusText: String
    let agentName: String
    let inTokens: Double
    let cacheTokens: Double
    let outTokens: Double
    let totalTokens: Double
    let steps: Int
    let models: [String: ModelUsage]

    var primaryModel: String {
        TokenAggregator.sortedModelEntries(models).first?.name ?? "其他模型"
    }

    var cacheHitRate: Int {
        let denom = inTokens + cacheTokens
        return denom > 0 ? Int((cacheTokens / denom * 100.0).rounded()) : 0
    }
}

struct ActivityStats: Equatable {
    var todayKey: String = TokenDateHelper.localTodayKey()
    var today = PeriodSummary()
    var thisWeek = PeriodSummary()
    var thisMonth = PeriodSummary()
    var allTime = PeriodSummary()
    var totalConversations: Int = 0
    var days: [String: DailyBucket] = [:]
    var conversationRecords: [ConversationRecord] = []
    var lastUpdated: Date = Date()
    var desktopConvCount: Int = 0
    var cliConvCount: Int = 0

    func filteredComposition(range: TimeRangeFilter, sourceFilter: SourceFilter, calendar: Calendar = .current) -> (summary: PeriodSummary, conversations: [ConversationSummary]) {
        let todayNoon = TokenDateHelper.parseDateKeyLocal(todayKey, calendar: calendar)
        let monIdx = TokenDateHelper.mondayBasedWeekdayIndex(todayNoon, calendar: calendar)
        let weekStart = TokenDateHelper.addDays(todayNoon, days: -monIdx, calendar: calendar)
        let weekEnd = TokenDateHelper.addDays(weekStart, days: 6, calendar: calendar)
        let weekStartKey = TokenDateHelper.formatDateKey(weekStart, calendar: calendar)
        let weekEndKey = TokenDateHelper.formatDateKey(weekEnd, calendar: calendar)
        let monthPrefix = String(todayKey.prefix(7))

        func dayMatches(_ dayKey: String) -> Bool {
            switch range {
            case .today: return dayKey == todayKey
            case .week: return dayKey >= weekStartKey && dayKey <= weekEndKey
            case .month: return dayKey.hasPrefix(monthPrefix)
            case .all: return true
            }
        }

        var summary = PeriodSummary()
        var activeDayKeys = Set<String>()
        var convList: [ConversationSummary] = []

        for rec in conversationRecords {
            switch sourceFilter {
            case .all: break
            case .desktop: if rec.source != "desktop" { continue }
            case .cli: if rec.source != "cli" { continue }
            }

            var cIn: Double = 0
            var cCache: Double = 0
            var cOut: Double = 0
            var cTotal: Double = 0
            var cSteps = 0
            var cModels: [String: ModelUsage] = [:]

            for (dayKey, bucket) in rec.daily where dayMatches(dayKey) {
                let dTot = bucket.totalTokens > 0 ? bucket.totalTokens : (bucket.inTokens + bucket.cacheTokens + bucket.outTokens)
                guard dTot > 0 || bucket.steps > 0 else { continue }
                activeDayKeys.insert(dayKey)
                cIn += bucket.inTokens
                cCache += bucket.cacheTokens
                cOut += bucket.outTokens
                cTotal += dTot
                cSteps += bucket.steps
                TokenAggregator.mergeModels(
                    &cModels,
                    src: bucket.models,
                    fallbackIn: bucket.inTokens,
                    fallbackCache: bucket.cacheTokens,
                    fallbackOut: bucket.outTokens,
                    fallbackTotal: dTot,
                    fallbackSteps: bucket.steps
                )
            }

            guard cTotal > 0 else { continue }

            summary.inTokens += cIn
            summary.cacheTokens += cCache
            summary.outTokens += cOut
            summary.totalTokens += cTotal
            summary.steps += cSteps
            if rec.source == "cli" {
                summary.cli += cTotal
            } else {
                summary.desktop += cTotal
            }
            TokenAggregator.mergeModels(&summary.models, src: cModels)

            convList.append(ConversationSummary(
                id: rec.id,
                convId: rec.convId,
                source: rec.source,
                title: rec.title,
                lastActiveDate: Date(timeIntervalSince1970: rec.lastActiveMs / 1000.0),
                isRunning: rec.isRunning,
                statusText: rec.statusText,
                agentName: rec.agentName,
                inTokens: cIn,
                cacheTokens: cCache,
                outTokens: cOut,
                totalTokens: cTotal,
                steps: cSteps,
                models: cModels
            ))
        }

        summary.activeDays = activeDayKeys.count
        convList.sort { a, b in
            if a.totalTokens != b.totalTokens { return a.totalTokens > b.totalTokens }
            return a.lastActiveDate > b.lastActiveDate
        }
        return (summary, convList)
    }
}

struct LiveSessionStats: Identifiable, Equatable {
    var conversationId: String
    var source: String // "desktop" or "cli"
    var title: String
    var modelName: String
    var isRunning: Bool
    var statusText: String
    var agentName: String
    var parentConvId: String
    var tokensPerSecond: Int
    var cacheHitRate: Int
    var latestContextUsed: Double
    var compactedJustNow: Bool
    var cumulativePromptTokens: Double
    var cumulativeTokens: Double
    var updatedAt: Date

    var id: String { "\(source):\(conversationId)" }

    var contextPercent: Int {
        let pct = (latestContextUsed / 1_000_000.0) * 100.0
        return max(0, min(100, Int(pct.rounded())))
    }
}

enum MainWorkspaceTab: String, CaseIterable, Identifiable {
    case trend = "trend"
    case composition = "composition"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .trend: return "活动趋势"
        case .composition: return "构成与会话"
        }
    }
}

enum TrendGranularity: String, CaseIterable, Identifiable {
    case day = "day"
    case week = "week"
    case month = "month"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return "按天 · 热力图"
        case .week: return "按周 · 趋势柱"
        case .month: return "按月 · 日历图"
        }
    }
}

enum HeatmapRangeMode: String, CaseIterable, Identifiable {
    case weeks16 = "16w"
    case weeks53 = "53w"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .weeks16: return "16周"
        case .weeks53: return "53周"
        }
    }
    var weekCount: Int {
        switch self {
        case .weeks16: return 16
        case .weeks53: return 53
        }
    }
}

enum TimeRangeFilter: String, CaseIterable, Identifiable {
    case today = "today"
    case week = "week"
    case month = "month"
    case all = "all"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "今日"
        case .week: return "本周"
        case .month: return "本月"
        case .all: return "全部"
        }
    }
}

enum SourceFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case desktop = "desktop"
    case cli = "cli"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .desktop: return "Desktop"
        case .cli: return "CLI"
        }
    }
}

enum BreakdownMode: String, CaseIterable, Identifiable {
    case source = "source"
    case model = "model"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .source: return "端侧"
        case .model: return "模型"
        }
    }
}

enum ThemePreference: String, CaseIterable, Identifiable {
    case system = "system"
    case dark = "dark"
    case light = "light"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }
}

enum MenuBarLabelMode: String, CaseIterable, Identifiable {
    case todayTotal = "todayTotal"
    case liveContext = "liveContext"
    case iconOnly = "iconOnly"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .todayTotal: return "今日消耗"
        case .liveContext: return "当前会话上下文"
        case .iconOnly: return "仅显示图标"
        }
    }
}

// MARK: - Relative Heatmap Scale

struct HeatScaleBounds: Equatable {
    let minPositive: Double
    let maxPositive: Double

    static func compute<S: Sequence>(from values: S) -> HeatScaleBounds where S.Element == Double {
        var minVal = Double.infinity
        var maxVal: Double = 0
        for v in values where v > 0 {
            if v < minVal { minVal = v }
            if v > maxVal { maxVal = v }
        }
        guard maxVal > 0, minVal.isFinite else {
            return HeatScaleBounds(minPositive: 0, maxPositive: 0)
        }
        return HeatScaleBounds(minPositive: minVal, maxPositive: maxVal)
    }

    /// Maps 0 -> level 0, minPositive -> level 1, maxPositive -> level 4, intermediate values linearly across levels 1..4.
    func level(for totalTokens: Double) -> Int {
        guard totalTokens > 0, maxPositive > 0 else { return 0 }
        let span = maxPositive - minPositive
        if span <= 0 {
            return 4
        }
        let ratio = max(0.0, min(1.0, (totalTokens - minPositive) / span))
        if ratio < 0.25 { return 1 }
        if ratio < 0.50 { return 2 }
        if ratio < 0.75 { return 3 }
        return 4
    }
}

// MARK: - Formatting Utilities

enum TokenFormatter {
    static let fixedMaxContextTokens: Double = 1_000_000

    static func compact(_ num: Double) -> String {
        guard num.isFinite && num > 0 else { return "0" }
        if num >= 1_000_000 {
            let tenths = floor((num / 1_000_000.0) * 10.0 + 0.5) / 10.0
            let val = String(format: "%.1f", tenths)
            return trimTrailingDotZero(val) + "M"
        }
        if num >= 1_000 {
            return "\(Int(floor(num / 1_000.0 + 0.5)))k"
        }
        return "\(Int(floor(num + 0.5)))"
    }

    static func activity(_ num: Double) -> String {
        guard num.isFinite && num > 0 else { return "0" }
        if num >= 1e9 {
            let hundredths = floor((num / 1e9) * 100.0 + 0.5) / 100.0
            return trimTrailingZeros(String(format: "%.2f", hundredths)) + "B"
        }
        if num >= 1e6 {
            let scale = num >= 100e6 ? 10.0 : 100.0
            let fmt = num >= 100e6 ? "%.1f" : "%.2f"
            let rounded = floor((num / 1e6) * scale + 0.5) / scale
            return trimTrailingZeros(String(format: fmt, rounded)) + "M"
        }
        if num >= 1e3 {
            let tenths = floor((num / 1e3) * 10.0 + 0.5) / 10.0
            let val = String(format: "%.1f", tenths)
            return trimTrailingDotZero(val) + "k"
        }
        return "\(Int(floor(num + 0.5)))"
    }

    private static func trimTrailingDotZero(_ s: String) -> String {
        s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    private static func trimTrailingZeros(_ s: String) -> String {
        var out = s
        while out.contains(".") && out.hasSuffix("0") {
            out.removeLast()
        }
        if out.hasSuffix(".") {
            out.removeLast()
        }
        return out
    }
}

// MARK: - Date & ISO Week Helpers

enum TokenDateHelper {
    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let sqlMicroFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        return f
    }()

    private static let sqlSecFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return f
    }()

    static func parseISO8601(_ str: String?) -> Date? {
        guard var s = str?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        // Normalize SQLite datetime like "2026-11-17 04:03:58.386441+00:00"
        if s.count >= 19, s[s.index(s.startIndex, offsetBy: 10)] == " " {
            let idx = s.index(s.startIndex, offsetBy: 10)
            s.replaceSubrange(idx...idx, with: "T")
        }
        if let d = isoFractionalFormatter.date(from: s) {
            return d
        }
        if let d = isoFormatter.date(from: s) {
            return d
        }
        if let d = sqlMicroFormatter.date(from: s) {
            return d
        }
        return sqlSecFormatter.date(from: s)
    }

    static func formatDateKey(_ date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 1970
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    static func localTodayKey(now: Date = Date(), calendar: Calendar = .current) -> String {
        formatDateKey(now, calendar: calendar)
    }

    static func parseDateKeyLocal(_ dateKey: String, calendar: Calendar = .current) -> Date {
        let parts = dateKey.split(separator: "-")
        if parts.count == 3,
           let y = Int(parts[0]),
           let m = Int(parts[1]),
           let d = Int(parts[2]) {
            var comps = DateComponents()
            comps.year = y
            comps.month = m
            comps.day = d
            comps.hour = 12
            comps.minute = 0
            comps.second = 0
            if let dt = calendar.date(from: comps) {
                return dt
            }
        }
        return Date()
    }

    static func addDays(_ date: Date, days: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    /// Returns 0 for Monday .. 6 for Sunday
    static func mondayBasedWeekdayIndex(_ date: Date, calendar: Calendar = .current) -> Int {
        let wd = calendar.component(.weekday, from: date) // 1=Sun, 2=Mon, ..., 7=Sat
        return (wd + 5) % 7
    }

    static func isoWeekInfo(for dateKey: String, calendar: Calendar = .current) -> (key: String, range: String, startKey: String) {
        let d = parseDateKeyLocal(dateKey, calendar: calendar)
        let monIdx = mondayBasedWeekdayIndex(d, calendar: calendar)
        let mon = addDays(d, days: -monIdx, calendar: calendar)
        let sun = addDays(mon, days: 6, calendar: calendar)
        let thu = addDays(mon, days: 3, calendar: calendar)

        let isoYear = calendar.component(.year, from: thu)
        var jan4Comps = DateComponents()
        jan4Comps.year = isoYear
        jan4Comps.month = 1
        jan4Comps.day = 4
        jan4Comps.hour = 12
        let jan4 = calendar.date(from: jan4Comps) ?? thu
        let jan4MonIdx = mondayBasedWeekdayIndex(jan4, calendar: calendar)
        let week1Thu = addDays(jan4, days: 3 - jan4MonIdx, calendar: calendar)
        let diffDays = calendar.dateComponents([.day], from: week1Thu, to: thu).day ?? 0
        let weekNum = 1 + Int((Double(diffDays) / 7.0).rounded())

        let monComps = calendar.dateComponents([.month, .day], from: mon)
        let sunComps = calendar.dateComponents([.month, .day], from: sun)

        let key = String(format: "%04d-W%02d", isoYear, weekNum)
        let range = String(format: "%02d/%02d~%02d/%02d", monComps.month ?? 1, monComps.day ?? 1, sunComps.month ?? 1, sunComps.day ?? 1)
        let startKey = formatDateKey(mon, calendar: calendar)
        return (key, range, startKey)
    }

    static func weekdayShortCN(_ dateKey: String, calendar: Calendar = .current) -> String {
        let d = parseDateKeyLocal(dateKey, calendar: calendar)
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let wd = calendar.component(.weekday, from: d)
        return names[(wd - 1) % 7]
    }
}

// MARK: - Model Name Normalization (Matches ipc-block.js)

enum ModelNormalizer {
    private static let hexRe = try! NSRegularExpression(pattern: "^[0-9a-f]{16,64}$", options: [.caseInsensitive])
    private static let uuidRe = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: [.caseInsensitive])
    private static let parenSuffixRe = try! NSRegularExpression(
        pattern: #"\s*\((?:Extra\s+Low|Very\s+High|XHigh|High|Medium|Low|Max|Thinking|Fast|Slow|Standard|Preview|Experimental|MaaS|\d+(?:\.\d+)?\s*[KM](?:\s*context)?)\)\s*$"#,
        options: [.caseInsensitive]
    )
    private static let slugSuffixRe = try! NSRegularExpression(
        pattern: #"-(?:maas|extra[-_]low|very[-_]high|xhigh|high|medium|low|max|thinking|tiered|trial|preview|exp|latest|control|worker-agy|orchestrator-g1-pro|1m|2m|128k|200k|256k|512k|1000k|\d{4}-\d{2}-\d{2}|\d{8}|[nhabc])$"#,
        options: [.caseInsensitive]
    )
    private static let looksLikeSlugSuffixRe = try! NSRegularExpression(
        pattern: #"-(?:maas|extra[-_]low|very[-_]high|xhigh|high|medium|low|max|thinking|tiered|trial|preview|exp|latest|control|worker-agy|orchestrator-g1-pro)$"#,
        options: [.caseInsensitive]
    )
    private static let providerPrefixRe = try! NSRegularExpression(pattern: "^(?:[a-z0-9._-]+/)+", options: [.caseInsensitive])
    private static let atSuffixRe = try! NSRegularExpression(pattern: "@.*$", options: [])
    private static let atNonSpaceRe = try! NSRegularExpression(pattern: "@[^\\s()]*$", options: [])
    private static let digitSepRe = try! NSRegularExpression(pattern: "(\\d)[-_](\\d)", options: [])
    private static let orchestratorRe = try! NSRegularExpression(pattern: "^Orchestrator\\s*\\(([^)]+)\\)$", options: [.caseInsensitive])
    private static let lowerSlugRe = try! NSRegularExpression(pattern: "^[a-z0-9._-]+$", options: [])
    private static let sizeTokenRe = try! NSRegularExpression(pattern: "^\\d+(?:\\.\\d+)?[bk]$", options: [.caseInsensitive])

    static func isHexOrUuid(_ s: String) -> Bool {
        let range = NSRange(location: 0, length: s.utf16.count)
        return hexRe.firstMatch(in: s, options: [], range: range) != nil ||
               uuidRe.firstMatch(in: s, options: [], range: range) != nil
    }

    private static func replaceRegex(_ text: String, _ re: NSRegularExpression, with template: String) -> String {
        let range = NSRange(location: 0, length: text.utf16.count)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    static func stripParenSuffixes(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            let next = replaceRegex(name, parenSuffixRe, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if next == name { break }
            name = next
        }
        return name
    }

    static func normalizeSlug(_ raw: String) -> String {
        var s = stripParenSuffixes(raw)
        if s.isEmpty || isHexOrUuid(s) { return "" }
        s = replaceRegex(s, providerPrefixRe, with: "")
        s = replaceRegex(s, atSuffixRe, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || isHexOrUuid(s) { return "" }
        if s.caseInsensitiveCompare("gemini-pro-orchestrator-g1-pro") == .orderedSame {
            return "Gemini 4 Argon"
        }
        while true {
            let next = replaceRegex(s, slugSuffixRe, with: "")
            if next == s { break }
            s = next
        }
        s = replaceRegex(s, digitSepRe, with: "$1.$2")
        s = replaceRegex(s, digitSepRe, with: "$1.$2")
        let parts = s.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init).filter { !$0.isEmpty }.map { w -> String in
            if w.caseInsensitiveCompare("gpt") == .orderedSame { return "GPT" }
            if w.caseInsensitiveCompare("oss") == .orderedSame { return "OSS" }
            let r = NSRange(location: 0, length: w.utf16.count)
            if sizeTokenRe.firstMatch(in: w, options: [], range: r) != nil {
                return w.uppercased()
            }
            if let first = w.first, first.isNumber {
                return w
            }
            return w.prefix(1).uppercased() + w.dropFirst()
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeModelName(rawDisplay: String, rawInternal: String) -> String {
        let d = rawDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty && !isHexOrUuid(d) {
            var name = stripParenSuffixes(d)
            let hasWhitespace = name.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            let r = NSRange(location: 0, length: name.utf16.count)
            let looksLikeSlug = !name.isEmpty && !hasWhitespace && (
                name.contains("/") ||
                name.contains("@") ||
                looksLikeSlugSuffixRe.firstMatch(in: name, options: [], range: r) != nil ||
                (lowerSlugRe.firstMatch(in: name, options: [], range: r) != nil && name.contains("-"))
            )
            if looksLikeSlug {
                let slugRes = normalizeSlug(name)
                if !slugRes.isEmpty { return slugRes }
            }
            name = replaceRegex(name, providerPrefixRe, with: "")
            name = replaceRegex(name, atNonSpaceRe, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let nr = NSRange(location: 0, length: name.utf16.count)
            if let m = orchestratorRe.firstMatch(in: name, options: [], range: nr),
               let capRange = Range(m.range(at: 1), in: name) {
                name = "Gemini 4 " + name[capRange].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !name.isEmpty && !isHexOrUuid(name) {
                return name
            }
        }
        let intern = rawInternal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !intern.isEmpty && !isHexOrUuid(intern) {
            let res = normalizeSlug(intern)
            if !res.isEmpty { return res }
        }
        return ""
    }
}

// MARK: - Aggregation Helper

enum TokenAggregator {
    static func mergeModels(
        _ target: inout [String: ModelUsage],
        src: [String: ModelUsage]?,
        fallbackIn: Double = 0,
        fallbackCache: Double = 0,
        fallbackOut: Double = 0,
        fallbackTotal: Double = 0,
        fallbackSteps: Int = 0
    ) {
        if let src = src, !src.isEmpty {
            for (name, val) in src {
                var cur = target[name] ?? ModelUsage()
                cur.add(val)
                target[name] = cur
            }
        } else if fallbackTotal > 0 {
            let fbName = "其他模型"
            var cur = target[fbName] ?? ModelUsage()
            cur.inTokens += fallbackIn
            cur.cacheTokens += fallbackCache
            cur.outTokens += fallbackOut
            cur.totalTokens += fallbackTotal
            cur.steps += fallbackSteps
            target[fbName] = cur
        }
    }

    static func sortedModelEntries(_ models: [String: ModelUsage]) -> [(name: String, usage: ModelUsage)] {
        models
            .filter { $0.value.totalTokens > 0 }
            .map { (name: $0.key, usage: $0.value) }
            .sorted { a, b in
                if a.usage.totalTokens != b.usage.totalTokens {
                    return a.usage.totalTokens > b.usage.totalTokens
                }
                return a.name < b.name
            }
    }
}
