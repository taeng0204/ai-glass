import SwiftUI
import AIGlassCore

enum Theme {
    static let safeGreen = Color(red: 0.35, green: 0.82, blue: 0.54)

    static func color(for service: ServiceID) -> Color {
        switch service {
        case .claude: return Color(red: 0.93, green: 0.60, blue: 0.47)  // 테라코타 파스텔 #EE9978
        case .codex: return Color(red: 0.31, green: 0.79, blue: 0.64)   // ChatGPT 그린 파스텔 #4FC9A3
        case .gemini: return Color(red: 0.47, green: 0.66, blue: 0.97)  // 구글 블루 파스텔 #78A8F7
        }
    }
    static func statusColor(percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return safeGreen
    }
}

struct GaugeBar: View {
    let percent: Double
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            let fillWidth = percent <= 0 ? 0 : max(4, geo.size.width * min(1, percent / 100))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: fillWidth)
            }
        }
        .frame(height: 6)
        .animation(.spring(duration: 0.5), value: percent)
    }
}
