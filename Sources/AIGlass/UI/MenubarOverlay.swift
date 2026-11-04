import AppKit
import QuartzCore
import AIGlassCore

/// 메뉴바 콘텐츠를 GPU 합성 오버레이로 그린다 (펄스 바 웨이브 전용).
///
/// 배경: NSStatusItem 안에서 애니메이션이 돌면 macOS가 매 프레임 레이어 트리를 CPU로 스냅샷(`_updateReplicants`)해
/// 앱 CPU가 수십 %까지 오른다. 그래서 상태 아이템은 "자리"(length)만 잡고, 실제 내용은 그 위에 겹친 투명 NSPanel에
/// 그린다. 펄스 바 높이는 CAKeyframeAnimation으로 한 번 등록해 두면 화면 합성기가 매 프레임 처리하고,
/// 앱은 1초에 한 번만 텍스트·색·진폭을 갱신한다.
///
/// 배치·폰트·색은 `MenubarContentView`(SwiftUI)와 동일하게 맞춘다.
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

    // 웨이브
    private let gradient = CAGradientLayer()
    private let maskLayer = CALayer()
    private var bars: [CALayer] = []
    private var lastAmplitude = -1.0
    private var lastStopsKey = ""

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
    private let waveW: CGFloat = 36, waveH: CGFloat = 16
    private let barW: CGFloat = 3, barGap: CGFloat = 2.5

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

        root.wantsLayer = true
        root.frame = NSRect(x: 0, y: 0, width: 100, height: height)
        root.autoresizingMask = [.width, .height]
        panel.contentView = root

        // 웨이브 레이어 (마스크 = 막대 7개)
        maskLayer.frame = CGRect(x: 0, y: 0, width: waveW, height: waveH)
        for i in 0..<7 {
            let b = CALayer()
            b.backgroundColor = NSColor.white.cgColor
            b.cornerRadius = barW / 2
            b.bounds = CGRect(x: 0, y: 0, width: barW, height: 8)
            b.position = CGPoint(x: barW / 2 + CGFloat(i) * (barW + barGap), y: waveH / 2)
            maskLayer.addSublayer(b)
            bars.append(b)
        }
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.mask = maskLayer
        gradient.isHidden = true
        root.layer?.addSublayer(gradient)

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

    // MARK: - 데이터 (MenubarContentView와 동일 규칙)

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
        gradient.isHidden = true
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
                    gradient.frame = CGRect(x: x, y: (height - waveH) / 2, width: waveW, height: waveH)
                    gradient.isHidden = false
                    x += waveW + 8
                    x += layoutInfo(at: x, current: current, curPercent: curPercent, maxPercent: maxPercent, now: now)
                    x += 4
                case .todayTokens:
                    let text = (idx == 0 ? "✦ " : "") + MenubarContentView.formatTokens(store.todayTokens(now: now))
                    x += put(today, text, font: textFont, color: .labelColor)
                case .burnRate:
                    let text = MenubarContentView.formatRate(store.tokensPerMinute(windowMinutes: 5, now: now))
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

        updateGradient(now: now)
        CATransaction.commit()

        updateAmplitude(now: now)

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

    /// share 비례 가로 그라데이션 — 값이 바뀔 때만 갱신.
    private func updateGradient(now: Date) {
        let full = store.recentActivityShare(now: now).filter { enabled.contains($0.key) }
        let grand = full.values.reduce(0, +)
        let active = grand > 0
            ? ServiceID.allCases.compactMap { s -> (ServiceID, Double)? in
                guard let v = full[s], v > 0 else { return nil }
                return (s, v / grand)
            }
            : []
        let key = active.map { "\($0.0.rawValue):\(Int($0.1 * 100))" }.joined(separator: ",")
        guard key != lastStopsKey else { return }
        lastStopsKey = key
        var colors: [CGColor] = [], locs: [NSNumber] = []
        if active.isEmpty {
            colors = [CGColor(red: 0.63, green: 0.13, blue: 0.94, alpha: 0.9), CGColor(red: 0, green: 0, blue: 1, alpha: 0.7)]
            locs = [0, 1]
        } else {
            var cursor = 0.0
            for (i, e) in active.enumerated() {
                let end = cursor + e.1
                let bs = i == 0 ? cursor : max(cursor, cursor - 0.08)
                let be = i == active.count - 1 ? 1.0 : min(1.0, end - 0.08)
                for loc in [bs, max(bs, be)] {
                    colors.append(cgColor(e.0))
                    locs.append(NSNumber(value: loc))
                }
                cursor = end
            }
        }
        gradient.colors = colors
        gradient.locations = locs
    }

    /// 진폭이 0.04 이상 달라질 때만 막대 애니메이션을 다시 등록한다 (절대 시간 위상 → 이어서 재생).
    private func updateAmplitude(now: Date) {
        let level = max(store.activityLevel(now: now), store.requestActivityLevel(now: now))
        let amplitude = 0.15 + 0.85 * level
        guard abs(amplitude - lastAmplitude) > 0.04 else { return }
        lastAmplitude = amplitude
        let tNow = now.timeIntervalSinceReferenceDate
        let samples = 40
        for (i, bar) in bars.enumerated() {
            let omega = 2.2 + Double(i) * 0.13
            let phase0 = tNow * omega + Double(i) * 0.9
            // 기존 식: h = 4 + 12·amp·(0.5 + 0.5·sin(phase))
            let values = (0...samples).map { k -> NSNumber in
                let ph = phase0 + 2 * Double.pi * Double(k) / Double(samples)
                return NSNumber(value: 4 + 12 * amplitude * (0.5 + 0.5 * sin(ph)))
            }
            let anim = CAKeyframeAnimation(keyPath: "bounds.size.height")
            anim.values = values
            anim.calculationMode = .cubic
            anim.duration = 2 * Double.pi / omega
            anim.repeatCount = .infinity
            bar.add(anim, forKey: "h")
        }
    }

    // MARK: - 투명 창 위치·가시성

    /// 상태 아이템 위치에 투명 패널을 맞춘다. 아이템이 가려지거나 화면 밖이면(메뉴바 숨김·풀스크린·정리 앱) 패널도 숨긴다.
    private func syncPanel() {
        guard let button = item?.button, let win = button.window else { panel.orderOut(nil); return }
        observe(win)
        let f = win.frame
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(f) }
        guard win.isVisible, f.width > 1, onScreen, win.occlusionState.contains(.visible) else {
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
