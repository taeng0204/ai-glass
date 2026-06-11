import Foundation
import ServiceManagement

/// 로그인 시 자동 시작 (SMAppService.mainApp).
/// swift run 환경에서는 .app 번들이 아니므로 no-op (등록 시도가 무의미/오류).
enum LaunchAtLogin {
    /// .app 번들로 실행 중일 때만 동작. (swift run에서도 bundleIdentifier가 nil이 아닐 수 있어
    /// 확실한 가드로 번들 URL의 확장자가 .app인지 확인한다.)
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        guard isAvailable else {
            NSLog("[AIGlass] LaunchAtLogin: .app 번들이 아니라 무시 (swift run 환경). make-app.sh로 번들 생성 후 사용하세요.")
            return
        }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("[AIGlass] LaunchAtLogin 토글 실패: \(error)")
        }
    }
}
