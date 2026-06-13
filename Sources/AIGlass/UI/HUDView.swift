import SwiftUI
import Combine
import AIGlassCore

@MainActor
@Observable
final class HUDState {
    var currentEvent: HUDEvent?
    var hovering = false
    /// ⌘⇧E로 호버 카드를 고정 표시. true면 마우스가 떠나도 카드 유지.
    var pinnedExpand = false
    private var dismissTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?

    /// 호버 카드를 보여야 하는가 (hover 중이거나 expand 고정).
    var showsHoverCard: Bool { hovering || pinnedExpand }

    /// ⌘⇧E 토글 — expand 고정 켜기/끄기.
    func togglePinnedExpand() {
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { pinnedExpand.toggle() }
    }

    func show(_ event: HUDEvent, duration: TimeInterval = 6) {
        dismissTask?.cancel()
        withAnimation(.spring(duration: 0.55, bounce: 0.25)) { currentEvent = event }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.45)) { self?.currentEvent = nil }
        }
    }

    func setHover(_ inside: Bool) {
        hoverTask?.cancel()
        if inside {
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) { hovering = true }
        } else {
            hoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(duration: 0.35)) { self?.hovering = false }
            }
        }
    }
}

/// share 비율로 barCount개 바에 서비스를 배분한다.
/// 큰 share부터 floor로 바 개수를 할당하고, 잔여 바는 share가 큰 순서로 한 개씩 분배한다.
/// 빈 share면 전부 nil. 결과는 좌→우로 서비스 그룹을 연속 배치한다(셔플 없음).
func allocateBars(share: [ServiceID: Double], barCount: Int) -> [ServiceID?] {
    guard barCount > 0 else { return [] }
    guard !share.isEmpty else { return Array(repeating: nil, count: barCount) }

    // share 큰 순서로 정렬 (동률은 ServiceID rawValue로 안정 정렬)
    let sorted = share.sorted { lhs, rhs in
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        return lhs.key.rawValue < rhs.key.rawValue
    }

    // floor 할당
    var counts: [(service: ServiceID, count: Int, remainder: Double)] = sorted.map { svc, frac in
        let exact = frac * Double(barCount)
        let floored = Int(exact.rounded(.down))
        return (svc, floored, exact - Double(floored))
    }

    var assigned = counts.reduce(0) { $0 + $1.count }
    var leftover = barCount - assigned

    // 잔여 바를 remainder가 큰 순서로 분배. remainder 동률이면 share 큰 순서(이미 sorted) 유지.
    let order = counts.enumerated().sorted { a, b in
        if a.element.remainder != b.element.remainder { return a.element.remainder > b.element.remainder }
        return a.offset < b.offset
    }.map { $0.offset }

    var oi = 0
    while leftover > 0 {
        counts[order[oi % order.count]].count += 1
        leftover -= 1
        oi += 1
    }
    assigned = counts.reduce(0) { $0 + $1.count }

    // 좌→우 연속 배치
    var result: [ServiceID?] = []
    for entry in counts {
        result.append(contentsOf: Array(repeating: ServiceID?.some(entry.service), count: entry.count))
    }
    // 안전장치: barCount에 정확히 맞춤
    if result.count > barCount { result = Array(result.prefix(barCount)) }
    while result.count < barCount { result.append(nil) }
    return result
}

/// 이벤트 종류별 아이콘/색 — EventCard와 대시보드 기록 탭에서 공유.
extension HUDEvent.Kind {
    var iconName: String {
        switch self {
        case .limitThreshold: return "exclamationmark.triangle.fill"
        case .depletionRisk: return "hourglass.bottomhalf.filled"
        case .windowReset: return "sparkles"
        case .burnSpike: return "flame.fill"
        case .comeback: return "figure.wave"
        case .milestone: return "party.popper.fill"
        case .record: return "trophy.fill"
        case .briefing(let period):
            switch period {
            case .morning: return "sun.max.fill"
            case .lunch: return "gauge.with.needle"
            case .evening: return "moon.stars.fill"
            }
        }
    }
    var iconColor: Color {
        switch self {
        case .limitThreshold: return .orange
        case .depletionRisk: return .orange
        case .windowReset: return .green
        case .burnSpike: return .pink
        case .comeback: return .cyan
        case .milestone: return .yellow
        case .record: return .orange
        case .briefing(let period):
            switch period {
            case .morning: return .yellow
            case .lunch: return .blue
            case .evening: return .indigo
            }
        }
    }
}

