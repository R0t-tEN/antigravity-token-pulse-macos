import SwiftUI

struct SettingsView: View {
    @ObservedObject var vm: TelemetryViewModel
    let theme: PulseTheme
    let onClose: () -> Void

    @State private var cliHomeDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.accent)
                    Text("设置与数据源")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.title)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .overlay(WindowDragArea())
                Button(action: onClose) {
                    Text("返回看板")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(theme.elevatedBg)
                        .foregroundColor(theme.primaryText)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Divider().overlay(theme.divider)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    // Display Settings
                    settingSection(title: "外观与菜单栏") {
                        settingRow(label: "主题配色") {
                            Picker("", selection: $vm.themePreferenceRaw) {
                                ForEach(ThemePreference.allCases) { t in
                                    Text(t.title).tag(t.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 220)
                        }

                        settingRow(label: "菜单栏文本") {
                            Picker("", selection: $vm.menuBarLabelModeRaw) {
                                ForEach(MenuBarLabelMode.allCases) { m in
                                    Text(m.title).tag(m.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 170)
                        }

                        settingRow(label: "显示实时会话条") {
                            Toggle("", isOn: $vm.showLiveSessionStrip)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }

                        settingRow(label: "自动刷新间隔") {
                            Picker("", selection: Binding(
                                get: { vm.refreshIntervalSec },
                                set: { vm.updateRefreshInterval($0) }
                            )) {
                                Text("3 秒").tag(3.0)
                                Text("5 秒").tag(5.0)
                                Text("10 秒").tag(10.0)
                                Text("30 秒").tag(30.0)
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 110)
                        }

                        settingRow(label: "登录时自动启动") {
                            Toggle("", isOn: Binding(
                                get: { vm.launchAtLoginEnabled },
                                set: { vm.setLaunchAtLogin($0) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                    }

                    // CLI StatusLine Integration
                    settingSection(title: "Antigravity CLI (agy) 状态栏与数据同步") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("当前状态:")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(theme.secondaryText)
                                Text(vm.cliStatusText)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(vm.cliInstalled ? theme.outputTokenColor : theme.primaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }

                            HStack(spacing: 8) {
                                Button {
                                    vm.installCliStatusLine()
                                } label: {
                                    Text(vm.cliInstalled ? "更新 / 重新部署状态栏" : "一键启用 agy 状态栏 (Python3)")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(theme.accentBg)
                                        .foregroundColor(theme.accent)
                                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.accentBorder, lineWidth: 1))
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                                .buttonStyle(.plain)

                                if vm.cliInstalled {
                                    Button {
                                        vm.uninstallCliStatusLine()
                                    } label: {
                                        Text("卸载配置")
                                            .font(.system(size: 11.5))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(theme.elevatedBg)
                                            .foregroundColor(theme.secondaryText)
                                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
                                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if let msg = vm.cliMessage {
                                Text(msg)
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.secondaryText)
                            }
                        }
                    }

                    // Data Sources
                    settingSection(title: "本地数据目录（100% 纯本地读取）") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text("自定义 CLI 目录:")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.secondaryText)
                                TextField("默认 ~/.gemini/antigravity-cli", text: $cliHomeDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11))
                                Button("应用") {
                                    vm.customCliHome = cliHomeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                    vm.refreshNow()
                                    vm.refreshCliStatus()
                                }
                                .font(.system(size: 11))
                            }

                            pathStatusRow(label: "Desktop 会话日志", url: vm.paths.desktopDir.appendingPathComponent("brain"))
                            pathStatusRow(label: "Desktop 标题库", url: vm.paths.desktopDir.appendingPathComponent("conversation_summaries.db"))
                            pathStatusRow(label: "Desktop 模型库", url: vm.paths.desktopDir.appendingPathComponent("conversations"))
                            pathStatusRow(label: "CLI 会话日志", url: vm.paths.cliHomeDir.appendingPathComponent("brain"))
                            pathStatusRow(label: "共享活动缓存 v4", url: vm.paths.cachePath)
                        }
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .onAppear {
            cliHomeDraft = vm.customCliHome
            vm.refreshCliStatus()
        }
    }

    private func settingSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.rowBg)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func settingRow<Control: View>(label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
            Spacer()
            control()
        }
    }

    private func pathStatusRow(label: String, url: URL) -> some View {
        let exists = FileManager.default.fileExists(atPath: url.path)
        return HStack(spacing: 6) {
            Circle()
                .fill(exists ? theme.outputTokenColor : theme.mutedText.opacity(0.45))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.primaryText)
                .frame(width: 115, alignment: .leading)
            Text(url.path)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(theme.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(exists ? "已就绪" : "未发现")
                .font(.system(size: 10.5))
                .foregroundColor(exists ? theme.outputTokenColor : theme.mutedText)
        }
    }
}
