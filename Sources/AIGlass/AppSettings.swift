import Foundation
import Observation
import AIGlassCore

/// 메뉴바 표시 모드. 자동 로테이션 없음 — 고정 표시 (깜빡임 방지, 사용자 결정).
/// 구버전 todayAndBurn/serviceRotation 저장값은 raw 불일치로 기본값(todayTokens) 폴백.
enum MenubarMode: String, CaseIterable, Identifiable {
    /// 오늘 누적 토큰 "✦ 612M" (기본).
    case todayTokens
    /// 소모 속도 "✦ 38K/m".
    case burnRate
    /// 켜진 에이전트 중 최고 사용률 "✦ N%".
    case maxPercent
    /// "✦"만 표시 (위험도 색).
    case iconOnly
    /// HUD 웨이브 알약 미니 버전 (이슈 #1).
    case wavePill

    var id: String { rawValue }
    var label: String {
        switch self {
        case .todayTokens: return "오늘 누적 토큰"
        case .burnRate: return "소모 속도 (t/min)"
        case .maxPercent: return "최고 사용률 %"
        case .iconOnly: return "아이콘만"
        case .wavePill: return "미니 알약 (웨이브)"
        }
    }
}

/// 메뉴바에 동시 표시할 수 있는 항목 (다중 선택). 고정 순서로 렌더된다.
enum MenubarItem: String, CaseIterable, Identifiable {
    case wave         // 미니 웨이브 알약
    case todayTokens  // 오늘 누적 토큰 "612M"
    case burnRate     // 소모 속도 "38K/m"
    case maxPercent   // 최고 사용률 "49%"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .wave: return "웨이브 알약"
        case .todayTokens: return "오늘 누적 토큰"
        case .burnRate: return "소모 속도 (t/min)"
        case .maxPercent: return "최고 사용률 %"
        }
    }

    /// 주어진 집합을 allCases 고정 순으로 정렬한 배열 (렌더 순서).
    static func ordered(_ items: Set<MenubarItem>) -> [MenubarItem] {
        allCases.filter { items.contains($0) }
    }
}

/// HUD 알약 웨이브 스타일.
enum WaveStyle: String, CaseIterable, Identifiable {
    /// 펄스 바 7개 (기본).
    case pulseBars
    /// 연속 사인 물결 곡선.
    case smoothWave
    /// 흐르는 사인 파면 2겹 수위.
    case waterFill
    /// 숨쉬는 그라데이션 구슬.
    case orbGlow
    /// 심전도 하트비트 라인.
    case heartbeat

    var id: String { rawValue }
    var label: String {
        switch self {
        case .pulseBars: return "펄스 바"
        case .smoothWave: return "스무스 웨이브"
        case .waterFill: return "워터필"
        case .orbGlow: return "오브 글로우"
        case .heartbeat: return "하트비트"
        }
    }
}

