import SwiftUI
import AIGlassCore

/// 설정 창. 임계값/HUD/알림/자동시작/Antigravity 쿼터를 조정한다.
/// 변경은 AppSettings(UserDefaults)에 즉시 반영되며, HUD 표시는 hudController로 바로 토글된다.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    weak var hudController: HUDPanelController?
    /// 메뉴바 모드 변경 시 타이틀 즉시 갱신 (다음 refresh까지 안 기다림).
    var onMenubarModeChange: () -> Void = {}

    var body: some View {
        Form {
            Section("임계값") {
                Stepper(value: $settings.warnThreshold,
                        in: 50...(settings.critThreshold - 5), step: 5) {
                    Text("경고: \(Int(settings.warnThreshold))%")
                }
                Stepper(value: $settings.critThreshold,
                        in: (settings.warnThreshold + 5)...99, step: 5) {
                    Text("위험: \(Int(settings.critThreshold))%")
                }
                Text("게이지 색상과 알림 기준에 함께 적용됩니다")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("표시할 에이전트") {
                ForEach(ServiceID.allCases) { service in
                    Toggle(service.displayName, isOn: enabledBinding(for: service))
                        .disabled(settings.enabledServices == [service]) // 마지막 1개는 못 끔
                }
                Text("끄면 대시보드·HUD·알림에서 제외됩니다")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("표시 / 알림") {
                Toggle("HUD 표시", isOn: $settings.hudVisible)
                    .onChange(of: settings.hudVisible) { _, newValue in
                        hudController?.setVisible(newValue)
                    }
                Toggle("알림 보내기", isOn: $settings.notificationsEnabled)
            }

            Section("HUD 표시 정보") {
                Toggle("사용률 %", isOn: $settings.hudShowsPercent)
                Toggle("리셋 카운트다운", isOn: $settings.hudShowsCountdown)
                Text("알약에 표시할 항목을 고릅니다 (웨이브는 항상 표시)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("메뉴바") {
                Picker("표시 모드", selection: $settings.menubarMode) {
                    ForEach(MenubarMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .onChange(of: settings.menubarMode) { _, _ in onMenubarModeChange() }
                Text("메뉴바에 고정 표시할 정보를 고릅니다")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("웨이브 스타일") {
                Picker("스타일", selection: $settings.waveStyle) {
                    ForEach(WaveStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
            }

            Section("재미") {
                Toggle("마일스톤 (오늘 누적 돌파)", isOn: $settings.funMilestone)
                Toggle("신기록 (역대 최대 갱신)", isOn: $settings.funRecord)
                Toggle("스트릭 (연속 사용일)", isOn: $settings.funStreak)
                Toggle("주간 리포트 (월요일 아침)", isOn: $settings.funWeeklyReport)
                Toggle("알림 사운드", isOn: $settings.funSoundEnabled)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("전역 단축키")
                    Text("⌘⇧U  대시보드 토글")
                    Text("⌘⇧E  HUD 호버 카드 고정")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 서비스 표시 토글 바인딩 — 마지막 1개를 끄려는 시도는 무시(최소 1개 보장).
    private func enabledBinding(for service: ServiceID) -> Binding<Bool> {
        Binding(
            get: { settings.enabledServices.contains(service) },
            set: { newValue in
                if newValue {
                    settings.enabledServices.insert(service)
                } else if settings.enabledServices.count > 1 {
                    settings.enabledServices.remove(service)
                }
            })
    }
}
