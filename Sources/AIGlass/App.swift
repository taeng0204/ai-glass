import AppKit
import SwiftUI
import AIGlassCore
import Foundation

@main
enum AIGlassMain {
    static func main() {
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

        MainActor.assumeIsolated {
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = UsageStore()
    let settings = AppSettings()
    var statusItem: NSStatusItem?
    var dashboardPanel: DashboardPanelController?
    let hudState = HUDState()
    let eventEngine = EventEngine()
    var hudController: HUDPanelController?
    var watcher: DirectoryWatcher?
    var hotKey: GlobalHotKey?
    let notifier = Notifier()
    /// SQLite 영구 통계 (30일 추이용). 실패 시 nil 허용.
    let statsStore: DailyStatsStore? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIGlass")
        return DailyStatsStore(path: dir.appendingPathComponent("stats.db").path)
    }()
    /// upsert 디바운스 (60초). refresh마다 갱신, 만료 시 1회 upsert.
    private var lastUpsertAt: Date = .distantPast
    /// 설정 창 (중복 생성 방지).
    private var settingsWindow: NSWindow?
    lazy var claudeCollector = ClaudeCollector(
        root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"))
    lazy var codexCollector = CodexCollector(
        root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"))
    lazy var geminiCollector = GeminiCollector(
        root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/tmp"),
        dailyQuota: settings.geminiDailyQuota)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "✦ –"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        dashboardPanel = DashboardPanelController(
            store: store,
            statsStore: statsStore,
            onRefresh: { [weak self] in self?.refresh() },
            onClose: {})

        hudController = HUDPanelController(store: store, state: hudState, settings: settings) { [weak self] in
            self?.togglePopover()
        }
        hudController?.setVisible(settings.hudVisible)

        // 글로벌 단축키 ⌘⇧U → 팝오버 토글 (Carbon 이벤트는 메인 스레드)
        hotKey = GlobalHotKey { [weak self] in
            MainActor.assumeIsolated { self?.togglePopover() }
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
        // 설정 임계값 주입.
        eventEngine.thresholds = [Int(settings.warnThreshold), Int(settings.critThreshold)]
        // 서비스별 소진 예측.
        var depletions: [ServiceID: Depletion] = [:]
        for service in ServiceID.allCases {
            if let d = store.depletion(for: service, now: now) { depletions[service] = d }
        }
        // 세션 리포트: windowReset 발화 시 직전 5h 윈도우 요약을 subtitle로.
        let reportProvider: (ServiceID) -> String? = { [store] service in
            store.sessionSummary(service: service, from: now.addingTimeInterval(-5 * 3600), to: now)
        }
        let events = eventEngine.evaluate(
            limits: store.limits,
            burnRate: store.tokensPerMinute(windowMinutes: 10, now: now),
            baseline: store.activeBaselineRate(now: now),
            now: now,
            depletions: depletions,
            reportProvider: reportProvider)
        // MVP: 갱신 주기당 최우선 이벤트 1건만 표시 (큐잉은 추후)
        if let first = events.first {
            hudState.show(first)
            if settings.notificationsEnabled {
                notifier.notify(title: first.title, subtitle: first.subtitle)
            }
        }
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
        persistStatsIfDue()
    }

    /// 60초 디바운스로 최근 8일 이벤트 전체를 SQLite에 upsert (REPLACE 멱등).
    private func persistStatsIfDue() {
        guard let statsStore else { return }
        let now = Date()
        guard now.timeIntervalSince(lastUpsertAt) >= 60 else { return }
        lastUpsertAt = now
        statsStore.upsert(events: store.events, calendar: .utc)
    }

    @objc func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    func showContextMenu() {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "대시보드 열기", action: #selector(togglePopover), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let hudItem = NSMenuItem(title: "HUD 표시", action: #selector(toggleHUD), keyEquivalent: "")
        hudItem.target = self
        hudItem.state = settings.hudVisible ? .on : .off
        menu.addItem(hudItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "AI Glass 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        statusItem?.menu = menu          // 일시 부착
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil           // 분리해야 좌클릭 팝오버가 계속 동작
    }

    @objc func toggleHUD() {
        settings.hudVisible.toggle()
        hudController?.setVisible(settings.hudVisible)
    }

    /// 설정 창을 연다. 이미 떠 있으면 앞으로 가져온다.
    @objc func openSettings() {
        if let win = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(settings: settings, hudController: hudController)
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "AI Glass 설정"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        win.delegate = self
        settingsWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            settingsWindow = nil
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        dashboardPanel?.toggle(relativeTo: button)
    }
}
