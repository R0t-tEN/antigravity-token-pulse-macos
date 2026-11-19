import Foundation
import Darwin
import SQLite3

final class TelemetryService {
    struct PathsConfig {
        let geminiRoot: URL
        let desktopDir: URL
        let cliHomeDir: URL
        let cachePath: URL

        static func resolve(customCliHome: String? = nil, geminiRootOverride: URL? = nil) -> PathsConfig {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let geminiRoot = geminiRootOverride ?? home.appendingPathComponent(".gemini", isDirectory: true)
            let desktopDir = geminiRoot.appendingPathComponent("antigravity", isDirectory: true)

            let cliHome: URL
            let trimmedCustom = customCliHome?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let envCli = ProcessInfo.processInfo.environment["ANTIGRAVITY_CLI_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedCustom.isEmpty {
                cliHome = URL(fileURLWithPath: (trimmedCustom as NSString).expandingTildeInPath, isDirectory: true)
            } else if !envCli.isEmpty {
                cliHome = URL(fileURLWithPath: (envCli as NSString).expandingTildeInPath, isDirectory: true)
            } else {
                cliHome = geminiRoot.appendingPathComponent("antigravity-cli", isDirectory: true)
            }

            let cachePath = geminiRoot.appendingPathComponent("telemetry-activity-cache.json", isDirectory: false)
            return PathsConfig(geminiRoot: geminiRoot, desktopDir: desktopDir, cliHomeDir: cliHome, cachePath: cachePath)
        }
    }

    struct ConversationSummaryMeta {
        let convId: String
        let title: String
        let status: String
        let notFullyIdle: Bool
        let killed: Bool
        let agentName: String
        let parentConvId: String
        let lastModifiedDate: Date?

        func isActive(now: Date, transcriptMtime: Date) -> Bool {
            if killed { return false }
            let flagged = status.localizedCaseInsensitiveContains("RUNNING") || notFullyIdle
            guard flagged else { return false }
            let refDate = lastModifiedDate.map { max($0, transcriptMtime) } ?? transcriptMtime
            return now.timeIntervalSince(refDate) <= 6 * 3600
        }

        func statusLabel(isActive: Bool) -> String {
            guard isActive else { return "空闲" }
            if status.localizedCaseInsensitiveContains("RUNNING") {
                return "运行中"
            }
            return notFullyIdle ? "子任务运行中" : "运行中"
        }
    }

    struct Snapshot {
        let activity: ActivityStats
        let liveSession: LiveSessionStats?
        let runningSessions: [LiveSessionStats]
        let recentSessions: [LiveSessionStats]
        let paths: PathsConfig
    }

    private struct TranscriptRow: Decodable {
        let type: String?
        let step_index: Int?
        let created_at: String?
        let input_tokens: Double?
        let cache_read_tokens: Double?
        let output_tokens: Double?
        let content: String?
    }

    private static let userRequestRe = try! NSRegularExpression(
        pattern: #"<USER_REQUEST>\s*([\s\S]*?)\s*</USER_REQUEST>"#,
        options: []
    )
    private static let xmlTagRe = try! NSRegularExpression(
        pattern: #"<[A-Z0-9_]+>[\s\S]*?</[A-Z0-9_]+>"#,
        options: []
    )

    private static func extractUserPromptTitle(from rawContent: String?) -> String? {
        guard let raw = rawContent?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let fullRange = NSRange(location: 0, length: raw.utf16.count)
        var text = raw
        if let m = userRequestRe.firstMatch(in: raw, options: [], range: fullRange),
           let cap = Range(m.range(at: 1), in: raw) {
            text = String(raw[cap])
        } else {
            text = xmlTagRe.stringByReplacingMatches(in: raw, options: [], range: fullRange, withTemplate: " ")
        }
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count > 48 {
            return String(collapsed.prefix(46)) + "…"
        }
        return collapsed
    }

