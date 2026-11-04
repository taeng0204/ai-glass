import AppKit
import QuartzCore
import AIGlassCore

/// 메뉴바 오버레이용 웨이브 렌더러. 스타일마다 레이어 트리와 Core Animation 애니메이션을 한 번 구성해 두면
/// 화면 합성기(GPU)가 매 프레임 그리고, 앱은 `update`로 1초에 한 번 입력(점유율·활동량·사용률)만 반영한다.
@MainActor
protocol WaveRenderer: AnyObject {
    /// 웨이브 레이어. 크기는 width × 16 (오버레이가 frame을 배치한다).
    var layer: CALayer { get }
    var width: CGFloat { get }
    /// 1초마다 호출. share = 서비스별 최근 활동 비율(합 1, 비었으면 idle), level = 활동 수준 0...1, percent = 표시 사용률.
    func update(share: [(ServiceID, Double)], level: Double, percent: Double, now: Date)
}

enum WaveRenderers {
    @MainActor
    static func make(_ style: WaveStyle) -> WaveRenderer {
        switch style {
        case .pulseBars: return PulseBarsRenderer()
        case .smoothWave: return SmoothWaveRenderer()
        case .waterFill: return WaterFillRenderer()
        case .orbGlow: return OrbGlowRenderer()
        case .heartbeat: return HeartbeatRenderer()
        }
    }
}

enum WaveGradient {
    static func cg(_ s: ServiceID) -> CGColor {
        let c = Theme.rgb(for: s)
        return CGColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// share 비례 누적 위치에 서비스 색을 배치한 가로 그라데이션 (WaveInput.gradient와 같은 규칙).
    /// 활동 없으면 보라-파랑.
    static func linear(_ share: [(ServiceID, Double)]) -> (colors: [CGColor], locations: [NSNumber]) {
        guard !share.isEmpty else {
            return ([CGColor(red: 0.63, green: 0.13, blue: 0.94, alpha: 0.9), CGColor(red: 0, green: 0, blue: 1, alpha: 0.7)], [0, 1])
        }
        var colors: [CGColor] = [], locs: [NSNumber] = []
        var cursor = 0.0
        for (i, e) in share.enumerated() {
            let end = cursor + e.1
            let bs = i == 0 ? cursor : max(cursor, cursor - 0.08)
            let be = i == share.count - 1 ? 1.0 : min(1.0, end - 0.08)
            for loc in [bs, max(bs, be)] {
                colors.append(cg(e.0))
                locs.append(NSNumber(value: loc))
            }
            cursor = end
        }
        return (colors, locs)
    }
}

/// 가로 그라데이션을 도형 마스크로 오려내는 웨이브의 공통 틀. 서브클래스는 `content`(마스크)에 흰색 도형을 그린다.
@MainActor
class LinearMaskedWave: WaveRenderer {
    let layer = CALayer()
    let width: CGFloat
    let height: CGFloat = 16
    /// 마스크 — 흰색(알파) 도형들이 들어간다. 그라데이션은 이 도형 모양으로만 보인다.
    let content = CALayer()
    private let gradient = CAGradientLayer()
    private var stopsKey = ""

    init(width: CGFloat = 36) {
        self.width = width
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        gradient.frame = bounds
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        content.frame = bounds
        gradient.mask = content
        layer.bounds = bounds
        layer.addSublayer(gradient)
    }

    final func update(share: [(ServiceID, Double)], level: Double, percent: Double, now: Date) {
        // 그라데이션은 share가 바뀔 때만 갱신
        let key = share.map { "\($0.0.rawValue):\(Int($0.1 * 100))" }.joined(separator: ",")
        if key != stopsKey {
            stopsKey = key
            let g = WaveGradient.linear(share)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.colors = g.colors
            gradient.locations = g.locations
            CATransaction.commit()
        }
        updateContent(level: level, percent: percent, now: now)
    }

