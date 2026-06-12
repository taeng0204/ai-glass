import SwiftUI
import AppKit
import AIGlassCore

/// 메뉴바 미니 알약 (이슈 #1) — HUD WavePill의 compact 변형을 NSStatusItem에 띄운다.
enum MenubarPill {
    /// 상태 아이템 고정 폭: 웨이브 영역 + 텍스트 영역(점 6 + 간격 + "100%" + 좌우 패딩) 52pt.
    /// % 자릿수가 변해도 폭이 출렁이지 않도록 고정한다 (이웃 메뉴바 아이템 점프 방지).
    static func width(for style: WaveStyle) -> CGFloat {
        style.areaWidth + 52
    }
}

/// 메뉴바 상태 아이템에 들어가는 미니 웨이브 알약 뷰.
/// idle(활동 0)이면 TimelineView를 멈춰 상시 애니메이션 비용을 없앤다 —
/// store가 @Observable이라 다음 데이터 갱신 때 body가 재평가되며 자동 재개된다.
struct MenubarPillView: View {
    let store: UsageStore
    let settings: AppSettings

    private var paused: Bool {
        let now = Date()
        return store.activityLevel(now: now) == 0 && store.requestActivityLevel(now: now) == 0
    }

    var body: some View {
        WavePill(store: store,
                 enabled: settings.enabledServices,
                 warn: settings.warnThreshold,
                 crit: settings.critThreshold,
                 showsPercent: true,
                 showsCountdown: false, // 메뉴바 폭 절약 — 카운트다운은 호버카드/대시보드에서
                 waveStyle: settings.waveStyle,
                 compact: true,
                 paused: paused)
            .frame(width: MenubarPill.width(for: settings.waveStyle), height: 22, alignment: .leading)
    }
}

/// 클릭을 NSStatusBarButton으로 통과시키는 호스팅 뷰 — 메뉴바 클릭 → 대시보드 토글 유지.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
