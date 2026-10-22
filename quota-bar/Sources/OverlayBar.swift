import AppKit

final class OverlayController: NSObject {
    private var bars: [BarWindow] = []
    private var timer: Timer?
    private var statusItem: NSStatusItem?
    private var lastLine = "Cursor 额度  ·  正在读取本机账号…"
    private var lastRatio: Double?
    private var lastIsError = false
    private let refreshSeconds: TimeInterval

    init(refreshSeconds: TimeInterval) {
        self.refreshSeconds = max(5, refreshSeconds)
        super.init()
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        rebuildBars()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshSeconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @objc private func screensChanged() {
        rebuildBars()
        apply(line: lastLine, ratio: lastRatio, isError: lastIsError)
    }

    @objc private func refreshFromMenu() {
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func rebuildBars() {
        bars.forEach { $0.window.close() }
        bars = NSScreen.screens.map { screen in
            let bar = BarWindow(screen: screen)
            appendLog("bar frame=\(NSStringFromRect(bar.window.frame)) screen=\(screen.localizedName) clickThrough=\(bar.window.ignoresMouseEvents)")
            return bar
        }
        apply(line: lastLine, ratio: lastRatio, isError: lastIsError)
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Cursor 额度"
        item.button?.toolTip = "Cursor 额度，不覆盖其他菜单栏用量项"
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let info = NSMenuItem(title: lastLine, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: "退出额度条", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let snapshot = try UsageClient.fetch()
                let line = UsageFormatter.line(from: snapshot)
                let ratio = UsageFormatter.usedRatio(from: snapshot)
                let title = UsageFormatter.statusItemTitle(from: snapshot)
                DispatchQueue.main.async {
                    appendLog("usage ok \(line)")
                    self?.apply(line: line, ratio: ratio, isError: false)
                    self?.statusItem?.button?.title = title
                    self?.rebuildMenu()
                }
            } catch {
                let message = (error as? QuotaError)?.description ?? "无法读取额度：\(error.localizedDescription)"
                UsageClient.persistError(message)
                DispatchQueue.main.async {
                    appendLog("usage error \(message)")
                    self?.apply(line: "Cursor 额度  ·  \(message)", ratio: nil, isError: true)
                    self?.statusItem?.button?.title = "Cursor 错误"
                    self?.rebuildMenu()
                }
            }
        }
    }

    private func apply(line: String, ratio: Double?, isError: Bool) {
        lastLine = line
        lastRatio = ratio
        lastIsError = isError
        bars.forEach { $0.update(line: line, ratio: ratio, isError: isError) }
    }
}

/// Overlay that can never become key and always reports click-through.
final class ClickThroughPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override var ignoresMouseEvents: Bool {
        get { true }
        set { super.ignoresMouseEvents = true }
    }
}

enum BarPlacement {
    static let hairline: CGFloat = 2

    static func frame(on screen: NSScreen) -> NSRect {
        // 2pt at the physical top of the menu bar. Does not cover
        // menu-extra text (Codex reminder, clock) or app ribbons.
        return NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - hairline,
            width: screen.frame.width,
            height: hairline
        )
    }
}

final class BarWindow {
    let window: ClickThroughPanel
    private let view: BarView

    init(screen: NSScreen) {
        let frame = BarPlacement.frame(on: screen)
        let panel = ClickThroughPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.sharingType = .readOnly
        panel.acceptsMouseMovedEvents = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)

        let barView = BarView(frame: NSRect(origin: .zero, size: frame.size))
        panel.contentView = barView
        panel.setContentSize(frame.size)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        panel.ignoresMouseEvents = true

        self.window = panel
        self.view = barView
        enforceClickThrough()
        appendLog("placement height=\(frame.height) y=\(frame.origin.y) ignoresMouse=\(panel.ignoresMouseEvents)")
    }

    func update(line: String, ratio: Double?, isError: Bool) {
        view.update(ratio: ratio, isError: isError)
        enforceClickThrough()
    }

    private func enforceClickThrough() {
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = false
        window.ignoresMouseEvents = true
    }
}

final class BarView: NSView {
    private let progressFill = NSView()
    private var progressFillWidth: NSLayoutConstraint!
    private var currentRatio: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor

        progressFill.wantsLayer = true
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressFill)
        NSLayoutConstraint.activate([
            progressFill.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        progressFillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)
        progressFillWidth.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    func update(ratio: Double?, isError: Bool) {
        currentRatio = isError ? nil : ratio
        progressFill.layer?.backgroundColor = accentColor(ratio: ratio, isError: isError).cgColor
        progressFillWidth.constant = bounds.width * CGFloat(currentRatio ?? 0)
        layoutSubtreeIfNeeded()
    }

    private func accentColor(ratio: Double?, isError: Bool) -> NSColor {
        if isError {
            return NSColor(calibratedRed: 1, green: 0.45, blue: 0.42, alpha: 1)
        }
        guard let ratio else {
            return NSColor(calibratedRed: 0.45, green: 0.72, blue: 1, alpha: 1)
        }
        if ratio >= 0.90 {
            return NSColor(calibratedRed: 1, green: 0.42, blue: 0.42, alpha: 1)
        }
        if ratio >= 0.70 {
            return NSColor(calibratedRed: 0.96, green: 0.72, blue: 0.26, alpha: 1)
        }
        return NSColor(calibratedRed: 0.24, green: 0.86, blue: 0.59, alpha: 1)
    }

    override func layout() {
        super.layout()
        progressFillWidth.constant = bounds.width * CGFloat(currentRatio ?? 0)
    }
}
