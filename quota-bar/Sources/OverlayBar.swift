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
            appendLog("bar frame=\(NSStringFromRect(bar.window.frame)) screen=\(screen.localizedName)")
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

final class BarWindow {
    let window: NSPanel
    private let view: BarView

    init(screen: NSScreen) {
        let height: CGFloat = 28
        // Sit just under the menu bar so the strip stays at the top
        // without covering Apple menu / clock. Clicks pass through.
        let frame = NSRect(
            x: screen.frame.minX,
            y: screen.visibleFrame.maxY - height,
            width: screen.frame.width,
            height: height
        )
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.sharingType = .readOnly
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Set last: NSPanel.floating can reset level back to 3.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)

        let barView = BarView(frame: NSRect(origin: .zero, size: frame.size))
        panel.contentView = barView
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        self.window = panel
        self.view = barView
    }

    func update(line: String, ratio: Double?, isError: Bool) {
        view.update(line: line, ratio: ratio, isError: isError)
    }
}

final class BarView: NSView {
    private let accent = NSView()
    private let progressTrack = NSView()
    private let progressFill = NSView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.90).cgColor

        accent.wantsLayer = true
        progressTrack.wantsLayer = true
        progressFill.wantsLayer = true
        progressTrack.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor

        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.96)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.backgroundColor = .clear
        label.isBezeled = false
        label.drawsBackground = false

        [accent, progressTrack, progressFill, label].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            accent.leadingAnchor.constraint(equalTo: leadingAnchor),
            accent.topAnchor.constraint(equalTo: topAnchor),
            accent.bottomAnchor.constraint(equalTo: bottomAnchor),
            accent.widthAnchor.constraint(equalToConstant: 4),

            label.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),

            progressTrack.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressTrack.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 2),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
        ])
        progressFillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)
        progressFillWidth.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var progressFillWidth: NSLayoutConstraint!
    private var currentRatio: Double?

    func update(line: String, ratio: Double?, isError: Bool) {
        label.stringValue = line
        currentRatio = isError ? nil : ratio
        let color = accentColor(ratio: ratio, isError: isError)
        accent.layer?.backgroundColor = color.cgColor
        progressFill.layer?.backgroundColor = color.cgColor
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
