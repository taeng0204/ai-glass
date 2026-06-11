import SwiftUI
import AIGlassCore

@MainActor
@Observable
final class HUDState {
    var currentEvent: HUDEvent?
    var hovering = false
    private var dismissTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?

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

    private var cornerRadius: CGFloat {
        if state.currentEvent != nil { return 18 }
        if state.hovering { return 16 }
        return 22
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let event = state.currentEvent {
                EventCard(event: event, warn: settings.warnThreshold, crit: settings.critThreshold)
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                    .onTapGesture { onTap() }
            } else if state.hovering {
                HoverCard(store: store, warn: settings.warnThreshold, crit: settings.critThreshold, onTap: onTap)
            } else {
                WavePill(store: store, warn: settings.warnThreshold, crit: settings.critThreshold)
                    .contentShape(RoundedRectangle(cornerRadius: 22))
                    .onTapGesture { onTap() }
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        .onHover { state.setHover($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(10)
    }
}

struct WavePill: View {
    let store: UsageStore
    var warn: Double = 70
    var crit: Double = 90

    /// limits가 있는 서비스 — claude, codex, gemini 고정 순.
    private var rotationServices: [ServiceID] {
        ServiceID.allCases.filter { !(store.limits[$0]?.isEmpty ?? true) }
    }

    /// 서비스의 표시 %: session5h 윈도우 우선, 없으면 최댓값 윈도우.
    private func displayPercent(_ service: ServiceID) -> Double {
        guard let windows = store.limits[service], !windows.isEmpty else { return 0 }
        if let s5h = windows.first(where: { $0.kind == .session5h }) { return s5h.usedPercent }
        return windows.map(\.usedPercent).max() ?? 0
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = store.activityLevel(now: context.date) // 0...1
            let amplitude = 0.15 + 0.85 * level               // idle에도 잔물결
            let share = store.recentShare(now: context.date)
            let services = rotationServices
            // 6초마다 로테이션 (limits 서비스 순환)
            let index = services.isEmpty ? 0 : Int(t / 6) % services.count
            let current: ServiceID? = services.isEmpty ? nil : services[index]
            let percent = current.map(displayPercent) ?? store.maxUsedPercent

            HStack(spacing: 8) {
                waveBars(t: t, amplitude: amplitude, share: share)
                    .frame(height: 16)
                // 점+% 묶음: 로테이션(index) 변화 시 위↔아래 슬라이드 전환.
                HStack(spacing: 4) {
                    if let current {
                        Circle()
                            .fill(Theme.color(for: current))
                            .frame(width: 6, height: 6)
                    }
                    Text("\(Int(percent))%")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.statusColor(percent: percent, warn: warn, crit: crit))
                }
                .id(index)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
                .frame(width: 44, height: 16)
                .clipped()
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .animation(.spring(duration: 0.45), value: index)
        }
    }

    /// 7개 바(높이 애니메이션) HStack을 mask로, share 누적 가로 그라데이션을 fill.
    private func waveBars(t: Double, amplitude: Double, share: [ServiceID: Double]) -> some View {
        let mask = HStack(spacing: 2.5) {
            ForEach(0..<7, id: \.self) { i in
                let phase = t * (2.2 + Double(i) * 0.13) + Double(i) * 0.9
                let h = 4 + 12 * amplitude * (0.5 + 0.5 * sin(phase))
                Capsule().frame(width: 3, height: h)
            }
        }
        .frame(height: 16)
        // Rectangle은 greedy라 가용 폭 전체로 확장되어 알약이 길어진다.
        // 바 7개×폭3 + 간격6×2.5 = 21 + 15 = 36pt로 고정.
        return Rectangle()
            .fill(waveGradient(share: share))
            .mask(mask)
            .frame(width: 7 * 3 + 6 * 2.5, height: 16)
    }

    /// share 비례 누적 위치에 서비스 색을 배치한 가로 그라데이션.
    /// 경계마다 ±0.08 오프셋 stop을 두어 부드럽게 블렌딩. 활동 없으면 보라-파랑.
    private func waveGradient(share: [ServiceID: Double]) -> LinearGradient {
        let active = ServiceID.allCases.compactMap { svc -> (ServiceID, Double)? in
            guard let s = share[svc], s > 0 else { return nil }
            return (svc, s)
        }
        guard !active.isEmpty else {
            return LinearGradient(colors: [.purple.opacity(0.9), .blue.opacity(0.7)],
                                  startPoint: .leading, endPoint: .trailing)
        }
        var stops: [Gradient.Stop] = []
        var cursor = 0.0
        for (i, entry) in active.enumerated() {
            let (svc, frac) = entry
            let c = Theme.color(for: svc)
            let start = cursor
            let end = cursor + frac
            // 경계 블렌딩: 시작은 +0.08 이전부터(첫 세그먼트 제외), 끝은 -0.08 이후까지.
            let blendStart = i == 0 ? start : max(start, start - 0.08)
            let blendEnd = i == active.count - 1 ? 1.0 : min(1.0, end - 0.08)
            stops.append(.init(color: c, location: blendStart))
            stops.append(.init(color: c, location: max(blendStart, blendEnd)))
            cursor = end
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }
}

struct HoverCard: View {
    let store: UsageStore
    var warn: Double = 70
    var crit: Double = 90
    var onTap: () -> Void

    /// 서비스당 표시 순서: 5h → 주간 → 일일. 존재하는 윈도우만.
    private static let kindOrder: [LimitWindow.Kind] = [.session5h, .weekly, .daily]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ServiceID.allCases) { service in
                serviceBlock(for: service)
            }
        }
        .padding(12)
        .frame(width: 210, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { onTap() }
    }

    /// 서비스가 가진 윈도우를 표시 순서대로 정렬해 반환.
    private func windows(for service: ServiceID) -> [LimitWindow] {
        guard let windows = store.limits[service], !windows.isEmpty else { return [] }
        return Self.kindOrder.compactMap { kind in windows.first(where: { $0.kind == kind }) }
    }

    private func countdown(_ window: LimitWindow) -> String? {
        guard let resetsAt = window.resetsAt else { return nil }
        return EventEngine.countdown(to: resetsAt, from: Date())
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
                    metricRow(window)
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

    /// 한 윈도우 줄: 라벨 + 게이지 + % + 리셋 카운트다운.
    /// leading=false면 헤더 아래 들여쓰기.
    private func metricRow(_ window: LimitWindow) -> some View {
        let percent = window.usedPercent
        let tint = Theme.statusColor(percent: percent, warn: warn, crit: crit)
        return HStack(spacing: 6) {
            Text(window.kind.label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            GaugeBar(percent: percent, tint: tint)
                .frame(width: 50)
            Text("\(Int(percent))%")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(tint)
                .frame(width: 30, alignment: .trailing)
            if let cd = countdown(window) {
                Text(cd)
                    .font(.system(size: 8.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            } else {
                Spacer(minLength: 0).frame(width: 40)
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
