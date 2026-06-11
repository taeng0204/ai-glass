import Foundation
import Observation

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

    init() {
        warnThreshold = defaults.object(forKey: Key.warnThreshold) as? Double ?? 70
        critThreshold = defaults.object(forKey: Key.critThreshold) as? Double ?? 90
        hudVisible = defaults.object(forKey: Key.hudVisible) as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true
        geminiDailyQuota = defaults.object(forKey: Key.geminiDailyQuota) as? Int ?? 1000
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false
        hudFrame = defaults.string(forKey: Key.hudFrame)
    }
}
