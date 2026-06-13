import SwiftUI
import AIGlassCore

/// 첫 실행 온보딩 위저드 (6단계, 페이지 위저드 + 진행 점 + 이전/다음).
/// 선택값은 즉시 AppSettings에 반영된다 — 위저드를 중간에 닫아도 그대로 유지.
/// 마지막 "시작하기"에서 onboardingCompleted=true, 창 닫기(onFinish).
/// 온보딩 사용 방식 트랙 — HUD 메인 vs 메뉴바 메인 (둘은 배타적으로 쓰인다).
enum OnboardingTrack { case hud, menubar }

struct OnboardingView: View {
    @Bindable var settings: AppSettings
    /// 완료/닫기 시 호출 — onboardingCompleted=true 후 창을 닫는다.
    var onFinish: () -> Void

    @State private var step = 0
    /// HUD/메뉴바 트랙 선택 (nil = 트랙 단계 이전). 영속화하지 않음 — hudVisible+menubarMode로 환원됨.
    @State private var track: OnboardingTrack?
    private let stepCount = 7

    var body: some View {
        VStack(spacing: 0) {
            // 콘텐츠
            Group {
                switch step {
                case 0: welcomeStep
                case 1: trackStep
                case 2: step2()
                case 3: step3()
                case 4: agentsStep
                case 5: funStep
                default: keychainStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 24)

            // 진행 점
            HStack(spacing: 7) {
                ForEach(0..<stepCount, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.vertical, 14)

            Divider()

            // 네비게이션
            HStack {
                if step > 0 {
                    Button("이전") { withAnimation { step -= 1 } }
                }
                Spacer()
                if step < stepCount - 1 {
                    Button("다음") { withAnimation { step += 1 } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(step == 1 && track == nil)
                } else {
                    Button("시작하기") { finish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: 560)
        .background(.regularMaterial)
    }

    private func finish() {
        settings.onboardingCompleted = true
        onFinish()
    }

    // MARK: - 1. 환영

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.purple)
            Text("AI Glass에 오신 걸 환영합니다")
                .font(.title2.bold())
            Text("Claude·Codex·Antigravity의 사용량과 한도를 메뉴바와 HUD 알약으로 한눈에 봅니다. 토큰 소진 예측, 마일스톤, 주간 리포트까지 — 작업 흐름을 방해하지 않고 곁에서 알려줍니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // 실제 WavePill 컴포넌트(데모 데이터) 정적 프리뷰.
            VStack(spacing: 8) {
                Text("이런 알약이 화면 구석에 떠 있어요")
                    .font(.caption).foregroundStyle(.secondary)
                WaveStylePreview(style: settings.waveStyle)
                    .frame(height: 34)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - 2. 웨이브 스타일 선택 (라이브 프리뷰)

    private var waveStyleStep: some View {
        VStack(spacing: 16) {
            stepHeader("웨이브 스타일", waveStyleSubtitle)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(WaveStyle.allCases) { style in
                        waveStyleRow(style)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// 트랙·메뉴바 모드에 따라 웨이브 단계 부제를 바꾼다.
    private var waveStyleSubtitle: String {
        if track == .menubar {
            return settings.menubarMode == .wavePill
                ? "메뉴바 알약의 움직임을 고르세요. 탭하면 바로 적용됩니다."
                : "웨이브 스타일은 이렇게 다양해요 — 기본(펄스 바)으로 둬도 되고, 마음에 드는 걸 골라보세요."
        }
        return "HUD 알약의 움직임을 고르세요. 탭하면 바로 적용됩니다."
    }

    private func waveStyleRow(_ style: WaveStyle) -> some View {
        let selected = settings.waveStyle == style
        return Button {
            settings.waveStyle = style
        } label: {
            HStack(spacing: 14) {
                WaveStylePreview(style: style, chrome: false)
                    .frame(width: 44, height: 26)
                Text(style.label)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 3. 메뉴바 모드 선택

    private var menubarStep: some View {
        VStack(spacing: 16) {
            stepHeader("메뉴바 표시", "메뉴바에 어떤 정보를 고정 표시할지 고르세요.")
            VStack(spacing: 10) {
                ForEach(MenubarMode.allCases) { mode in
                    menubarRow(mode)
                }
            }
            Spacer()
        }
    }

    private func menubarRow(_ mode: MenubarMode) -> some View {
        let selected = settings.menubarMode == mode
        return Button {
            settings.menubarMode = mode
        } label: {
            HStack(spacing: 14) {
                // 미니 알약은 실제 웨이브를 라이브로(다른 모드는 메뉴바 텍스트 그대로).
                Group {
                    if mode == .wavePill {
                        WaveStylePreview(style: settings.waveStyle, chrome: false)
                            .fixedSize() // "49%"가 줄바꿈되지 않도록 자연 폭 유지
                    } else {
                        Text(menubarPreviewText(mode))
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                }
                .frame(width: 108, alignment: .leading)
                Text(mode.label)
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// 텍스트 모드 프리뷰 (wavePill은 WaveStylePreview 라이브 렌더 — 여기 미포함).
    private func menubarPreviewText(_ mode: MenubarMode) -> String {
        switch mode {
        case .todayTokens: return "✦ 612M"
        case .burnRate: return "✦ 38K/m"
        case .maxPercent: return "✦ 49%"
        case .iconOnly: return "✦"
        case .wavePill: return ""
        }
    }

    // MARK: - 4. 표시할 에이전트 (감지)

    private var agentsStep: some View {
        VStack(spacing: 16) {
            stepHeader("표시할 에이전트", "사용 중인 에이전트를 켜세요. 로그 폴더가 있으면 발견 표시됩니다.")
            VStack(spacing: 10) {
                ForEach(ServiceID.allCases) { service in
                    agentRow(service)
                }
            }
            Spacer()
        }
    }

    private func agentRow(_ service: ServiceID) -> some View {
        let detected = Self.isDetected(service)
        return HStack(spacing: 12) {
            Circle()
                .fill(Theme.color(for: service))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.displayName).font(.body)
                if detected {
                    Text("발견됨 ✓").font(.caption).foregroundStyle(.green)
                } else {
                    Text("미발견").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: enabledBinding(for: service))
                .labelsHidden()
                .disabled(settings.enabledServices == [service])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 서비스별 로그 폴더 존재 확인 (FileManager).
    /// gemini는 ~/.gemini 또는 antigravity-cli 하위 중 하나라도 있으면 발견.
    static func isDetected(_ service: ServiceID) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        switch service {
        case .claude:
            return fm.fileExists(atPath: home.appendingPathComponent(".claude").path)
        case .codex:
            return fm.fileExists(atPath: home.appendingPathComponent(".codex").path)
        case .gemini:
            return fm.fileExists(atPath: home.appendingPathComponent(".gemini").path)
                || fm.fileExists(atPath: home.appendingPathComponent(".gemini/antigravity-cli").path)
        }
    }

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

    // MARK: - 5. 알림 & 재미

    private var funStep: some View {
        VStack(spacing: 16) {
            stepHeader("알림 & 재미", "원하는 알림과 재미 기능을 고르세요. 나중에 설정에서 바꿀 수 있습니다.")
            VStack(spacing: 4) {
                funToggle("알림 보내기", isOn: $settings.notificationsEnabled)
                funToggle("마일스톤 (오늘 누적 돌파)", isOn: $settings.funMilestone)
                funToggle("신기록 (역대 최대 갱신)", isOn: $settings.funRecord)
                funToggle("스트릭 (연속 사용일)", isOn: $settings.funStreak)
                funToggle("주간 리포트 (월요일 아침)", isOn: $settings.funWeeklyReport)
                funToggle("알림 사운드", isOn: $settings.funSoundEnabled)
            }
            Spacer()
        }
    }

    private func funToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 6. Keychain 안내 + 단축키

    private var keychainStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("마지막으로, Keychain 안내")
                .font(.title3.bold())
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text("Claude 한도 조회를 위해 Keychain 접근 다이얼로그가 뜨면 **항상 허용**을 눌러주세요. 한 번만 허용하면 이후엔 묻지 않습니다.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                }
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("전역 단축키")
                        Text("⌘⇧U  대시보드 토글").foregroundStyle(.secondary)
                        Text("⌘⇧E  HUD 호버 카드 고정").foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "command").foregroundStyle(.blue)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            Text("준비됐어요. \"시작하기\"를 누르면 메뉴바에서 만나요!")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - 단계 분기 (트랙별 2·3단계 순서)

    @ViewBuilder private func step2() -> some View {
        if track == .menubar { menubarStep } else { waveStyleStep }
    }
    @ViewBuilder private func step3() -> some View {
        if track == .menubar { waveStyleStep } else { menubarStep }
    }

    // MARK: - 1.5 트랙 선택

    private var trackStep: some View {
        VStack(spacing: 16) {
            stepHeader("어떻게 보고 싶으세요?",
                       "느낌 가는 쪽으로 고르세요 — 설정에서 언제든 바꿀 수 있어요.")
            VStack(spacing: 12) {
                trackCard(
                    .hud, title: "HUD 알약", icon: "rectangle.on.rectangle.angled",
                    points: ["원하는 곳에 배치", "세련된 liquid glass 스타일", "마우스 호버로 사용량 빠르게 확인"],
                    warning: nil)
                trackCard(
                    .menubar, title: "메뉴바", icon: "menubar.rectangle",
                    points: ["깔끔하게 메뉴바 안에", "다른 화면 방해 없음", "단축키로 사용량 확인"],
                    warning: "HUD 알약은 표시되지 않아요")
            }
            Spacer()
        }
    }

    /// 트랙 카드 — 탭하면 트랙 선택 + hudVisible 적용 + 다음 단계로 자동 진행.
    private func trackCard(_ t: OnboardingTrack, title: String, icon: String,
                           points: [String], warning: String?) -> some View {
        let selected = track == t
        return Button {
            track = t
            settings.hudVisible = (t == .hud)
            withAnimation { step += 1 }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    ForEach(points, id: \.self) { p in
                        Label(p, systemImage: "checkmark")
                            .font(.caption).foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    if let warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 공통

    private func stepHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.title2.bold())
            Text(subtitle)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
