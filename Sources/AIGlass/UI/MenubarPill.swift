import SwiftUI
import AppKit
import AIGlassCore

/// 메뉴바 상태 아이템 콘텐츠 — 켜진 항목(MenubarItem)을 고정 순서로 한 줄에 조합한다.
/// store·settings를 @Observable로 관찰해 토큰/속도/% 값과 항목 집합 변화에 자동 반응.
struct MenubarContentView: View {
    let store: UsageStore
    let settings: AppSettings

    private var maxPercent: Double { store.maxUsedPercent(in: settings.enabledServices) }
    private var percentColor: Color {
        Theme.statusColor(percent: maxPercent, warn: settings.warnThreshold, crit: settings.critThreshold)
    }

    var body: some View {
        let items = MenubarItem.ordered(settings.menubarItems)
        HStack(spacing: 6) {
            if items.isEmpty {
                Text("✦").foregroundStyle(percentColor) // 빈 선택 fallback
            } else {
                ForEach(Array(items.enumerated()), id: \.element) { idx, item in
                    // 텍스트끼리만 · 구분 (웨이브 앞뒤엔 안 붙임 — 웨이브 자체가 시각 구분).
                    if idx > 0, item != .wave, items[idx - 1] != .wave {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    itemView(item, isFirst: idx == 0)
                }
            }
        }
        .font(.system(size: 13, weight: .medium).monospacedDigit())
        .fixedSize()
    }

    @ViewBuilder
    private func itemView(_ item: MenubarItem, isFirst: Bool) -> some View {
        switch item {
        case .wave:
            WavePill(store: store, enabled: settings.enabledServices,
                     warn: settings.warnThreshold, crit: settings.critThreshold,
                     showsPercent: false, showsCountdown: false,
                     waveStyle: settings.waveStyle, compact: true,
                     paused: store.activityLevel(now: Date()) == 0
                          && store.requestActivityLevel(now: Date()) == 0)
                .frame(height: 22)
        case .todayTokens:
            // ✦ 접두는 첫 항목일 때만 (웨이브 등이 앞서면 중복 아이콘 방지).
            Text((isFirst ? "✦ " : "") + Self.formatTokens(store.todayTokens(now: Date())))
                .foregroundStyle(.primary)
        case .burnRate:
            Text(Self.formatRate(store.tokensPerMinute(windowMinutes: 5, now: Date())))
                .foregroundStyle(.primary)
        case .maxPercent:
            Text(Theme.formatUsagePercent(maxPercent))
                .foregroundStyle(percentColor)
        }
    }

    static func formatTokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1_000_000_000)
        case 1_000_000...: return String(format: "%.0fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    static func formatRate(_ perMinute: Double) -> String {
        let n = Int(perMinute.rounded())
        switch n {
        case 1_000_000...: return String(format: "%.1fM/m", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fK/m", Double(n) / 1_000)
        default: return "\(n)/m"
        }
    }
}

/// 클릭을 NSStatusBarButton으로 통과시키는 호스팅 뷰 — 메뉴바 클릭 → 대시보드 토글 유지.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
