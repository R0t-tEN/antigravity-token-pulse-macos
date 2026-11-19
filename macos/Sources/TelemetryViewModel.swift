import Foundation
import SwiftUI
import ServiceManagement

@MainActor
final class TelemetryViewModel: ObservableObject {
    @Published var stats: ActivityStats = ActivityStats()
    @Published var liveSession: LiveSessionStats? = nil
    @Published var runningSessions: [LiveSessionStats] = []
    @Published var recentSessions: [LiveSessionStats] = []
    @Published var pinnedConversationId: String? = nil
    @Published var paths: TelemetryService.PathsConfig = TelemetryService.PathsConfig.resolve()
    @Published var isRefreshing: Bool = false
    @Published var cliStatusText: String = "未检查"
    @Published var cliInstalled: Bool = false
    @Published var cliMessage: String? = nil
    @Published var isPanelDetached: Bool = false
    @Published var isAlwaysOnTop: Bool = false

    @AppStorage("themePreference") var themePreferenceRaw: String = ThemePreference.system.rawValue
    @AppStorage("menuBarLabelMode") var menuBarLabelModeRaw: String = MenuBarLabelMode.todayTotal.rawValue
    @AppStorage("refreshIntervalSec") var refreshIntervalSec: Double = 5.0
    @AppStorage("customCliHome") var customCliHome: String = ""
    @AppStorage("showLiveSessionStrip") var showLiveSessionStrip: Bool = true

    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?

    var themePreference: ThemePreference {
        get { ThemePreference(rawValue: themePreferenceRaw) ?? .system }
        set { themePreferenceRaw = newValue.rawValue }
    }

    var menuBarLabelMode: MenuBarLabelMode {
        get { MenuBarLabelMode(rawValue: menuBarLabelModeRaw) ?? .todayTotal }
        set { menuBarLabelModeRaw = newValue.rawValue }
    }

    init() {
        startPolling()
        refreshNow()
        refreshCliStatus()
    }

    deinit {
        timer?.invalidate()
        refreshTask?.cancel()
    }

    func startPolling() {
        timer?.invalidate()
        let interval = max(2.0, refreshIntervalSec)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
    }

    func updateRefreshInterval(_ seconds: Double) {
        refreshIntervalSec = seconds
        startPolling()
    }

    func selectLiveSession(_ convId: String?) {
        pinnedConversationId = convId
        if let convId = convId,
           let found = (runningSessions + recentSessions).first(where: { $0.conversationId == convId || $0.id == convId }) {
            liveSession = found
        } else if convId == nil {
            liveSession = runningSessions.first ?? recentSessions.first
        } else {
            refreshNow()
        }
    }