struct HUDView: View {
    let store: UsageStore
    let state: HUDState
    let settings: AppSettings
    var onTap: () -> Void
    /// 클릭 바운스 트리거.
    @State private var bounce = false

    /// 켜진 서비스만 (allCases 순 유지).
    private var enabled: Set<ServiceID> { settings.enabledServices }

    private var cornerRadius: CGFloat {
        if state.currentEvent != nil { return 18 }
        if state.showsHoverCard { return 16 }
        return 22
    }

    private func tapped() {
        bounce = true
        withAnimation(.spring(duration: 0.35, bounce: 0.5)) { bounce = false }
        onTap()
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let event = state.currentEvent {
                EventCard(event: event, warn: settings.warnThreshold, crit: settings.critThreshold)
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                    .onTapGesture { tapped() }
            } else if !settings.hudVisible {
                // 알림 전용 모드 — 카드 dismiss 후 패널이 숨겨질 때까지 빈 상태 유지.
                Color.clear.frame(width: 1, height: 1)
            } else if state.showsHoverCard {
                HoverCard(store: store, enabled: enabled,
                          warn: settings.warnThreshold, crit: settings.critThreshold, onTap: tapped)
            } else {
                WavePill(store: store, enabled: enabled,
                         warn: settings.warnThreshold, crit: settings.critThreshold,
                         showsPercent: settings.hudShowsPercent,
                         showsCountdown: settings.hudShowsCountdown,
                         waveStyle: settings.waveStyle)
                    .contentShape(RoundedRectangle(cornerRadius: 22))
                    .onTapGesture { tapped() }
            }
        }
        .scaleEffect(bounce ? 0.94 : 1.0)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        .onHover { state.setHover($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(10)
    }
}

struct WavePill: View {
    let store: UsageStore
    /// 표시할 서비스 (enabled 필터). 기본 전체.
    var enabled: Set<ServiceID> = Set(ServiceID.allCases)
    var warn: Double = 70
    var crit: Double = 90
    /// 사용률 % 표시 여부 (설정 hudShowsPercent).
    var showsPercent: Bool = true
    /// 리셋 카운트다운(작은 회색) 표시 여부 (설정 hudShowsCountdown).
    var showsCountdown: Bool = true
    /// 웨이브 스타일 (설정 waveStyle). 기본 펄스 바.
    var waveStyle: WaveStyle = .pulseBars
    /// 메뉴바 등 좁은 컨테이너용 — 패딩 최소화, 빨강 글로우 생략. 기본 false(HUD 원형 유지).
    var compact: Bool = false
    /// true면 TimelineView 정지 (idle 시 에너지 절약 — 메뉴바는 상시 노출).
    var paused: Bool = false

    /// limits가 있고 enabled인 서비스 — claude, codex, gemini 고정 순.
    private var rotationServices: [ServiceID] {
        ServiceID.allCases.filter { enabled.contains($0) && !(store.limits[$0]?.isEmpty ?? true) }
    }

    /// 서비스의 표시 윈도우: session5h 우선, 없으면 최댓값 윈도우.
    private func displayWindow(_ service: ServiceID) -> LimitWindow? {
        guard let windows = store.limits[service], !windows.isEmpty else { return nil }
        if let s5h = windows.first(where: { $0.kind == .session5h }) { return s5h }
        return windows.max { $0.usedPercent < $1.usedPercent }
    }

    /// 서비스의 표시 %: session5h 윈도우 우선, 없으면 최댓값 윈도우.
    private func displayPercent(_ service: ServiceID) -> Double {
        displayWindow(service)?.usedPercent ?? 0
    }

    /// 표시 윈도우의 리셋 카운트다운. resetsAt(미래)이 있으면 정확, 없으면 approxFullReset("~"), 둘 다 없으면 nil.
    private func resetCountdown(_ service: ServiceID, now: Date) -> String? {
        guard let window = displayWindow(service) else { return nil }
        if let resets = window.resetsAt, resets > now {
            return EventEngine.countdown(to: resets, from: now)
        }
        if let approx = store.approxFullReset(service: service, kind: window.kind, now: now) {
            return "~" + EventEngine.countdown(to: approx, from: now)
        }
        return nil
    }

    /// enabled 서비스 중 최대 사용률 (글로우/대체 % 표기용).
    private var maxEnabledPercent: Double {
        ServiceID.allCases
            .filter { enabled.contains($0) }
            .compactMap { store.limits[$0]?.map(\.usedPercent).max() }
            .max() ?? 0
    }

