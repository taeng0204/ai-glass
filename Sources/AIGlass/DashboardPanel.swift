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
    private let settings: AppSettings
    private let onRefresh: () -> Void
    private let onClose: () -> Void

    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// HUD/메뉴바 버튼처럼 클릭 자체가 토글 액션으로 이어지는 영역.
    /// 바깥 클릭 모니터가 mouseDown에서 먼저 닫아버리면 mouseUp 액션이 다시 열어 토글이 깨진다.
    var toggleSourceFrames: () -> [NSRect] = { [] }
    /// 메인 화면 메뉴바에서 상태 아이템(오버레이)이 놓인 프레임. 저장된 위치가 없을 때 이 아래에 연다.
    /// 상태 아이템 창은 모니터마다 복제본이 있어 `button.window`가 다른 모니터 쪽을 가리킬 수 있으므로,
    /// 오버레이가 메인 화면에서 확인한 위치를 우선 쓴다.
    var anchorFrame: () -> NSRect? = { nil }
    /// 패널이 열릴 때마다 +1 → DashboardView가 `.id`로 콘텐츠 재생성(첫 진입 애니메이션 재생).
    private let openToken = OpenToken()

    init(store: UsageStore,
         statsStore: DailyStatsStore?,
         settings: AppSettings,
         eventLog: EventLog,
         updateState: UpdateState? = nil,
         onRefresh: @escaping () -> Void,
         onClose: @escaping () -> Void,
         onSettings: @escaping () -> Void,
         onReplay: @escaping (HUDEvent) -> Void) {
        self.store = store
        self.statsStore = statsStore
        self.settings = settings
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
                                 updateState: updateState,
                                 onSettings: onSettings,
                                 onReplay: onReplay,
                                 onResize: { [weak self] in self?.resizeToFit() },
                                 openToken: openToken,
                                 onDragEnd: { [weak self] in self?.dragEnded() })
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
        // 위로 옮겨 둔 팝업이 탭 전환으로 커지면 아래가 화면 밖으로 나갈 수 있어 안으로 보정한다.
        let clamped = PopupPlacement.clamp(topLeft: NSPoint(x: frame.minX, y: frame.maxY), size: fitting,
                                           visible: Self.mainVisibleFrame())
        frame.origin = NSPoint(x: clamped.x, y: clamped.y - fitting.height)
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

        // 콘텐츠 재생성 → onAppear 애니메이션이 패널 표시 후 처음부터 재생.
        // (게이지 폭은 0→값이라 fittingSize 높이엔 영향 없음 → 사이징 전에 올려도 안전.)
        openToken.count += 1

        // 콘텐츠 크기에 맞게 패널 크기 확정.
        panel.layoutIfNeeded()
        let fitting = panel.contentView?.fittingSize ?? NSSize(width: 360, height: 360)
        panel.setContentSize(fitting)

        // 항상 메인 화면(메뉴바 아이콘이 있는 화면)에 연다 — ⌘⇧U 단축키로 열어도 마찬가지.
        let size = panel.frame.size
        let visible = Self.mainVisibleFrame()
        let topLeft: NSPoint
        if let offset = settings.dashboardOffset {
            // 사용자가 옮겨 둔 위치 (우상단 기준 오프셋 → 현재 해상도의 좌표, 화면 안으로 보정)
            topLeft = PopupPlacement.topLeft(offset: offset, size: size, visible: visible)
        } else {
            // 기본: 상태 아이템 바로 아래, 오른쪽 끝 정렬
            topLeft = PopupPlacement.defaultTopLeft(anchor: anchorFrame() ?? Self.mainScreenFrame(of: button),
                                                    size: size, visible: visible)
        }
        panel.setFrameTopLeftPoint(topLeft)
        panel.orderFrontRegardless()

        installMonitors()
    }

    /// 메인 화면(원점이 (0,0)인 화면 — 메뉴바가 있는 화면)의 visibleFrame.
    static func mainVisibleFrame() -> NSRect {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    }

    /// `anchorFrame`을 모를 때의 폴백: 버튼 창이 메인 화면 메뉴바 띠 안에 있을 때만 그 프레임을 쓴다.
    /// (다른 모니터 복제본의 프레임이면 엉뚱한 화면 기준이 되므로 버린다.)
    private static func mainScreenFrame(of button: NSStatusBarButton) -> NSRect? {
        guard let f = button.window?.frame,
              let main = NSScreen.screens.first(where: { $0.frame.origin == .zero }),
              main.frame.maxY - main.visibleFrame.maxY > 8,
              f.midX > main.frame.minX, f.midX < main.frame.maxX,
              f.midY > main.visibleFrame.maxY, f.midY < main.frame.maxY else { return nil }
        return f
    }

    /// 헤더 핸들로 옮기고 놓았을 때: 화면 안으로 보정한 뒤 그 위치를 저장한다.
    private func dragEnded() {
        let visible = Self.mainVisibleFrame()
        let size = panel.frame.size
        let clamped = PopupPlacement.clamp(topLeft: NSPoint(x: panel.frame.minX, y: panel.frame.maxY),
                                           size: size, visible: visible)
        var frame = panel.frame
        frame.origin = NSPoint(x: clamped.x, y: clamped.y - size.height)
        if frame != panel.frame { panel.setFrame(frame, display: true, animate: true) }
        settings.dashboardOffset = PopupPlacement.offset(frame: frame, visible: visible)
    }

    /// 저장된 위치를 지우고 기본 위치(상태 아이템 아래)로 되돌린다. 열려 있으면 바로 옮긴다.
    func resetPosition(relativeTo button: NSStatusBarButton?) {
        settings.dashboardOffset = nil
        guard isShown else { return }
        let size = panel.frame.size
        let topLeft = PopupPlacement.defaultTopLeft(
            anchor: anchorFrame() ?? button.flatMap(Self.mainScreenFrame(of:)),
            size: size, visible: Self.mainVisibleFrame())
        panel.setFrame(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height),
                       display: true, animate: true)
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
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.isToggleSourceClick(at: NSEvent.mouseLocation) { self.close() }
            }
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
                if !self.panel.frame.contains(point), !self.isToggleSourceClick(at: point) {
                    self.close()
                }
                return event
            }
        }
    }

    private func isToggleSourceClick(at point: NSPoint) -> Bool {
        toggleSourceFrames().contains { $0.contains(point) }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
