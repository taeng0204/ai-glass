import Testing
@testable import AIGlass

@MainActor @Test func menubarPillWidthAddsTextAreaToWaveWidth() {
    // 점(6) + 간격 + "100%"(11pt bold mono) + 좌우 패딩 = 52pt 고정 텍스트 영역.
    // 근사 비교: CGFloat 산술이라 릴리스 빌드의 상수 폴딩과 debug 런타임 계산이
    // 부동소수점 last-bit에서 갈릴 수 있다 (CI release에서 == 가 깨졌음).
    #expect(abs(MenubarPill.width(for: .pulseBars) - (WaveStyle.pulseBars.areaWidth + 52)) < 0.001)
    #expect(abs(MenubarPill.width(for: .orbGlow) - (WaveStyle.orbGlow.areaWidth + 52)) < 0.001)
    // orbGlow(20)는 pulseBars(36)보다 좁다 — 스타일별 폭 차이가 반영되는지.
    #expect(MenubarPill.width(for: .orbGlow) < MenubarPill.width(for: .pulseBars))
}