    /// enabled 서비스만 남긴 recent share (합 1.0 재정규화).
    private func filteredShare(now: Date) -> [ServiceID: Double] {
        let full = store.recentActivityShare(now: now).filter { enabled.contains($0.key) }
        let grand = full.values.reduce(0, +)
        guard grand > 0 else { return [:] }
        return full.mapValues { $0 / grand }
    }

    /// 리셋 카운트다운 텍스트 — 분 단위라 1초에 1회만 갱신(매 프레임 문자열 포맷 낭비 제거).
    @State private var displayCountdown: String?
    /// idle 저프레임 여부 — 1Hz로 갱신(@State라 변경 시 body 재평가 → TimelineView 스케줄 갱신).
    /// 계산 프로퍼티로 두면 idle 진입(시간 경과)이 body 재평가를 트리거하지 않아 30fps가 고착된다.
    @State private var slowFrame = false

    /// 카운트다운·저프레임 상태를 1Hz로 재계산해 @State에 반영한다.
    private func refreshDynamicState(now: Date) {
        // 카운트다운 (현재 로테이션 서비스 기준)
        let services = rotationServices
        if showsCountdown, !services.isEmpty {
            let current = services[Int(now.timeIntervalSinceReferenceDate / 6) % services.count]
            displayCountdown = resetCountdown(current, now: now)
        } else {
            displayCountdown = nil
        }
        // idle 저프레임: 활동 0 + 한도 글로우 불필요 + 메뉴바 정지 모드 아님
        slowFrame = !paused
            && store.activityLevel(now: now) == 0
            && store.requestActivityLevel(now: now) == 0
            && maxEnabledPercent < crit
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: slowFrame ? 1.0 / 8.0 : 1.0 / 30.0,
                                paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = max(store.activityLevel(now: context.date),
                            store.requestActivityLevel(now: context.date)) // 0...1
            let amplitude = 0.15 + 0.85 * level               // idle에도 잔물결
            let share = filteredShare(now: context.date)
            let services = rotationServices
            // 6초마다 로테이션 (limits 서비스 순환)
            let index = services.isEmpty ? 0 : Int(t / 6) % services.count
            let current: ServiceID? = services.isEmpty ? nil : services[index]
            let percent = current.map(displayPercent) ?? maxEnabledPercent
            // 현재 롤링 중인 서비스의 표시 윈도우가 임계값 이상일 때만 빨강 글로우 호흡.
            let critical = current != nil && percent >= crit
            let glow = 0.5 + 0.5 * sin(t * (2 * .pi / 2.0)) // 0...1, 2초 주기
            let glowRadius = critical ? 6 + 8 * glow : 0

            // 카운트다운은 1Hz @State(refreshCountdown)에서 갱신 — 매 프레임 재계산하지 않는다.
            let countdown = current != nil ? displayCountdown : nil

            let input = WaveInput(t: t, level: level, amplitude: amplitude,
                                  share: share, current: current, percent: percent)

            HStack(spacing: 8) {
                waveView(input)
                    .frame(width: waveStyle.areaWidth, height: 16)
                // 점+%+카운트다운 묶음: 로테이션(index) 변화 시 위↔아래 슬라이드 전환.
                HStack(spacing: 4) {
                    if let current {
                        Circle()
                            .fill(Theme.color(for: current))
                            .frame(width: 6, height: 6)
                    }
                    if showsPercent {
                        Text(Theme.formatUsagePercent(percent))
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(Theme.statusColor(percent: percent, warn: warn, crit: crit))
                    }
                    if let countdown {
                        Text(countdown)
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .id(index)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
                .fixedSize()
                .frame(height: 16)
                .clipped()
            }
            .padding(.horizontal, compact ? 4 : 13)
            .padding(.vertical, compact ? 0 : 8)
            .shadow(color: .red.opacity(!compact && critical ? 0.55 * glow + 0.2 : 0),
                    radius: compact ? 0 : glowRadius)
            .animation(.spring(duration: 0.45), value: index)
        }
        .onAppear { refreshDynamicState(now: Date()) }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            refreshDynamicState(now: now)
        }
    }

