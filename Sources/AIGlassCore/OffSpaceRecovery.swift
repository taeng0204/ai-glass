import Foundation

/// 보이는 상태인데 현재 스페이스에 없는 창을 새로 만들지 판단한다.
///
/// 실측(macOS 27, 9일 연속 실행): 메뉴바 오버레이 창이 창 서버에서 스페이스 3개 중 1개에만 소속된 채 굳었다.
/// canJoinAllSpaces와 sticky 태그는 그대로였고, AppKit은 `isVisible == true`라 다시 올리지 않아 다른 데스크톱에서는
/// 알약이 사라졌다. orderOut/orderFront나 collectionBehavior 재설정으로는 복구되지 않고, 새로 만든 창은 모든 스페이스에
/// 정상 소속됐다. 어떤 사건(디스플레이·스페이스 재구성 추정)이 원인인지는 특정하지 못해, 증상(현재 스페이스에 없음)을 감지한다.
public struct OffSpaceRecovery {
    /// 현재 스페이스에 없는 상태가 이만큼 이어져야 다시 만든다 (스페이스 전환 중 순간값 배제).
    public static let confirmTime: TimeInterval = 0.5
    /// 다시 만든 뒤 이 시간 안에는 또 만들지 않는다 (새 창도 못 붙는 환경에서 매초 반복 방지).
    public static let cooldown: TimeInterval = 30

    private var offSince: Date?
    private var lastRebuild: Date = .distantPast

    public init() {}

    /// true면 호출 측이 지금 창을 새로 만든다 (이 시점부터 쿨다운).
    public mutating func shouldRebuild(visible: Bool, onActiveSpace: Bool, now: Date) -> Bool {
        guard visible, !onActiveSpace else { offSince = nil; return false }
        let since = offSince ?? now
        offSince = since
        guard now.timeIntervalSince(since) >= Self.confirmTime,
              now.timeIntervalSince(lastRebuild) >= Self.cooldown else { return false }
        lastRebuild = now
        offSince = nil
        return true
    }
}
