import CoreGraphics

/// 대시보드 팝업의 위치 계산 (순수 함수 — 좌표는 Cocoa 기준, y가 위로 증가).
///
/// 사용자가 드래그해 옮긴 위치는 "메인 화면 `visibleFrame`의 **우상단 모서리 기준 오프셋**"으로 저장한다.
/// 절대 좌표 대신 모서리 기준으로 두면 해상도·모니터 구성이 바뀌어도 같은 모서리 근처에 열린다.
public enum PopupPlacement {
    /// 화면 가장자리와 띄울 최소 간격.
    public static let margin: CGFloat = 4

    /// 저장된 오프셋(우상단 기준) → 패널 좌상단 좌표 (화면 안으로 보정).
    public static func topLeft(offset: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
        clamp(topLeft: CGPoint(x: visible.maxX - size.width - offset.x, y: visible.maxY - offset.y),
              size: size, visible: visible)
    }

    /// 패널 프레임 → 저장할 오프셋 (우상단 기준). `topLeft(offset:)`의 역변환.
    public static func offset(frame: CGRect, visible: CGRect) -> CGPoint {
        CGPoint(x: visible.maxX - frame.maxX, y: visible.maxY - frame.maxY)
    }

    /// 저장된 위치가 없을 때의 기본 위치: 상태 아이템 바로 아래, 오른쪽 끝 정렬.
    /// 아이템 위치를 모르면(`anchor == nil`) 화면 우상단에 연다.
    public static func defaultTopLeft(anchor: CGRect?, size: CGSize, visible: CGRect) -> CGPoint {
        let raw: CGPoint
        if let anchor {
            raw = CGPoint(x: anchor.maxX - size.width, y: anchor.minY - 2)
        } else {
            raw = CGPoint(x: visible.maxX - size.width - 8, y: visible.maxY - 2)
        }
        return clamp(topLeft: raw, size: size, visible: visible)
    }

    /// 패널이 `visible` 안에 완전히 들어오도록 좌상단을 보정한다. 패널이 화면보다 크면 위쪽·왼쪽에 붙인다.
    public static func clamp(topLeft: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
        let minX = visible.minX + margin
        let maxX = visible.maxX - size.width - margin
        let x = maxX < minX ? minX : min(max(topLeft.x, minX), maxX)
        let minTop = visible.minY + size.height   // 아래 모서리가 화면 아래로 안 나가게
        let maxTop = visible.maxY                 // 위 모서리가 메뉴바 밑으로 안 들어가게
        let y = minTop > maxTop ? maxTop : min(max(topLeft.y, minTop), maxTop)
        return CGPoint(x: x, y: y)
    }
}
