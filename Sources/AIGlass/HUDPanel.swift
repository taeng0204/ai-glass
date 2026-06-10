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

    init(store: UsageStore, state: HUDState, onTap: @escaping () -> Void) {
        let size = NSSize(width: 280, height: 130)
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
            rootView: HUDView(store: store, state: state, onTap: onTap))

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - size.width - 8, y: frame.maxY - 2))
        }
        panel.orderFrontRegardless()
    }
}
