import AppKit
import SwiftUI
import AIGlassCore

/// 비활성(nonactivating) 패널은 key가 되지 않아 모든 클릭이 "first mouse"로 취급된다.
/// 기본 NSHostingView는 이를 삼키므로, 첫 클릭부터 SwiftUI 제스처에 전달되게 한다.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class HUDPanelController {
    let panel: NSPanel
    private let settings: AppSettings
    private var moveObserver: NSObjectProtocol?

    init(store: UsageStore, state: HUDState, settings: AppSettings, onTap: @escaping () -> Void) {
        self.settings = settings
        // HoverCard가 서비스당 2줄(5h+주간)로 확장되어 높이 상향 (v0.5).
        let size = NSSize(width: 292, height: 190)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // 그림자는 glassEffect가 그림
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = FirstMouseHostingView(
            rootView: HUDView(store: store, state: state, settings: settings, onTap: onTap))

        restoreFrame(size: size)

        // 패널 이동 감지 → settings.hudFrame 저장
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settings.hudFrame = NSStringFromRect(self.panel.frame)
            }
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    /// 저장된 프레임에서 **위치(좌상단)만** 복원하고 크기는 현재 코드 기준을 쓴다.
    /// 구버전이 저장한 작은 크기(예: 높이 179)를 그대로 복원하면 호버 카드 하단이 잘린다.
    /// 화면 visibleFrame과 교차하지 않으면 기본(우상단) 위치.
    private func restoreFrame(size: NSSize) {
        if let saved = settings.hudFrame {
            let rect = NSRectFromString(saved)
            if rect.width > 0, rect.height > 0,
               NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                panel.setContentSize(size)
                panel.setFrameTopLeftPoint(NSPoint(x: rect.minX, y: rect.maxY))
                // 새 패널 크기가 저장 당시보다 커진 경우 하단이 화면 밖(독 뒤)으로 빠지지 않게 클램프
                if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(rect) }),
                   panel.frame.minY < screen.visibleFrame.minY {
                    panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: screen.visibleFrame.minY))
                }
                return
            }
        }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - size.width - 8, y: frame.maxY - 4))
        }
    }

    /// HUD 표시/숨김 토글.
    func setVisible(_ visible: Bool) {
        if visible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }
}
