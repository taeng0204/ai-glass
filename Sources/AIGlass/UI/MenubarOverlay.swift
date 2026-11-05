import AppKit
import QuartzCore
import AIGlassCore

/// 메뉴바 콘텐츠를 GPU 합성 오버레이로 그린다. 웨이브는 스타일별 `WaveRenderer`(MenubarWaves.swift)가 맡는다.
///
/// 배경: NSStatusItem 안에서 애니메이션이 돌면 macOS가 매 프레임 레이어 트리를 CPU로 스냅샷(`_updateReplicants`)해
/// 앱 CPU가 수십 %까지 오른다. 그래서 상태 아이템은 "자리"(length)만 잡고, 실제 내용은 그 위에 겹친 투명 NSPanel에
/// 그린다. 웨이브 애니메이션은 Core Animation으로 한 번 등록해 두면 화면 합성기가 매 프레임 처리하고,
/// 앱은 1초에 한 번만 텍스트·색·진폭을 갱신한다.
///
/// 항목 배치 규칙: 웨이브가 켜져 있으면 사용률·리셋시간은 웨이브 옆 묶음이 흡수하고, 텍스트 항목끼리는 · 로 구분한다.
@MainActor
final class MenubarOverlay {
    private let store: UsageStore
    private let settings: AppSettings
    private weak var item: NSStatusItem?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?

    private let panel: NSPanel
    private let root = PassThroughView()

    // 웨이브 (스타일별 렌더러 — MenubarWaves.swift)
    private var renderer: WaveRenderer?
    private var rendererStyle: WaveStyle?

    // 웨이브 옆 정보 묶음 (점 + % + 카운트다운) — 서비스 로테이션 시 슬라이드 전환
    private let info = PassThroughView()
    private let infoDot = CALayer()
    private let infoPct = MenubarOverlay.makeLabel()
    private let infoCd = MenubarOverlay.makeLabel()
    private var lastCurrent: ServiceID?

    // 독립 텍스트 항목
    private let star = MenubarOverlay.makeLabel()
    private let today = MenubarOverlay.makeLabel()
    private let rate = MenubarOverlay.makeLabel()
    private let usagePct = MenubarOverlay.makeLabel()
    private let usageDot = CALayer()
    private let resetCd = MenubarOverlay.makeLabel()
    private let seps = (0..<4).map { _ in MenubarOverlay.makeLabel() }

    private var lastWidth: CGFloat = 0

    // 폭 안정화 — 로테이션으로 퍼센트 자릿수(9% ↔ 21%)·카운트다운 길이가 달라져도 메뉴바가 꿈틀대지 않도록,
    // 로테이션 후보 중 가장 넓은 값만큼 자리를 예약한다. 줄이는 건 60초 이상 계속 좁을 때만 천천히 (래칫).
    private struct WidthRatchet {
        var width: CGFloat = 0
        var narrowSince: Date?
        mutating func update(needed: CGFloat, now: Date) -> CGFloat {
            if needed >= width - 0.5 {
                width = max(width, needed)
                narrowSince = nil
            } else {
                let since = narrowSince ?? now
                narrowSince = since
                if now.timeIntervalSince(since) > 60 { width = needed; narrowSince = nil }
            }
            return width
        }
    }
    private var infoRatchet = WidthRatchet()
    private var usageRatchet = WidthRatchet()
    private var cdRatchet = WidthRatchet()
    /// 현재 로테이션 후보 서비스 (tick마다 갱신).
    private var rotation: [ServiceID] = []
    private let scratch = MenubarOverlay.makeLabel()

    /// 라벨과 같은 방식(sizeToFit)으로 텍스트 폭을 잰다 — 배치 폭과 어긋나지 않게.
    private func measure(_ text: String, _ font: NSFont) -> CGFloat {
        scratch.font = font
        scratch.stringValue = text
        scratch.sizeToFit()
        return ceil(scratch.frame.width)
    }
    /// 퍼센트는 항상 두 자리("00%") 폭 이상을 잡아 한 자리↔두 자리 전환에도 위치가 안 움직인다.
    private func pctSlot(_ font: NSFont) -> CGFloat { measure("00%", font) }
    private func candidates() -> [ServiceID?] { rotation.isEmpty ? [nil] : rotation.map { Optional($0) } }