/// 사용자 설정. UserDefaults 백킹, 네임스페이스 키 `aiglass.*`.
/// 단위 테스트는 코어가 아니므로 생략(수동 검증).
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let warnThreshold = "aiglass.warnThreshold"
        static let critThreshold = "aiglass.critThreshold"
        static let hudVisible = "aiglass.hudVisible"
        static let notificationsEnabled = "aiglass.notificationsEnabled"
        static let geminiDailyQuota = "aiglass.geminiDailyQuota"
        static let launchAtLogin = "aiglass.launchAtLogin"
        static let hudFrame = "aiglass.hudFrame"
        static let enabledServices = "aiglass.enabledServices"
        static let hudShowsPercent = "aiglass.hudShowsPercent"
        static let hudShowsCountdown = "aiglass.hudShowsCountdown"
        static let menubarMode = "aiglass.menubarMode"
        static let menubarItems = "aiglass.menubarItems"
        static let waveStyle = "aiglass.waveStyle"
        static let funMilestone = "aiglass.funMilestone"
        static let funRecord = "aiglass.funRecord"
        static let funStreak = "aiglass.funStreak"
        static let funWeeklyReport = "aiglass.funWeeklyReport"
        static let funSoundEnabled = "aiglass.funSoundEnabled"
        static let onboardingCompleted = "aiglass.onboardingCompleted"
    }

    var warnThreshold: Double {
        didSet { defaults.set(warnThreshold, forKey: Key.warnThreshold) }
    }
    var critThreshold: Double {
        didSet { defaults.set(critThreshold, forKey: Key.critThreshold) }
    }
    var hudVisible: Bool {
        didSet { defaults.set(hudVisible, forKey: Key.hudVisible) }
    }
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }
    var geminiDailyQuota: Int {
        didSet { defaults.set(geminiDailyQuota, forKey: Key.geminiDailyQuota) }
    }
    /// SMAppService와 동기화 (배선은 LaunchAtLogin에서).
    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }
    /// NSStringFromRect 직렬화된 HUD 패널 프레임. nil이면 기본 위치.
    var hudFrame: String? {
        didSet { defaults.set(hudFrame, forKey: Key.hudFrame) }
    }
    /// 대시보드/HUD에 표시할 에이전트. 최소 1개 보장은 UI(SettingsView)에서. 기본 전체.
    var enabledServices: Set<ServiceID> {
        didSet { defaults.set(enabledServices.map(\.rawValue).sorted(), forKey: Key.enabledServices) }
    }
    /// HUD 알약에 사용률 %를 표시할지. 끄면 점+웨이브(+카운트다운)만.
    var hudShowsPercent: Bool {
        didSet { defaults.set(hudShowsPercent, forKey: Key.hudShowsPercent) }
    }
    /// HUD 알약에 리셋 카운트다운(작은 회색)을 표시할지.
    var hudShowsCountdown: Bool {
        didSet { defaults.set(hudShowsCountdown, forKey: Key.hudShowsCountdown) }
    }
    /// 메뉴바 표시 모드 (MenubarMode rawValue). 기본 todayTokens.
    /// (레거시 — menubarItems로 마이그레이션됨. 신규 코드는 menubarItems 사용.)
    var menubarMode: MenubarMode {
        didSet { defaults.set(menubarMode.rawValue, forKey: Key.menubarMode) }
    }
    /// 메뉴바에 동시 표시할 항목 집합 (다중). 빈 집합이면 ✦ 아이콘만. 기본 [.todayTokens].
    var menubarItems: Set<MenubarItem> {
        didSet { defaults.set(menubarItems.map(\.rawValue).sorted(), forKey: Key.menubarItems) }
    }

    /// 구 단일 모드 → 신 항목 집합 1:1 변환.
    static func migratedItems(from mode: MenubarMode) -> Set<MenubarItem> {
        switch mode {
        case .todayTokens: return [.todayTokens]
        case .burnRate:    return [.burnRate]
        case .maxPercent:  return [.maxPercent]
        case .iconOnly:    return []        // 빈 집합 = ✦ fallback
        case .wavePill:    return [.wave]
        }
    }
    /// HUD 알약 웨이브 스타일 (WaveStyle rawValue). 기본 pulseBars.
    var waveStyle: WaveStyle {
        didSet { defaults.set(waveStyle.rawValue, forKey: Key.waveStyle) }
    }
    /// 재미 — 마일스톤 알림. 기본 on.
    var funMilestone: Bool {
        didSet { defaults.set(funMilestone, forKey: Key.funMilestone) }
    }
    /// 재미 — 신기록 알림. 기본 on.
    var funRecord: Bool {
        didSet { defaults.set(funRecord, forKey: Key.funRecord) }
    }
    /// 재미 — 스트릭(연속 사용일) 브리핑 표기. 기본 on.
    var funStreak: Bool {
        didSet { defaults.set(funStreak, forKey: Key.funStreak) }
    }
    /// 재미 — 월요일 주간 리포트. 기본 on.
    var funWeeklyReport: Bool {
        didSet { defaults.set(funWeeklyReport, forKey: Key.funWeeklyReport) }
    }
    /// 재미 — 알림성 이벤트 시 사운드 재생. 기본 off.
    var funSoundEnabled: Bool {
        didSet { defaults.set(funSoundEnabled, forKey: Key.funSoundEnabled) }
    }
    /// 첫 실행 온보딩 완료 여부. false면 앱 시작 시 온보딩 위저드 표시. 기본 false.
    var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    init() {
        warnThreshold = defaults.object(forKey: Key.warnThreshold) as? Double ?? 70
        critThreshold = defaults.object(forKey: Key.critThreshold) as? Double ?? 90
        hudVisible = defaults.object(forKey: Key.hudVisible) as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true
        geminiDailyQuota = defaults.object(forKey: Key.geminiDailyQuota) as? Int ?? 1000
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false
        hudFrame = defaults.string(forKey: Key.hudFrame)
        hudShowsPercent = defaults.object(forKey: Key.hudShowsPercent) as? Bool ?? true
        hudShowsCountdown = defaults.object(forKey: Key.hudShowsCountdown) as? Bool ?? true
        // 구버전 raw(todayAndBurn/serviceRotation 등) 불일치 시 기본값 폴백 = 마이그레이션.
        let resolvedMode = MenubarMode(rawValue: defaults.string(forKey: Key.menubarMode) ?? "") ?? .todayTokens
        menubarMode = resolvedMode
        waveStyle = WaveStyle(rawValue: defaults.string(forKey: Key.waveStyle) ?? "") ?? .pulseBars
        funMilestone = defaults.object(forKey: Key.funMilestone) as? Bool ?? true
        funRecord = defaults.object(forKey: Key.funRecord) as? Bool ?? true
        funStreak = defaults.object(forKey: Key.funStreak) as? Bool ?? true
        funWeeklyReport = defaults.object(forKey: Key.funWeeklyReport) as? Bool ?? true
        funSoundEnabled = defaults.object(forKey: Key.funSoundEnabled) as? Bool ?? false
        onboardingCompleted = defaults.object(forKey: Key.onboardingCompleted) as? Bool ?? false
        let raw = defaults.stringArray(forKey: Key.enabledServices) ?? []
        let parsed = Set(raw.compactMap(ServiceID.init(rawValue:)))
        enabledServices = parsed.isEmpty ? Set(ServiceID.allCases) : parsed
        // 메뉴바 항목: 신 포맷 키가 있으면 그대로, 없으면 구 menubarMode에서 1회 마이그레이션.
        if let rawItems = defaults.stringArray(forKey: Key.menubarItems) {
            menubarItems = Set(rawItems.compactMap(MenubarItem.init(rawValue:)))
        } else {
            menubarItems = Self.migratedItems(from: resolvedMode)
        }
    }
}
