import SwiftUI
import Charts
import AIGlassCore

struct DashboardView: View {
    let store: UsageStore
    @State private var tab: Tab = .overview

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "개요", trends = "추이", models = "모델별"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .overview: OverviewTab(store: store)
            case .trends: TrendsTab(store: store)
            case .models: ModelsTab(store: store)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct OverviewTab: View {
    let store: UsageStore
    var body: some View {
        VStack(spacing: 10) {
            ForEach(ServiceID.allCases) { service in
                ServiceRow(service: service, windows: store.limits[service] ?? [])
            }
            HStack(spacing: 8) {
                StatCard(value: formatTokens(store.todayTokens(now: Date())), label: "오늘 토큰")
                StatCard(value: "\(store.todayRequests(now: Date()))", label: "오늘 요청")
                StatCard(value: "\(Int(store.maxUsedPercent))%", label: "최고 사용률")
            }
        }
    }
    private func formatTokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }
}

private struct ServiceRow: View {
    let service: ServiceID
    let windows: [LimitWindow]

    private var primary: LimitWindow? {
        windows.first { $0.kind == .session5h } ?? windows.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(Theme.color(for: service)).frame(width: 8, height: 8)
                Text(service.displayName).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(primary.map { "\(Int($0.usedPercent))%" } ?? "–")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(primary.map { Theme.statusColor(percent: $0.usedPercent) } ?? .secondary)
            }
            GaugeBar(percent: primary?.usedPercent ?? 0, tint: Theme.color(for: service))
            Text(subline)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var subline: String {
        guard !windows.isEmpty else { return "데이터 없음" }
        return windows.map { window in
            var part = "\(window.kind.label) \(Int(window.usedPercent))%"
            if let resets = window.resetsAt {
                part += " · 리셋 \(EventEngine.countdown(to: resets, from: Date()))"
            }
            return part
        }.joined(separator: "  ·  ")
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 14, weight: .bold).monospacedDigit())
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct TrendsTab: View {
    let store: UsageStore
    var body: some View {
        let data = store.dailyTotals(days: 7, now: Date())
        Chart(data, id: \.day) { item in
            BarMark(x: .value("날짜", item.day, unit: .day), y: .value("토큰", item.tokens))
                .foregroundStyle(.linearGradient(colors: [.blue, .purple],
                                                 startPoint: .bottom, endPoint: .top))
                .cornerRadius(3)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) {
                AxisValueLabel(format: .dateTime.day(), centered: true)
            }
        }
        .frame(height: 160)
    }
}

private struct ModelsTab: View {
    let store: UsageStore
    var body: some View {
        let models = store.modelBreakdown(days: 7, now: Date())
        let total = max(1, models.reduce(0) { $0 + $1.tokens })
        VStack(spacing: 8) {
            if models.isEmpty {
                Text("최근 7일 데이터 없음").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            ForEach(models.prefix(6), id: \.model) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.model).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text("\(Int(Double(item.tokens) / Double(total) * 100))%")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    GaugeBar(percent: Double(item.tokens) / Double(total) * 100, tint: .purple)
                }
            }
        }
    }
}
