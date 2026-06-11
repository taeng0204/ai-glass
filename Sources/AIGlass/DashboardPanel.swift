import AppKit
import SwiftUI
import AIGlassCore

/// 비활성(nonactivating) 패널은 key가 되지 않아 모든 클릭이 "first mouse"로 취급된다.
/// 기본 NSHostingView는 이를 삼키므로, 첫 클릭부터 SwiftUI 제스처에 전달되게 한다.
private final class FirstMouseDashboardHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 메뉴바 직하에 뜨는 glass 대시보드 패널. NSPopover를 대체한다.
@MainActor
final class DashboardPanelController {
    let panel: NSPanel
    private let store: UsageStore
    private let statsStore: DailyStatsStore?
    private let onRefresh: () -> Void
    private let onClose: () -> Void

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(store: UsageStore,
         statsStore: DailyStatsStore?,
         settings: AppSettings,
         eventLog: EventLog,
         onRefresh: @escaping () -> Void,
         onClose: @escaping () -> Void,
         onSettings: @escaping () -> Void,
         onReplay: @escaping (HUDEvent) -> Void) {
        self.store = store
        self.statsStore = statsStore
        self.onRefresh = onRefresh
        self.onClose = onClose

        panel = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 360, height: 360)),
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // 그림자는 glassEffect가 그림
        panel.hidesOnDeactivate = false

        let root = DashboardView(store: store,
                                 statsStore: statsStore,
                                 settings: settings,
                                 eventLog: eventLog,
                                 onSettings: onSettings,
                                 onReplay: onReplay,
                                 onResize: { [weak self] in self?.resizeToFit() })
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
            .padding(8)
            .fixedSize()
        panel.contentView = FirstMouseDashboardHostingView(rootView: root)
    }

    /// 탭 전환 등으로 콘텐츠 높이가 바뀔 때 패널 크기를 다시 맞춘다 (상단 모서리 고정).
    /// 전환 애니메이션 중에는 두 탭이 공존(fittingSize=max)하므로, 즉시 한 번 + 전환 종료 후 한 번 더.
    func resizeToFit() {
        applyFittingSize()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.applyFittingSize()
        }
    }

    private func applyFittingSize() {
        guard panel.isVisible else { return }
        panel.layoutIfNeeded()
        guard let fitting = panel.contentView?.fittingSize,
              fitting.width > 0, fitting.height > 0 else { return }
        var frame = panel.frame
        // 상단 고정: 높이 변화만큼 origin.y 보정.
        frame.origin.y = frame.maxY - fitting.height
        frame.size = fitting
        panel.setFrame(frame, display: true, animate: true)
    }

    deinit {
        // 패널 닫힘 없이 해제되어도 모니터 누수 방지.
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    var isShown: Bool { panel.isVisible }

    /// 열려 있으면 닫고, 닫혀 있으면 statusItem 버튼 직하에 연다.
    func toggle(relativeTo button: NSStatusBarButton) {
        if isShown {
            close()
        } else {
            open(relativeTo: button)
        }
    }

    private func open(relativeTo button: NSStatusBarButton) {
        onRefresh()

        // 콘텐츠 크기에 맞게 패널 크기 확정.
        panel.layoutIfNeeded()
        let fitting = panel.contentView?.fittingSize ?? NSSize(width: 360, height: 360)
        panel.setContentSize(fitting)

        guard let buttonWindow = button.window else { return }
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)

        let size = panel.frame.size
        // 우측 정렬: 패널 우측 끝을 버튼 우측 끝에 맞춤.
        var x = buttonRectOnScreen.maxX - size.width
        let top = buttonRectOnScreen.minY - 2

        // 화면 밖이면 클램프.
        let screen = buttonWindow.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        }

        panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
        panel.orderFrontRegardless()

        installMonitors()
    }

    func close() {
        removeMonitors()
        panel.orderOut(nil)
        onClose()
    }

    private func installMonitors() {
        removeMonitors()
        // 바깥(다른 앱) 클릭 → 닫기. 자기 앱 클릭엔 안 오므로 로컬 모니터로 보강.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        // 자기 앱 내 클릭(패널 밖) + ESC 처리.
        // nonactivating 패널은 key가 되지 않아 event.window가 패널이 아닐 수 있으므로,
        // 패널 안/밖 판정은 화면 좌표 기준으로 한다(그래야 탭 클릭에 닫히지 않음).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event } // ESC만 처리
                MainActor.assumeIsolated { self.close() }
                return nil
            }
            // 클릭: 화면 좌표가 패널 프레임 밖이면 닫기.
            let point = NSEvent.mouseLocation
            return MainActor.assumeIsolated {
                if !self.panel.frame.contains(point) { self.close() }
                return event
            }
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
