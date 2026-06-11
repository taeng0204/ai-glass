import SwiftUI
import AIGlassCore

/// 웨이브 스타일 5종의 렌더링 입력. WavePill이 매 프레임 구성해 넘긴다.
/// 모든 스타일은 동일 입력을 쓰고, 알약 내 웨이브 영역(폭 고정)만 차지한다.
struct WaveInput {
    /// 애니메이션 시간 (TimelineView date의 referenceDate 기준 초).
    let t: Double
    /// 활동 수준 0...1 (idle도 약간의 잔물결).
    let level: Double
    /// 진폭 0...1 (= 0.15 + 0.85*level).
    let amplitude: Double
    /// enabled 서비스별 share (합 1.0, 비었으면 idle).
    let share: [ServiceID: Double]
    /// 현재 표시 서비스(로테이션). nil이면 idle/전체.
    let current: ServiceID?
    /// 표시 서비스의 사용률 % (waterFill 수위 등).
    let percent: Double
}

/// 기본 웨이브 영역 폭. 7바×3 + 6간격×2.5 = 36. (orbGlow만 20 — areaWidth 참조)
private let waveWidth: CGFloat = 36
private let waveHeight: CGFloat = 16

extension WaveStyle {
    /// 스타일별 웨이브 영역 폭. 오브는 구슬 하나라 36pt가 과해 20pt로 축소.
    var areaWidth: CGFloat {
        self == .orbGlow ? 20 : 36
    }
}

