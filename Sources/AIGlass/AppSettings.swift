import Foundation
import Observation
import AIGlassCore

/// 메뉴바 표시 모드.
enum MenubarMode: String, CaseIterable, Identifiable {
    /// 오늘 누적 토큰 ↔ 소모 속도(burn) 6초 로테이션 (기본).
    case todayAndBurn
    /// 서비스별 사용률 6초 로테이션 ("● C 49%").
    case serviceRotation
    /// 켜진 에이전트 중 최고 사용률 % (기존 동작).
    case maxPercent
    /// "✦"만 표시 (위험도 색 점).
    case minimalDot

    var id: String { rawValue }
    var label: String {
        switch self {
        case .todayAndBurn: return "오늘 누적 ↔ 소모 속도"
        case .serviceRotation: return "서비스별 사용률 로테이션"
        case .maxPercent: return "최고 사용률 %"
        case .minimalDot: return "미니멀 (점만)"
        }
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
        static let waveStyle = "aiglass.waveStyle"
        static let funMilestone = "aiglass.funMilestone"
        static let funRecord = "aiglass.funRecord"
        static let funStreak = "aiglass.funStreak"
        static let funWeeklyReport = "aiglass.funWeeklyReport"
        static let funSoundEnabled = "aiglass.funSoundEnabled"
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
    /// 메뉴바 표시 모드 (MenubarMode rawValue). 기본 todayAndBurn.
    var menubarMode: MenubarMode {
        didSet { defaults.set(menubarMode.rawValue, forKey: Key.menubarMode) }
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
        menubarMode = MenubarMode(rawValue: defaults.string(forKey: Key.menubarMode) ?? "") ?? .todayAndBurn
        waveStyle = WaveStyle(rawValue: defaults.string(forKey: Key.waveStyle) ?? "") ?? .pulseBars
        funMilestone = defaults.object(forKey: Key.funMilestone) as? Bool ?? true
        funRecord = defaults.object(forKey: Key.funRecord) as? Bool ?? true
        funStreak = defaults.object(forKey: Key.funStreak) as? Bool ?? true
        funWeeklyReport = defaults.object(forKey: Key.funWeeklyReport) as? Bool ?? true
        funSoundEnabled = defaults.object(forKey: Key.funSoundEnabled) as? Bool ?? false
        let raw = defaults.stringArray(forKey: Key.enabledServices) ?? []
        let parsed = Set(raw.compactMap(ServiceID.init(rawValue:)))
        enabledServices = parsed.isEmpty ? Set(ServiceID.allCases) : parsed
    }
}
