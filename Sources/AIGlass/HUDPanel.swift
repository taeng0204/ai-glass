import AppKit
import SwiftUI
import AIGlassCore

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
        panel.contentView = NSHostingView(
            rootView: HUDView(store: store, state: state, onTap: onTap))

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - size.width - 8, y: frame.maxY - 4))
        }
        panel.orderFrontRegardless()
    }
}
