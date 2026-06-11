import Foundation
import UserNotifications

/// 알림센터 래퍼. UNUserNotificationCenter는 번들 없이 호출하면 crash하므로,
/// .app 번들일 때만 동작하고 그 외엔 no-op (swift run 보호).
@MainActor
final class Notifier {
    /// .app 번들로 실행 중일 때만 사용 가능.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private var didRequestAuthorization = false

    func notify(title: String, subtitle: String) {
        guard Notifier.isAvailable else { return }
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty { content.subtitle = subtitle }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]) { granted, error in
            if let error { NSLog("[AIGlass] 알림 권한 요청 실패: \(error)") }
            _ = granted
        }
    }
}
