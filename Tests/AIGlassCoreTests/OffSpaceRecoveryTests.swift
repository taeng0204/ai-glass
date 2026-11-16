import Foundation
import Testing
@testable import AIGlassCore

// 실측(macOS 27, 9일 연속 실행): 메뉴바 오버레이 창이 창 서버에서 스페이스 3개 중 1개에만 소속된 채 굳었다.
// AppKit은 isVisible=true라 다시 올리지 않았고, 다른 데스크톱에서는 알약이 사라졌다.
// 판단: 보이는 상태인데 현재 스페이스에 없는 상태가 잠깐 이어지면 창을 새로 만든다.

private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

/// 시각 s(초)에 한 번 판단하고 결과를 돌려준다. (#expect 안에서는 mutating 호출을 못 해서 분리)
private func check(_ r: inout OffSpaceRecovery, visible: Bool = true, onActiveSpace: Bool, at s: TimeInterval) -> Bool {
    r.shouldRebuild(visible: visible, onActiveSpace: onActiveSpace, now: t0 + s)
}

@Test func neverRebuildsWhileOnActiveSpace() {
    var r = OffSpaceRecovery()
    var rebuilt = false
    for s in stride(from: 0.0, through: 120.0, by: 1.0) {
        rebuilt = rebuilt || check(&r, onActiveSpace: true, at: s)
    }
    #expect(!rebuilt)
}

@Test func rebuildsAfterStayingOffSpaceForConfirmTime() {
    var r = OffSpaceRecovery()
    let first = check(&r, onActiveSpace: false, at: 0)
    let almost = check(&r, onActiveSpace: false, at: OffSpaceRecovery.confirmTime - 0.1)
    let confirmed = check(&r, onActiveSpace: false, at: OffSpaceRecovery.confirmTime)
    #expect(!first)
    #expect(!almost)
    #expect(confirmed)
}

@Test func hiddenPanelIsNeverRebuilt() {
    // 오버레이를 일부러 내린 상태(미션 컨트롤·Hidden Bar 등)에서는 스페이스 소속을 따지지 않는다.
    var r = OffSpaceRecovery()
    let a = check(&r, visible: false, onActiveSpace: false, at: 0)
    let b = check(&r, visible: false, onActiveSpace: false, at: 10)
    #expect(!a)
    #expect(!b)
}

@Test func offSpaceTimerRestartsWhenPanelComesBackOrHides() {
    var r = OffSpaceRecovery()
    _ = check(&r, onActiveSpace: false, at: 0)
    _ = check(&r, onActiveSpace: true, at: 0.3)          // 다시 현재 스페이스에 보이면 초기화
    let afterBack = check(&r, onActiveSpace: false, at: 0.6)
    _ = check(&r, visible: false, onActiveSpace: false, at: 0.7)   // 숨겨져도 초기화
    let afterHide = check(&r, onActiveSpace: false, at: 1.0)
    let confirmed = check(&r, onActiveSpace: false, at: 1.0 + OffSpaceRecovery.confirmTime)
    #expect(!afterBack)
    #expect(!afterHide)
    #expect(confirmed)
}

@Test func cooldownPreventsRebuildLoopWhenNewPanelIsStillOffSpace() {
    // 새 창도 현재 스페이스에 못 붙는 환경(예: 특수 스페이스)이면 매초 다시 만들지 않는다.
    var r = OffSpaceRecovery()
    _ = check(&r, onActiveSpace: false, at: 0)
    let firstRebuild = check(&r, onActiveSpace: false, at: 1)
    var rebuiltDuringCooldown = false
    for s in stride(from: 2.0, to: 1 + OffSpaceRecovery.cooldown, by: 1.0) {
        rebuiltDuringCooldown = rebuiltDuringCooldown || check(&r, onActiveSpace: false, at: s)
    }
    let afterCooldown = check(&r, onActiveSpace: false, at: 1 + OffSpaceRecovery.cooldown)
    #expect(firstRebuild)
    #expect(!rebuiltDuringCooldown)
    #expect(afterCooldown)
}
