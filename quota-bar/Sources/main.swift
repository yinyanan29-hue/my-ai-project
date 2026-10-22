import AppKit
import Foundation

func parseRefreshSeconds() -> TimeInterval {
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: "--refresh-seconds"), args.indices.contains(index + 1),
       let value = TimeInterval(args[index + 1]) {
        return value
    }
    return 60
}

func appendLog(_ message: String) {
    let line = "\(UsageClient.isoNow()) \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/cursor-quota-bar.log")
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
    }
}

if CommandLine.arguments.contains("--once") {
    do {
        let snapshot = try UsageClient.fetch()
        print(UsageFormatter.line(from: snapshot))
        print("snapshot=\(UsageClient.snapshotURL.path)")
    } catch {
        let message = (error as? QuotaError)?.description ?? error.localizedDescription
        UsageClient.persistError(message)
        fputs(message + "\n", stderr)
        exit(2)
    }
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: OverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appendLog("applicationDidFinishLaunching screens=\(NSScreen.screens.count)")
        NSApp.setActivationPolicy(.accessory)
        let overlay = OverlayController(refreshSeconds: parseRefreshSeconds())
        overlay.start()
        controller = overlay
        appendLog("overlay started")
    }
}

appendLog("process start args=\(CommandLine.arguments)")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
