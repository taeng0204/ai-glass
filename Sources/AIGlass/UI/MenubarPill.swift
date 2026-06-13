import SwiftUI
import AppKit
import AIGlassCore

/// 메뉴바 상태 아이템 콘텐츠 — 켜진 항목(MenubarItem)을 고정 순서로 한 줄에 조합한다.
/// store·settings를 @Observable로 관찰해 값과 항목 집합 변화에 자동 반응.
/// 사용률·리셋시간 항목은 HUD처럼 6초마다 서비스 로테이션하므로 TimelineView로 갱신한다.
struct MenubarContentView: View {
    let store: UsageStore
    let settings: AppSettings

    private var enabled: Set<ServiceID> { settings.enabledServices }
    private func color(_ p: Double) -> Color {
        Theme.statusColor(percent: p, warn: settings.warnThreshold, crit: settings.critThreshold)
    }

    /// limits가 있고 enabled인 서비스 (HUD WavePill과 동일 기준).
    private var rotationServices: [ServiceID] {
        ServiceID.allCases.filter { enabled.contains($0) && !(store.limits[$0]?.isEmpty ?? true) }
    }
    /// 서비스 표시 윈도우: session5h 우선, 없으면 최댓값 윈도우.
    private func displayWindow(_ s: ServiceID) -> LimitWindow? {
        guard let ws = store.limits[s], !ws.isEmpty else { return nil }
        if let s5h = ws.first(where: { $0.kind == .session5h }) { return s5h }
        return ws.max { $0.usedPercent < $1.usedPercent }
    }
    /// 리셋 카운트다운: resetsAt(미래) 우선, 없으면 approxFullReset("~"). 둘 다 없으면 nil.
    private func resetText(_ s: ServiceID, now: Date) -> String? {
        guard let w = displayWindow(s) else { return nil }
        if let r = w.resetsAt, r > now { return EventEngine.countdown(to: r, from: now) }
        if let a = store.approxFullReset(service: s, kind: w.kind, now: now) {
            return "~" + EventEngine.countdown(to: a, from: now)
        }
        return nil
    }
    /// 6초마다 바뀌는 로테이션 current 서비스 (HUD WavePill과 동일 위상 — 같은 t 기준).
    private func current(now: Date) -> ServiceID? {
        let svc = rotationServices
        guard !svc.isEmpty else { return nil }
        return svc[Int(now.timeIntervalSinceReferenceDate / 6) % svc.count]
    }

    var body: some View {
        let items = MenubarItem.ordered(settings.menubarItems)
        let needsRotation = items.contains(.usagePercent) || items.contains(.resetCountdown)
        Group {
            if needsRotation {
                // 로테이션(6초)·카운트다운(분) 갱신 — 1초 주기면 충분(저비용).
                TimelineView(.animation(minimumInterval: 1.0)) { ctx in
                    row(items, now: ctx.date)
                }
            } else {
                row(items, now: Date())
            }
        }
    }

    @ViewBuilder
    private func row(_ items: [MenubarItem], now: Date) -> some View {
        let cur = current(now: now)
        HStack(spacing: 6) {
            if items.isEmpty {
                Text("✦").foregroundStyle(color(store.maxUsedPercent(in: enabled)))
            } else {
                ForEach(Array(items.enumerated()), id: \.element) { idx, item in
                    // 텍스트끼리만 · 구분 (웨이브 앞뒤엔 안 붙임 — 웨이브 자체가 시각 구분).
                    if idx > 0, item != .wave, items[idx - 1] != .wave {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    itemView(item, isFirst: idx == 0, now: now, current: cur)
                }
            }
        }
        .font(.system(size: 13, weight: .medium).monospacedDigit())
        .fixedSize()
    }

    @ViewBuilder
    private func itemView(_ item: MenubarItem, isFirst: Bool, now: Date, current: ServiceID?) -> some View {
        switch item {
        case .wave:
            WavePill(store: store, enabled: settings.enabledServices,
                     warn: settings.warnThreshold, crit: settings.critThreshold,
                     showsPercent: false, showsCountdown: false,
                     waveStyle: settings.waveStyle, compact: true,
                     paused: store.activityLevel(now: now) == 0
                          && store.requestActivityLevel(now: now) == 0)
                .frame(height: 22)
        case .todayTokens:
            // ✦ 접두는 첫 항목일 때만 (웨이브 등이 앞서면 중복 아이콘 방지).
            Text((isFirst ? "✦ " : "") + Self.formatTokens(store.todayTokens(now: now)))
                .foregroundStyle(.primary)
        case .burnRate:
            Text(Self.formatRate(store.tokensPerMinute(windowMinutes: 5, now: now)))
                .foregroundStyle(.primary)
        case .usagePercent:
            // 로테이션 서비스의 점(서비스색) + 5h %.
            if let cur = current, let w = displayWindow(cur) {
                HStack(spacing: 4) {
                    Circle().fill(Theme.color(for: cur)).frame(width: 6, height: 6)
                    Text(Theme.formatUsagePercent(w.usedPercent)).foregroundStyle(color(w.usedPercent))
                }
            } else {
                Text("–%").foregroundStyle(.secondary)
            }
        case .resetCountdown:
            // 로테이션 서비스의 리셋까지 남은 시간.
            if let cur = current, let t = resetText(cur, now: now) {
                Text(t).foregroundStyle(.secondary)
            } else {
                Text("–").foregroundStyle(.secondary)
            }
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
/// `onResize`로 레이아웃 완료 시점의 콘텐츠 크기를 알려, statusItem 폭을 정확히 맞춘다
/// (외부에서 fittingSize 타이밍을 추측하지 않게 — 콘텐츠 변경 시 자동 갱신).
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    var onResize: ((CGSize) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        onResize?(fittingSize)
    }
}
