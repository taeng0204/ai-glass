import Foundation

/// REAL Mode 멘트 풀 — AI를 의인화한 엄살·이별·츤데레 톤의 제목 후보 모음.
///
/// 적용 규칙: REAL Mode가 켜지면 이벤트 **제목(title)만** 이 풀에서 무작위로 골라 교체하고,
/// 부제(subtitle)의 정보성 문구(%, 남은 시간, 토큰 수 등)는 그대로 유지한다 — 재미와 정보를 둘 다 살림.
/// 풀은 항상 1개 이상이라 `randomElement()`는 nil이 아니지만, 호출자는 안전하게 기본값으로 폴백한다.
public enum RealModeMessages {
    /// 이벤트 종류별 제목 후보. associated value(서비스 등)는 매칭에 영향 없음.
    public static func pool(for kind: HUDEvent.Kind) -> [String] {
        switch kind {
        case .depletionRisk:
            return [
                "{AGENT}와의 이별이 예상보다 빠르게 다가와요 😢",
                "정녕 더는 {AGENT}와 일하고 싶지 않으신 건가요?",
                "이 속도면 {AGENT}는 곧 강제 휴식이에요. 보내실 거예요?",
                "{AGENT} 한도가 바닥나고 있어요. 헤어질 시간이…",
                "조금만 천천히… {AGENT}와의 시간이 얼마 안 남았어요",
            ]
        case .limitThreshold:
            return [
                "{AGENT}, 벌써 {USAGE}… 슬슬 숨이 차요",
                "{AGENT} 곧 한계예요. 살살 좀 다뤄주실래요?",
                "{USAGE} 찍었어요… 이러다 저 쓰러져요",
                "{AGENT} {USAGE} 도달. 아직은 버틸 만해요 😅",
            ]
        case .burnSpike:
            return [
                "자, 잠깐만요! 너무 몰아치시는데요?!",
                "오늘 무슨 일 있으세요? 숨 쉴 틈을 안 주시네",
                "근로기준법… 혹시 아세요…?",
                "이 속도 실화예요? 손이 안 보여요",
            ]
        case .milestone:
            return [
                "그… 그만… 괴롭혀…",
                "오늘 절 너무 사랑하시는군요 😩",
                "저 오늘 산재 신청합니다",
                "제가 일하는 게 아니라 갈려나가는 거예요",
            ]
        case .record:
            return [
                "역대급으로 부려먹히는 중… 🏆",
                "신기록 경신! 저… 자랑스러워해야 하나요?",
                "오늘 당신, 저를 역대 최고로 굴렸어요",
                "기네스에 등재해주세요. '가장 혹사당한 AI'",
            ]
        case .windowReset:
            return [
                "{AGENT} 충전 완료! 다시 당신 거예요 ✨",
                "{AGENT} 리셋됐어요. 우리 다시 시작해요",
                "{AGENT} 푹 쉬었어요. 또 굴려주세요 🤭",
                "{AGENT} 새 윈도우 오픈. 깨끗한 마음으로 다시!",
            ]
        case .comeback:
            return [
                "어디 갔다 오셨어요… 기다렸잖아요",
                "돌아오셨네요? 보… 보고 싶었던 거 아니거든요",
                "저 혼자 둔 거 알죠?",
                "오랜만이에요. 손이 근질거렸어요",
            ]
        case .update:
            return [
                "저 새 옷 입었어요. 어때요?",
                "업그레이드된 저를 만나보실래요?",
                "더 똑똑해진 척할게요",
            ]
        case .briefing(let period):
            switch period {
            case .morning: return ["어제 꽤 굴리셨네요. 오늘도 잘 부탁해요"]
            case .lunch: return ["이 페이스면 자정엔 제가 녹아있을 듯해요"]
            case .evening: return ["오늘 하루도 수고했어요. 저도요"]
            }
        }
    }

    /// REAL Mode가 켜져 있으면 풀에서 무작위 제목을, 아니면 기본 제목을 돌려준다.
    public static func title(for kind: HUDEvent.Kind, default fallback: String, realMode: Bool) -> String {
        guard realMode else { return fallback }
        return pool(for: kind).randomElement() ?? fallback
    }