    private static func sqliteString(_ stmt: OpaquePointer?, col: Int32) -> String {
        guard col >= 0, let ptr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sqliteBool(_ stmt: OpaquePointer?, col: Int32) -> Bool {
        guard col >= 0 else { return false }
        return sqlite3_column_int(stmt, col) != 0
    }

    private static func loadConversationSummaries(from dbURLs: [URL]) -> [String: ConversationSummaryMeta] {
        var result: [String: ConversationSummaryMeta] = [:]
        for url in dbURLs {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if readSummariesFromSqlite(path: url.path, flags: SQLITE_OPEN_READONLY, into: &result) {
                continue
            }
            // Fallback for WAL-mode DBs when `-wal` is absent (causes SQLITE_CANTOPEN on READONLY)
            // or when the writer holds an exclusive/busy WAL lock: snapshot `.db` (+ `.db-wal`) to `/tmp`.
            let _ = readSummariesViaTempSnapshot(sourceURL: url, into: &result)
        }
        return result
    }

    private static func readSummariesViaTempSnapshot(sourceURL: URL, into result: inout [String: ConversationSummaryMeta]) -> Bool {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("agy_sum_\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            return false
        }
        defer { try? fm.removeItem(at: tmpDir) }

        let tmpDbURL = tmpDir.appendingPathComponent("summaries.db", isDirectory: false)
        do {
            try fm.copyItem(at: sourceURL, to: tmpDbURL)
        } catch {
            return false
        }

        let walSourceURL = URL(fileURLWithPath: sourceURL.path + "-wal")
        if fm.fileExists(atPath: walSourceURL.path) {
            let tmpWalURL = URL(fileURLWithPath: tmpDbURL.path + "-wal")
            try? fm.copyItem(at: walSourceURL, to: tmpWalURL)
        }

        // Opening the disposable temp copy READWRITE lets SQLite create an empty `-wal` or recover copied WAL frames.
        if readSummariesFromSqlite(path: tmpDbURL.path, flags: SQLITE_OPEN_READWRITE, into: &result) {
            return true
        }

        // Last-resort immutable read if a copied WAL frame was mid-flush during file copy.
        let immutableURI = "file:\(tmpDbURL.path)?immutable=1"
        return readSummariesFromSqlite(path: immutableURI, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, into: &result)
    }

    private static func readSummariesFromSqlite(
        path: String,
        flags: Int32,
        into result: inout [String: ConversationSummaryMeta]
    ) -> Bool {
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            if let db = db { sqlite3_close(db) }
            return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)

        var availableCols = Set<String>()
        var pragmaStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(conversation_summaries)", -1, &pragmaStmt, nil) == SQLITE_OK else {
            return false
        }
        var pragmaStepRc = SQLITE_OK
        while true {
            pragmaStepRc = sqlite3_step(pragmaStmt)
            if pragmaStepRc == SQLITE_ROW {
                let colName = sqliteString(pragmaStmt, col: 1)
                if !colName.isEmpty { availableCols.insert(colName) }
            } else {
                break
            }
        }
        sqlite3_finalize(pragmaStmt)
        guard pragmaStepRc == SQLITE_DONE, availableCols.contains("conversation_id") else {
            return false
        }

        let desiredCols = [
            "conversation_id",
            "title",
            "status",
            "not_fully_idle",
            "killed",
            "agent_name",
            "parent_conversation_id",
            "last_modified_time",
        ]
        var colIndex: [String: Int32] = [:]
        var selectExprs: [String] = []
        for (idx, col) in desiredCols.enumerated() {
            if availableCols.contains(col) {
                colIndex[col] = Int32(idx)
                selectExprs.append(col)
            } else {
                colIndex[col] = -1
                selectExprs.append("'' AS \(col)")
            }
        }