extension WaveInput {
    /// share 비례 누적 위치에 서비스 색을 배치한 가로 그라데이션.
    /// 활동 없으면 보라-파랑. (WavePill의 기존 로직과 동일 의미.)
    var gradient: LinearGradient {
        let active = ServiceID.allCases.compactMap { svc -> (ServiceID, Double)? in
            guard let s = share[svc], s > 0 else { return nil }
            return (svc, s)
        }
        guard !active.isEmpty else {
            return LinearGradient(colors: [.purple.opacity(0.9), .blue.opacity(0.7)],
                                  startPoint: .leading, endPoint: .trailing)
        }
        var stops: [Gradient.Stop] = []
        var cursor = 0.0
        for (i, entry) in active.enumerated() {
            let (svc, frac) = entry
            let c = Theme.color(for: svc)
            let start = cursor
            let end = cursor + frac
            let blendStart = i == 0 ? start : max(start, start - 0.08)
            let blendEnd = i == active.count - 1 ? 1.0 : min(1.0, end - 0.08)
            stops.append(.init(color: c, location: blendStart))
            stops.append(.init(color: c, location: max(blendStart, blendEnd)))
            cursor = end
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    /// share 가중 혼합색 (orbGlow/waterFill 단색용). 활동 없으면 보라.
    var mixedColor: Color {
        let active = ServiceID.allCases.compactMap { svc -> (ServiceID, Double)? in
            guard let s = share[svc], s > 0 else { return nil }
            return (svc, s)
        }
        guard !active.isEmpty else { return .purple }
        var r = 0.0, g = 0.0, b = 0.0
        for (svc, frac) in active {
            let rgb = Theme.rgb(for: svc)
            r += rgb.r * frac; g += rgb.g * frac; b += rgb.b * frac
        }
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - A: 펄스 바 (기존)

struct PulseBarsWave: View {
    let input: WaveInput
    var body: some View {
        let mask = HStack(spacing: 2.5) {
            ForEach(0..<7, id: \.self) { i in
                let phase = input.t * (2.2 + Double(i) * 0.13) + Double(i) * 0.9
                let h = 4 + 12 * input.amplitude * (0.5 + 0.5 * sin(phase))
                Capsule().frame(width: 3, height: h)
            }
        }
        .frame(height: waveHeight)
        Rectangle()
            .fill(input.gradient)
            .mask(mask)
            .frame(width: waveWidth, height: waveHeight)
    }
}

// MARK: - B: 스무스 웨이브 (연속 사인 곡선)

struct SmoothWave: View {
    let input: WaveInput
    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            let amp = (size.height / 2 - 1.5) * input.amplitude
            // 속도는 상수 — 가변 속도 × t는 t가 거대해 위상 점프(깜빡임)를 만든다.
            // 활동 반응은 진폭(amplitude)으로 충분.
            let speed = 2.4
            var path = Path()
            let steps = 48
            for i in 0...steps {
                let x = size.width * Double(i) / Double(steps)
                let phase = (Double(i) / Double(steps)) * 4 * .pi + input.t * speed
                let y = midY + amp * sin(phase)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .linearGradient(input.gGradient,
                                                   startPoint: .zero,
                                                   endPoint: CGPoint(x: size.width, y: 0)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: waveWidth, height: waveHeight)
    }
}

// MARK: - C: 워터필 (흐르는 사인 파면 2겹)

struct WaterFillWave: View {
    let input: WaveInput
    var body: some View {
        let level = max(0, min(1, input.percent / 100))
        Canvas { ctx, size in
            let waterTop = size.height * (1 - level)
            // 찰랑임 진폭 = burn(level)에 반응. idle도 미세하게.
            let amp = 0.6 + 2.4 * input.level
            let baseColor = input.mixedColor
            // 2겹: 뒤(느린·연한) + 앞(빠른·진한).
            drawWaveLayer(&ctx, size: size, top: waterTop, amp: amp * 0.7,
                          speed: 1.4, phaseShift: 0, color: baseColor.opacity(0.35))
            drawWaveLayer(&ctx, size: size, top: waterTop, amp: amp,
                          speed: 2.3, phaseShift: 1.7, color: baseColor.opacity(0.7))
        }
        .frame(width: waveWidth, height: waveHeight)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }

    private func drawWaveLayer(_ ctx: inout GraphicsContext, size: CGSize, top: CGFloat,
                               amp: CGFloat, speed: Double, phaseShift: Double, color: Color) {
        var path = Path()
        let steps = 40
        path.move(to: CGPoint(x: 0, y: size.height))
        for i in 0...steps {
            let x = size.width * CGFloat(i) / CGFloat(steps)
            let phase = (Double(i) / Double(steps)) * 3 * .pi + input.t * speed + phaseShift
            let y = top + amp * sin(phase)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        ctx.fill(path, with: .color(color))
    }
}

// MARK: - D: 오브 글로우 (숨쉬는 그라데이션 구슬)

struct OrbGlowWave: View {
    let input: WaveInput
    var body: some View {
        // 맥동 속도는 상수 — 가변 속도 × t는 위상 점프(깜빡임). 활동은 숨 깊이로 반영.
        let pulse = 0.5 + 0.5 * sin(input.t * 1.8)
        let depth = 0.10 + 0.12 * input.level
        let scale = (1.0 - depth) + depth * pulse
        let color = input.mixedColor
        ZStack {
            Circle()
                .fill(color.opacity(0.25))
                .blur(radius: 4)
                .scaleEffect(scale * 1.25)
            Circle()
                .fill(RadialGradient(colors: [color, color.opacity(0.5)],
                                     center: .center, startRadius: 0, endRadius: 8))
                .scaleEffect(scale)
        }
        // 구슬 하나는 36pt가 과해 알약이 비어 보임 — 오브만 20pt로 축소.
        .frame(width: WaveStyle.orbGlow.areaWidth, height: waveHeight)
    }
}

// MARK: - E: 하트비트 (심전도 라인, 매끄러운 무한 스크롤)

struct HeartbeatWave: View {
    let input: WaveInput
    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            // 활동은 진폭에만 반영 — 차분한 톤.
            let amp = (size.height / 2 - 1.0) * (0.5 + 0.5 * input.amplitude)
            // 고정 주기 연속 스크롤. 가변 주기 × t는 t(referenceDate 초)가 거대해
            // 주기의 미세 변화에도 위상이 수백 사이클씩 점프 → 깜빡임. 상수로 고정한다.
            let scrollT = input.t / 2.4
            var path = Path()
            let steps = 80
            for i in 0...steps {
                let frac = Double(i) / Double(steps)
                let x = size.width * frac
                // 각 x를 박동 주기 좌표로 (스크롤하여 흐름).
                let cyc = (frac * 1.6 + scrollT).truncatingRemainder(dividingBy: 1.0)
                let y = midY - amp * Self.ecg(cyc)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .linearGradient(input.gGradient,
                                                   startPoint: .zero,
                                                   endPoint: CGPoint(x: size.width, y: 0)),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .frame(width: waveWidth, height: waveHeight)
    }

    /// 0...1 주기 좌표를 받아 매끄러운 심전도 파형을 반환.
    /// 가우시안 합으로 P-QRS-T를 근사 (미분 연속 → 끊김 없는 스크롤).
    /// 스파이크를 낮추고 폭을 넓혀 차분한 톤.
    static func ecg(_ x: Double) -> Double {
        func g(_ c: Double, _ w: Double) -> Double {
            let d = (x - c) / w
            return exp(-d * d)
        }
        // P파(작은 양) - Q(작은 음) - R(완화된 양) - S(완화된 음) - T파(중간 양)
        let p =  0.12 * g(0.18, 0.045)
        let q = -0.10 * g(0.35, 0.018)
        let r =  0.72 * g(0.40, 0.022)
        let s = -0.20 * g(0.45, 0.022)
        let tw = 0.24 * g(0.68, 0.06)
        return p + q + r + s + tw
    }
}

extension WaveInput {
    /// Canvas용 Gradient (LinearGradient는 Canvas에서 못 쓰므로 Gradient로).
    var gGradient: Gradient {
        let active = ServiceID.allCases.compactMap { svc -> (ServiceID, Double)? in
            guard let s = share[svc], s > 0 else { return nil }
            return (svc, s)
        }
        guard !active.isEmpty else {
            return Gradient(colors: [.purple.opacity(0.95), .blue.opacity(0.8)])
        }
        var stops: [Gradient.Stop] = []
        var cursor = 0.0
        for (i, entry) in active.enumerated() {
            let (svc, frac) = entry
            let c = Theme.color(for: svc)
            let start = cursor
            let end = cursor + frac
            let blendStart = i == 0 ? start : max(start, start - 0.08)
            let blendEnd = i == active.count - 1 ? 1.0 : min(1.0, end - 0.08)
            stops.append(.init(color: c, location: blendStart))
            stops.append(.init(color: c, location: max(blendStart, blendEnd)))
            cursor = end
        }
        return Gradient(stops: stops)
    }
}
