import SwiftUI
import Charts
import AIGlassCore

struct DashboardView: View {
    let store: UsageStore
    @State private var tab: Tab = .overview

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "개요", trends = "추이", projects = "프로젝트"
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
            case .projects: ProjectsTab(store: store)
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
                StatCard(value: formatTokens(Int(store.tokensPerMinute(windowMinutes: 3, now: Date()))), label: "현재 t/min")
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
        windows.max { $0.usedPercent < $1.usedPercent }
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
            GaugeBar(percent: primary?.usedPercent ?? 0, tint: Theme.statusColor(percent: primary?.usedPercent ?? 0))
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

    private struct Point: Identifiable {
        let id = UUID()
        let day: Date
        let service: ServiceID
        let tokens: Int
    }

    var body: some View {
        let data = store.dailyTotalsByService(days: 7, now: Date())
            .map { Point(day: $0.day, service: $0.service, tokens: $0.tokens) }
        Chart(data) { item in
            BarMark(x: .value("날짜", item.day, unit: .day), y: .value("토큰", item.tokens))
                .foregroundStyle(by: .value("서비스", item.service.displayName))
                .cornerRadius(3)
        }
        .chartForegroundStyleScale([
            "Claude Code": Theme.color(for: .claude),
            "Codex": Theme.color(for: .codex),
            "Gemini": Theme.color(for: .gemini),
        ])
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) {
                AxisValueLabel(format: .dateTime.day(), centered: true)
            }
        }
        .chartLegend(position: .bottom)
        .font(.system(size: 9))
        .frame(height: 160)
    }
}

private struct ProjectsTab: View {
    let store: UsageStore
    var body: some View {
        let projects = store.projectBreakdown(days: 7, now: Date())
        let total = max(1, projects.reduce(0) { $0 + $1.tokens })
        VStack(spacing: 8) {
            if projects.isEmpty {
                Text("최근 7일 데이터 없음").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            ForEach(projects.prefix(6), id: \.project) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.project).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text(formatTokens(item.tokens))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("\(Int(Double(item.tokens) / Double(total) * 100))%")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    GaugeBar(percent: Double(item.tokens) / Double(total) * 100, tint: .purple)
                }
            }
            if !projects.isEmpty {
                Text("Claude Code · Codex 기준 (Gemini는 프로젝트 정보 없음)")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