    func refreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let cliOverride = customCliHome
        let pinned = pinnedConversationId
        refreshTask = Task.detached(priority: .utility) {
            let snapshot = TelemetryService.loadSnapshot(customCliHome: cliOverride, pinnedConversationId: pinned)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.stats = snapshot.activity
                self.liveSession = snapshot.liveSession
                self.runningSessions = snapshot.runningSessions
                self.recentSessions = snapshot.recentSessions
                self.paths = snapshot.paths
                self.isRefreshing = false
            }
        }
    }

    var menuBarDisplayText: String {
        let runningSuffix = runningSessions.count >= 2 ? " · \(runningSessions.count)运行" : ""
        switch menuBarLabelMode {
        case .iconOnly:
            return ""
        case .todayTotal:
            return TokenFormatter.activity(stats.today.totalTokens) + runningSuffix
        case .liveContext:
            if let live = liveSession {
                if runningSessions.count >= 2 {
                    return "\(runningSessions.count)并行 · \(live.contextPercent)%"
                }
                return "\(TokenFormatter.compact(live.latestContextUsed)) · \(live.contextPercent)%"
            }
            return TokenFormatter.activity(stats.today.totalTokens) + runningSuffix
        }
    }

    // MARK: - Launch at Login

    var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                objectWillChange.send()
            } catch {
                cliMessage = "开机自启设置失败（请将 App 放入 /Applications 后重试）: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - CLI StatusLine Configuration Helper

    func refreshCliStatus() {
        let currentPaths = TelemetryService.PathsConfig.resolve(customCliHome: customCliHome)
        let settingsURL = currentPaths.cliHomeDir.appendingPathComponent("settings.json")
        let fm = FileManager.default

        guard fm.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = obj["statusLine"] as? [String: Any],
              let enabled = statusLine["enabled"] as? Bool,
              enabled,
              let cmd = statusLine["command"] as? String,
              cmd.contains("agy-statusline") else {
            cliInstalled = false
            cliStatusText = fm.fileExists(atPath: currentPaths.cliHomeDir.path) ? "未配置 statusLine" : "未检测到 ~/.gemini/antigravity-cli"
            return
        }
        cliInstalled = true
        cliStatusText = "已启用 (\(cmd))"
    }

    func installCliStatusLine() {
        let fm = FileManager.default
        let currentPaths = TelemetryService.PathsConfig.resolve(customCliHome: customCliHome)
        let cliDir = currentPaths.cliHomeDir
        let targetPy = cliDir.appendingPathComponent("agy-statusline.py")
        let settingsURL = cliDir.appendingPathComponent("settings.json")

        guard let bundledPy = locateBundledCliScript() else {
            cliMessage = "未找到内置 agy-statusline.py，请使用项目中的 scripts/install-cli.sh 安装。"
            return
        }

        do {
            if !fm.fileExists(atPath: cliDir.path) {
                try fm.createDirectory(at: cliDir, withIntermediateDirectories: true)
            }
            if fm.fileExists(atPath: targetPy.path) {
                try fm.removeItem(at: targetPy)
            }
            try fm.copyItem(at: bundledPy, to: targetPy)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetPy.path)

            var settingsDict: [String: Any] = [:]
            if fm.fileExists(atPath: settingsURL.path),
               let existingData = try? Data(contentsOf: settingsURL),
               let parsed = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                settingsDict = parsed
            }

            let quotedPath = targetPy.path.contains(" ") ? "\"\(targetPy.path)\"" : targetPy.path
            settingsDict["statusLine"] = [
                "type": "command",
                "command": "/usr/bin/python3 \(quotedPath)",
                "enabled": true
            ]

            let jsonData = try JSONSerialization.data(withJSONObject: settingsDict, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: settingsURL, options: .atomic)

            cliMessage = "已成功写入 CLI 状态栏配置（使用 macOS 原生 Python3，无需 Node.js）。"
            refreshCliStatus()
        } catch {
            cliMessage = "写入 CLI 配置失败: \(error.localizedDescription)"
        }
    }

    func uninstallCliStatusLine() {
        let fm = FileManager.default
        let currentPaths = TelemetryService.PathsConfig.resolve(customCliHome: customCliHome)
        let cliDir = currentPaths.cliHomeDir
        let settingsURL = cliDir.appendingPathComponent("settings.json")
        let targetPy = cliDir.appendingPathComponent("agy-statusline.py")

        do {
            if fm.fileExists(atPath: targetPy.path) {
                try fm.removeItem(at: targetPy)
            }
            if fm.fileExists(atPath: settingsURL.path),
               let existingData = try? Data(contentsOf: settingsURL),
               var parsed = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                parsed.removeValue(forKey: "statusLine")
                let jsonData = try JSONSerialization.data(withJSONObject: parsed, options: [.prettyPrinted, .sortedKeys])
                try jsonData.write(to: settingsURL, options: .atomic)
            }
            cliMessage = "已移除托管的 agy CLI 状态栏配置。"
            refreshCliStatus()
        } catch {
            cliMessage = "移除 CLI 配置失败: \(error.localizedDescription)"
        }
    }

    private func locateBundledCliScript() -> URL? {
        if let res = Bundle.main.url(forResource: "agy-statusline", withExtension: "py") {
            return res
        }
        let execDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let sibling = execDir.appendingPathComponent("cli/agy-statusline.py")
        if FileManager.default.fileExists(atPath: sibling.path) {
            return sibling
        }
        return nil
    }
}