    /// 서브클래스 훅 — 입력이 의미 있게 바뀌었을 때만 도형·애니메이션을 다시 구성한다.
    func updateContent(level: Double, percent: Double, now: Date) {}
}

// MARK: - 펄스 바

/// 막대 7개 높이를 sin 곡선 CAKeyframeAnimation으로 반복 재생한다.
/// 기존 식 h = 4 + 12·amp·(0.5 + 0.5·sin(phase)), phase = t·(2.2 + 0.13i) + 0.9i 와 동일.
@MainActor
final class PulseBarsRenderer: LinearMaskedWave {
    private var bars: [CALayer] = []
    private var lastAmplitude = -1.0
    private let barW: CGFloat = 3, barGap: CGFloat = 2.5

    init() {
        super.init(width: 36)
        for i in 0..<7 {
            let b = CALayer()
            b.backgroundColor = NSColor.white.cgColor
            b.cornerRadius = barW / 2
            b.bounds = CGRect(x: 0, y: 0, width: barW, height: 8)
            b.position = CGPoint(x: barW / 2 + CGFloat(i) * (barW + barGap), y: height / 2)
            content.addSublayer(b)
            bars.append(b)
        }
    }

    override func updateContent(level: Double, percent: Double, now: Date) {
        let amplitude = 0.15 + 0.85 * level
        // 진폭이 0.04 이상 달라질 때만 애니메이션을 다시 등록한다 (절대 시간 위상 → 이어서 재생).
        guard abs(amplitude - lastAmplitude) > 0.04 else { return }
        lastAmplitude = amplitude
        let tNow = now.timeIntervalSinceReferenceDate
        let samples = 40
        for (i, bar) in bars.enumerated() {
            let omega = 2.2 + Double(i) * 0.13
            let phase0 = tNow * omega + Double(i) * 0.9
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
}

// MARK: - 스무스 웨이브

/// 연속 사인 곡선. 한 번 그려 둔 경로를 한 주기(λ)만큼 평행 이동하는 무한 애니메이션으로 흐름을 표현한다.
/// 기존 식: y = mid + amp·sin((x/W)·4π + t·2.4) → 파장 λ = W/2, 이동 주기 2π/2.4초.
@MainActor
final class SmoothWaveRenderer: LinearMaskedWave {
    private let shape = CAShapeLayer()
    private var lastAmp = -1.0
    private let wavelength: CGFloat = 18

    init() {
        super.init(width: 36)
        shape.strokeColor = NSColor.white.cgColor
        shape.fillColor = nil
        shape.lineWidth = 2
        shape.lineCap = .round
        shape.lineJoin = .round
        shape.bounds = CGRect(x: 0, y: 0, width: width + 2 * wavelength, height: height)
        shape.position = CGPoint(x: (width + 2 * wavelength) / 2, y: height / 2)
        content.addSublayer(shape)
        // 절대 시간 위상에서 시작 — 이동 거리 s·λ (s: 0→1 반복). 한 주기 뒤 되돌아가도 패턴이 같아 끊김이 없다.
        let frac0 = (Date().timeIntervalSinceReferenceDate * 2.4 / (2 * .pi)).truncatingRemainder(dividingBy: 1)
        let anim = CABasicAnimation(keyPath: "transform.translation.x")
        anim.fromValue = -wavelength * frac0
        anim.toValue = -wavelength * (frac0 + 1)
        anim.duration = 2 * .pi / 2.4
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        shape.add(anim, forKey: "scroll")
    }

    override func updateContent(level: Double, percent: Double, now: Date) {
        let amplitude = 0.15 + 0.85 * level
        let amp = (height / 2 - 1.5) * amplitude
        guard abs(amp - lastAmp) > 0.2 else { return }
        lastAmp = amp
        let path = CGMutablePath()
        let span = width + 2 * wavelength
        let steps = 96
        for i in 0...steps {
            let x = span * CGFloat(i) / CGFloat(steps)
            let y = height / 2 - amp * sin(Double(x / width) * 4 * .pi)   // CA는 y가 위로 증가 → SwiftUI와 부호 반대
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path
        CATransaction.commit()
    }
}

// MARK: - 하트비트

/// 심전도 라인 — 가우시안 합 파형(HeartbeatWave.ecg)을 주기 경로로 한 번 그려 두고 한 주기(P)만큼 이동하는 무한 애니메이션.
/// 기존 식: cyc = (frac·1.6 + t/2.4) mod 1 → 주기 길이 P = W/1.6, 이동 주기 2.4초.
@MainActor
final class HeartbeatRenderer: LinearMaskedWave {
    private let shape = CAShapeLayer()
    private var lastAmp = -1.0
    private var period: CGFloat { width / 1.6 }

    init() {
        super.init(width: 36)
        shape.strokeColor = NSColor.white.cgColor
        shape.fillColor = nil
        shape.lineWidth = 1.6
        shape.lineCap = .round
        shape.lineJoin = .round
        let span = width + 2 * period
        shape.bounds = CGRect(x: 0, y: 0, width: span, height: height)
        shape.position = CGPoint(x: span / 2, y: height / 2)
        content.addSublayer(shape)
        let frac0 = (Date().timeIntervalSinceReferenceDate / 2.4).truncatingRemainder(dividingBy: 1)
        let anim = CABasicAnimation(keyPath: "transform.translation.x")
        anim.fromValue = -period * frac0
        anim.toValue = -period * (frac0 + 1)
        anim.duration = 2.4
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        shape.add(anim, forKey: "scroll")
    }

    override func updateContent(level: Double, percent: Double, now: Date) {
        let amplitude = 0.15 + 0.85 * level
        let amp = (height / 2 - 1.0) * (0.5 + 0.5 * amplitude)
        guard abs(amp - lastAmp) > 0.15 else { return }
        lastAmp = amp
        let path = CGMutablePath()
        let span = width + 2 * period
        let steps = 180
        for i in 0...steps {
            let x = span * CGFloat(i) / CGFloat(steps)
            let cyc = Double(x / width * 1.6).truncatingRemainder(dividingBy: 1)
            let y = height / 2 + amp * HeartbeatWave.ecg(cyc)   // CA는 y가 위로 증가 → 스파이크가 위로
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path
        CATransaction.commit()
    }
}

// MARK: - 워터필

/// 사용률만큼 차오른 수면이 사인 파면으로 찰랑이는 2겹. 겹마다 속도가 달라 경로를 각자 한 주기(λ=W/1.5)씩 이동시킨다.
/// 기존 식: y = top + amp·sin((x/W)·3π + t·speed + shift), 뒤 겹(1.4, 0.7amp, 불투명도 0.4) / 앞 겹(2.3, amp, 0.75, shift 1.7).
@MainActor
final class WaterFillRenderer: LinearMaskedWave {
    private struct Layer {
        let shape = CAShapeLayer()
        let speed: Double
        let shift: Double
        let ampScale: Double
    }
    private let layers: [Layer]
    private var lastKey = ""
    private let wavelength: CGFloat = 24

    init() {
        layers = [Layer(speed: 1.4, shift: 0, ampScale: 0.7), Layer(speed: 2.3, shift: 1.7, ampScale: 1.0)]
        super.init(width: 36)
        // 둥근 사각형으로 오려내는 클립 안에 두 겹을 넣는다.
        let clip = CALayer()
        clip.frame = CGRect(x: 0, y: 0, width: width, height: height)
        clip.cornerRadius = 4
        clip.masksToBounds = true
        content.addSublayer(clip)
        let span = width + 2 * wavelength
        let now = Date().timeIntervalSinceReferenceDate
        for (i, l) in layers.enumerated() {
            l.shape.fillColor = NSColor.white.cgColor
            l.shape.opacity = i == 0 ? 0.4 : 0.75
            l.shape.bounds = CGRect(x: 0, y: 0, width: span, height: height)
            l.shape.position = CGPoint(x: span / 2, y: height / 2)
            clip.addSublayer(l.shape)
            let frac0 = (now * l.speed / (2 * .pi)).truncatingRemainder(dividingBy: 1)
            let anim = CABasicAnimation(keyPath: "transform.translation.x")
            anim.fromValue = -wavelength * frac0
            anim.toValue = -wavelength * (frac0 + 1)
            anim.duration = 2 * .pi / l.speed
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .linear)
            l.shape.add(anim, forKey: "scroll")
        }
        // 가장자리 테두리 (그라데이션 밖 — 흰색 12%)
        let border = CAShapeLayer()
        border.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: 0.25, dy: 0.25),
                             cornerWidth: 3.75, cornerHeight: 3.75, transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        border.lineWidth = 0.5
        layer.addSublayer(border)
    }

    override func updateContent(level: Double, percent: Double, now: Date) {
        let fill = max(0, min(1, percent / 100))
        let amp = 0.6 + 2.4 * level
        let key = String(format: "%.3f/%.1f", fill, amp)
        guard key != lastKey else { return }
        lastKey = key
        let span = width + 2 * wavelength
        let steps = 120
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in layers {
            let a = amp * l.ampScale
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            for i in 0...steps {
                let x = span * CGFloat(i) / CGFloat(steps)
                let phase = Double(x / width) * 3 * .pi + l.shift
                // 수면 높이 = height·fill (CA는 y가 위로 증가)
                path.addLine(to: CGPoint(x: x, y: height * fill - a * sin(phase)))
            }
            path.addLine(to: CGPoint(x: span, y: 0))
            path.closeSubpath()
            l.shape.path = path
        }
        CATransaction.commit()
    }
}

// MARK: - 오브 글로우

/// 숨쉬는 그라데이션 구슬. 색이 구슬 표면을 굴러가는 회전(등속 + 느린 흔들림)과 숨쉬기(크기 맥동)를 레이어 애니메이션으로 만든다.
/// 기존 식: roll = 55°·t + 14°·sin(0.7t), scale = (1-depth) + depth·(0.5+0.5·sin(1.8t)), depth = 0.10 + 0.12·level.
/// 근사: 글로우의 블러는 방사형 그라데이션으로 대체한다.
@MainActor
final class OrbGlowRenderer: WaveRenderer {
    let layer = CALayer()
    let width: CGFloat = 20
    private let d: CGFloat = 16   // 구슬 지름
    private let glow = CAGradientLayer()
    private let orb = CALayer()          // 숨쉬기(scale) 대상
    private let spin = CALayer()         // 등속 회전
    private let wobble = CAGradientLayer() // 원뿔 그라데이션 + 느린 흔들림
    private let highlight = CAGradientLayer()
    private var stopsKey = ""
    private var lastDepth = -1.0

    init() {
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: 16)
        let center = CGPoint(x: width / 2, y: 8)

        glow.type = .radial
        glow.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        glow.position = center
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        // CA 방사형 그라데이션의 반지름 = 시작점~끝점의 직선 거리 → 가로로만 줘야 반지름이 14pt가 된다 (대각선이면 √2배).
        glow.endPoint = CGPoint(x: 1, y: 0.5)
        // 블러된 원판처럼: 안쪽은 평평하다가 반지름의 ~0.57(원판 가장자리)에서 절반, 가장자리에서 0.
        glow.locations = [0, 0.3, 0.57, 1]
        layer.addSublayer(glow)

        orb.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        orb.position = center
        let clip = CALayer()
        clip.frame = orb.bounds
        clip.cornerRadius = d / 2
        clip.masksToBounds = true
        orb.addSublayer(clip)
        layer.addSublayer(orb)

        spin.frame = orb.bounds
        clip.addSublayer(spin)
        wobble.type = .conic
        wobble.frame = orb.bounds
        wobble.startPoint = CGPoint(x: 0.5, y: 0.5)
        wobble.endPoint = CGPoint(x: 1, y: 0.5)
        spin.addSublayer(wobble)

        // 하이라이트(광원)는 회전 밖 — 왼쪽 위 (SwiftUI 기준 0.35, 0.32 → y 뒤집기)
        highlight.type = .radial
        highlight.frame = orb.bounds
        highlight.startPoint = CGPoint(x: 0.35, y: 0.68)
        highlight.endPoint = CGPoint(x: 0.35 + 9.0 / 16.0, y: 0.68)   // 반지름 9pt (가로로만)
        highlight.colors = [NSColor.white.withAlphaComponent(0.35).cgColor, NSColor.clear.cgColor]
        clip.addSublayer(highlight)

        startRotation()
    }

    /// 회전: 등속(55°/s)은 spin, 흔들림(±14°, 0.7rad/s)은 그 안의 wobble — 합성하면 기존 roll과 같다.
    /// SwiftUI의 양의 회전은 시계 방향, CA는 반시계 방향이라 부호를 뒤집는다.
    private func startRotation() {
        let t0 = Date().timeIntervalSinceReferenceDate
        let a0 = (55 * t0).truncatingRemainder(dividingBy: 360) * .pi / 180
        let spinAnim = CABasicAnimation(keyPath: "transform.rotation.z")
        spinAnim.fromValue = -a0
        spinAnim.toValue = -(a0 + 2 * .pi)
        spinAnim.duration = 360.0 / 55.0
        spinAnim.repeatCount = .infinity
        spinAnim.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.add(spinAnim, forKey: "spin")

        let n = 40
        let values = (0...n).map { k -> NSNumber in
            let ph = 0.7 * t0 + 2 * Double.pi * Double(k) / Double(n)
            return NSNumber(value: -14 * sin(ph) * .pi / 180)
        }
        let wob = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        wob.values = values
        wob.calculationMode = .cubic
        wob.duration = 2 * .pi / 0.7
        wob.repeatCount = .infinity
        wobble.add(wob, forKey: "wobble")
    }

    private func breathe(depth: Double, now: Date) {
        let t0 = now.timeIntervalSinceReferenceDate
        let n = 40
        func anim(_ factor: Double) -> CAKeyframeAnimation {
            let values = (0...n).map { k -> NSNumber in
                let pulse = 0.5 + 0.5 * sin(1.8 * t0 + 2 * Double.pi * Double(k) / Double(n))
                return NSNumber(value: factor * ((1 - depth) + depth * pulse))
            }
            let a = CAKeyframeAnimation(keyPath: "transform.scale")
            a.values = values
            a.calculationMode = .cubic
            a.duration = 2 * .pi / 1.8
            a.repeatCount = .infinity
            return a
        }
        orb.add(anim(1.0), forKey: "breathe")
        glow.add(anim(1.25), forKey: "breathe")
    }

    func update(share: [(ServiceID, Double)], level: Double, percent: Double, now: Date) {
        let depth = 0.10 + 0.12 * level
        if abs(depth - lastDepth) > 0.01 {
            lastDepth = depth
            breathe(depth: depth, now: now)
        }
        let key = share.map { "\($0.0.rawValue):\(Int($0.1 * 100))" }.joined(separator: ",")
        guard key != stopsKey else { return }
        stopsKey = key
        var colors: [CGColor] = [], locs: [NSNumber] = []
        var mixed = (r: 0.0, g: 0.0, b: 0.0)
        if share.isEmpty {
            let p = NSColor.systemPurple.cgColor, b = NSColor.systemBlue.cgColor
            colors = [p, b, p]
            locs = [0, 0.5, 1]
            mixed = (0.69, 0.32, 0.87)
        } else {
            // 경계를 ±0.04 블렌딩 — 회전 시 색이 칼같이 끊기지 않고 흐르듯 섞인다. 원형으로 닫히게 첫 색을 끝에 한 번 더.
            let blend = 0.04
            var cursor = 0.0
            var prev = 0.0
            func add(_ c: CGColor, _ loc: Double) {
                let l = max(prev, min(1, max(0, loc)))   // CA는 위치가 비감소여야 한다
                colors.append(c); locs.append(NSNumber(value: l)); prev = l
            }
            for (svc, frac) in share {
                let c = WaveGradient.cg(svc)
                add(c, cursor + blend)
                cursor += frac
                add(c, cursor - blend)
                let rgb = Theme.rgb(for: svc)
                mixed.r += rgb.r * frac; mixed.g += rgb.g * frac; mixed.b += rgb.b * frac
            }
            add(WaveGradient.cg(share[0].0), 1.0)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wobble.colors = colors
        wobble.locations = locs
        func glowColor(_ a: CGFloat) -> CGColor { CGColor(red: mixed.r, green: mixed.g, blue: mixed.b, alpha: a) }
        glow.colors = [glowColor(0.25), glowColor(0.25), glowColor(0.12), glowColor(0)]
        CATransaction.commit()
    }
}
