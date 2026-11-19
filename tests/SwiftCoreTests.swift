import Foundation
import SQLite3

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String, file: String = #file, line: Int = #line) {
    if actual != expected {
        fputs("FAIL [\(file):\(line)] \(label): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

func assertTrue(_ cond: Bool, _ label: String, file: String = #file, line: Int = #line) {
    if !cond {
        fputs("FAIL [\(file):\(line)] \(label)\n", stderr)
        exit(1)
    }
}

func testFormatters() {
    assertEqual(TokenFormatter.compact(0), "0", "compact 0")
    assertEqual(TokenFormatter.compact(850), "850", "compact 850")
    assertEqual(TokenFormatter.compact(1500), "2k", "compact 1500")
    assertEqual(TokenFormatter.compact(1_000_000), "1M", "compact 1M")
    assertEqual(TokenFormatter.compact(1_250_000), "1.3M", "compact 1.25M")

    assertEqual(TokenFormatter.activity(0), "0", "activity 0")
    assertEqual(TokenFormatter.activity(1500), "1.5k", "activity 1.5k")
    assertEqual(TokenFormatter.activity(1_250_000), "1.25M", "activity 1.25M")
    assertEqual(TokenFormatter.activity(150_000_000), "150M", "activity 150M")
    assertEqual(TokenFormatter.activity(1_234_000_000), "1.23B", "activity 1.23B")
}

func testModelNormalization() {
    assertEqual(
        ModelNormalizer.normalizeModelName(rawDisplay: "Gemini 4 Hydrogen (XHigh)", rawInternal: ""),
        "Gemini 4 Hydrogen",
        "strip XHigh paren suffix"
    )
    assertEqual(
        ModelNormalizer.normalizeModelName(rawDisplay: "", rawInternal: "anthropic/claude-opus-4-6-thinking@default"),
        "Claude Opus 4.6",
        "normalize internal slug"
    )
    assertEqual(
        ModelNormalizer.normalizeModelName(rawDisplay: "", rawInternal: "gemini-pro-orchestrator-g1-pro"),
        "Gemini 4 Argon",
        "orchestrator g1 pro special mapping"
    )
    assertEqual(
        ModelNormalizer.normalizeModelName(rawDisplay: "Orchestrator (Argon)", rawInternal: ""),
        "Gemini 4 Argon",
        "Orchestrator display mapping"
    )
    assertEqual(
        ModelNormalizer.normalizeModelName(rawDisplay: "", rawInternal: "gpt-oss-120b-maas"),
        "GPT OSS 120B",
        "GPT OSS 120B"
    )
    assertEqual(
        ModelNormalizer.normalizeModelName(rawDisplay: "deadbeefdeadbeefdeadbeef", rawInternal: ""),
        "",
        "ignore hex string"
    )
}

func testDateAndIsoWeek() {
    let d1 = TokenDateHelper.parseISO8601("2026-11-16T14:44:33Z")
    assertTrue(d1 != nil, "parse UTC ISO8601")
    let d2 = TokenDateHelper.parseISO8601("2026-11-16T14:44:33.123Z")
    assertTrue(d2 != nil, "parse fractional ISO8601")

    let w1 = TokenDateHelper.isoWeekInfo(for: "2026-11-16")
    assertEqual(w1.key, "2026-W47", "2026-11-16 ISO week")
    assertEqual(w1.range, "11/16~11/22", "2026-11-16 ISO week range")
    assertEqual(w1.startKey, "2026-11-16", "2026-11-16 ISO week start")

    let wBoundary = TokenDateHelper.isoWeekInfo(for: "2025-12-31")
    assertEqual(wBoundary.key, "2026-W01", "2025-12-31 belongs to 2026-W01")

    let mon = TokenDateHelper.parseDateKeyLocal("2026-11-16")
    assertEqual(TokenDateHelper.mondayBasedWeekdayIndex(mon), 0, "Monday index is 0")
    let sun = TokenDateHelper.parseDateKeyLocal("2026-11-22")
    assertEqual(TokenDateHelper.mondayBasedWeekdayIndex(sun), 6, "Sunday index is 6")
}

func makeProtoRecord(step: Int, internalSlug: String, displayName: String) -> Data {
    var d = Data()
    // prefix noise
    d.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
    // 0x9a 0x01 <len> <internalSlug>
    let slugBytes = Array(internalSlug.utf8)
    d.append(contentsOf: [0x9a, 0x01, UInt8(slugBytes.count)])
    d.append(contentsOf: slugBytes)
    d.append(contentsOf: [0x08, 0x10])
    // needle \x0flast_step_index\x12 <vlen> <stepDigits>
    let stepBytes = Array(String(step).utf8)
    d.append(0x0f)
    d.append(contentsOf: Array("last_step_index".utf8))
    d.append(0x12)
    d.append(UInt8(stepBytes.count))
    d.append(contentsOf: stepBytes)
    // 0xaa 0x01 <len> <displayName>
    let dispBytes = Array(displayName.utf8)
    d.append(contentsOf: [0xaa, 0x01, UInt8(dispBytes.count)])
    d.append(contentsOf: dispBytes)
    d.append(contentsOf: [0x00, 0x00])
    return d
}

func testProtoModelScannerAndTelemetryService() throws {
    let fm = FileManager.default
    let tmpRoot = fm.temporaryDirectory.appendingPathComponent("agy_swift_test_\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: tmpRoot) }

    let desktopConvId = "conv-desktop-1"
    let cliConvId = "conv-cli-1"

    let desktopLogs = tmpRoot
        .appendingPathComponent("antigravity/brain/\(desktopConvId)/.system_generated/logs", isDirectory: true)
    let desktopConvs = tmpRoot.appendingPathComponent("antigravity/conversations", isDirectory: true)
    let cliHome = tmpRoot.appendingPathComponent("antigravity-cli", isDirectory: true)
    let cliLogs = cliHome.appendingPathComponent("brain/\(cliConvId)/.system_generated/logs", isDirectory: true)
    let cliConvs = cliHome.appendingPathComponent("conversations", isDirectory: true)

    try fm.createDirectory(at: desktopLogs, withIntermediateDirectories: true)
    try fm.createDirectory(at: desktopConvs, withIntermediateDirectories: true)
    try fm.createDirectory(at: cliLogs, withIntermediateDirectories: true)
    try fm.createDirectory(at: cliConvs, withIntermediateDirectories: true)

    // Write binary db & wal for desktop
    let dbData = makeProtoRecord(step: 1, internalSlug: "gemini-4-hydrogen-xhigh", displayName: "Gemini 4 Hydrogen (XHigh)")
    try dbData.write(to: desktopConvs.appendingPathComponent("\(desktopConvId).db"))
    let walData = makeProtoRecord(step: 5, internalSlug: "claude-sonnet-4-5-thinking", displayName: "Claude Sonnet 4.5 (Thinking)")
    try walData.write(to: desktopConvs.appendingPathComponent("\(desktopConvId).db-wal"))

    let modelInfo = ProtoModelScanner.extractConvModelMap(convDbPath: desktopConvs.appendingPathComponent("\(desktopConvId).db").path)
    assertEqual(modelInfo.stepMap[1], "Gemini 4 Hydrogen", "db step 1 model")
    assertEqual(modelInfo.stepMap[5], "Claude Sonnet 4.5", "wal step 5 model")
    assertEqual(ProtoModelScanner.resolveStepModel(stepIdx: 3, modelInfo: modelInfo), "Gemini 4 Hydrogen", "interpolated step 3")
    assertEqual(ProtoModelScanner.resolveStepModel(stepIdx: 6, modelInfo: modelInfo), "Claude Sonnet 4.5", "interpolated step 6")

    // Fixed now: 2026-11-16T12:00:00Z
    let now = TokenDateHelper.parseISO8601("2026-11-16T12:00:00Z")!

    let desktopTranscript = [
        #"{"step_index":0,"type":"USER_INPUT","created_at":"2026-11-16T10:00:00Z","content":"<USER_REQUEST>\n构建 macOS 热力图\n</USER_REQUEST>\n<ADDITIONAL_METADATA>ignored</ADDITIONAL_METADATA>"}"#,
        #"{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-11-16T10:00:01Z","input_tokens":1000,"cache_read_tokens":9000,"output_tokens":500}"#,
        #"{"step_index":2,"type":"GENERIC","created_at":"2026-11-16T10:00:06Z","content":"done"}"#,
        #"{"step_index":5,"type":"PLANNER_RESPONSE","created_at":"2026-11-16T10:01:00Z","input_tokens":2000,"cache_read_tokens":18000,"output_tokens":1000}"#,
    ].joined(separator: "\n") + "\n"
    try desktopTranscript.write(to: desktopLogs.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

    let cliDb = makeProtoRecord(step: 1, internalSlug: "gemini-pro-orchestrator-g1-pro", displayName: "")
    try cliDb.write(to: cliConvs.appendingPathComponent("\(cliConvId).db"))
    let cliTranscript = [
        #"{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-11-15T10:00:00Z","input_tokens":500,"cache_read_tokens":1500,"output_tokens":200}"#,
    ].joined(separator: "\n") + "\n"
    try cliTranscript.write(to: cliLogs.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

    // Pre-populate an external CLI entry in cache to verify preservation
    let preCache = ActivityCacheFile(version: 4, conversations: [
        "cli:archived-conv": CacheConversationEntry(
            mtimeMs: 1_700_000_000_000,
            size: 123,
            dbSize: 0,
            source: "cli",
            daily: [
                "2026-11-14": CacheDailyBucket(
                    inTokens: 100,
                    cacheTokens: 200,
                    outTokens: 50,
                    totalTokens: 350,
                    steps: 1,
                    models: ["Gemini 4 Argon": ModelUsage(inTokens: 100, cacheTokens: 200, outTokens: 50, totalTokens: 350, steps: 1)]
                )
            ]
        )
    ])
    let cacheURL = tmpRoot.appendingPathComponent("telemetry-activity-cache.json")
    try JSONEncoder().encode(preCache).write(to: cacheURL)

    let snapshot = TelemetryService.loadSnapshot(customCliHome: cliHome.path, geminiRootOverride: tmpRoot, now: now)
    assertEqual(snapshot.activity.totalConversations, 3, "total conversations including archived")
    assertEqual(snapshot.activity.today.desktop, 31500, "today desktop tokens (10500 + 21000)")
    assertEqual(snapshot.activity.today.cli, 0, "today cli tokens")
    assertEqual(snapshot.activity.allTime.desktop, 31500, "allTime desktop tokens")
    assertEqual(snapshot.activity.allTime.cli, 2550, "allTime cli tokens (2200 + 350)")
    assertEqual(snapshot.activity.allTime.totalTokens, 34050, "allTime total tokens")
    assertEqual(snapshot.activity.allTime.models["Gemini 4 Hydrogen"]?.totalTokens, 10500, "Gemini 4 Hydrogen tokens")
    assertEqual(snapshot.activity.allTime.models["Claude Sonnet 4.5"]?.totalTokens, 21000, "Claude Sonnet 4.5 tokens")
    assertEqual(snapshot.activity.allTime.models["Gemini 4 Argon"]?.totalTokens, 2550, "Gemini 4 Argon tokens")

    assertTrue(fm.fileExists(atPath: cacheURL.path), "telemetry-activity-cache.json created")
    let savedData = try Data(contentsOf: cacheURL)
    let savedCache = try JSONDecoder().decode(ActivityCacheFile.self, from: savedData)
    assertTrue(savedCache.conversations["cli:archived-conv"] != nil, "archived cli entry preserved")
    assertTrue(savedCache.conversations["desktop:\(desktopConvId)"] != nil, "desktop entry saved")
    assertTrue(savedCache.conversations["cli:\(cliConvId)"] != nil, "cli entry saved")

    // Verify full conversation list sorted descending + period & source filtering
    let allComp = snapshot.activity.filteredComposition(range: .all, sourceFilter: .all)
    assertEqual(allComp.conversations.count, 3, "all conversations returned")
    assertEqual(allComp.conversations[0].totalTokens, 31500, "top conversation sorted first")
    assertEqual(allComp.conversations[0].title, "构建 macOS 热力图", "extracted USER_REQUEST title")
    assertEqual(allComp.conversations[1].totalTokens, 2200, "second conversation sorted second")
    assertEqual(allComp.conversations[2].totalTokens, 350, "third conversation sorted third")

    let todayComp = snapshot.activity.filteredComposition(range: .today, sourceFilter: .all)
    assertEqual(todayComp.conversations.count, 1, "today filtered conversations count")
    assertEqual(todayComp.summary.totalTokens, 31500, "today filtered summary total")

    let cliComp = snapshot.activity.filteredComposition(range: .all, sourceFilter: .cli)
    assertEqual(cliComp.conversations.count, 2, "cli filtered conversations count")
    assertEqual(cliComp.summary.cli, 2550, "cli filtered summary total")

    // Verify conversation_summaries.db overrides USER_INPUT title and updates without transcript edits
    let summaryDbURL = tmpRoot.appendingPathComponent("antigravity/conversation_summaries.db")
    var sumDb: OpaquePointer?
    assertEqual(sqlite3_open(summaryDbURL.path, &sumDb), SQLITE_OK, "create test conversation_summaries.db")
    let createSql = "CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '');"
    assertEqual(sqlite3_exec(sumDb, createSql, nil, nil, nil), SQLITE_OK, "create conversation_summaries table")
    let insertSql = "INSERT INTO conversation_summaries (conversation_id, title) VALUES ('\(desktopConvId)', '我的重命名对话');"
    assertEqual(sqlite3_exec(sumDb, insertSql, nil, nil, nil), SQLITE_OK, "insert initial summary title")
    sqlite3_close(sumDb)

    let snapRenamed1 = TelemetryService.loadSnapshot(customCliHome: cliHome.path, geminiRootOverride: tmpRoot, now: now)
    let compRenamed1 = snapRenamed1.activity.filteredComposition(range: .all, sourceFilter: .all)
    assertEqual(compRenamed1.conversations[0].title, "我的重命名对话", "summary db title overrides prompt title")

    var sumDb2: OpaquePointer?
    assertEqual(sqlite3_open(summaryDbURL.path, &sumDb2), SQLITE_OK, "reopen test conversation_summaries.db")
    let updateSql = "UPDATE conversation_summaries SET title = '改名后的新标题' WHERE conversation_id = '\(desktopConvId)';"
    assertEqual(sqlite3_exec(sumDb2, updateSql, nil, nil, nil), SQLITE_OK, "update summary title")
    sqlite3_close(sumDb2)

    let snapRenamed2 = TelemetryService.loadSnapshot(customCliHome: cliHome.path, geminiRootOverride: tmpRoot, now: now)
    let compRenamed2 = snapRenamed2.activity.filteredComposition(range: .all, sourceFilter: .all)
    assertEqual(compRenamed2.conversations[0].title, "改名后的新标题", "live rename picked up on cache hit")
}

func testRelativeHeatScaleBounds() {
    let bounds = HeatScaleBounds.compute(from: [0, 223_000, 9_920_000, 19_190_000])
    assertEqual(bounds.minPositive, 223_000, "minPositive ignores zero")
    assertEqual(bounds.maxPositive, 19_190_000, "maxPositive matches max")
    assertEqual(bounds.level(for: 0), 0, "unused day stays level 0")
    assertEqual(bounds.level(for: 223_000), 1, "min positive day gets darkest active level 1")
    assertEqual(bounds.level(for: 9_920_000), 3, "mid day scales proportionally to level 3")
    assertEqual(bounds.level(for: 19_190_000), 4, "max day gets brightest level 4")

    let singleDay = HeatScaleBounds.compute(from: [0, 5_000_000])
    assertEqual(singleDay.level(for: 5_000_000), 4, "single active day gets brightest level 4")
    assertEqual(singleDay.level(for: 0), 0, "single active day zero stays level 0")
}

func testMultiTaskParallelMonitoring() throws {
    // Verify SQLite microsecond timestamp parsing ('YYYY-MM-DD HH:MM:SS.SSSSSS+00:00')
    let parsedSqlTs = TokenDateHelper.parseISO8601("2026-11-17 04:03:58.386441+00:00")
    assertTrue(parsedSqlTs != nil, "parse SQLite microsecond timestamp")
    let expectedSec = TokenDateHelper.parseISO8601("2026-11-17T04:03:58Z")!
    assertTrue(abs((parsedSqlTs?.timeIntervalSince(expectedSec) ?? 999) - 0.386441) < 0.01, "SQLite fractional seconds preserved")

    let fm = FileManager.default
    let tmpRoot = fm.temporaryDirectory.appendingPathComponent("agy_parallel_test_\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: tmpRoot) }

    let cliHome = tmpRoot.appendingPathComponent("antigravity-cli", isDirectory: true)
    try fm.createDirectory(at: cliHome, withIntermediateDirectories: true)
    let antigravityDir = tmpRoot.appendingPathComponent("antigravity", isDirectory: true)
    try fm.createDirectory(at: antigravityDir, withIntermediateDirectories: true)

    let now = TokenDateHelper.parseISO8601("2026-11-16T12:00:00Z")!
    let specs: [(id: String, ageSec: TimeInterval, tokens: Int)] = [
        ("conv-main", 10, 10_000),
        ("conv-sub", 30, 5_000),
        ("conv-killed", 60, 4_000),
        ("conv-idle", 300, 3_000),
        ("conv-stale", 8 * 3600, 2_000),
    ]

    for spec in specs {
        let logDir = antigravityDir.appendingPathComponent("brain/\(spec.id)/.system_generated/logs", isDirectory: true)
        try fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("transcript.jsonl")
        let line = #"{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-11-16T11:50:00Z","input_tokens":\#(spec.tokens),"cache_read_tokens":0,"output_tokens":100}"# + "\n"
        try line.write(to: logFile, atomically: true, encoding: .utf8)
        let mtime = now.addingTimeInterval(-spec.ageSec)
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: logFile.path)
    }

    let summaryDbURL = antigravityDir.appendingPathComponent("conversation_summaries.db")
    var db: OpaquePointer?
    assertEqual(sqlite3_open(summaryDbURL.path, &db), SQLITE_OK, "create parallel conversation_summaries.db")
    let createSql = """
    CREATE TABLE conversation_summaries (
        conversation_id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '',
        last_modified_time TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT '',
        agent_name TEXT NOT NULL DEFAULT '',
        parent_conversation_id TEXT NOT NULL DEFAULT '',
        not_fully_idle INTEGER NOT NULL DEFAULT 0,
        killed INTEGER NOT NULL DEFAULT 0
    );
    """
    assertEqual(sqlite3_exec(db, createSql, nil, nil, nil), SQLITE_OK, "create full conversation_summaries table")

    let rowsSql = """
    INSERT INTO conversation_summaries (conversation_id, title, last_modified_time, status, agent_name, parent_conversation_id, not_fully_idle, killed) VALUES
    ('conv-main',   '主任务开发',     '2026-11-16 11:59:50.000000+00:00', 'CASCADE_RUN_STATUS_RUNNING', '',        '',          1, 0),
    ('conv-sub',    '浏览器子代理',   '2026-11-16 11:59:30.000000+00:00', 'CASCADE_RUN_STATUS_IDLE',    'browser', 'conv-main', 1, 0),
    ('conv-killed', '已强杀任务',     '2026-11-16 11:59:00.000000+00:00', 'CASCADE_RUN_STATUS_RUNNING', '',        '',          1, 1),
    ('conv-idle',   '普通空闲对话',   '2026-11-16 11:55:00.000000+00:00', 'CASCADE_RUN_STATUS_IDLE',    '',        '',          0, 0),
    ('conv-stale',  '超时未清理任务', '2026-11-16 04:00:00.000000+00:00', 'CASCADE_RUN_STATUS_RUNNING', '',        '',          1, 0);
    """
    assertEqual(sqlite3_exec(db, rowsSql, nil, nil, nil), SQLITE_OK, "insert parallel status rows")
    sqlite3_close(db)

    let snapDefault = TelemetryService.loadSnapshot(customCliHome: cliHome.path, geminiRootOverride: tmpRoot, pinnedConversationId: nil, now: now)
    assertEqual(snapDefault.runningSessions.count, 2, "only non-killed non-stale active sessions listed")
    assertEqual(snapDefault.runningSessions.map(\.conversationId), ["conv-main", "conv-sub"], "running sessions ordered by recency")
    assertEqual(snapDefault.liveSession?.conversationId, "conv-main", "default live session picks newest active task")

    let subLive = snapDefault.runningSessions[1]
    assertEqual(subLive.agentName, "browser", "subagent name extracted")
    assertEqual(subLive.parentConvId, "conv-main", "parent conversation id extracted")
    assertTrue(subLive.isRunning, "not_fully_idle marks subagent running")
    assertEqual(subLive.statusText, "子任务运行中", "subagent status label")

    let comp = snapDefault.activity.filteredComposition(range: .all, sourceFilter: .all)
    let byId = Dictionary(uniqueKeysWithValues: comp.conversations.map { ($0.convId, $0) })
    assertTrue(byId["conv-main"]?.isRunning == true, "conv-main composition marked running")
    assertTrue(byId["conv-sub"]?.isRunning == true, "conv-sub composition marked running")
    assertEqual(byId["conv-sub"]?.agentName, "browser", "conv-sub composition carries agentName")
    assertTrue(byId["conv-killed"]?.isRunning == false, "killed conversation not marked running")
    assertTrue(byId["conv-idle"]?.isRunning == false, "idle conversation not marked running")
    assertTrue(byId["conv-stale"]?.isRunning == false, "stale >6h conversation not marked running")

    let snapPinned = TelemetryService.loadSnapshot(customCliHome: cliHome.path, geminiRootOverride: tmpRoot, pinnedConversationId: "conv-sub", now: now)
    assertEqual(snapPinned.liveSession?.conversationId, "conv-sub", "pinnedConversationId switches live telemetry target")

    let snapPinnedIdle = TelemetryService.loadSnapshot(customCliHome: cliHome.path, geminiRootOverride: tmpRoot, pinnedConversationId: "conv-idle", now: now)
    assertEqual(snapPinnedIdle.liveSession?.conversationId, "conv-idle", "pinnedConversationId can inspect idle recent conversation")
}

func testWalConversationSummariesSnapshot() throws {
    let fm = FileManager.default
    let tmpRoot = fm.temporaryDirectory.appendingPathComponent("agy_wal_test_\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: tmpRoot) }

    let cliHome = tmpRoot.appendingPathComponent("antigravity-cli", isDirectory: true)
    try fm.createDirectory(at: cliHome, withIntermediateDirectories: true)
    let antigravityDir = tmpRoot.appendingPathComponent("antigravity", isDirectory: true)
    let convId = "conv-wal-1"
    let logDir = antigravityDir.appendingPathComponent("brain/\(convId)/.system_generated/logs", isDirectory: true)
    try fm.createDirectory(at: logDir, withIntermediateDirectories: true)

    let now = TokenDateHelper.parseISO8601("2026-11-17T12:00:00Z")!
    let transcript = [
        #"{"step_index":0,"type":"USER_INPUT","created_at":"2026-11-17T11:55:00Z","content":"原始首条提示词"}"#,
        #"{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-11-17T11:56:00Z","input_tokens":1000,"cache_read_tokens":2000,"output_tokens":300}"#,
    ].joined(separator: "\n") + "\n"
    let logFile = logDir.appendingPathComponent("transcript.jsonl")
    try transcript.write(to: logFile, atomically: true, encoding: .utf8)

    let summaryDbURL = antigravityDir.appendingPathComponent("conversation_summaries.db")
    var db: OpaquePointer?
    assertEqual(sqlite3_open(summaryDbURL.path, &db), SQLITE_OK, "create wal conversation_summaries.db")
    let setupSql = """
    PRAGMA journal_mode=WAL;
    CREATE TABLE conversation_summaries (
        conversation_id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT '',
        not_fully_idle INTEGER NOT NULL DEFAULT 0,
        killed INTEGER NOT NULL DEFAULT 0,
        last_modified_time TEXT NOT NULL DEFAULT ''
    );
    INSERT INTO conversation_summaries VALUES ('\(convId)', 'WAL官方标题1', 'CASCADE_RUN_STATUS_RUNNING', 1, 0, '2026-11-17 11:59:00.000000+00:00');
    PRAGMA wal_checkpoint(TRUNCATE);
    """
    assertEqual(sqlite3_exec(db, setupSql, nil, nil, nil), SQLITE_OK, "setup WAL table")
    sqlite3_close(db)

    // Case 1: WAL-mode DB header but `-wal`/`-shm` files removed (historically caused SQLITE_CANTOPEN on SQLITE_OPEN_READONLY)
    try? fm.removeItem(atPath: summaryDbURL.path + "-wal")
    try? fm.removeItem(atPath: summaryDbURL.path + "-shm")
    let snapNoWal = TelemetryService.loadSnapshot(customCliHome: cliHome.path, geminiRootOverride: tmpRoot, now: now)
    let compNoWal = snapNoWal.activity.filteredComposition(range: .all, sourceFilter: .all)
    assertEqual(compNoWal.conversations.first?.title, "WAL官方标题1", "reads WAL db when -wal/-shm are absent")
    assertTrue(compNoWal.conversations.first?.isRunning == true, "reads running state when -wal/-shm are absent")
    assertTrue(!fm.fileExists(atPath: summaryDbURL.path + "-wal"), "zero-invasive: does not create -wal in live dir")

    // Case 2: Writer holds EXCLUSIVE WAL lock with uncheckpointed rename only inside `-wal`
    var writerDb: OpaquePointer?
    assertEqual(sqlite3_open(summaryDbURL.path, &writerDb), SQLITE_OK, "reopen writer db")
    let updateSql = """
    PRAGMA journal_mode=WAL;
    PRAGMA wal_autocheckpoint=0;
    PRAGMA locking_mode=EXCLUSIVE;
    UPDATE conversation_summaries SET title = 'WAL实时新标题2', status = 'CASCADE_RUN_STATUS_IDLE', not_fully_idle = 0 WHERE conversation_id = '\(convId)';
    """
    assertEqual(sqlite3_exec(writerDb, updateSql, nil, nil, nil), SQLITE_OK, "write uncheckpointed WAL update under exclusive lock")

    let snapExclusiveWal = TelemetryService.loadSnapshot(customCliHome: cliHome.path, geminiRootOverride: tmpRoot, now: now)
    let compExclusiveWal = snapExclusiveWal.activity.filteredComposition(range: .all, sourceFilter: .all)
    assertEqual(compExclusiveWal.conversations.first?.title, "WAL实时新标题2", "reads uncheckpointed -wal title even under EXCLUSIVE writer lock")
    assertTrue(compExclusiveWal.conversations.first?.isRunning == false, "reads uncheckpointed -wal idle status update")
    sqlite3_close(writerDb)
}

@main
struct SwiftCoreTestRunner {
    static func main() throws {
        testFormatters()
        testModelNormalization()
        testDateAndIsoWeek()
        try testProtoModelScannerAndTelemetryService()
        testRelativeHeatScaleBounds()
        try testMultiTaskParallelMonitoring()
        try testWalConversationSummariesSnapshot()
        print("PASS: All SwiftCoreTests succeeded!")
    }
}
