import AppKit
import SwiftUI
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
            let (windows, raw, status) = try await ClaudeUsageAPI.fetch(token: creds.accessToken)
            if !(200..<300).contains(status) {
                print("HTTP", status)
            }
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    let hudState = HUDState()
    let eventEngine = EventEngine()
    var hudController: HUDPanelController?
    var watcher: DirectoryWatcher?
    lazy var claudeCollector = ClaudeCollector(
        root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"))
    lazy var codexCollector = CodexCollector(
        root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"))
    lazy var geminiCollector = GeminiCollector(
        root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/tmp"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "✦ –"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: DashboardView(store: store))
        popover = pop

        hudController = HUDPanelController(store: store, state: hudState) { [weak self] in
            self?.togglePopover()
        }

        refresh()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        watcher = DirectoryWatcher(paths: [
            home + "/.claude/projects",
            home + "/.codex/sessions",
            home + "/.gemini/tmp",
        ]) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }

        // Claude 한도: 60초 폴링 (Keychain 접근은 최초 1회 허용 필요)
        pollClaudeLimits()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollClaudeLimits() }
        }
    }

    func updateStatusTitle() {
        let percent = store.maxUsedPercent
        statusItem?.button?.title = percent > 0 ? "✦ \(Int(percent))%" : "✦ –"
    }

    func evaluateEvents() {
        let now = Date()
        let events = eventEngine.evaluate(
            limits: store.limits,
            burnRate: store.tokensPerMinute(windowMinutes: 10, now: now),
            baseline: store.activeBaselineRate(now: now),
            now: now)
        // MVP: 갱신 주기당 최우선 이벤트 1건만 표시 (큐잉은 추후)
        if let first = events.first { hudState.show(first) }
    }

    func pollClaudeLimits() {
        Task { @MainActor in
            guard let creds = ClaudeCredentials.fromKeychain() else { return }
            guard let result = try? await ClaudeUsageAPI.fetch(token: creds.accessToken),
                  result.statusCode / 100 == 2,
                  let windows = result.windows else { return }
            store.setLimits(windows, for: .claude)
            updateStatusTitle()
            evaluateEvents()
        }
    }

    func refresh() {
        claudeCollector.collect(into: store)
        codexCollector.collect(into: store)
        geminiCollector.collect(into: store)
        updateStatusTitle()
        evaluateEvents()
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