        let sql = "SELECT \(selectExprs.joined(separator: ", ")) FROM conversation_summaries"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }

        var parsedRows: [ConversationSummaryMeta] = []
        var stepRc = SQLITE_OK
        while true {
            stepRc = sqlite3_step(stmt)
            if stepRc == SQLITE_ROW {
                let convId = sqliteString(stmt, col: colIndex["conversation_id"] ?? -1)
                guard !convId.isEmpty else { continue }
                let title = sqliteString(stmt, col: colIndex["title"] ?? -1)
                let status = sqliteString(stmt, col: colIndex["status"] ?? -1)
                let notFullyIdle = sqliteBool(stmt, col: colIndex["not_fully_idle"] ?? -1)
                let killed = sqliteBool(stmt, col: colIndex["killed"] ?? -1)
                let agentName = sqliteString(stmt, col: colIndex["agent_name"] ?? -1)
                let parentConvId = sqliteString(stmt, col: colIndex["parent_conversation_id"] ?? -1)
                let lastModStr = sqliteString(stmt, col: colIndex["last_modified_time"] ?? -1)
                let lastModDate = TokenDateHelper.parseISO8601(lastModStr)

                parsedRows.append(ConversationSummaryMeta(
                    convId: convId,
                    title: title,
                    status: status,
                    notFullyIdle: notFullyIdle,
                    killed: killed,
                    agentName: agentName,
                    parentConvId: parentConvId,
                    lastModifiedDate: lastModDate
                ))
            } else {
                break
            }
        }

        guard stepRc == SQLITE_DONE else {
            return false
        }
        for row in parsedRows {
            result[row.convId] = row
        }
        return true
    }

    private static func stripBom(_ s: String) -> String {
        s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
    }

    private static func isConvEntryNewer(_ candidate: CacheConversationEntry?, than current: CacheConversationEntry?) -> Bool {
        guard let candidate = candidate else { return false }
        guard let current = current else { return true }
        if candidate.mtimeMs != current.mtimeMs {
            return candidate.mtimeMs > current.mtimeMs
        }
        if candidate.size != current.size {
            return candidate.size > current.size
        }
        return (candidate.dbSize ?? 0) > (current.dbSize ?? 0)
    }

    private static func readCacheFile(at url: URL) -> ActivityCacheFile {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let rawStr = String(data: data, encoding: .utf8) else {
            return ActivityCacheFile()
        }
        let clean = stripBom(rawStr).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let cleanData = clean.data(using: .utf8) else {
            return ActivityCacheFile()
        }
        if let parsed = try? JSONDecoder().decode(ActivityCacheFile.self, from: cleanData), parsed.version == 4 {
            return parsed
        }
        return ActivityCacheFile()
    }

    private static func acquireLock(at lockPath: String, timeoutSec: TimeInterval = 1.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSec)
        let pidStr = "\(getpid())"
        while Date() < deadline {
            let fd = open(lockPath, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 {
                _ = pidStr.withCString { ptr in
                    write(fd, ptr, strlen(ptr))
                }
                close(fd)
                return true
            }
            if errno == EEXIST {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: lockPath),
                   let mod = attrs[.modificationDate] as? Date,
                   Date().timeIntervalSince(mod) > 5.0 {
                    try? FileManager.default.removeItem(atPath: lockPath)
                    continue
                }
            } else if errno != EPERM && errno != EBUSY && errno != EACCES {
                return false
            }
            Thread.sleep(forTimeInterval: Double.random(in: 0.012...0.026))
        }
        return false
    }

    private static func releaseLock(at lockPath: String) {
        try? FileManager.default.removeItem(atPath: lockPath)
    }

    private static func writeAtomic(data: Data, to targetURL: URL) throws {
        let dir = targetURL.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let tmpURL = dir.appendingPathComponent("\(targetURL.lastPathComponent).\(getpid()).\(UUID().uuidString.prefix(8)).tmp")
        defer { try? fm.removeItem(at: tmpURL) }
        try data.write(to: tmpURL, options: .atomic)
        _ = try fm.replaceItemAt(targetURL, withItemAt: tmpURL, backupItemName: nil, options: .usingNewMetadataOnly)
    }

    private struct TranscriptCandidate {
        let source: String
        let convId: String
        let transcriptURL: URL
        let dbPath: String
        let mtimeMs: Double
        let mtime: Date
    }

    static func loadSnapshot(
        customCliHome: String? = nil,
        geminiRootOverride: URL? = nil,
        pinnedConversationId: String? = nil,
        now: Date = Date()
    ) -> Snapshot {
        let paths = PathsConfig.resolve(customCliHome: customCliHome, geminiRootOverride: geminiRootOverride)
        let fm = FileManager.default
        let decoder = JSONDecoder()

        let sources: [(source: String, brainDir: URL, convDir: URL)] = [
            ("desktop", paths.desktopDir.appendingPathComponent("brain", isDirectory: true), paths.desktopDir.appendingPathComponent("conversations", isDirectory: true)),
            ("cli", paths.cliHomeDir.appendingPathComponent("brain", isDirectory: true), paths.cliHomeDir.appendingPathComponent("conversations", isDirectory: true)),
        ]

        var cache = readCacheFile(at: paths.cachePath)
        var cacheDirty = false
        var updatedKeys = Set<String>()

        var allCandidates: [TranscriptCandidate] = []

        for srcObj in sources {
            guard fm.fileExists(atPath: srcObj.brainDir.path),
                  let entries = try? fm.contentsOfDirectory(at: srcObj.brainDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                continue
            }

            for entryURL in entries {
                let isDir = (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }

                let convId = entryURL.lastPathComponent
                let transcriptURL = entryURL
                    .appendingPathComponent(".system_generated", isDirectory: true)
                    .appendingPathComponent("logs", isDirectory: true)
                    .appendingPathComponent("transcript.jsonl", isDirectory: false)

                guard let attrs = try? fm.attributesOfItem(atPath: transcriptURL.path),
                      let fType = attrs[.type] as? FileAttributeType,
                      fType == .typeRegular else {
                    continue
                }

                let mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
                let mtimeMs = (mtime.timeIntervalSince1970 * 1000.0).rounded()
                let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let dbPath = srcObj.convDir.appendingPathComponent("\(convId).db", isDirectory: false).path

                allCandidates.append(TranscriptCandidate(
                    source: srcObj.source,
                    convId: convId,
                    transcriptURL: transcriptURL,
                    dbPath: dbPath,
                    mtimeMs: mtimeMs,
                    mtime: mtime
                ))

                let key = "\(srcObj.source):\(convId)"
                let dbSize = ProtoModelScanner.dbTotalSize(at: dbPath)
                if let existing = cache.conversations[key],
                   abs(existing.mtimeMs - mtimeMs) < 1.5,
                   existing.size == fileSize,
                   (existing.dbSize ?? 0) == dbSize,
                   existing.daily != nil,
                   existing.title != nil,
                   existing.lastActiveMs != nil {
                    continue
                }

                guard let rawData = try? Data(contentsOf: transcriptURL),
                      let rawText = String(data: rawData, encoding: .utf8) else {
                    continue
                }

                let modelInfo = ProtoModelScanner.extractConvModelMap(convDbPath: dbPath)
                var daily: [String: CacheDailyBucket] = [:]
                var extractedTitle: String? = nil
                var latestRowMs: Double = mtimeMs
                var maxTimestampSeen: Double = 0
                let lines = stripBom(rawText).split(whereSeparator: \.isNewline)
                for subLine in lines {
                    let line = stripBom(String(subLine)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty,
                          let lineData = line.data(using: .utf8),
                          let row = try? decoder.decode(TranscriptRow.self, from: lineData) else {
                        continue
                    }
                    if let rowDt = TokenDateHelper.parseISO8601(row.created_at) {
                        let ms = rowDt.timeIntervalSince1970 * 1000.0
                        if ms > maxTimestampSeen { maxTimestampSeen = ms }
                    }
                    if extractedTitle == nil && row.type == "USER_INPUT" {
                        extractedTitle = extractUserPromptTitle(from: row.content)
                    }
                    guard row.type == "PLANNER_RESPONSE" || row.type == "CHECKPOINT" else { continue }
                    let inTok = row.input_tokens ?? 0
                    let cacheTok = row.cache_read_tokens ?? 0
                    let outTok = row.output_tokens ?? 0
                    let rowTotal = inTok + cacheTok + outTok
                    guard rowTotal > 0 else { continue }

                    let dt = TokenDateHelper.parseISO8601(row.created_at) ?? mtime
                    let dayKey = TokenDateHelper.formatDateKey(dt)
                    let stepIdx = row.step_index ?? 0
                    let modelName = ProtoModelScanner.resolveStepModel(stepIdx: stepIdx, modelInfo: modelInfo)

                    var bucket = daily[dayKey] ?? CacheDailyBucket()
                    bucket.inTokens += inTok
                    bucket.cacheTokens += cacheTok
                    bucket.outTokens += outTok
                    bucket.totalTokens += rowTotal
                    bucket.steps += 1

                    var modelsMap = bucket.models ?? [:]
                    var mUsage = modelsMap[modelName] ?? ModelUsage()
                    mUsage.inTokens += inTok
                    mUsage.cacheTokens += cacheTok
                    mUsage.outTokens += outTok
                    mUsage.totalTokens += rowTotal
                    mUsage.steps += 1
                    modelsMap[modelName] = mUsage
                    bucket.models = modelsMap
                    daily[dayKey] = bucket
                }

                if maxTimestampSeen > 0 {
                    latestRowMs = max(mtimeMs, maxTimestampSeen)
                }
                let finalTitle = extractedTitle ?? "会话 \(convId.prefix(8))"

                cache.conversations[key] = CacheConversationEntry(
                    mtimeMs: mtimeMs,
                    size: fileSize,
                    dbSize: modelInfo.dbSize,
                    source: srcObj.source,
                    title: finalTitle,
                    lastActiveMs: latestRowMs,
                    daily: daily
                )
                cacheDirty = true
                updatedKeys.insert(key)
            }
        }

        if cacheDirty {
            let cacheDir = paths.cachePath.deletingLastPathComponent()
            if !fm.fileExists(atPath: cacheDir.path) {
                try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            }
            let lockPath = paths.cachePath.path + ".lock"
            let hasLock = acquireLock(at: lockPath, timeoutSec: 1.0)
            defer {
                if hasLock { releaseLock(at: lockPath) }
            }
            let latestDisk = readCacheFile(at: paths.cachePath)
            for (k, v) in latestDisk.conversations {
                if !updatedKeys.contains(k) {
                    cache.conversations[k] = v
                } else if isConvEntryNewer(v, than: cache.conversations[k]) {
                    cache.conversations[k] = v
                }
            }
            if let encoded = try? JSONEncoder().encode(cache) {
                try? writeAtomic(data: encoded, to: paths.cachePath)
            }
        }

        let summariesMeta = loadConversationSummaries(from: [
            paths.desktopDir.appendingPathComponent("conversation_summaries.db", isDirectory: false),
            paths.cliHomeDir.appendingPathComponent("conversation_summaries.db", isDirectory: false),
        ])
        let activity = aggregate(cache: cache, summariesMeta: summariesMeta, now: now)

        func resolveActivityState(for cand: TranscriptCandidate) -> (isRunning: Bool, statusText: String, title: String, agentName: String, parentConvId: String) {
            let meta = summariesMeta[cand.convId]
            let key = "\(cand.source):\(cand.convId)"
            let cachedTitle = cache.conversations[key]?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let officialTitle = meta?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = (officialTitle?.isEmpty == false ? officialTitle : nil)
                ?? (cachedTitle?.isEmpty == false ? cachedTitle : nil)
                ?? (cand.source == "cli" ? "CLI 会话 \(cand.convId.prefix(8))" : "会话 \(cand.convId.prefix(8))")

            if let meta = meta {
                let active = meta.isActive(now: now, transcriptMtime: cand.mtime)
                return (active, meta.statusLabel(isActive: active), resolvedTitle, meta.agentName, meta.parentConvId)
            }
            if cand.source == "cli" && now.timeIntervalSince(cand.mtime) <= 45.0 && now.timeIntervalSince(cand.mtime) >= -10.0 {
                return (true, "活跃中", resolvedTitle, "", "")
            }
            return (false, "空闲", resolvedTitle, "", "")
        }

        let sortedCandidates = allCandidates.sorted { $0.mtimeMs > $1.mtimeMs }
        var selectedCandidates: [TranscriptCandidate] = []
        var selectedKeys = Set<String>()

        for cand in sortedCandidates {
            let state = resolveActivityState(for: cand)
            if state.isRunning {
                let key = "\(cand.source):\(cand.convId)"
                if selectedKeys.insert(key).inserted {
                    selectedCandidates.append(cand)
                }
            }
        }
        if let pin = pinnedConversationId, !pin.isEmpty {
            if let pinnedCand = sortedCandidates.first(where: { $0.convId == pin || "\($0.source):\($0.convId)" == pin }) {
                let key = "\(pinnedCand.source):\(pinnedCand.convId)"
                if selectedKeys.insert(key).inserted {
                    selectedCandidates.append(pinnedCand)
                }
            }
        }
        var recentAdded = 0
        for cand in sortedCandidates {
            if selectedCandidates.count >= 12 || recentAdded >= 6 { break }
            let key = "\(cand.source):\(cand.convId)"
            if selectedKeys.insert(key).inserted {
                selectedCandidates.append(cand)
                recentAdded += 1
            }
        }

        var parsedSessions: [LiveSessionStats] = []
        parsedSessions.reserveCapacity(selectedCandidates.count)
        for cand in selectedCandidates {
            let state = resolveActivityState(for: cand)
            if let live = parseLiveSession(
                source: cand.source,
                convId: cand.convId,
                title: state.title,
                isRunning: state.isRunning,
                statusText: state.statusText,
                agentName: state.agentName,
                parentConvId: state.parentConvId,
                transcriptURL: cand.transcriptURL,
                dbPath: cand.dbPath,
                mtime: cand.mtime
            ) {
                parsedSessions.append(live)
            }
        }

        let runningSessions = parsedSessions
            .filter { $0.isRunning }
            .sorted { $0.updatedAt > $1.updatedAt }
        let idleSessions = parsedSessions
            .filter { !$0.isRunning }
            .sorted { $0.updatedAt > $1.updatedAt }
        let recentSessions = Array((runningSessions + idleSessions).prefix(8))

        let liveSession: LiveSessionStats?
        if let pin = pinnedConversationId, !pin.isEmpty,
           let matched = parsedSessions.first(where: { $0.conversationId == pin || $0.id == pin }) {
            liveSession = matched
        } else {
            liveSession = runningSessions.first ?? recentSessions.first
        }

        return Snapshot(
            activity: activity,
            liveSession: liveSession,
            runningSessions: runningSessions,
            recentSessions: recentSessions,
            paths: paths
        )
    }

    static func aggregate(cache: ActivityCacheFile, summariesMeta: [String: ConversationSummaryMeta] = [:], now: Date = Date(), calendar: Calendar = .current) -> ActivityStats {
        var days: [String: DailyBucket] = [:]
        var conversationRecords: [ConversationRecord] = []
        var totalConversations = 0
        var desktopConvCount = 0
        var cliConvCount = 0

        for (key, conv) in cache.conversations {
            guard let convDaily = conv.daily else { continue }
            let isCli = (conv.source == "cli") || (conv.source == nil && key.hasPrefix("cli:"))
            let sourceName = isCli ? "cli" : "desktop"
            let convId = key.contains(":") ? String(key.split(separator: ":", maxSplits: 1)[1]) : key
            var convHasTokens = false

            for (dayKey, d) in convDaily {
                let dTotal = d.totalTokens > 0 ? d.totalTokens : (d.inTokens + d.cacheTokens + d.outTokens)
                guard dTotal > 0 || d.steps > 0 else { continue }
                convHasTokens = true

                var bucket = days[dayKey] ?? DailyBucket()
                bucket.inTokens += d.inTokens
                bucket.cacheTokens += d.cacheTokens
                bucket.outTokens += d.outTokens
                bucket.totalTokens += dTotal
                bucket.steps += d.steps
                if isCli {
                    bucket.cli += dTotal
                } else {
                    bucket.desktop += dTotal
                }
                TokenAggregator.mergeModels(
                    &bucket.models,
                    src: d.models,
                    fallbackIn: d.inTokens,
                    fallbackCache: d.cacheTokens,
                    fallbackOut: d.outTokens,
                    fallbackTotal: dTotal,
                    fallbackSteps: d.steps
                )
                days[dayKey] = bucket
            }

            if convHasTokens {
                totalConversations += 1
                if isCli { cliConvCount += 1 } else { desktopConvCount += 1 }
                let meta = summariesMeta[convId]
                let officialTitle = meta?.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackPromptTitle = conv.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedTitle = (officialTitle?.isEmpty == false ? officialTitle : nil)
                    ?? (fallbackPromptTitle?.isEmpty == false ? fallbackPromptTitle : nil)
                    ?? (isCli ? "CLI 会话 \(convId.prefix(8))" : "会话 \(convId.prefix(8))")
                let resolvedLastMs = conv.lastActiveMs ?? conv.mtimeMs
                let mtimeDate = Date(timeIntervalSince1970: conv.mtimeMs / 1000.0)
                let isRunning: Bool
                let statusText: String
                if let meta = meta {
                    isRunning = meta.isActive(now: now, transcriptMtime: mtimeDate)
                    statusText = meta.statusLabel(isActive: isRunning)
                } else if isCli && now.timeIntervalSince(mtimeDate) <= 45.0 && now.timeIntervalSince(mtimeDate) >= -10.0 {
                    isRunning = true
                    statusText = "活跃中"
                } else {
                    isRunning = false
                    statusText = "空闲"
                }
                conversationRecords.append(ConversationRecord(
                    id: key,
                    convId: convId,
                    source: sourceName,
                    title: resolvedTitle,
                    lastActiveMs: resolvedLastMs,
                    isRunning: isRunning,
                    statusText: statusText,
                    agentName: meta?.agentName ?? "",
                    daily: convDaily
                ))
            }
        }

        let todayKey = TokenDateHelper.localTodayKey(now: now, calendar: calendar)
        let todayNoon = TokenDateHelper.parseDateKeyLocal(todayKey, calendar: calendar)
        let monIdx = TokenDateHelper.mondayBasedWeekdayIndex(todayNoon, calendar: calendar)
        let weekStart = TokenDateHelper.addDays(todayNoon, days: -monIdx, calendar: calendar)
        let weekEnd = TokenDateHelper.addDays(weekStart, days: 6, calendar: calendar)
        let weekStartKey = TokenDateHelper.formatDateKey(weekStart, calendar: calendar)
        let weekEndKey = TokenDateHelper.formatDateKey(weekEnd, calendar: calendar)
        let monthPrefix = String(todayKey.prefix(7))

        var today = PeriodSummary()
        var thisWeek = PeriodSummary()
        var thisMonth = PeriodSummary()
        var allTime = PeriodSummary()

        for (dayKey, bucket) in days {
            allTime.add(day: bucket)
            if dayKey == todayKey {
                today.add(day: bucket)
            }
            if dayKey >= weekStartKey && dayKey <= weekEndKey {
                thisWeek.add(day: bucket)
            }
            if dayKey.hasPrefix(monthPrefix) {
                thisMonth.add(day: bucket)
            }
        }

        return ActivityStats(
            todayKey: todayKey,
            today: today,
            thisWeek: thisWeek,
            thisMonth: thisMonth,
            allTime: allTime,
            totalConversations: totalConversations,
            days: days,
            conversationRecords: conversationRecords,
            lastUpdated: now,
            desktopConvCount: desktopConvCount,
            cliConvCount: cliConvCount
        )
    }

    static func parseLiveSession(
        source: String,
        convId: String,
        title: String = "",
        isRunning: Bool = false,
        statusText: String = "空闲",
        agentName: String = "",
        parentConvId: String = "",
        transcriptURL: URL,
        dbPath: String,
        mtime: Date
    ) -> LiveSessionStats? {
        guard let data = try? Data(contentsOf: transcriptURL),
              let rawText = String(data: data, encoding: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()
        let lines = stripBom(rawText).split(whereSeparator: \.isNewline)
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(lines.count)
        for sub in lines {
            let line = stripBom(String(sub)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let d = line.data(using: .utf8),
                  let r = try? decoder.decode(TranscriptRow.self, from: d) else {
                continue
            }
            rows.append(r)
        }

        let modelInfo = ProtoModelScanner.extractConvModelMap(convDbPath: dbPath)
        var sumInput: Double = 0
        var sumCache: Double = 0
        var sumOutput: Double = 0
        var latestStepTps = 0
        var baseInstructionTokens: Double = 16_000
        var firstPlannerSeen = false
        var latestPlanner: (inTok: Double, cacheTok: Double, outTok: Double, stepIdx: Int)? = nil
        var compactedContextUsed: Double? = nil
        var latestStepIdx = 0

        let mtimeMs = mtime.timeIntervalSince1970 * 1000.0

        for i in 0..<rows.count {
            let row = rows[i]
            if row.type == "PLANNER_RESPONSE" {
                let inTok = row.input_tokens ?? 0
                let cacheTok = row.cache_read_tokens ?? 0
                let outTok = row.output_tokens ?? 0
                if !firstPlannerSeen && (inTok + cacheTok > 0) {
                    firstPlannerSeen = true
                    baseInstructionTokens = min(25_000, inTok + cacheTok)
                }
                sumInput += inTok
                sumCache += cacheTok
                sumOutput += outTok

                if outTok > 0, let dt0 = TokenDateHelper.parseISO8601(row.created_at) {
                    let t0 = dt0.timeIntervalSince1970 * 1000.0
                    let t1: Double
                    if i + 1 < rows.count,
                       rows[i + 1].type != "USER_INPUT",
                       let dt1 = TokenDateHelper.parseISO8601(rows[i + 1].created_at) {
                        t1 = dt1.timeIntervalSince1970 * 1000.0
                    } else if i == rows.count - 1 {
                        t1 = mtimeMs
                    } else {
                        t1 = 0
                    }
                    if t1 > t0 {
                        let elapsed = (t1 - t0) / 1000.0
                        if elapsed >= 0.4 && elapsed <= 180.0 {
                            let stepTps = outTok / elapsed
                            if stepTps >= 5.0 && stepTps <= 350.0 {
                                latestStepTps = max(1, min(350, Int(stepTps.rounded())))
                            }
                        }
                    }
                }

                let stepIdx = row.step_index ?? 0
                latestStepIdx = stepIdx
                latestPlanner = (inTok, cacheTok, outTok, stepIdx)
                compactedContextUsed = nil
            } else if row.type == "CHECKPOINT" {
                let cpIn = row.input_tokens ?? 0
                let cpCache = row.cache_read_tokens ?? 0
                let cpOut = row.output_tokens ?? 0
                sumInput += cpIn
                sumCache += cpCache
                sumOutput += cpOut
                let summaryTokens = cpOut > 0 ? cpOut : (Double((row.content ?? "").count) / 3.6).rounded()
                compactedContextUsed = baseInstructionTokens + summaryTokens
                if let sIdx = row.step_index {
                    latestStepIdx = sIdx
                }
            }
        }

        let cumulativePrompt = sumInput + sumCache
        let cacheHitRate = cumulativePrompt > 0 ? Int(((sumCache / cumulativePrompt) * 100.0).rounded()) : 0
        var latestContextUsed: Double = 0
        if let compacted = compactedContextUsed {
            latestContextUsed = compacted
        } else if let lp = latestPlanner {
            latestContextUsed = lp.inTok + lp.cacheTok + lp.outTok
        }

        let cumulativeTokens = sumInput + sumCache + sumOutput
        let modelName = ProtoModelScanner.resolveStepModel(stepIdx: latestStepIdx, modelInfo: modelInfo)

        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "会话 \(convId.prefix(8))"
            : title

        return LiveSessionStats(
            conversationId: convId,
            source: source,
            title: resolvedTitle,
            modelName: modelName,
            isRunning: isRunning,
            statusText: statusText,
            agentName: agentName,
            parentConvId: parentConvId,
            tokensPerSecond: latestStepTps,
            cacheHitRate: cacheHitRate,
            latestContextUsed: latestContextUsed,
            compactedJustNow: compactedContextUsed != nil,
            cumulativePromptTokens: cumulativePrompt,
            cumulativeTokens: cumulativeTokens,
            updatedAt: mtime
        )
    }
}