    /// 설정된 스타일에 맞는 웨이브 서브뷰. 입력(share/level/amplitude/percent)은 공통.
    @ViewBuilder
    private func waveView(_ input: WaveInput) -> some View {
        switch waveStyle {
        case .pulseBars: PulseBarsWave(input: input)
        case .smoothWave: SmoothWave(input: input)
        case .waterFill: WaterFillWave(input: input)
        case .orbGlow: OrbGlowWave(input: input)
        case .heartbeat: HeartbeatWave(input: input)
        }
    }
}

struct HoverCard: View {
    let store: UsageStore
    /// 표시할 서비스 (enabled 필터). 기본 전체.
    var enabled: Set<ServiceID> = Set(ServiceID.allCases)
    var warn: Double = 70
    var crit: Double = 90
    var onTap: () -> Void

    /// 서비스당 표시 순서: 5h → 주간 → 일일. 존재하는 윈도우만.
    private static let kindOrder: [LimitWindow.Kind] = [.session5h, .weekly, .daily]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ServiceID.allCases.filter { enabled.contains($0) }) { service in
                serviceBlock(for: service)
            }
        }
        .padding(12)
        // 100%와 d-포맷 카운트다운("6d 23h 59m")까지 잘림 없이 들어가도록 폭 확보.
        .frame(width: 238, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { onTap() }
    }

    /// 서비스가 가진 윈도우를 표시 순서대로 정렬해 반환.
    private func windows(for service: ServiceID) -> [LimitWindow] {
        guard let windows = store.limits[service], !windows.isEmpty else { return [] }
        return Self.kindOrder.compactMap { kind in windows.first(where: { $0.kind == kind }) }
    }

    /// 대시보드 개요와 동일한 의미론: resetsAt(미래)이 있으면 정확 카운트다운,
    /// 없거나 이미 지났으면 approxFullReset 근사(`~` + 톤 다운), 둘 다 없으면 nil.
    /// (기존엔 resetsAt만 봐서 Codex처럼 근사만 가능한 서비스는 시간이 통째로 빠졌다.)
    private func countdown(_ window: LimitWindow, service: ServiceID) -> (text: String, isApprox: Bool)? {
        let now = Date()
        if let resetsAt = window.resetsAt, resetsAt > now {
            return (EventEngine.countdown(to: resetsAt, from: now), false)
        }
        if let approx = store.approxFullReset(service: service, kind: window.kind, now: now) {
            return ("~" + EventEngine.countdown(to: approx, from: now), true)
        }
        return nil
    }

    /// 서비스명+점은 첫 줄에만, 이후 줄은 들여쓰기. 윈도우 없으면 단일 "–" 줄.
    @ViewBuilder
    private func serviceBlock(for service: ServiceID) -> some View {
        let rows = windows(for: service)
        VStack(alignment: .leading, spacing: 3) {
            if rows.isEmpty {
                header(service: service)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, window in
                    if idx == 0 {
                        header(service: service)
                    }
                    metricRow(window, service: service)
                }
            }
        }
    }

    /// 서비스명 + 점 (첫 줄 헤더).
    private func header(service: ServiceID) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.color(for: service))
                .frame(width: 6, height: 6)
            Text(service.displayName)
                .font(.system(size: 10.5, weight: .semibold))
        }
    }

    /// 한 윈도우 줄: 라벨 + 게이지 + % + 리셋 카운트다운(`~`는 근사 시간에만, tertiary 톤 다운).
    /// leading=false면 헤더 아래 들여쓰기.
    private func metricRow(_ window: LimitWindow, service: ServiceID) -> some View {
        let percent = window.usedPercent
        let tint = Theme.statusColor(percent: percent, warn: warn, crit: crit)
        return HStack(spacing: 6) {
            Text(window.kind.label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            GaugeBar(percent: percent, tint: tint)
                .frame(width: 50)
            Text(Theme.formatUsagePercent(percent))
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .frame(width: 36, alignment: .trailing)
            if let cd = countdown(window, service: service) {
                Text(cd.text)
                    .font(.system(size: 8.5).monospacedDigit())
                    .foregroundStyle(cd.isApprox ? AnyShapeStyle(.tertiary)
                                                 : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .frame(width: 56, alignment: .trailing) // "6d 23h 59m" 수용
            } else {
                Spacer(minLength: 0).frame(width: 56)
            }
        }
        .padding(.leading, 14)
    }
}

struct EventCard: View {
    let event: HUDEvent
    var warn: Double = 70
    var crit: Double = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: event.kind.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(event.kind.iconColor)
                Text(event.title).font(.system(size: 12, weight: .bold))
            }
            Text(event.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
            if let percent = event.percent {
                GaugeBar(percent: percent, tint: Theme.statusColor(percent: percent, warn: warn, crit: crit))
            }
        }
        .padding(12)
        .frame(width: 230, alignment: .leading)
    }
}
