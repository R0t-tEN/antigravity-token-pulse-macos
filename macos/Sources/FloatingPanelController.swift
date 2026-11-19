import AppKit
import Combine
import SwiftUI

final class PulseFloatingWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            if !NSApp.isActive || !self.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                self.makeKeyAndOrderFront(nil)
            }
        }
        super.sendEvent(event)
    }
}

final class PulseHostingController: NSHostingController<DashboardView> {
    override func viewDidLoad() {
        super.viewDidLoad()
        safeAreaRegions = []
    }
}

final class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if let win = window {
            if !NSApp.isActive || !win.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                win.makeKeyAndOrderFront(nil)
            }
            win.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView {
        WindowDragNSView()
    }

    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

@MainActor
final class StatusBarPanelController: NSObject, NSWindowDelegate {
    private let vm: TelemetryViewModel
    private let statusItem: NSStatusItem
    private var panel: PulseFloatingWindow?
    private var hostingController: PulseHostingController?
    private var cancellables = Set<AnyCancellable>()
    private var globalMouseMonitor: Any?
    private var appDeactivateObserver: Any?

    private var isProgrammaticMove = false
    private var attachedOrigin: NSPoint?
    private var attachedTopY: CGFloat?

    init(vm: TelemetryViewModel) {
        self.vm = vm
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        setupStatusItem()
        observeViewModel()
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        let img = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "Antigravity Token Pulse")
        img?.isTemplate = true
        button.image = img
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.target = self
        button.action = #selector(handleStatusBarClick(_:))
        updateStatusButtonTitle()
    }

    private func observeViewModel() {
        vm.$stats
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusButtonTitle() }
            .store(in: &cancellables)

        vm.$liveSession
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusButtonTitle() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusButtonTitle() }
            .store(in: &cancellables)
    }

    private func updateStatusButtonTitle() {
        guard let button = statusItem.button else { return }
        let txt = vm.menuBarDisplayText
        button.title = txt.isEmpty ? "" : " \(txt)"
    }

    @objc private func handleStatusBarClick(_ sender: Any?) {
        guard let panel = panel else {
            showPanelAttached()
            return
        }

        if panel.isVisible {
            if vm.isPanelDetached && (!panel.isKeyWindow || !NSApp.isActive) {
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            } else {
                hidePanel()
            }
        } else {
            showPanelAttached()
        }
    }

    private func ensurePanelCreated() -> PulseFloatingWindow {
        if let existing = panel {
            return existing
        }

        let contentView = DashboardView(
            vm: vm,
            onTogglePin: { [weak self] in
                self?.toggleDetached()
            },
            onToggleAlwaysOnTop: { [weak self] in
                self?.toggleAlwaysOnTop()
            },
            onClosePanel: { [weak self] in
                self?.hidePanel()
            }
        )

        let host = PulseHostingController(rootView: contentView)
        host.sizingOptions = [.preferredContentSize]
        self.hostingController = host

        let newPanel = PulseFloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 630),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.contentViewController = host
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.isMovable = true
        newPanel.isMovableByWindowBackground = true
        newPanel.isReleasedWhenClosed = false
        newPanel.hidesOnDeactivate = false
        newPanel.hasShadow = true
        newPanel.standardWindowButton(.closeButton)?.isHidden = true
        newPanel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newPanel.standardWindowButton(.zoomButton)?.isHidden = true
        newPanel.delegate = self
        newPanel.onEscape = { [weak self] in
            guard let self = self else { return }
            if !self.vm.isPanelDetached {
                self.hidePanel()
            }
        }

        self.panel = newPanel
        syncWindowAppearance()
        return newPanel
    }

    /// Attached menu-bar popovers float above normal windows while open and auto-dismiss on blur.
    /// Detached windows use `.normal` level by default so other apps cover them naturally unless pinned on top.
    private func syncWindowAppearance() {
        guard let p = panel else { return }
        let shouldFloat = !vm.isPanelDetached || vm.isAlwaysOnTop
        let targetLevel: NSWindow.Level = shouldFloat ? .floating : .normal
        if p.level != targetLevel {
            p.level = targetLevel
        }
        let targetBehavior: NSWindow.CollectionBehavior = shouldFloat
            ? [.moveToActiveSpace, .fullScreenAuxiliary]
            : [.moveToActiveSpace]
        if p.collectionBehavior != targetBehavior {
            p.collectionBehavior = targetBehavior
        }
    }

    func showPanelAttached() {
        let p = ensurePanelCreated()
        vm.isPanelDetached = false
        vm.isAlwaysOnTop = false
        syncWindowAppearance()
        vm.refreshNow()

        let panelSize = hostingController?.view.fittingSize ?? p.frame.size
        let targetSize = NSSize(
            width: max(800, panelSize.width),
            height: max(480, panelSize.height)
        )
        let anchor = computeAttachedOrigin(for: targetSize)

        isProgrammaticMove = true
        p.setFrame(NSRect(origin: anchor.origin, size: targetSize), display: true)
        installDismissMonitors()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        attachedOrigin = p.frame.origin
        attachedTopY = p.frame.maxY
        isProgrammaticMove = false
    }

    func hidePanel() {
        removeDismissMonitors()
        panel?.orderOut(nil)
        vm.isPanelDetached = false
        vm.isAlwaysOnTop = false
        syncWindowAppearance()
        attachedOrigin = nil
        attachedTopY = nil
    }

    func toggleDetached() {
        guard let p = panel, p.isVisible else { return }
        if vm.isPanelDetached {
            vm.isPanelDetached = false
            vm.isAlwaysOnTop = false
            syncWindowAppearance()
            installDismissMonitors()
            let anchor = computeAttachedOrigin(for: p.frame.size)
            isProgrammaticMove = true
            p.setFrameOrigin(anchor.origin)
            attachedOrigin = p.frame.origin
            attachedTopY = p.frame.maxY
            isProgrammaticMove = false
        } else {
            vm.isPanelDetached = true
            syncWindowAppearance()
        }
    }

    func toggleAlwaysOnTop() {
        guard let p = panel, p.isVisible else { return }
        if !vm.isPanelDetached {
            vm.isPanelDetached = true
        }
        vm.isAlwaysOnTop.toggle()
        syncWindowAppearance()
        if !p.isKeyWindow || !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            p.makeKeyAndOrderFront(nil)
        }
    }

    private func computeAttachedOrigin(for size: NSSize) -> (origin: NSPoint, topY: CGFloat) {
        if let button = statusItem.button, let btnWin = button.window {
            let btnRectInWin = button.convert(button.bounds, to: nil)
            let btnScreenRect = btnWin.convertToScreen(btnRectInWin)
            let screen = btnWin.screen ?? NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

            let rawX = btnScreenRect.midX - size.width / 2.0
            let clampedX = max(visible.minX + 8.0, min(visible.maxX - size.width - 8.0, rawX))
            let topY = min(visible.maxY - 4.0, btnScreenRect.minY - 6.0)
            let y = max(visible.minY + 8.0, topY - size.height)
            return (NSPoint(x: clampedX, y: y), topY)
        }

        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let x = visible.midX - size.width / 2.0
        let topY = visible.maxY - 12.0
        return (NSPoint(x: x, y: topY - size.height), topY)
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove, let p = panel, p.isVisible else { return }
        if !vm.isPanelDetached, let anchor = attachedOrigin {
            let dist = hypot(p.frame.origin.x - anchor.x, p.frame.origin.y - anchor.y)
            if dist > 8.0 {
                vm.isPanelDetached = true
                syncWindowAppearance()
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard !isProgrammaticMove, !vm.isPanelDetached, let p = panel, p.isVisible, let topY = attachedTopY else {
            return
        }
        let targetY = topY - p.frame.height
        if abs(p.frame.origin.y - targetY) > 1.0 {
            let nextOrigin = NSPoint(x: p.frame.origin.x, y: targetY)
            isProgrammaticMove = true
            p.setFrameOrigin(nextOrigin)
            attachedOrigin = p.frame.origin
            isProgrammaticMove = false
        }
    }

    // MARK: - Auto Dismiss Monitors (Attached Mode Only)

    private func installDismissMonitors() {
        removeDismissMonitors()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let p = self.panel, p.isVisible, !self.vm.isPanelDetached else { return }
                self.hidePanel()
            }
        }

        appDeactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let p = self.panel, p.isVisible, !self.vm.isPanelDetached else { return }
                self.hidePanel()
            }
        }
    }

    private func removeDismissMonitors() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let observer = appDeactivateObserver {
            NotificationCenter.default.removeObserver(observer)
            appDeactivateObserver = nil
        }
    }
}
