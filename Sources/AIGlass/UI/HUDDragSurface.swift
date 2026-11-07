import AppKit
import SwiftUI

/// HUD 위에 얹는 투명 면 — 클릭(탭)과 드래그를 구분한다.
/// SwiftUI `.onTapGesture`가 mouseDown을 가져가면 `isMovableByWindowBackground`가 동작하지 않으므로,
/// 직접 mouseDown/Dragged/Up을 받아 3pt 넘게 움직이면 창을 옮기고, 아니면 탭으로 처리한다.
struct HUDDragSurface: NSViewRepresentable {
    let onTap: () -> Void

    func makeNSView(context: Context) -> SurfaceView {
        let v = SurfaceView()
        v.onTap = onTap
        return v
    }
    func updateNSView(_ v: SurfaceView, context: Context) { v.onTap = onTap }

    final class SurfaceView: NSView {
        var onTap: () -> Void = {}
        private var startMouse = NSPoint.zero   // 화면 좌표
        private var startOrigin = NSPoint.zero
        private var moved = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            startMouse = NSEvent.mouseLocation
            startOrigin = window.frame.origin
            moved = false
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let m = NSEvent.mouseLocation
            let dx = m.x - startMouse.x, dy = m.y - startMouse.y
            if !moved, hypot(dx, dy) < 3 { return }
            moved = true
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }
        override func mouseUp(with event: NSEvent) {
            if !moved { onTap() }
        }
    }
}
