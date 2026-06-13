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
    /// 온보딩/설정 프리뷰용 데모 입력 (store 의존 없음).
    /// share: 3색 모두 보이도록 claude 0.45 / codex 0.35 / gemini 0.20,
    /// activityLevel 0.5, percent 49%. `t`만 TimelineView가 주입 — 나머지는 고정.
    static func demo(t: Double) -> WaveInput {
        let level = 0.5
        return WaveInput(
            t: t,
            level: level,
            amplitude: 0.15 + 0.85 * level,
            share: [.claude: 0.45, .codex: 0.35, .gemini: 0.20],
            current: .claude,
            percent: 49)
    }
}

/// store 없이 스타일 하나를 라이브 렌더하는 프리뷰 래퍼 (온보딩·설정 재사용).
/// 알약 외형(글래스 캡슐)까지 포함해 실제 HUD와 동일한 느낌을 준다.
struct WaveStylePreview: View {
    let style: WaveStyle
    /// 캡슐 외형(글래스 배경)을 그릴지. false면 웨이브만.
    var chrome: Bool = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let input = WaveInput.demo(t: t)
            let content = HStack(spacing: 6) {
                waveView(input)
                    .frame(width: style.areaWidth, height: waveHeight)
                Circle()
                    .fill(Theme.color(for: .claude))
                    .frame(width: 5, height: 5)
                Text("49%")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.statusColor(percent: 49))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)

            if chrome {
                content
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private func waveView(_ input: WaveInput) -> some View {
        switch style {
        case .pulseBars: PulseBarsWave(input: input)
        case .smoothWave: SmoothWave(input: input)
        case .waterFill: WaterFillWave(input: input)
        case .orbGlow: OrbGlowWave(input: input)
        case .heartbeat: HeartbeatWave(input: input)
        }
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

    /// orbGlow용 각도 그라데이션 — share 비례 호로 서비스 색을 배치(끝색=첫색으로 닫음).
    /// 활동 없으면 보라-파랑.
    var orbGradient: AngularGradient {
        let active = ServiceID.allCases.compactMap { svc -> (ServiceID, Double)? in
            guard let s = share[svc], s > 0 else { return nil }
            return (svc, s)
        }
        guard !active.isEmpty else {
            return AngularGradient(colors: [.purple, .blue, .purple], center: .center)
        }
        var stops: [Gradient.Stop] = []
        var cursor = 0.0
        // 경계를 ±0.04 블렌딩 — 회전(굴림) 시 색이 칼같이 끊기지 않고 흐르듯 섞인다.
        let blend = 0.04
        for (svc, frac) in active {
            let c = Theme.color(for: svc)
            stops.append(.init(color: c, location: min(1.0, cursor + blend)))
            cursor += frac
            stops.append(.init(color: c, location: max(0.0, min(1.0, cursor - blend))))
        }
        // 원형으로 닫히도록 첫 색을 끝에 한 번 더.
        if let first = active.first { stops.append(.init(color: Theme.color(for: first.0), location: 1.0)) }
        return AngularGradient(gradient: Gradient(stops: stops), center: .center)
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
        // Canvas(CPU 래스터) 대신 Shape(GPU 렌더) — 매 프레임 CPU Path 래스터를 피한다.
        // path 생성(sin 계산)은 CPU지만 가볍고, stroke 래스터는 GPU가 처리.
        SmoothWaveShape(t: input.t, amplitude: input.amplitude)
            .stroke(input.gradient,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: waveWidth, height: waveHeight)
    }
}

/// 연속 사인 물결 곡선 (GPU 렌더용 Shape — 기존 Canvas와 동일 기하).
struct SmoothWaveShape: Shape {
    let t: Double
    let amplitude: Double
    func path(in rect: CGRect) -> Path {
        let midY = rect.height / 2
        let amp = (rect.height / 2 - 1.5) * amplitude
        // 속도는 상수 — 가변 속도 × t는 t가 거대해 위상 점프(깜빡임)를 만든다.
        let speed = 2.4
        var path = Path()
        let steps = 48
        for i in 0...steps {
            let x = rect.width * Double(i) / Double(steps)
            let phase = (Double(i) / Double(steps)) * 4 * .pi + t * speed
            let y = midY + amp * sin(phase)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

// MARK: - C: 워터필 (흐르는 사인 파면 2겹)

struct WaterFillWave: View {
    let input: WaveInput
    var body: some View {
        let level = max(0, min(1, input.percent / 100))
        let topFrac = 1 - level
        // 찰랑임 진폭 = burn(level)에 반응. idle도 미세하게.
        let amp = 0.6 + 2.4 * input.level
        // Canvas(CPU 래스터) 대신 Shape 2겹(GPU 렌더). 색은 가로 그라데이션(3색 유지).
        ZStack {
            // 뒤(느린·연한)
            WaterLayerShape(t: input.t, topFrac: topFrac, amp: amp * 0.7, speed: 1.4, phaseShift: 0)
                .fill(input.gradient)
                .opacity(0.4)
            // 앞(빠른·진한)
            WaterLayerShape(t: input.t, topFrac: topFrac, amp: amp, speed: 2.3, phaseShift: 1.7)
                .fill(input.gradient)
                .opacity(0.75)
        }
        .frame(width: waveWidth, height: waveHeight)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// 워터필 한 겹 — 사인 파면 아래를 채우는 닫힌 Path (GPU 렌더용 Shape).
struct WaterLayerShape: Shape {
    let t: Double
    let topFrac: Double   // 수면 높이: top = rect.height * topFrac
    let amp: CGFloat
    let speed: Double
    let phaseShift: Double
    func path(in rect: CGRect) -> Path {
        let top = rect.height * topFrac
        var path = Path()
        let steps = 40
        path.move(to: CGPoint(x: 0, y: rect.height))
        for i in 0...steps {
            let x = rect.width * CGFloat(i) / CGFloat(steps)
            let phase = (Double(i) / Double(steps)) * 3 * .pi + t * speed + phaseShift
            let y = top + amp * sin(phase)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.closeSubpath()
        return path
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
        // 단색 평균(mixedColor)은 보색 섞이면 회색 → "무색". share 가중 각도 그라데이션으로
        // 여러 서비스 색이 구슬에 함께 비치게 한다. glow는 대표(평균)색으로 은은히.
        let grad = input.orbGradient
        let glowColor = input.mixedColor
        // 색이 구슬 표면을 따라 계속 굴러가는 흐름 — 회전 속도는 상수(위상 점프 방지),
        // 느린 wobble을 더해 등속 회전의 기계적인 느낌을 깬다. 하이라이트(광원)는 회전 밖.
        let roll = Angle.degrees(input.t * 55 + 14 * sin(input.t * 0.7))
        ZStack {
            Circle()
                .fill(glowColor.opacity(0.25))
                .blur(radius: 4)
                .scaleEffect(scale * 1.25)
            Circle()
                .fill(grad)
                .rotationEffect(roll)
                .scaleEffect(scale)
                .overlay(
                    Circle()
                        .fill(RadialGradient(colors: [.white.opacity(0.35), .clear],
                                             center: .init(x: 0.35, y: 0.32),
                                             startRadius: 0, endRadius: 9))
                        .scaleEffect(scale)
                )
        }
        // 구슬 하나는 36pt가 과해 알약이 비어 보임 — 오브만 20pt로 축소.
        .frame(width: WaveStyle.orbGlow.areaWidth, height: waveHeight)
    }
}

// MARK: - E: 하트비트 (심전도 라인, 매끄러운 무한 스크롤)

struct HeartbeatWave: View {
    let input: WaveInput
    var body: some View {
        // Canvas(CPU 래스터) 대신 Shape(GPU 렌더).
        HeartbeatShape(t: input.t, amplitude: input.amplitude)
            .stroke(input.gradient,
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
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

/// 심전도 라인 (GPU 렌더용 Shape — 기존 Canvas와 동일 기하).
struct HeartbeatShape: Shape {
    let t: Double
    let amplitude: Double
    func path(in rect: CGRect) -> Path {
        let midY = rect.height / 2
        let amp = (rect.height / 2 - 1.0) * (0.5 + 0.5 * amplitude)
        // 고정 주기 연속 스크롤 (가변 주기 × t는 위상 점프 → 깜빡임).
        let scrollT = t / 2.4
        var path = Path()
        let steps = 80
        for i in 0...steps {
            let frac = Double(i) / Double(steps)
            let x = rect.width * frac
            let cyc = (frac * 1.6 + scrollT).truncatingRemainder(dividingBy: 1.0)
            let y = midY - amp * HeartbeatWave.ecg(cyc)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

