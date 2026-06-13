import SwiftUI
import AIGlassCore

/// 설정 창. macOS 표준 탭 설정 창(일반/표시/HUD/재미)으로 재편.
/// 변경은 AppSettings(UserDefaults)에 즉시 반영되며, HUD 표시는 hudController로 바로 토글된다.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    weak var hudController: HUDPanelController?
    @State private var showCustomEditor = false
    /// 메뉴바 모드 변경 시 타이틀 즉시 갱신 (다음 refresh까지 안 기다림).
    var onMenubarModeChange: () -> Void = {}
    /// "온보딩 다시 보기" 버튼 — 온보딩 위저드를 강제로 띄운다.
    var onReplayOnboarding: () -> Void = {}
    /// 커스텀 메시지 미리보기 — 샘플 HUD 카드를 잠깐 띄운다.
    var onPreviewEvent: (HUDEvent) -> Void = { _ in }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("일반", systemImage: "gearshape") }
            displayTab
                .tabItem { Label("표시", systemImage: "rectangle.3.group") }
            hudTab
                .tabItem { Label("HUD", systemImage: "capsule") }
            notificationsTab
                .tabItem { Label("알림", systemImage: "bell") }
            messagesTab
                .tabItem { Label("메시지", systemImage: "quote.bubble") }
        }
        .frame(width: 500, height: 540)
        .sheet(isPresented: $showCustomEditor) {
            CustomMessagesEditor(settings: settings, onPreview: onPreviewEvent)
        }
    }

    // MARK: - 일반 — 로그인 시 시작 / 알림 / 온보딩 다시 보기

    private var generalTab: some View {
        Form {
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

            Section("온보딩") {
                Button("온보딩 다시 보기") { onReplayOnboarding() }
                Text("첫 실행 시 보았던 튜토리얼을 다시 표시합니다")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 표시 — 메뉴바 모드 / 표시할 에이전트 / 임계값 / Antigravity 쿼터

    private var displayTab: some View {
        Form {
            Section("메뉴바") {
                ForEach(MenubarItem.allCases) { item in
                    Toggle(item.label, isOn: menubarItemBinding(for: item))
                }
                Text("켤 항목을 고르세요 — 모두 끄면 ✦ 아이콘만 표시됩니다")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: settings.menubarItems) { _, _ in onMenubarModeChange() }

            Section("표시할 에이전트") {
                ForEach(ServiceID.allCases) { service in
                    Toggle(service.displayName, isOn: enabledBinding(for: service))
                        .disabled(settings.enabledServices == [service]) // 마지막 1개는 못 끔
                }
                Text("끄면 대시보드·HUD·알림에서 제외됩니다")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Antigravity") {
                TextField("일일 쿼터", value: $settings.geminiDailyQuota, format: .number)
                    .frame(width: 100)
                Text("재시작 후 적용")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - HUD — 웨이브 스타일 / HUD 표시 정보 / 단축키 안내

    private var hudTab: some View {
        Form {
            Section("HUD") {
                Toggle("HUD 표시", isOn: $settings.hudVisible)
                    .onChange(of: settings.hudVisible) { _, newValue in
                        hudController?.setVisible(newValue)
                    }
            }

            Section("웨이브 스타일") {
                Picker("스타일", selection: $settings.waveStyle) {
                    ForEach(WaveStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .onChange(of: settings.waveStyle) { _, _ in onMenubarModeChange() }
                HStack {
                    Spacer()
                    WaveStylePreview(style: settings.waveStyle)
                        .frame(height: 30)
                    Spacer()
                }
            }

            Section("HUD 표시 정보") {
                Toggle("사용률 %", isOn: $settings.hudShowsPercent)
                Toggle("리셋 카운트다운", isOn: $settings.hudShowsCountdown)
                Text("알약에 표시할 항목을 고릅니다 (웨이브는 항상 표시)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("전역 단축키") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("⌘⇧U  대시보드 토글")
                    Text("⌘⇧E  HUD 호버 카드 고정")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 알림 — 종류별 on/off (사용량 / 활동·요약 / 재미) + 전달 방식

    private var notificationsTab: some View {
        Form {
            Section("사용량 알림") {
                Toggle("한도 임박 (경고 · 위험 도달)", isOn: $settings.notifyLimitThreshold)
                Toggle("소진 임박 (리셋 전 소진 예측)", isOn: $settings.notifyDepletion)
                Toggle("새 윈도우 시작 (한도 리셋)", isOn: $settings.notifyWindowReset)
                Toggle("사용량 급증 (평소보다 빠른 소모)", isOn: $settings.notifyBurnSpike)
            }

            Section("한도 임박 기준") {
                Stepper(value: $settings.warnThreshold,
                        in: 50...(settings.critThreshold - 5), step: 5) {
                    Text("경고: \(Int(settings.warnThreshold))%")
                }
                Stepper(value: $settings.critThreshold,
                        in: (settings.warnThreshold + 5)...99, step: 5) {
                    Text("위험: \(Int(settings.critThreshold))%")
                }
                Text("이 값에서 한도 임박 알림이 뜨며, 게이지 색상에도 함께 적용됩니다")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("활동 · 요약") {
                Toggle("컴백 (공백 후 재개)", isOn: $settings.notifyComeback)
                Toggle("시간대별 브리핑 (아침·점심·저녁)", isOn: $settings.notifyBriefing)
                Toggle("업데이트 (새 버전 출시)", isOn: $settings.notifyUpdate)
            }

            Section("재미") {
                Toggle("마일스톤 (오늘 누적 돌파)", isOn: $settings.funMilestone)
                Toggle("신기록 (역대 최대 갱신)", isOn: $settings.funRecord)
                Toggle("스트릭 (연속 사용일)", isOn: $settings.funStreak)
                Toggle("주간 리포트 (월요일 아침)", isOn: $settings.funWeeklyReport)
            }

            Section("전달 방식") {
                Toggle("알림 사운드", isOn: $settings.funSoundEnabled)
                Toggle("시스템 알림센터 배너", isOn: $settings.notificationsEnabled)
                Text("기본은 HUD 카드로 표시합니다. 배너를 켜면 macOS 알림센터로도 보냅니다")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 메시지 — REAL Mode / 커스텀 알림 문구

    private var messagesTab: some View {
        Form {
            Section("REAL Mode 😎") {
                Toggle("REAL Mode 켜기", isOn: $settings.realMode)
                Text("당신의 AI들의 속내를 들어볼 수 있습니다. (정보 %·시간은 그대로 유지돼요)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("커스텀 메시지") {
                Button("커스텀 메시지 편집…") { showCustomEditor = true }
                Text("이벤트별로 나만의 알림 문구를 직접 정할 수 있어요. {AGENT} {USAGE} 같은 변수도 사용 가능하고, 여러 개를 넣으면 무작위로 번갈아 표시됩니다")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// 메뉴바 항목 토글 바인딩 — 켜고 끔 자유(빈 집합 허용 = ✦ 아이콘).
    private func menubarItemBinding(for item: MenubarItem) -> Binding<Bool> {
        Binding(
            get: { settings.menubarItems.contains(item) },
            set: { on in
                if on { settings.menubarItems.insert(item) }
                else { settings.menubarItems.remove(item) }
            })
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
