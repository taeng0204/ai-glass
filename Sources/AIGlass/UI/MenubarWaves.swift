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
    /// 오버레이로 그릴 수 있는 스타일. 목록에 없는 스타일은 App이 기존 SwiftUI 방식으로 폴백한다.
    static let supported: Set<WaveStyle> = [.pulseBars, .smoothWave, .heartbeat]

    @MainActor
    static func make(_ style: WaveStyle) -> WaveRenderer {
        switch style {
        case .smoothWave: return SmoothWaveRenderer()
        case .heartbeat: return HeartbeatRenderer()
        default: return PulseBarsRenderer()
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
