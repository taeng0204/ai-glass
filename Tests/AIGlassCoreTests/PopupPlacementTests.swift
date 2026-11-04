import CoreGraphics
import Testing
@testable import AIGlassCore

// 메인 화면 visibleFrame 예: 1710×1073 (메뉴바 34pt 아래), 원점 (0,0)
private let visible = CGRect(x: 0, y: 0, width: 1710, height: 1073)
private let size = CGSize(width: 336, height: 400)

@Test func offsetRoundTripsThroughFrame() {
    let topLeft = CGPoint(x: 700, y: 900)
    let frame = CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
    let off = PopupPlacement.offset(frame: frame, visible: visible)
    #expect(PopupPlacement.topLeft(offset: off, size: size, visible: visible) == topLeft)
}

@Test func offsetIsMeasuredFromTopRightCorner() {
    // 패널을 우상단 모서리에서 (20, 30)만큼 안쪽에 둔 경우
    let frame = CGRect(x: visible.maxX - 20 - size.width, y: visible.maxY - 30 - size.height,
                       width: size.width, height: size.height)
    let off = PopupPlacement.offset(frame: frame, visible: visible)
    #expect(off == CGPoint(x: 20, y: 30))
}

@Test func savedOffsetFollowsTheCornerWhenResolutionChanges() {
    // 같은 오프셋이 더 작은 화면에서도 우상단 모서리 기준으로 열린다
    let small = CGRect(x: 0, y: 0, width: 1280, height: 777)
    let tl = PopupPlacement.topLeft(offset: CGPoint(x: 40, y: 60), size: size, visible: small)
    #expect(tl == CGPoint(x: 1280 - 336 - 40, y: 777 - 60))
}

@Test func clampKeepsPanelFullyInsideVisibleArea() {
    // 오른쪽·아래로 너무 나간 위치 → 안쪽으로
    let c1 = PopupPlacement.clamp(topLeft: CGPoint(x: 5000, y: -500), size: size, visible: visible)
    #expect(c1.x == visible.maxX - size.width - PopupPlacement.margin)
    #expect(c1.y == visible.minY + size.height) // 아래 모서리가 화면 아래 끝에 닿음
    // 왼쪽·위로 너무 나간 위치 → 안쪽으로 (메뉴바 밑)
    let c2 = PopupPlacement.clamp(topLeft: CGPoint(x: -999, y: 9999), size: size, visible: visible)
    #expect(c2.x == visible.minX + PopupPlacement.margin)
    #expect(c2.y == visible.maxY)
}

@Test func clampLeavesAValidPositionUntouched() {
    let p = CGPoint(x: 400, y: 800)
    #expect(PopupPlacement.clamp(topLeft: p, size: size, visible: visible) == p)
}

@Test func clampHandlesPanelLargerThanScreen() {
    let tiny = CGRect(x: 0, y: 0, width: 300, height: 300)
    let c = PopupPlacement.clamp(topLeft: CGPoint(x: 50, y: 50), size: CGSize(width: 500, height: 600), visible: tiny)
    #expect(c.x == tiny.minX + PopupPlacement.margin) // 왼쪽 위에 붙임
    #expect(c.y == tiny.maxY)
}

@Test func defaultPositionIsBelowAnchorRightAligned() {
    // 상태 아이템 창: (1175, 1073, 89, 34) → 팝업 우측 끝 = 아이템 우측 끝, 위 끝 = 아이템 아래 2pt
    let anchor = CGRect(x: 1175, y: 1073, width: 89, height: 34)
    let tl = PopupPlacement.defaultTopLeft(anchor: anchor, size: size, visible: visible)
    #expect(tl.x == anchor.maxX - size.width)
    #expect(tl.y == anchor.minY - 2)
}

@Test func defaultPositionFallsBackToTopRightWithoutAnchor() {
    let tl = PopupPlacement.defaultTopLeft(anchor: nil, size: size, visible: visible)
    #expect(tl.x == visible.maxX - size.width - 8)
    #expect(tl.y == visible.maxY - 2)
}

@Test func defaultPositionIsClampedWhenAnchorIsNearTheScreenEdge() {
    // 아이템이 화면 오른쪽 끝에 붙어 있어 우측 정렬하면 화면 밖으로 나가는 경우
    let anchor = CGRect(x: 1690, y: 1073, width: 89, height: 34)
    let tl = PopupPlacement.defaultTopLeft(anchor: anchor, size: size, visible: visible)
    #expect(tl.x == visible.maxX - size.width - PopupPlacement.margin)
}
