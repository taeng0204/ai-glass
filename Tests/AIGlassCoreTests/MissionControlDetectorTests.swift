import CoreGraphics
import Testing
@testable import AIGlassCore

// 실측(macOS 27, 내장 1710×1107 + 세로 외장 1440×2560, Dock 자동 숨김). 좌표는 CG(왼쪽 위 원점).
private let mainDisplay = CGRect(x: 0, y: 0, width: 1710, height: 1107)
private let external = CGRect(x: 1710, y: -765, width: 1440, height: 2560)

private func dockBar(on rect: CGRect) -> MissionControlDetector.Window {
    .init(owner: "Dock", name: "Dock", layer: 20, bounds: rect)
}
private func shield(on rect: CGRect) -> MissionControlDetector.Window {
    .init(owner: "WindowManager", name: "ExposeShieldWindow", layer: 19, bounds: rect)
}
private let menubar = MissionControlDetector.Window(owner: "Window Server", name: "Menubar", layer: 24,
                                                     bounds: CGRect(x: 0, y: 0, width: 1710, height: 34))

@Test func dockRevealedOnExternalDisplayIsNotMissionControl() {
    // 커서가 외장 모니터 아래 끝에 있어 Dock이 그쪽에 펼쳐진 상태 — 예전 판정은 이걸 미션 컨트롤로 보고 알약을 계속 내렸다.
    #expect(!MissionControlDetector.isActive(windows: [menubar, dockBar(on: external)], mainDisplay: mainDisplay))
}

@Test func dockRevealedOnMainDisplayIsNotMissionControl() {
    #expect(!MissionControlDetector.isActive(windows: [menubar, dockBar(on: mainDisplay)], mainDisplay: mainDisplay))
}

@Test func exposeShieldCoveringMainDisplayIsMissionControl() {
    // 미션 컨트롤 중 실측 창 목록: 화면마다 ExposeShieldWindow(레이어 19) + Dock 막대
    let windows = [menubar, dockBar(on: external), shield(on: external), shield(on: mainDisplay)]
    #expect(MissionControlDetector.isActive(windows: windows, mainDisplay: mainDisplay))
}

@Test func detectsShieldWithoutReadableWindowNames() {
    // 화면 기록 권한이 없으면 남의 창 이름이 비어 온다(AI Glass 실측: 권한 없음). 소유자·레이어만으로도 판단한다.
    let unnamedShield = MissionControlDetector.Window(owner: "WindowManager", name: "", layer: 19, bounds: mainDisplay)
    let unnamedDock = MissionControlDetector.Window(owner: "Dock", name: "", layer: 20, bounds: mainDisplay)
    #expect(MissionControlDetector.isActive(windows: [unnamedDock, unnamedShield], mainDisplay: mainDisplay))
    #expect(!MissionControlDetector.isActive(windows: [unnamedDock], mainDisplay: mainDisplay))
}

@Test func wallpaperWindowIsNotMissionControl() {
    // WindowManager는 화면 크기 배경화면 창도 갖고 있다 — 데스크톱 아래(음수 레이어)라 제외.
    let wallpaper = MissionControlDetector.Window(owner: "WindowManager", name: "Wallpaper", layer: -2147483624,
                                                  bounds: mainDisplay)
    #expect(!MissionControlDetector.isActive(windows: [wallpaper], mainDisplay: mainDisplay))
}

@Test func exposeShieldOnlyOnOtherDisplayDoesNotHideMainMenubarOverlay() {
    // 오버레이는 메인 화면 메뉴바에만 그린다 — 다른 화면만 덮인 경우는 상관없다.
    #expect(!MissionControlDetector.isActive(windows: [shield(on: external)], mainDisplay: mainDisplay))
}