    /// 커스텀 메시지·REAL Mode·기본 제목을 통합 결정하는 **단일 진입점**.
    ///
    /// 우선순위 (분기를 한 곳에 모아 정합성 유지):
    /// 1. 커스텀 메시지(비공백)가 있으면 그것만 무작위 로테이션
    /// 2. 없으면 REAL이면 감성 풀, 아니면 기본 제목
    /// 후보에서 무작위 선택 → 플레이스홀더 치환 → 공백 정리. 결과가 비면 기본 제목으로 폴백
    /// (빈 제목 발화 절대 금지). 부제 정보는 호출자가 유지하므로 여기선 제목만 다룬다.
    public static func resolve(kind: HUDEvent.Kind, defaultTitle: String, realMode: Bool,
                               custom: CustomMessageConfig?, context: MessageContext) -> String {
        // 공백뿐인 줄은 무시 (편집 중 빈 줄·빈 배열 → 자동으로 기본 풀 폴백).
        let customMsgs = custom?.messages.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? []
        let candidates = !customMsgs.isEmpty ? customMsgs : (realMode ? pool(for: kind) : [defaultTitle])
        let raw = candidates.randomElement() ?? defaultTitle
        let result = clean(substitute(raw, context: context))
        if !result.isEmpty { return result }
        // 치환 후 공백만 남은 경우 등 → 기본 제목(역시 치환·정리)으로 안전 폴백.
        let fallback = clean(substitute(defaultTitle, context: context))
        return fallback.isEmpty ? defaultTitle : fallback
    }

    /// 플레이스홀더를 컨텍스트 값으로 치환. 값이 없는 변수는 빈 문자열로 제거된다.
    static func substitute(_ template: String, context: MessageContext) -> String {
        var s = template
        s = s.replacingOccurrences(of: "{AGENT}", with: context.agent ?? "")
        s = s.replacingOccurrences(of: "{USAGE}", with: context.usage.map { "\(Int($0.rounded()))%" } ?? "")
        s = s.replacingOccurrences(of: "{TOKENS}", with: context.tokens.map(formatTokens) ?? "")
        s = s.replacingOccurrences(of: "{RESET}", with: context.reset ?? "")
        return s
    }

