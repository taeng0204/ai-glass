import Testing
@testable import AIGlass

@MainActor @Test func menubarPillWidthAddsTextAreaToWaveWidth() {
    // 점(6) + 간격 + "100%"(11pt bold mono) + 좌우 패딩 = 52pt 고정 텍스트 영역.
    #expect(MenubarPill.width(for: .pulseBars) == WaveStyle.pulseBars.areaWidth + 52)
    #expect(MenubarPill.width(for: .orbGlow) == WaveStyle.orbGlow.areaWidth + 52)
    // orbGlow(20)는 pulseBars(36)보다 좁다 — 스타일별 폭 차이가 반영되는지.
    #expect(MenubarPill.width(for: .orbGlow) < MenubarPill.width(for: .pulseBars))
}
