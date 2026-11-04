import AppKit
import SwiftUI

/// 팝업 상단의 드래그 핸들. 잡고 끌면 창이 움직이고, 놓으면 `onDragEnd`가 불린다.
/// 비활성(nonactivating) 패널은 SwiftUI 제스처로는 창을 못 옮긴다. `performDrag`는 마우스를 놓기 전에 바로 반환해
/// (창은 그 뒤에 움직인다) "놓은 시점"을 알 수 없어서, mouseDown/Dragged/Up을 직접 받아 창을 옮긴다.
struct PopupDragHandle: NSViewRepresentable {
    let onDragEnd: () -> Void

    func makeNSView(context: Context) -> DragView {
        let v = DragView()
        v.onDragEnd = onDragEnd
        return v
    }
    func updateNSView(_ v: DragView, context: Context) { v.onDragEnd = onDragEnd }

    final class DragView: NSView {
        var onDragEnd: () -> Void = {}
        private let grip = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            // 잡을 수 있다는 표시 — 작은 캡슐.
            grip.cornerRadius = 1.5
            layer?.addSublayer(grip)
            updateGripColor()
        }
        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            grip.frame = CGRect(x: bounds.midX - 14, y: bounds.midY - 1.5 + 1, width: 28, height: 3)
        }
        override func viewDidChangeEffectiveAppearance() { updateGripColor() }
        private func updateGripColor() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                grip.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55).cgColor
            }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        private var dragStartMouse = NSPoint.zero   // 화면 좌표
        private var dragStartOrigin = NSPoint.zero

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            dragStartMouse = NSEvent.mouseLocation
            dragStartOrigin = window.frame.origin
            NSCursor.closedHand.push()
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let m = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: dragStartOrigin.x + m.x - dragStartMouse.x,
                                          y: dragStartOrigin.y + m.y - dragStartMouse.y))
        }
        override func mouseUp(with event: NSEvent) {
            NSCursor.pop()
            onDragEnd()
        }
    }
}
