import SwiftUI
import AIGlassCore

/// 설정 창. 임계값/HUD/알림/자동시작/Antigravity 쿼터를 조정한다.
/// 변경은 AppSettings(UserDefaults)에 즉시 반영되며, HUD 표시는 hudController로 바로 토글된다.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    weak var hudController: HUDPanelController?

    var body: some View {
        Form {
            Section("알림 임계값") {
                Stepper(value: $settings.warnThreshold,
                        in: 50...(settings.critThreshold - 5), step: 5) {
                    Text("경고: \(Int(settings.warnThreshold))%")
                }
                Stepper(value: $settings.critThreshold,
                        in: (settings.warnThreshold + 5)...99, step: 5) {
                    Text("위험: \(Int(settings.critThreshold))%")
                }
            }

            Section("표시 / 알림") {
                Toggle("HUD 표시", isOn: $settings.hudVisible)
                    .onChange(of: settings.hudVisible) { _, newValue in
                        hudController?.setVisible(newValue)
                    }
                Toggle("알림 보내기", isOn: $settings.notificationsEnabled)
            }

            Section("시스템") {
                Toggle("로그인 시 시작", isOn: $settings.launchAtLogin)
                    .disabled(!LaunchAtLogin.isAvailable)
                    .onChange(of: settings.launchAtLogin) { _, newValue in
                        LaunchAtLogin.set(newValue)
                    }
                if !LaunchAtLogin.isAvailable {
                    Text("앱 번들에서만 가능 (make-app.sh로 .app 생성 후)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Antigravity") {
                TextField("일일 쿼터", value: $settings.geminiDailyQuota, format: .number)
                    .frame(width: 100)
                Text("재시작 후 적용")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("전역 단축키: ⌘⇧U")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }
}