    private let height: CGFloat = 22
    private let waveH: CGFloat = 16

    private let textFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    private let pctFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
    private let cdFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)

    private static func makeLabel() -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.lineBreakMode = .byClipping
        l.usesSingleLineMode = true
        l.isHidden = true
        return l
    }

    init(store: UsageStore, settings: AppSettings, item: NSStatusItem) {
        self.store = store
        self.settings = settings
        self.item = item

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        item.button?.title = ""
        item.button?.image = nil

        // ⌘+클릭이 우리 아이템 위에서 시작되면 좌표가 흔들리기를 기다리지 않고 바로 드래그 모드로 들어간다.
        // 놓으면(mouseUp) 곧바로 재확인한다. (마우스 이벤트 전역 감시는 별도 권한이 필요 없다)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .leftMouseDown {
                    guard event.modifierFlags.contains(.command), let pf = self.primaryFrame,
                          pf.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) else { return }
                    self.panel.orderOut(nil)
                    self.showDragPlaceholder()
                    self.dragging = true
                    self.dragStartedAt = Date()
                } else if self.dragging {
                    self.dragging = false
                    self.recentFrames.removeAll()
                    self.stableSince = .distantPast
                    self.scheduleSettleCheck(after: Self.settleTime + 0.05)
                }
            }
        }

        root.wantsLayer = true
        root.frame = NSRect(x: 0, y: 0, width: 100, height: height)
        root.autoresizingMask = [.width, .height]
        panel.contentView = root

        // 정보 묶음
        info.wantsLayer = true
        info.layer?.masksToBounds = true
        infoDot.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
        infoDot.cornerRadius = 3
        info.layer?.addSublayer(infoDot)
        info.addSubview(infoPct)
        info.addSubview(infoCd)
        info.isHidden = true
        root.addSubview(info)

        usageDot.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
        usageDot.cornerRadius = 3
        usageDot.isHidden = true
        root.layer?.addSublayer(usageDot)
        for l in [star, today, rate, usagePct, resetCd] + seps { root.addSubview(l) }

        tick()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.syncPanel() } })
    }

    /// 오버레이 해제 — 투명 창과 타이머·관찰자를 정리한다.
    func stop() {
        timer?.invalidate(); timer = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        panel.orderOut(nil)
        panel.close()
    }

    /// 설정·항목 변경 직후 즉시 다시 그린다.
    func refresh() { tick() }

    // MARK: - 데이터

    private var enabled: Set<ServiceID> { settings.enabledServices }

    private func displayWindow(_ s: ServiceID) -> LimitWindow? {
        guard let ws = store.limits[s], !ws.isEmpty else { return nil }
        if let s5h = ws.first(where: { $0.kind == .session5h }) { return s5h }
        return ws.max { $0.usedPercent < $1.usedPercent }
    }

    private func resetText(_ s: ServiceID, now: Date) -> String? {
        guard let w = displayWindow(s) else { return nil }
        if let r = w.resetsAt, r > now { return EventEngine.countdown(to: r, from: now) }
        if let a = store.approxFullReset(service: s, kind: w.kind, now: now) {
            return "~" + EventEngine.countdown(to: a, from: now)
        }
        return nil
    }

    private func statusColor(_ p: Double) -> NSColor {
        NSColor(Theme.statusColor(percent: p, warn: settings.warnThreshold, crit: settings.critThreshold))
    }

    private func cgColor(_ s: ServiceID) -> CGColor {
        let c = Theme.rgb(for: s)
        return CGColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    // MARK: - 갱신

    private func tick() {
        guard item?.button != nil else { return }
        let now = Date()
        let t = now.timeIntervalSinceReferenceDate

        let services = ServiceID.allCases.filter { enabled.contains($0) && !(store.limits[$0]?.isEmpty ?? true) }
        rotation = services
        let current: ServiceID? = services.isEmpty ? nil : services[Int(t / 6) % services.count]
        let curPercent = current.flatMap { displayWindow($0)?.usedPercent }
        let maxPercent = store.maxUsedPercent(in: enabled)

        let items = MenubarItem.ordered(settings.menubarItems)
        let waveAbsorbs = items.contains(.wave)
        let display = waveAbsorbs ? items.filter { $0 != .usagePercent && $0 != .resetCountdown } : items

        // 전부 숨기고 아래에서 쓰는 것만 보인다.
        for l in [star, today, rate, usagePct, resetCd] + seps { l.isHidden = true }
        usageDot.isHidden = true
        renderer?.layer.isHidden = true
        info.isHidden = true

        var x: CGFloat = 0
        var placed = false
        var sepIndex = 0

        func put(_ l: NSTextField, _ text: String, font: NSFont, color: NSColor, in container: NSView? = nil,
                 at px: CGFloat? = nil) -> CGFloat {
            l.font = font
            l.textColor = color
            l.stringValue = text
            l.sizeToFit()
            l.isHidden = false
            let ox = px ?? x
            l.setFrameOrigin(NSPoint(x: ox, y: ((container?.frame.height ?? height) - l.frame.height) / 2))
            return ceil(l.frame.width)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if display.isEmpty {
            x += put(star, "✦", font: textFont, color: statusColor(maxPercent))
            placed = true
        } else {
            for (idx, it) in display.enumerated() {
                if placed { x += 6 }
                // 텍스트끼리만 · 구분 (웨이브 앞뒤엔 안 붙임)
                if idx > 0, it != .wave, display[idx - 1] != .wave, sepIndex < seps.count {
                    x += put(seps[sepIndex], "·", font: textFont, color: .tertiaryLabelColor)
                    sepIndex += 1
                    x += 6
                }
                placed = true
                switch it {
                case .wave:
                    x += 4
                    let r = ensureRenderer()
                    r.layer.frame = CGRect(x: x, y: (height - waveH) / 2, width: r.width, height: waveH)
                    r.layer.isHidden = false
                    x += r.width + 8
                    x += layoutInfo(at: x, current: current, curPercent: curPercent, maxPercent: maxPercent, now: now)
                    // 끝 패딩 없음 — 라벨 자체가 오른쪽에 ~2pt 안쪽 여백을 갖고 있어서(NSTextField 셀 inset)
                    // 보이는 오른쪽 여백은 그 2pt뿐이다 (왼쪽 패딩은 4). 더 줄이면 글자가 알약 끝에 붙는다.
                case .todayTokens:
                    let text = (idx == 0 ? "✦ " : "") + MenubarFormat.formatTokens(store.todayTokens(now: now))
                    x += put(today, text, font: textFont, color: .labelColor)
                case .burnRate:
                    let text = MenubarFormat.formatRate(store.tokensPerMinute(windowMinutes: 5, now: now))
                    x += put(rate, text, font: textFont, color: .labelColor)
                case .usagePercent:
                    let startX = x
                    if let cur = current, let p = curPercent {
                        usageDot.backgroundColor = cgColor(cur)
                        usageDot.position = CGPoint(x: x + 3, y: height / 2)
                        usageDot.isHidden = false
                        x += 6 + 4
                        x += put(usagePct, Theme.formatUsagePercent(p), font: textFont, color: statusColor(p))
                    } else {
                        x += put(usagePct, "–%", font: textFont, color: .secondaryLabelColor)
                    }
                    var needed: CGFloat = 0
                    for c in candidates() {
                        if let c, let p = displayWindow(c)?.usedPercent {
                            needed = max(needed, 10 + max(measure(Theme.formatUsagePercent(p), textFont), pctSlot(textFont)))
                        } else {
                            needed = max(needed, measure("–%", textFont))
                        }
                    }
                    x = startX + max(x - startX, usageRatchet.update(needed: needed, now: now))
                case .resetCountdown:
                    let startX = x
                    let text = current.flatMap { resetText($0, now: now) } ?? "–"
                    x += put(resetCd, text, font: textFont, color: .secondaryLabelColor)
                    var needed: CGFloat = 0
                    for c in candidates() {
                        needed = max(needed, measure(c.flatMap { resetText($0, now: now) } ?? "–", textFont))
                    }
                    x = startX + max(x - startX, cdRatchet.update(needed: needed, now: now))
                }
            }
        }

        CATransaction.commit()

        if let r = renderer, !r.layer.isHidden {
            let level = max(store.activityLevel(now: now), store.requestActivityLevel(now: now))
            r.update(share: activeShare(now: now), level: level, percent: curPercent ?? maxPercent, now: now)
        }

        let width = max(1, x)
        if abs(width - lastWidth) > 0.5 { lastWidth = width; item?.length = width }
        syncPanel()
    }

    /// 웨이브 옆 점+%+카운트다운 묶음 배치. 반환 = 묶음 폭.
    private func layoutInfo(at x: CGFloat, current: ServiceID?, curPercent: Double?, maxPercent: Double, now: Date) -> CGFloat {
        let showsPct = settings.menubarItems.contains(.usagePercent)
        let showsCd = settings.menubarItems.contains(.resetCountdown)
        let percent = curPercent ?? maxPercent
        let countdown = (showsCd && current != nil) ? current.flatMap { resetText($0, now: now) } : nil

        infoPct.isHidden = true
        infoCd.isHidden = true
        infoDot.isHidden = true
        var ix: CGFloat = 0
        var n = 0
        func gap() { if n > 0 { ix += 4 }; n += 1 }

        if let cur = current {
            gap()
            infoDot.backgroundColor = cgColor(cur)
            infoDot.position = CGPoint(x: ix + 3, y: height / 2)
            infoDot.isHidden = false
            ix += 6
        }
        if showsPct {
            gap()
            infoPct.font = pctFont
            infoPct.textColor = statusColor(percent)
            infoPct.stringValue = Theme.formatUsagePercent(percent)
            infoPct.sizeToFit()
            infoPct.setFrameOrigin(NSPoint(x: ix, y: (height - infoPct.frame.height) / 2))
            infoPct.isHidden = false
            ix += max(ceil(infoPct.frame.width), pctSlot(pctFont))
        }
        if let countdown {
            gap()
            infoCd.font = cdFont
            infoCd.textColor = .secondaryLabelColor
            infoCd.stringValue = countdown
            infoCd.sizeToFit()
            infoCd.setFrameOrigin(NSPoint(x: ix, y: (height - infoCd.frame.height) / 2))
            infoCd.isHidden = false
            ix += ceil(infoCd.frame.width)
        }

        // 후보 서비스 중 가장 넓은 묶음 폭만큼 예약 (내용은 왼쪽 정렬 — 점 위치가 고정된다).
        var needed: CGFloat = 0
        for c in candidates() {
            needed = max(needed, infoWidth(for: c, showsPct: showsPct, showsCd: showsCd, maxPercent: maxPercent, now: now))
        }
        let w = max(ix, infoRatchet.update(needed: needed, now: now))
        info.frame = NSRect(x: x, y: 0, width: w, height: height)
        info.isHidden = w == 0

        // 서비스 로테이션 시 아래에서 위로 슬라이드 (기존 SwiftUI 전환과 동일)
        if let last = lastCurrent, last != current, w > 0 {
            let tr = CATransition()
            tr.type = .push
            tr.subtype = .fromBottom
            tr.duration = 0.45
            tr.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            info.layer?.add(tr, forKey: "rotate")
        }
        lastCurrent = current
        return w
    }

    /// 특정 서비스가 표시될 때의 정보 묶음 폭 (layoutInfo와 같은 규칙).
    private func infoWidth(for c: ServiceID?, showsPct: Bool, showsCd: Bool, maxPercent: Double, now: Date) -> CGFloat {
        var w: CGFloat = 0
        var n = 0
        func gap() { if n > 0 { w += 4 }; n += 1 }
        if c != nil { gap(); w += 6 }
        if showsPct {
            gap()
            let p = c.flatMap { displayWindow($0)?.usedPercent } ?? maxPercent
            w += max(measure(Theme.formatUsagePercent(p), pctFont), pctSlot(pctFont))
        }
        if showsCd, let c, let cd = resetText(c, now: now) {
            gap()
            w += measure(cd, cdFont)
        }
        return w
    }

    /// 설정된 웨이브 스타일의 렌더러를 보장한다 (스타일이 바뀌면 교체).
    private func ensureRenderer() -> WaveRenderer {
        if let r = renderer, rendererStyle == settings.waveStyle { return r }
        renderer?.layer.removeFromSuperlayer()
        let r = WaveRenderers.make(settings.waveStyle)
        r.layer.isHidden = true
        root.layer?.addSublayer(r.layer)
        renderer = r
        rendererStyle = settings.waveStyle
        return r
    }

    /// enabled 서비스만 남긴 최근 활동 비율 (합 1.0 재정규화). 활동 없으면 빈 배열.
    private func activeShare(now: Date) -> [(ServiceID, Double)] {
        let full = store.recentActivityShare(now: now).filter { enabled.contains($0.key) }
        let grand = full.values.reduce(0, +)
        guard grand > 0 else { return [] }
        return ServiceID.allCases.compactMap { s in
            guard let v = full[s], v > 0 else { return nil }
            return (s, v / grand)
        }
    }

    // MARK: - 투명 창 위치·가시성

    /// 메인 화면 메뉴바에서 마지막으로 보고된 상태 아이템 창 위치.
    private var primaryFrame: NSRect?
    private var primarySeenAt = Date.distantPast
    /// 최근 창 좌표 표본 — ⌘+드래그로 아이템을 옮기는 동안 창 좌표가 제자리와 드래그 프록시(엉뚱한 위치) 사이를
    /// 수 ms 간격으로 오간다. 흔들리는 동안은 오버레이를 숨기고, 같은 좌표가 이 시간 이상 유지될 때만 인정한다.
    private var recentFrames: [(at: Date, frame: NSRect)] = []
    private var stableFrame: NSRect = .zero
    private var stableSince = Date.distantPast
    private static let settleTime: TimeInterval = 0.15
    private static let flapWindow: TimeInterval = 0.35
    private var mouseMonitor: Any?
    private var settleCheck: DispatchWorkItem?
    private var placeholderShown = false
    private var dragging = false
    private var dragStartedAt = Date.distantPast

    /// 드래그 중에는 오버레이를 숨기므로 시스템이 보여 주는 아이템이 투명해 위치를 알 수 없다.
    /// 그동안만 버튼에 고정 알약 모양을 얹어 둔다 (안정되면 제거).
    private func showDragPlaceholder() {
        guard !placeholderShown, let button = item?.button else { return }
        placeholderShown = true
        let size = NSSize(width: max(24, lastWidth - 4), height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: rect.height / 2, yRadius: rect.height / 2)
            NSColor.labelColor.withAlphaComponent(0.22).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
            // 웨이브 느낌의 막대 몇 개
            NSColor.labelColor.withAlphaComponent(0.6).setFill()
            let barW: CGFloat = 2, gap: CGFloat = 3
            let hs: [CGFloat] = [5, 9, 12, 8, 11, 6, 9]
            var x = (rect.width - (CGFloat(hs.count) * barW + CGFloat(hs.count - 1) * gap)) / 2
            for h in hs where x + barW < rect.width {
                NSBezierPath(roundedRect: NSRect(x: x, y: (rect.height - h) / 2, width: barW, height: h), xRadius: 1, yRadius: 1).fill()
                x += barW + gap
            }
            return true
        }
        button.imagePosition = .imageOnly
        button.image = image
    }

    private func scheduleSettleCheck(after delay: TimeInterval) {
        settleCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.syncPanel() } }
        settleCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func hideDragPlaceholder() {
        guard placeholderShown, let button = item?.button else { return }
        placeholderShown = false
        button.image = nil
    }

    /// 메인 화면 메뉴바에서 최근(8초 이내)에 확인된 상태 아이템 창 프레임. 대시보드 팝업의 기본 위치 기준.
    /// 아이템이 숨겨졌거나 위치를 모르면 nil.
    var anchorFrame: NSRect? {
        guard let f = primaryFrame, Date().timeIntervalSince(primarySeenAt) < 8 else { return nil }
        return f
    }

    /// 상태 아이템 위치에 투명 패널을 맞춘다.
    ///
    /// 모니터가 여러 대면 macOS가 화면마다 상태 아이템 복제본을 두고, `button.window`가 그 사이를 번갈아 보고한다
    /// (예: 메인 (1202, 1073) ↔ 보조 모니터 (846, -32)). 오버레이는 메인 화면에만 그리므로, 메인 화면의 메뉴바 띠 안에서
    /// 보고된 위치만 기억해 쓴다. 메인 위치가 한동안(8초) 안 보이면 아이템이 숨겨진 것(앞 앱 메뉴가 길어 공간 부족 등)이라
    /// 패널도 숨긴다. 보조 모니터의 복제본은 오버레이를 그리지 않아 빈 자리로 보인다.
    private func syncPanel() {
        guard let button = item?.button, let win = button.window else { panel.orderOut(nil); return }
        observe(win)
        let f = win.frame
        let now = Date()
        recentFrames.append((now, f))
        recentFrames.removeAll { now.timeIntervalSince($0.at) > Self.flapWindow }
        if f != stableFrame { stableFrame = f; stableSince = now }
        let flapping = recentFrames.contains { $0.frame != f }
        let settled = now.timeIntervalSince(stableSince) >= Self.settleTime
        if flapping || !settled {
            // 흔들리거나 막 바뀐 좌표는 믿지 않는다 — 숨기고, 안정될 즈음 다시 확인한다.
            if flapping {
                panel.orderOut(nil)
                showDragPlaceholder()
            }
            scheduleSettleCheck(after: Self.settleTime + 0.05)
            return
        }
        if dragging, now.timeIntervalSince(dragStartedAt) < 8 { return }
        dragging = false   // 버튼을 아직 누르고 있다 — 놓을 때까지 숨김 유지
        // 메뉴바 띠(visibleFrame 위 ~ 화면 맨 위) 안에 있을 때만 인정한다 (엄격한 부등호).
        // 메인 화면 = 원점이 (0,0)인 화면 (screens 배열 순서는 디스플레이 재구성 때 순간적으로 바뀔 수 있어 쓰지 않는다).
        if let main = NSScreen.screens.first(where: { $0.frame.origin == .zero }),
           main.frame.maxY - main.visibleFrame.maxY > 8,
           f.width > 1, win.isVisible, win.occlusionState.contains(.visible),
           f.midX > main.frame.minX, f.midX < main.frame.maxX,
           f.midY > main.visibleFrame.maxY, f.midY < main.frame.maxY {
            primaryFrame = f
            primarySeenAt = now
        }
        hideDragPlaceholder()
        guard let pf = primaryFrame, now.timeIntervalSince(primarySeenAt) < 8 else {
            panel.orderOut(nil)
            return
        }
        panel.appearance = button.effectiveAppearance
        let width = max(1, lastWidth)
        let target = NSRect(x: pf.minX + (pf.width - width) / 2, y: pf.minY + (pf.height - height) / 2,
                            width: width, height: height)
        if panel.frame != target { panel.setFrame(target, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// 상태 아이템 창의 이동·가림 변화를 즉시 따라가도록 관찰한다 (1초 주기만으로는 어긋남이 보임).
    private func observe(_ win: NSWindow) {
        guard observedWindow !== win else { return }
        observedWindow = win
        let names: [Notification.Name] = [NSWindow.didMoveNotification, NSWindow.didChangeOcclusionStateNotification,
                                          NSWindow.didChangeScreenNotification, NSWindow.didResizeNotification]
        for n in names {
            observers.append(NotificationCenter.default.addObserver(forName: n, object: win, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncPanel() }
            })
        }
    }
}

/// 클릭을 아래 NSStatusBarButton으로 통과시킨다.
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
