import SwiftUI
import AIGlassCore

/// GitHub 잔디 스타일 사용량 히트맵.
///
/// 최근 15주 × 7일(월~일) 그리드. 열 = 주(왼쪽=과거, 오른쪽=최신),
/// 행 = 요일(위=월, 아래=일). 셀 농도 = 일 토큰 / 기간 최대 토큰을 5단계로 양자화.
/// hover 시 그리드 하단에 고정 캡션(날짜 + 토큰)을 표시한다(팝오버 금지).
/// 오늘 셀은 테두리로 강조하고, 등장 시 주 단위 stagger로 농도가 0→값으로 차오른다(1회성).
struct HeatmapView: View {
    /// 격자는 부모가 통계 DB를 한 번 읽어 만든다 (`HeatmapGrid.load`). 이 뷰는 그리기만 해서,
    /// 마우스를 올려 hover 상태가 바뀌어도 DB를 다시 읽지 않는다.
    let grid: HeatmapGrid

    private static let cellSize: CGFloat = 9
    private static let cellSpacing: CGFloat = 3
    private static let cellCorner: CGFloat = 2

    @State private var appeared = false
    @State private var hovered: HeatmapGrid.Day? = nil

    // 민트(safeGreen) 계열 농도. 라이트/다크 시맨틱 대비 위해 0단계는 .quaternary.
    private func cellColor(level: Int) -> Color {
        switch level {
        case 1: return Theme.safeGreen.opacity(0.30)
        case 2: return Theme.safeGreen.opacity(0.55)
        case 3: return Theme.safeGreen.opacity(0.78)
        case 4: return Theme.safeGreen.opacity(1.0)
        default: return Color.primary.opacity(0.10)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: Self.cellSpacing) {
                ForEach(grid.weeks) { week in
                    VStack(spacing: Self.cellSpacing) {
                        ForEach(0..<7, id: \.self) { row in
                            cell(week.days[row], staggerIndex: week.index)
                        }
                    }
                }
            }
            caption
        }
        .padding(.vertical, 4)
        .onAppear {
            guard !appeared else { return }
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
        }
    }

    @ViewBuilder
    private func cell(_ gridDay: HeatmapGrid.Day?, staggerIndex: Int) -> some View {
        if let gridDay {
            let isToday = gridDay.isToday
            RoundedRectangle(cornerRadius: Self.cellCorner)
                .fill(cellColor(level: gridDay.level))
                .frame(width: Self.cellSize, height: Self.cellSize)
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cellCorner)
                        .strokeBorder(isToday ? Theme.safeGreen : .clear, lineWidth: 1.2)
                )
                // 주 단위 stagger: 최신 주일수록 살짝 늦게 차오른다(1회성).
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.4)
                .animation(.spring(duration: 0.5).delay(Double(staggerIndex) * 0.02), value: appeared)
                .onHover { inside in
                    hovered = inside ? gridDay : (hovered == gridDay ? nil : hovered)
                }
        } else {
            // 빈 칸(미래/격자 패딩) — 자리만 차지.
            Color.clear
                .frame(width: Self.cellSize, height: Self.cellSize)
        }
    }

    // 그리드 하단 고정 캡션. hover 중인 셀의 날짜+토큰, 없으면 범례.
    @ViewBuilder
    private var caption: some View {
        if let hovered {
            HStack(spacing: 6) {
                Text(Self.captionDateFormatter.string(from: hovered.day))
                Text("·")
                Text("\(formatTokens(hovered.tokens)) 토큰")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                Text("적음").font(.system(size: 9)).foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { lvl in
                    RoundedRectangle(cornerRadius: Self.cellCorner)
                        .fill(cellColor(level: lvl))
                        .frame(width: Self.cellSize, height: Self.cellSize)
                }
                Text("많음").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }

    private static let captionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")!
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}
