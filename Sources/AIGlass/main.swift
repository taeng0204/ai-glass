import AppKit
import AIGlassCore
import Foundation

if CommandLine.arguments.contains("--check-claude") {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        defer { semaphore.signal() }
        guard let creds = ClaudeCredentials.fromKeychain() else {
            print("Keychain에서 Claude Code 자격증명을 찾지 못했습니다.")
            return
        }
        do {
            let (windows, raw) = try await ClaudeUsageAPI.fetch(token: creds.accessToken)
            print("RAW:", String(decoding: raw, as: UTF8.self))
            print("PARSED:", windows ?? "파싱 실패 — parse(_:)를 실제 스키마에 맞춰 수정할 것")
        } catch {
            print("API 호출 실패:", error)
        }
    }
    semaphore.wait()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "✦ –"
        statusItem = item
    }
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
