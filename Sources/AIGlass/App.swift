import AppKit
import SwiftUI
import AIGlassCore
import Foundation
import Carbon.HIToolbox

@main
enum AIGlassMain {
    static func main() {
        if CommandLine.arguments.contains("--check-claude") {
            guard let creds = ClaudeCredentials.fromKeychain(allowSecurityToolFallback: true) else {
                print("Keychain에서 Claude Code 자격증명을 찾지 못했습니다.")
                exit(0)
            }
            do {
                let (windows, raw, status) = try ClaudeUsageAPI.fetchSynchronously(token: creds.accessToken)
                if !(200..<300).contains(status) {
                    print("HTTP", status)
                }
                print("RAW:", String(decoding: raw, as: UTF8.self))
                print("PARSED:", windows ?? "파싱 실패 — parse(_:)를 실제 스키마에 맞춰 수정할 것")
            } catch {
                print("API 호출 실패:", error)
            }
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
    /// 새 버전 배지 상태 (대시보드 헤더).
    let updateState = UpdateState()
    /// 새 버전 알림을 보낸 버전 — 버전당 1회만 발화 (재시작 간 영속).
    private static let updateNotifiedVersionKey = "aiglass.updateNotifiedVersion"
    /// 오늘 누적 토큰 마일스톤 추적 (날짜 바뀌면 내부 리셋).
    let milestoneTracker = MilestoneTracker()
    /// 신기록 알림을 보낸 날짜(UTC yyyy-MM-dd) — 하루 1회만 발화. UserDefaults에 영속화
    /// (재시작해도 같은 날 중복 발화 방지).
    private static let recordFiredDayKey = "aiglass.recordFiredDay"
    private var recordFiredDay: String? {
        get { UserDefaults.standard.string(forKey: Self.recordFiredDayKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.recordFiredDayKey) }
    }
    /// Keychain 토큰 메모리 캐시 — 매 폴링마다 Keychain 다이얼로그가 뜨는 것을 막는다.
    let claudeTokens = ClaudeTokenProvider(reader: { ClaudeCredentials.fromKeychain() })
    /// Claude 한도 API가 한 번이라도 성공했는지. 초기 Keychain 허용 직후 짧은 재시도 중단에 사용.
    private var claudeLimitsLoaded = false
    /// Claude 사용량 API가 429를 주면 이 시각까지 재시도를 멈춘다.
    private var claudeLimitRetryAfter: Date?
    private var initialClaudeLimitRetryTask: Task<Void, Never>?
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
    /// 온보딩 위저드 창 (중복 생성 방지).
    private var onboardingWindow: NSWindow?
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
            updateState: updateState,
            onRefresh: { [weak self] in self?.refresh() },
            onClose: {},
            onSettings: { [weak self] in self?.openSettings() },
            onReplay: { [weak self] event in self?.flashHUD(event, duration: 2.5) })

        hudController = HUDPanelController(store: store, state: hudState, settings: settings) { [weak self] in
            self?.togglePopover()
        }
        hudController?.setVisible(settings.hudVisible)
        dashboardPanel?.toggleSourceFrames = { [weak self] in
            guard let self else { return [] }
            var frames: [NSRect] = []
            if let hudPanel = self.hudController?.panel, hudPanel.isVisible {
                frames.append(hudPanel.frame)
            }
            if let button = self.statusItem?.button, let window = button.window {
                let rectInWindow = button.convert(button.bounds, to: nil)
                frames.append(window.convertToScreen(rectInWindow).insetBy(dx: -4, dy: -4))
            }
            return frames
        }

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

        // Claude 한도: 시작 직후에는 Keychain 허용 타이밍 때문에 짧게 재시도하고, 이후 60초 주기로 유지.
        startInitialClaudeLimitWarmup()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollClaudeLimits() }
        }

        // 새 버전 확인: 시작 15초 후 1회(네트워크/UI 워밍업 뒤) + 이후 24시간마다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.checkForUpdates()
        }
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates() }
        }

        // 첫 실행 온보딩: 미완료면 약간의 지연 후 띄운다(메뉴바/HUD 자리잡은 뒤).
        if !settings.onboardingCompleted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.openOnboarding()
            }
        }
    }

    /// 온보딩 위저드 창을 연다. 이미 떠 있으면 앞으로 가져온다.
    @objc func openOnboarding() {
        if let win = onboardingWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let view = OnboardingView(settings: settings, onFinish: { [weak self] in
            self?.onboardingWindow?.close()
        })
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "AI Glass 시작하기"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        win.delegate = self
        onboardingWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// 마지막으로 set한 메뉴바 상태 키 — 동일 값 재설정 생략 (깜빡임 방지).
    private var lastMenubarKey: String?
    /// 메뉴바 미니 알약 호스팅 뷰 — wavePill 모드에서만 non-nil.
    private var menubarPillHost: NSView?

    /// 메뉴바 타이틀을 현재 모드/캐시값으로 갱신한다. 자동 로테이션 없음 — refresh에 편승.
    /// collect 호출 금지(store 캐시만 읽음), 이전 값과 동일하면 set 생략.
    func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        if settings.menubarMode == .wavePill {
            installMenubarPillIfNeeded(on: button)
            // 웨이브 스타일 변경으로 폭이 달라졌으면 갱신 (동일 값 set 생략 — 깜빡임 방지).
            let width = MenubarPill.width(for: settings.waveStyle) + 4
            if statusItem?.length != width { statusItem?.length = width }
            return
        }
        removeMenubarPillIfNeeded()
        let now = Date()
        switch settings.menubarMode {
        case .todayTokens:
            let tokens = store.todayTokens(now: now)
            setPlainTitle(tokens > 0 ? "✦ \(Self.formatTokens(tokens))" : "✦ –", on: button)

        case .burnRate:
            let burn = store.tokensPerMinute(windowMinutes: 5, now: now)
            setPlainTitle(burn > 0 ? "✦ \(Self.formatRate(burn))" : "✦ –", on: button)

        case .maxPercent:
            let percent = store.maxUsedPercent(in: settings.enabledServices)
            setPlainTitle(percent > 0 ? "✦ \(Theme.formatUsagePercent(percent))" : "✦ –", on: button)

        case .iconOnly:
            // "✦"만 + 위험도 색. 색 단계가 같으면 set 생략.
            let percent = store.maxUsedPercent(in: settings.enabledServices)
            let stage = percent >= settings.critThreshold ? "crit"
                      : percent >= settings.warnThreshold ? "warn" : "ok"
            let key = "icon:\(stage)"
            guard lastMenubarKey != key else { return }
            lastMenubarKey = key
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "✦", attributes: [
                .foregroundColor: statusNSColor(percent: percent),
                .font: NSFont.menuBarFont(ofSize: 0),
            ])

        case .wavePill:
            break // 위 early-return에서 처리됨
        }
    }

    /// wavePill 모드 진입 — 상태 버튼 위에 클릭-통과 호스팅 뷰를 얹는다 (멱등).
    private func installMenubarPillIfNeeded(on button: NSStatusBarButton) {
        guard menubarPillHost == nil else { return }
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "") // iconOnly 잔존 색 제거
        lastMenubarKey = "pill"
        let host = ClickThroughHostingView(
            rootView: MenubarPillView(store: store, settings: settings))
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            host.centerXAnchor.constraint(equalTo: button.centerXAnchor),
        ])
        menubarPillHost = host
    }

    /// wavePill 외 모드 — 호스팅 뷰 제거 + 가변 폭 복원 (멱등).
    private func removeMenubarPillIfNeeded() {
        guard let host = menubarPillHost else { return }
        host.removeFromSuperview()
        menubarPillHost = nil
        statusItem?.length = NSStatusItem.variableLength
        lastMenubarKey = nil // 텍스트 모드 타이틀 강제 재설정
    }

    /// 일반 텍스트 타이틀 set — 직전과 동일하면 생략.
    private func setPlainTitle(_ title: String, on button: NSStatusBarButton) {
        let key = "title:\(title)"
        guard lastMenubarKey != key else { return }
        lastMenubarKey = key
        button.attributedTitle = NSAttributedString(string: "") // iconOnly 잔존 색 제거
        button.title = title
    }

    private func statusNSColor(percent: Double) -> NSColor {
        if percent >= settings.critThreshold { return .systemRed }
        if percent >= settings.warnThreshold { return .systemOrange }
        return NSColor(red: 0.35, green: 0.82, blue: 0.54, alpha: 1)
    }

    static func formatTokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1_000_000_000)
        case 1_000_000...: return String(format: "%.0fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    /// 분당 토큰 소모 속도 ("38K/m").
    static func formatRate(_ perMinute: Double) -> String {
        let n = Int(perMinute.rounded())
        switch n {
        case 1_000_000...: return String(format: "%.1fM/m", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fK/m", Double(n) / 1_000)
        default: return "\(n)/m"
        }
    }

    /// HUD 알림 표시 + 기록(EventLog) 적재. 호버 리플레이는 이 경로를 쓰지 않는다(기록 금지).
    func showHUD(_ event: HUDEvent, duration: TimeInterval = 6) {
        flashHUD(event, duration: duration)
        eventLog.append(event)
    }

    /// HUD가 숨김 상태여도 이벤트 카드가 HUD 위치에 잠깐 떠오르게 한다 (기록 없음 — 리플레이 공용).
    func flashHUD(_ event: HUDEvent, duration: TimeInterval = 6) {
        hudState.show(event, duration: duration)
        // 사운드: 알림성 kind일 때만 (설정 가드).
        if settings.funSoundEnabled, Self.isAlertingKind(event.kind) {
            SoundPlayer.play()
        }
        guard !settings.hudVisible else { return }
        hudController?.setVisible(true)
        // 카드 dismiss 애니메이션(0.45s) 여유를 두고 숨김. 그 사이 새 이벤트가 오면 유지
        // (그 이벤트의 flashHUD가 자기 타이머로 다시 숨김).
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.6) { [weak self] in
            guard let self, !self.settings.hudVisible,
                  self.hudState.currentEvent == nil else { return }
            self.hudController?.setVisible(false)
        }
    }

    /// 사운드를 울릴 알림성 이벤트인지 (threshold/depletion/milestone/record).
    private static func isAlertingKind(_ kind: HUDEvent.Kind) -> Bool {
        switch kind {
        case .limitThreshold, .depletionRisk, .milestone, .record: return true
        default: return false
        }
    }

    func evaluateEvents() {
        let now = Date()
        // 설정 임계값 주입.
        eventEngine.thresholds = [Int(settings.warnThreshold), Int(settings.critThreshold)]
        // 서비스별 소진 예측: 5h(store, 분 단위 기울기) + 주간(statsStore 스냅샷 → 일단위 추정).
        var depletions: [ServiceID: [Depletion]] = [:]
        for service in ServiceID.allCases {
            var list: [Depletion] = []
            if let d = store.depletion(for: service, now: now) { list.append(d) }
            if let w = weeklyDepletion(for: service, now: now) { list.append(w) }
            if !list.isEmpty { depletions[service] = list }
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

    private func startInitialClaudeLimitWarmup() {
        initialClaudeLimitRetryTask?.cancel()
        initialClaudeLimitRetryTask = Task { @MainActor [weak self] in
            // 시작 직후 0s, 2s, 5s, 10s, 20s, 30s 근처에서만 짧게 재시도한다.
            for delay in [0, 2, 3, 5, 10, 10] {
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled, let self, !self.claudeLimitsLoaded else { return }
                if await self.fetchClaudeLimits() { return }
            }
        }
    }

    func pollClaudeLimits() {
        Task { @MainActor in
            _ = await fetchClaudeLimits()
        }
    }

    private func fetchClaudeLimits() async -> Bool {
        if let retryAfter = claudeLimitRetryAfter {
            if retryAfter > Date() { return false }
            claudeLimitRetryAfter = nil
        }
        guard let token = claudeTokens.token() else { return false }
        guard let result = try? await ClaudeUsageAPI.fetch(token: token) else { return false }
        // 401: 토큰 거부 → 캐시 무효화(다음 폴링에서 Keychain 재조회).
        if result.statusCode == 401 {
            claudeTokens.invalidate()
            claudeLimitsLoaded = false
            return false
        }
        // 429: 초기 웜업/수동 진단이 겹쳐 API 제한에 걸리면 기존 표시를 유지하고 잠시 쉰다.
        if result.statusCode == 429 {
            claudeLimitRetryAfter = Date().addingTimeInterval(5 * 60)
            claudeLimitsLoaded = !(store.limits[.claude]?.isEmpty ?? true)
            return false
        }
        guard result.statusCode / 100 == 2, let windows = result.windows else { return false }
        claudeLimitRetryAfter = nil
        claudeLimitsLoaded = true
        store.setLimits(windows, for: .claude)
        updateStatusTitle()
        evaluateEvents()
        return true
    }

    /// GitHub 최신 릴리스를 확인해 새 버전이면 대시보드 배지를 켜고, 버전당 1회 알림을 보낸다.
    /// 자동 설치는 하지 않는다. swift run(번들 버전 없음)에서는 건너뜀.
    func checkForUpdates() {
        guard let current = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return }
        Task { @MainActor [weak self] in
            guard let release = await UpdateChecker.fetchLatest(), let self else { return }
            guard UpdateChecker.isNewer(release.version, than: current) else {
                self.updateState.available = nil
                return
            }
            self.updateState.available = release
            if UserDefaults.standard.string(forKey: Self.updateNotifiedVersionKey) != release.version {
                UserDefaults.standard.set(release.version, forKey: Self.updateNotifiedVersionKey)
                self.notifier.notify(title: "AI Glass v\(release.version) 업데이트가 나왔어요",
                                     subtitle: "대시보드의 ↓ 배지에서 받을 수 있어요")
            }
        }
    }

    func refresh() {
        claudeCollector.collect(into: store)
        codexCollector.collect(into: store)
        geminiCollector.collect(into: store)
        updateStatusTitle()
        evaluateComebackIfDue()
        evaluateEvents()
        persistStatsIfDue()
        evaluateBriefingIfDue()
    }

    /// 활동 공백(≥3h) 후 재개를 감지하면 컴백 인사 HUD를 띄운다 (기록에도 남음).
    private func evaluateComebackIfDue() {
        guard let gap = store.consumeComebackGap() else { return }
        let now = Date()
        let formatted = EventEngine.countdown(to: now.addingTimeInterval(gap), from: now)
        showHUD(HUDEvent(kind: .comeback,
                         title: "다시 달려볼까요!",
                         subtitle: "\(formatted) 만에 AI 작업 재개",
                         percent: nil))
    }

    /// 60초 디바운스로 최근 8일 이벤트 전체를 SQLite에 upsert (REPLACE 멱등).
    private func persistStatsIfDue() {
        guard let statsStore else { return }
        let now = Date()
        guard now.timeIntervalSince(lastUpsertAt) >= 60 else { return }
        lastUpsertAt = now
        statsStore.upsert(events: store.events, calendar: .utc)
        recordPercentSnapshots(now: now)
        evaluateFun(now: now, statsStore: statsStore)
    }

    /// 마일스톤/신기록 체크 (60초 디바운스 지점, 스냅샷 기록과 함께).
    private func evaluateFun(now: Date, statsStore: DailyStatsStore) {
        let todayTokens = store.todayTokens(now: now)

        // 마일스톤: 오늘 누적이 새 임계 돌파 시 1회.
        if settings.funMilestone,
           let crossed = milestoneTracker.check(todayTokens: todayTokens, day: now, calendar: .utc) {
            showHUD(HUDEvent(kind: .milestone,
                             title: "오늘 \(Self.formatTokens(crossed)) 돌파! 🎉",
                             subtitle: "오늘 누적 \(Self.formatTokens(todayTokens)) tokens",
                             percent: nil))
        }

        // 신기록: 오늘 누적 > 종전 최대(오늘 제외) && 종전 > 0, 하루 1회.
        if settings.funRecord {
            let dayStr = Self.utcDayString(now)
            if recordFiredDay != dayStr,
               let prevMax = statsStore.maxDailyTokens(excludingDay: now, calendar: .utc),
               prevMax > 0, todayTokens > prevMax {
                recordFiredDay = dayStr
                showHUD(HUDEvent(kind: .record,
                                 title: "오늘 신기록! 🏆",
                                 subtitle: "종전 \(Self.formatTokens(prevMax))",
                                 percent: nil))
            }
        }
    }

    private static let utcDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")!
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func utcDayString(_ date: Date) -> String {
        utcDayFormatter.string(from: date)
    }

    /// 현재 limits의 각 윈도우 사용률(%)을 (오늘 UTC) percent_snapshots에 기록한다.
    /// REPLACE라 하루 동안 마지막 관측값만 남는다 — 주간 일단위 소진 추정의 입력.
    private func recordPercentSnapshots(now: Date) {
        guard let statsStore else { return }
        for (service, windows) in store.limits {
            for window in windows {
                statsStore.recordPercentSnapshot(service: service, kind: window.kind,
                                                 percent: window.usedPercent, day: now)
            }
        }
    }

    /// statsStore의 percent 스냅샷으로 주간 한도의 일단위 소진을 추정한다.
    /// 현재 주간 윈도우가 있어야 하며, 그 resetsAt 기준 `willDepleteBeforeReset`일 때만 의미.
    private func weeklyDepletion(for service: ServiceID, now: Date) -> Depletion? {
        guard let statsStore,
              let weekly = store.limits[service]?.first(where: { $0.kind == .weekly }) else { return nil }
        let snapshots = statsStore.percentSnapshots(service: service, kind: .weekly, days: 8, now: now)
        guard let rate = DepletionEstimator.weeklyDailyRate(snapshots: snapshots) else { return nil }
        guard let d = DepletionEstimator.weeklyDepletion(current: weekly.usedPercent, rate: rate,
                                                         resetsAt: weekly.resetsAt, now: now) else { return nil }
        return d.willDepleteBeforeReset ? d : nil
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

            // 스트릭 (funStreak 가드): 오늘부터 거꾸로 연속 토큰>0 일수.
            if settings.funStreak {
                data.streakDays = statsStore.streakDays(endingOn: now, calendar: .utc)
            }

            // 주간 리포트 (funWeeklyReport 가드, 월요일 morning에만 BriefingEngine이 사용).
            if settings.funWeeklyReport {
                fillWeeklyReport(&data, statsStore: statsStore, now: now, calendar: calendar)
            }
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

    /// 월요일 주간 리포트 4필드를 채운다 — dailyTotalsByService(days:14)로 지난주/전전주 분리.
    /// "지난주" = now 직전 7일(어제 포함 7일), "전주" = 그 이전 7일.
    private func fillWeeklyReport(_ data: inout BriefingEngine.BriefingData,
                                  statsStore: DailyStatsStore, now: Date, calendar: Calendar) {
        let startOfToday = calendar.startOfDay(for: now)
        // 지난주 경계: [today-7, today), 전주: [today-14, today-7).
        guard let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: startOfToday),
              let prevWeekStart = calendar.date(byAdding: .day, value: -14, to: startOfToday) else { return }

        let rows = statsStore.dailyTotalsByService(days: 14, now: now, calendar: .utc)
        var lastWeek = 0
        var prevWeek = 0
        for row in rows {
            if row.day >= lastWeekStart && row.day < startOfToday {
                lastWeek += row.tokens
            } else if row.day >= prevWeekStart && row.day < lastWeekStart {
                prevWeek += row.tokens
            }
        }
        guard lastWeek > 0 else { return }
        data.lastWeekTokens = lastWeek
        data.prevWeekTokens = prevWeek
        // 지난주 비용 = [D-7, 오늘) 정확 범위. (이전엔 14일-7일 = 전전주 비용이 섞였음.)
        data.lastWeekCost = statsStore.totalCost(from: lastWeekStart, to: startOfToday, calendar: .utc)
        // 지난주 top project: 14일 breakdown 중 최대 (정밀 일별 분리 미지원 — 근사).
        data.lastWeekTopProject = statsStore.projectBreakdown(days: 14, now: now, calendar: .utc).first?.project
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
        dashboardPanel?.close()
        if let win = settingsWindow {
            centerOnCurrentScreen(win)
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(settings: settings, hudController: hudController,
                                onMenubarModeChange: { [weak self] in self?.updateStatusTitle() },
                                onReplayOnboarding: { [weak self] in self?.openOnboarding() })
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "AI Glass 설정"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        centerOnCurrentScreen(win)
        win.delegate = self
        settingsWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func centerOnCurrentScreen(_ window: NSWindow) {
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        guard let frame = screen?.visibleFrame else {
            window.center()
            return
        }
        let size = window.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
        window.setFrameOrigin(origin)
    }

    func windowWillClose(_ notification: Notification) {
        let win = notification.object as? NSWindow
        if win === settingsWindow {
            settingsWindow = nil
        } else if win === onboardingWindow {
            onboardingWindow = nil
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        dashboardPanel?.toggle(relativeTo: button)
    }
}
