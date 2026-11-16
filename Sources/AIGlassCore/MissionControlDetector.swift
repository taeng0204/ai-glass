import CoreGraphics

/// 미션 컨트롤(익스포제)이 메인 화면을 덮고 있는지 창 목록으로 판단한다. 이때 시스템은 메뉴바 아이템을 숨기므로
/// 메뉴바 오버레이도 내려야 하는데, 미션 컨트롤은 알림을 주지 않아 창 목록을 짧은 주기로 본다.
///
/// 실측(macOS 27): 미션 컨트롤이 켜지면 WindowManager가 화면마다 `ExposeShieldWindow`(레이어 19)를 깐다.
/// 예전 판정(eb32399)은 "Dock 소유 레이어 20 화면 크기 창"을 봤는데, 그건 Dock 막대 자체의 창이라
/// 미션 컨트롤 중에도 보일 뿐 Dock이 펼쳐질 때마다(자동 숨김 Dock에 커서를 대면) 나타난다 —
/// 커서가 외장 모니터 아래 끝에 머무는 동안 알약이 계속 사라졌다.
public enum MissionControlDetector {
    public struct Window: Sendable {
        public let owner: String
        public let name: String
        public let layer: Int
        public let bounds: CGRect
        public init(owner: String, name: String, layer: Int, bounds: CGRect) {
            self.owner = owner
            self.name = name
            self.layer = layer
            self.bounds = bounds
        }
    }

    public static let shieldWindowName = "ExposeShieldWindow"

    /// - Parameter mainDisplay: 메인 화면 영역 (CG 좌표, 왼쪽 위 원점). 오버레이는 이 화면 메뉴바에만 그린다.
    public static func isActive(windows: [Window], mainDisplay: CGRect) -> Bool {
        windows.contains { isShield($0) && $0.bounds.insetBy(dx: -1, dy: -1).contains(mainDisplay) }
    }

    /// 화면 기록 권한이 없으면 남의 창 이름이 비어 온다(AI Glass는 권한 없음) — 소유자·레이어로도 판단한다.
    /// WindowManager의 화면 크기 창 중 배경화면은 데스크톱 아래(음수 레이어)라, 양수 레이어면 익스포제 가림막이다.
    private static func isShield(_ w: Window) -> Bool {
        w.name == shieldWindowName || (w.owner == "WindowManager" && w.layer > 0)
    }

    /// 화면에 올라온 창 목록(CGWindowListCopyWindowInfo)을 판단 입력으로 바꾼다.
    public static func windows(from list: [[String: Any]]) -> [Window] {
        list.compactMap { w in
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"] else { return nil }
            return Window(owner: w[kCGWindowOwnerName as String] as? String ?? "",
                          name: w[kCGWindowName as String] as? String ?? "",
                          layer: w[kCGWindowLayer as String] as? Int ?? 0,
                          bounds: CGRect(x: x, y: y, width: width, height: height))
        }
    }
}