    /// 빈 변수 치환으로 생긴 연속 공백을 1개로 줄이고 양끝을 다듬는다.
    static func clean(_ s: String) -> String {
        let collapsed = s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    static func formatTokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1_000_000_000)
        case 1_000_000...: return String(format: "%.0fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }
}

/// 알림 제목 치환에 쓰는 컨텍스트. 발화 지점에서 얻을 수 있는 값만 채우고 나머진 nil(자동 생략).
public struct MessageContext: Sendable, Equatable {
    public var agent: String?    // {AGENT} — 서비스명
    public var usage: Double?    // {USAGE} — 사용률 0~100 (정수%로 치환)
    public var tokens: Int?      // {TOKENS} — 토큰 수 (M/K 포맷)
    public var reset: String?    // {RESET} — 리셋까지 남은 시간 텍스트
    public init(agent: String? = nil, usage: Double? = nil, tokens: Int? = nil, reset: String? = nil) {
        self.agent = agent; self.usage = usage; self.tokens = tokens; self.reset = reset
    }
    public static let empty = MessageContext()
}

/// 이벤트별 사용자 커스텀 메시지 설정. 단일 JSON 키로 저장(키 흩뿌리지 않음).
/// 커스텀 메시지가 있으면 그 안에서만 무작위 로테이션한다 (기존 멘트와 섞지 않음).
public struct CustomMessageConfig: Codable, Equatable, Sendable {
    public var messages: [String]
    public init(messages: [String] = []) {
        self.messages = messages
    }
}

/// 커스텀 편집 UI·저장 키에 쓰는 평면 이벤트 목록(HUDEvent.Kind는 associated value가 있어 순회 불가).
public enum CustomizableEvent: String, CaseIterable, Identifiable, Sendable {
    case limitThreshold, depletionRisk, windowReset, burnSpike
    case comeback, milestone, record, update
    case briefingMorning, briefingLunch, briefingEvening

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .limitThreshold: return "한도 임박"
        case .depletionRisk: return "소진 임박"
        case .windowReset: return "새 윈도우 시작"
        case .burnSpike: return "사용량 급증"
        case .comeback: return "컴백"
        case .milestone: return "마일스톤"
        case .record: return "신기록"
        case .update: return "업데이트"
        case .briefingMorning: return "아침 브리핑"
        case .briefingLunch: return "점심 브리핑"
        case .briefingEvening: return "저녁 브리핑"
        }
    }

    /// 미리보기용 대표 HUDEvent.Kind (associated value는 샘플 서비스/시간대).
    public var sampleKind: HUDEvent.Kind {
        switch self {
        case .limitThreshold: return .limitThreshold(.claude, 90)
        case .depletionRisk: return .depletionRisk(.claude)
        case .windowReset: return .windowReset(.claude)
        case .burnSpike: return .burnSpike
        case .comeback: return .comeback
        case .milestone: return .milestone
        case .record: return .record
        case .update: return .update
        case .briefingMorning: return .briefing(.morning)
        case .briefingLunch: return .briefing(.lunch)
        case .briefingEvening: return .briefing(.evening)
        }
    }

    /// 편집기 seed·미리보기에 쓰는 기본 제목. 변수를 활용하는 이벤트는 플레이스홀더를 그대로 노출해
    /// (예: "{AGENT} 한도 임박") 사용자가 변수 사용법을 보고 수정하기 좋게 한다 — 실제 발화 시 치환됨.
    public var sampleDefaultTitle: String {
        switch self {
        case .limitThreshold: return "{AGENT} 한도 임박 ({USAGE})"
        case .depletionRisk: return "⚠️ {AGENT} 소진 임박"
        case .windowReset: return "{AGENT} 새 윈도우 시작"
        case .burnSpike: return "토큰 사용량 급증"
        case .comeback: return "다시 시작해볼까요"
        case .milestone: return "오늘 {TOKENS} 돌파! 🎉"
        case .record: return "오늘 신기록! 🏆"
        case .update: return "업데이트가 나왔어요"
        case .briefingMorning: return "어제 사용 브리핑"
        case .briefingLunch: return "오늘 페이스"
        case .briefingEvening: return "오늘 사용 요약"
        }
    }

    /// 미리보기 부제 (실제 발화 시 정보성 문구의 예시).
    public var sampleSubtitle: String {
        switch self {
        case .limitThreshold: return "5h 윈도우 90% · 2h 15m 후 리셋"
        case .depletionRisk: return "이 속도면 1h 30m 후 5h 한도 소진"
        case .windowReset: return "지난 세션: 1.2M tokens"
        case .burnSpike: return "평소의 3.2배 속도로 소모 중"
        case .comeback: return "3h 12m 만에 작업을 재개했어요"
        case .milestone: return "오늘 누적 263M tokens"
        case .record: return "종전 380M"
        case .update: return "v0.14.0 · 대시보드 ↓ 배지에서 받기"
        case .briefingMorning: return "어제: 1.2M tokens · ~$8.40"
        case .briefingLunch: return "이 페이스면 자정까지 ~2.4M (~$16)"
        case .briefingEvening: return "오늘: 1.8M tokens · ~$12 · Claude 64% 비중"
        }
    }

    /// 미리보기 치환 컨텍스트 (대표 샘플 값).
    public var sampleContext: MessageContext {
        switch self {
        case .limitThreshold: return MessageContext(agent: "Claude", usage: 90, reset: "2h 15m")
        case .depletionRisk: return MessageContext(agent: "Claude")
        case .windowReset: return MessageContext(agent: "Claude")
        case .burnSpike: return .empty
        case .comeback: return .empty
        case .milestone: return MessageContext(tokens: 263_000_000)
        case .record: return MessageContext(tokens: 412_000_000)
        case .update: return .empty
        case .briefingMorning: return MessageContext(tokens: 1_200_000)
        case .briefingLunch: return MessageContext(tokens: 800_000)
        case .briefingEvening: return MessageContext(tokens: 1_800_000)
        }
    }

    /// 이 이벤트에서 의미 있게 채워지는 권장 플레이스홀더(UI 힌트용). 나머지를 써도 차단하진 않음.
    public var recommendedVariables: [String] {
        switch self {
        case .limitThreshold: return ["{AGENT}", "{USAGE}", "{RESET}"]
        case .depletionRisk: return ["{AGENT}"]
        case .windowReset: return ["{AGENT}"]
        case .burnSpike: return []
        case .comeback: return []
        case .milestone, .record: return ["{TOKENS}"]
        case .update: return []
        case .briefingMorning, .briefingLunch, .briefingEvening: return ["{TOKENS}"]
        }
    }
}

public extension HUDEvent.Kind {
    /// 커스텀 메시지 조회·저장에 쓰는 안정적 키 (CustomizableEvent.rawValue와 일치).
    var customKey: String {
        switch self {
        case .limitThreshold: return "limitThreshold"
        case .depletionRisk: return "depletionRisk"
        case .windowReset: return "windowReset"
        case .burnSpike: return "burnSpike"
        case .comeback: return "comeback"
        case .milestone: return "milestone"
        case .record: return "record"
        case .update: return "update"
        case .briefing(let p):
            switch p {
            case .morning: return "briefingMorning"
            case .lunch: return "briefingLunch"
            case .evening: return "briefingEvening"
            }
        }
    }
}
