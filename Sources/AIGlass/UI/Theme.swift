import SwiftUI
import AIGlassCore

enum Theme {
    static let safeGreen = Color(red: 0.35, green: 0.82, blue: 0.54)

    static func color(for service: ServiceID) -> Color {
        switch service {
        case .claude: return safeGreen
        case .codex: return Color(red: 0.96, green: 0.73, blue: 0.26)   // amber
        case .gemini: return Color(red: 0.30, green: 0.55, blue: 0.96)  // blue
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
