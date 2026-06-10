import SwiftUI
import AIGlassCore

@MainActor
@Observable
final class HUDState {
    var currentEvent: HUDEvent?
    private var dismissTask: Task<Void, Never>?

    func show(_ event: HUDEvent) {
        dismissTask?.cancel()
        withAnimation(.spring(duration: 0.55, bounce: 0.25)) { currentEvent = event }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.45)) { self?.currentEvent = nil }
        }
    }
}

struct HUDView: View {
    let store: UsageStore
    let state: HUDState
    var onTap: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let event = state.currentEvent {
                EventCard(event: event)
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                    .onTapGesture { onTap() }
            } else {
                WavePill(store: store)
                    .contentShape(RoundedRectangle(cornerRadius: 22))
                    .onTapGesture { onTap() }
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: state.currentEvent != nil ? 18 : 22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(10)
    }
}

struct WavePill: View {
    let store: UsageStore

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = store.activityLevel(now: context.date) // 0...1
            let amplitude = 0.15 + 0.85 * level               // idle에도 잔물결
            HStack(spacing: 8) {
                HStack(spacing: 2.5) {
                    ForEach(0..<7, id: \.self) { i in
                        let phase = t * (2.2 + Double(i) * 0.13) + Double(i) * 0.9
                        let h = 4 + 12 * amplitude * (0.5 + 0.5 * sin(phase))
                        Capsule()
                            .fill(LinearGradient(colors: [.purple.opacity(0.9), .blue.opacity(0.7)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 3, height: h)
                    }
                }
                .frame(height: 16)
                Text("\(Int(store.maxUsedPercent))%")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.statusColor(percent: store.maxUsedPercent))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
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
