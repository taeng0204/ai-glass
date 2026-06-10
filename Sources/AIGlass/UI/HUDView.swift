import SwiftUI
import AIGlassCore

@MainActor
@Observable
final class HUDState {
    var currentEvent: HUDEvent?
    var hovering = false
    private var dismissTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?

    func show(_ event: HUDEvent) {
        dismissTask?.cancel()
        withAnimation(.spring(duration: 0.55, bounce: 0.25)) { currentEvent = event }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
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

struct HUDView: View {
    let store: UsageStore
    let state: HUDState
    var onTap: () -> Void

    private var cornerRadius: CGFloat {
        if state.currentEvent != nil { return 18 }
        if state.hovering { return 16 }
        return 22
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let event = state.currentEvent {
                EventCard(event: event)
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                    .onTapGesture { onTap() }
            } else if state.hovering {
                HoverCard(store: store, onTap: onTap)
            } else {
                WavePill(store: store)
                    .contentShape(RoundedRectangle(cornerRadius: 22))
                    .onTapGesture { onTap() }
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        .onHover { state.setHover($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 2)
        .padding(.trailing, 6)
        .padding(.bottom, 4)
        .padding(.leading, 4)
    }
}

struct WavePill: View {
    let store: UsageStore

    /// 최고 사용률 서비스
    private var topService: ServiceID? {
        store.limits.max {
            ($0.value.map(\.usedPercent).max() ?? 0) < ($1.value.map(\.usedPercent).max() ?? 0)
        }?.key
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = store.activityLevel(now: context.date) // 0...1
            let amplitude = 0.15 + 0.85 * level               // idle에도 잔물결
            let bars = allocateBars(share: store.recentShare(now: context.date), barCount: 7)
            let top = topService
            HStack(spacing: 8) {
                HStack(spacing: 2.5) {
                    ForEach(0..<7, id: \.self) { i in
                        let phase = t * (2.2 + Double(i) * 0.13) + Double(i) * 0.9
                        let h = 4 + 12 * amplitude * (0.5 + 0.5 * sin(phase))
                        Capsule()
                            .fill(barGradient(bars[i]))
                            .frame(width: 3, height: h)
                    }
                }
                .frame(height: 16)
                HStack(spacing: 4) {
                    if let top {
                        Circle()
                            .fill(Theme.color(for: top))
                            .frame(width: 6, height: 6)
                    }
                    Text("\(Int(store.maxUsedPercent))%")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.statusColor(percent: store.maxUsedPercent))
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
        }
    }

    private func barGradient(_ service: ServiceID?) -> LinearGradient {
        if let service {
            let c = Theme.color(for: service)
            return LinearGradient(colors: [c.opacity(0.9), c.opacity(0.6)],
                                  startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: [.purple.opacity(0.9), .blue.opacity(0.7)],
                              startPoint: .top, endPoint: .bottom)
    }
}

struct HoverCard: View {
    let store: UsageStore
    var onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ServiceID.allCases) { service in
                row(for: service)
            }
        }
        .padding(12)
        .frame(width: 210, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { onTap() }
    }

    private func maxPercent(_ service: ServiceID) -> Double? {
        guard let windows = store.limits[service], !windows.isEmpty else { return nil }
        return windows.map(\.usedPercent).max()
    }

    @ViewBuilder
    private func row(for service: ServiceID) -> some View {
        let percent = maxPercent(service)
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.color(for: service))
                .frame(width: 6, height: 6)
            Text(service.displayName)
                .font(.system(size: 10.5, weight: .semibold))
            Spacer(minLength: 4)
            GaugeBar(percent: percent ?? 0,
                     tint: percent.map { Theme.statusColor(percent: $0) } ?? .gray)
                .frame(width: 64)
            Text(percent.map { "\(Int($0))%" } ?? "–")
                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .foregroundStyle(percent.map { Theme.statusColor(percent: $0) } ?? .secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

struct EventCard: View {
    let event: HUDEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(event.title).font(.system(size: 12, weight: .bold))
            }
            Text(event.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
            if let percent = event.percent {
                GaugeBar(percent: percent, tint: Theme.statusColor(percent: percent))
            }
        }
        .padding(12)
        .frame(width: 230, alignment: .leading)
    }

    private var icon: String {
        switch event.kind {
        case .limitThreshold: return "exclamationmark.triangle.fill"
        case .windowReset: return "sparkles"
        case .burnSpike: return "flame.fill"
        }
    }
    private var iconColor: Color {
        switch event.kind {
        case .limitThreshold: return .orange
        case .windowReset: return .green
        case .burnSpike: return .pink
        }
    }
}
