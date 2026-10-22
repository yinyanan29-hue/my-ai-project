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
        item.button?.title = "额度"
        item.button?.toolTip = "Cursor 额度条"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "立即刷新", action: #selector(refreshFromMenu), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出额度条", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
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
                }
            } catch {
                let message = (error as? QuotaError)?.description ?? "无法读取额度：\(error.localizedDescription)"
                UsageClient.persistError(message)
                DispatchQueue.main.async {
                    appendLog("usage error \(message)")
                    self?.apply(line: "Cursor 额度  ·  \(message)", ratio: nil, isError: true)
                    self?.statusItem?.button?.title = "额度 错误"
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
/// AppKit resets `ignoresMouseEvents` when `level` changes; the setter
/// forces it back on so ribbon / header clicks reach the app underneath.
final class ClickThroughPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override var ignoresMouseEvents: Bool {
        get { true }
        set { super.ignoresMouseEvents = true }
    }
}

enum BarPlacement {
    static func frame(on screen: NSScreen) -> NSRect {
        let reserved = screen.frame.maxY - screen.visibleFrame.maxY
        let height = reserved > 1 ? reserved : max(NSStatusBar.system.thickness, 22)
        // Stay inside the menu-bar band. Never extend into the content
        // area where WPS/Excel ribbon buttons live.
        return NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - height,
            width: screen.frame.width,
            height: height
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
        view.update(line: line, ratio: ratio, isError: isError)
        enforceClickThrough()
    }

    private func enforceClickThrough() {
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = false
        window.ignoresMouseEvents = true
    }
}

final class BarView: NSView {
    private let progressTrack = NSView()
    private let progressFill = NSView()
    private let pill = NSView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        progressTrack.wantsLayer = true
        progressFill.wantsLayer = true
        progressTrack.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor

        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.82).cgColor
        pill.layer?.cornerRadius = 8

        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.96)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.backgroundColor = .clear
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.isEnabled = false
        label.refusesFirstResponder = true

        [progressTrack, progressFill, pill, label].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            progressTrack.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressTrack.topAnchor.constraint(equalTo: topAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 2),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),

            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            pill.heightAnchor.constraint(equalToConstant: 20),

            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        progressFillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)
        progressFillWidth.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var progressFillWidth: NSLayoutConstraint!
    private var currentRatio: Double?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var acceptsFirstResponder: Bool { false }
    override var acceptsTouchEvents: Bool {
        get { false }
        set {}
    }

    func update(line: String, ratio: Double?, isError: Bool) {
        label.stringValue = line
        currentRatio = isError ? nil : ratio
        let color = accentColor(ratio: ratio, isError: isError)
        progressFill.layer?.backgroundColor = color.cgColor
        pill.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: isError ? 0.88 : 0.82).cgColor
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
        pill.layer?.cornerRadius = 8
    }
}
