import AppKit
import SwiftUI
import AIGlassCore
import Foundation
import Carbon.HIToolbox

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
    /// 알림 기록 (대시보드 기록 탭). append 배선은 Y3에서.
    let eventLog = EventLog()
    var hudController: HUDPanelController?
    var watcher: DirectoryWatcher?
    var hotKey: GlobalHotKey?
    /// ⌘⇧E — HUD 호버 카드 expand 고정 토글.
    var expandHotKey: GlobalHotKey?
    let notifier = Notifier()
    /// Keychain 토큰 메모리 캐시 — 매 폴링마다 Keychain 다이얼로그가 뜨는 것을 막는다.
    let claudeTokens = ClaudeTokenProvider(reader: { ClaudeCredentials.fromKeychain() })
    /// 시간대별 1회 브리핑 엔진. lastFired는 UserDefaults에 저장/복원.
    let briefingEngine = BriefingEngine()
    /// 마지막 브리핑 평가 시각 — 5분에 1회만 evaluate.
    private var lastBriefingEvalAt: Date = .distantPast
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
            settings: settings,
            eventLog: eventLog,
            onRefresh: { [weak self] in self?.refresh() },
            onClose: {},
            onSettings: { [weak self] in self?.openSettings() },
            onReplay: { [weak self] event in self?.hudState.show(event, duration: 2.5) })

        hudController = HUDPanelController(store: store, state: hudState, settings: settings) { [weak self] in
            self?.togglePopover()
        }
        hudController?.setVisible(settings.hudVisible)

        restoreBriefingState()

        // 글로벌 단축키 ⌘⇧U → 팝오버 토글 (Carbon 이벤트는 메인 스레드)
        hotKey = GlobalHotKey { [weak self] in
            MainActor.assumeIsolated { self?.togglePopover() }
        }
        // ⌘⇧E → HUD expand 고정 토글.
        expandHotKey = GlobalHotKey(keyCode: kVK_ANSI_E, id: 2) { [weak self] in
            MainActor.assumeIsolated { self?.hudState.togglePinnedExpand() }
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
            home + "/.gemini/antigravity-cli",
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
        // 메뉴바 %는 켜진(enabled) 에이전트 한정 최대 사용률.
        let percent = store.maxUsedPercent(in: settings.enabledServices)
        statusItem?.button?.title = percent > 0 ? "✦ \(Int(percent))%" : "✦ –"
    }

    /// HUD 알림 표시 + 기록(EventLog) 적재. 호버 리플레이는 이 경로를 쓰지 않는다(기록 금지).
    func showHUD(_ event: HUDEvent, duration: TimeInterval = 6) {
        hudState.show(event, duration: duration)
        eventLog.append(event)
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
        // 꺼진(enabled 아닌) 에이전트는 한도 알림을 발화하지 않도록 필터.
        let enabledLimits = store.limits.filter { settings.enabledServices.contains($0.key) }
        let events = eventEngine.evaluate(
            limits: enabledLimits,
            burnRate: store.tokensPerMinute(windowMinutes: 10, now: now),
            baseline: store.activeBaselineRate(now: now),
            now: now,
            depletions: depletions,
            reportProvider: reportProvider)
        // MVP: 갱신 주기당 최우선 이벤트 1건만 표시 (큐잉은 추후)
        if let first = events.first {
            showHUD(first)
            if settings.notificationsEnabled {
                notifier.notify(title: first.title, subtitle: first.subtitle)
            }
        }
    }

    func pollClaudeLimits() {
        Task { @MainActor in
            guard let token = claudeTokens.token() else { return }
            guard let result = try? await ClaudeUsageAPI.fetch(token: token) else { return }
            // 401: 토큰 거부 → 캐시 무효화(다음 폴링에서 Keychain 재조회).
            if result.statusCode == 401 {
                claudeTokens.invalidate()
                return
            }
            guard result.statusCode / 100 == 2, let windows = result.windows else { return }
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
        evaluateBriefingIfDue()
    }

    /// 60초 디바운스로 최근 8일 이벤트 전체를 SQLite에 upsert (REPLACE 멱등).
    private func persistStatsIfDue() {
        guard let statsStore else { return }
        let now = Date()
        guard now.timeIntervalSince(lastUpsertAt) >= 60 else { return }
        lastUpsertAt = now
        statsStore.upsert(events: store.events, calendar: .utc)
    }

    // MARK: - 브리핑

    private static func briefingKey(_ period: BriefingEngine.Period) -> String {
        "aiglass.briefing.\(period.rawValue)"
    }

    /// UserDefaults에서 Period별 마지막 발화 시각을 복원해 엔진에 주입.
    private func restoreBriefingState() {
        let defaults = UserDefaults.standard
        var restored: [BriefingEngine.Period: Date] = [:]
        for period in BriefingEngine.Period.allCases {
            if let date = defaults.object(forKey: Self.briefingKey(period)) as? Date {
                restored[period] = date
            }
        }
        briefingEngine.lastFired = restored
    }

    /// 5분에 1회만 브리핑을 평가한다(기존 30초 refresh 타이머에 편승).
    private func evaluateBriefingIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastBriefingEvalAt) >= 5 * 60 else { return }
        lastBriefingEvalAt = now

        let data = makeBriefingData(now: now)
        let before = briefingEngine.lastFired
        guard let event = briefingEngine.evaluate(now: now, data: data) else { return }

        showHUD(event, duration: 10)
        if settings.notificationsEnabled {
            notifier.notify(title: event.title, subtitle: event.subtitle)
        }
        // lastFired 변경분만 UserDefaults에 저장.
        let defaults = UserDefaults.standard
        for (period, date) in briefingEngine.lastFired where before[period] != date {
            defaults.set(date, forKey: Self.briefingKey(period))
        }
    }

    /// 어제(statsStore)·오늘(store)에서 BriefingData를 구성한다.
    private func makeBriefingData(now: Date) -> BriefingEngine.BriefingData {
        let calendar = Calendar.current
        var data = BriefingEngine.BriefingData()

        // 어제: statsStore 일별 합계 + 비용(2일 - 1일 차).
        if let statsStore {
            let startOfToday = calendar.startOfDay(for: now)
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else {
                return data
            }
            let rows = statsStore.dailyTotalsByService(days: 2, now: now, calendar: .utc)
            data.yesterdayTokens = rows
                .filter { calendar.isDate($0.day, inSameDayAs: yesterday) }
                .reduce(0) { $0 + $1.tokens }
            // 어제 1일 비용 = (최근 2일) - (오늘 1일).
            data.yesterdayCost = max(0, statsStore.totalCost(days: 2, now: now, calendar: .utc)
                                     - statsStore.totalCost(days: 1, now: now, calendar: .utc))
            // 어제 top project는 projectBreakdown이 오늘 포함이라 부정확 → 생략(nil).
        }

        // 오늘: store.
        let startOfToday = calendar.startOfDay(for: now)
        let todayEvents = store.events.filter { $0.timestamp >= startOfToday }
        data.todayTokens = store.todayTokens(now: now)
        data.todayCost = CostEstimator.cost(of: todayEvents)

        // 오늘 top service: 서비스별 토큰 합 최대, share = 그 서비스/오늘 전체.
        var byService: [ServiceID: Int] = [:]
        for e in todayEvents { byService[e.service, default: 0] += e.totalTokens }
        let grand = byService.values.reduce(0, +)
        if grand > 0, let top = byService.max(by: { $0.value < $1.value }) {
            data.todayTopService = (service: top.key, share: Double(top.value) / Double(grand))
        }

        return data
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
