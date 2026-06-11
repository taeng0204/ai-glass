import Foundation

public struct HUDEvent: Equatable {
    public enum Kind: Equatable {
        case limitThreshold(ServiceID, Int)  // 70 또는 90 교차
        case depletionRisk(ServiceID)        // 리셋 전 소진 임박
        case windowReset(ServiceID)
        case burnSpike
        case briefing(BriefingEngine.Period)  // EventEngine과 무관 — HUDEvent 타입만 공유
        case comeback                         // 활동 공백 ≥3h 후 재시작
        case milestone                        // 오늘 누적 토큰 명예 임계 통과
        case record                           // 일일 토큰 신기록 경신
    }
    public let kind: Kind
    public let title: String
    public let subtitle: String
    public let percent: Double?
    public init(kind: Kind, title: String, subtitle: String, percent: Double?) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.percent = percent
    }
}

/// UsageStore 스냅샷을 평가해 HUD 이벤트를 만든다. 상태(직전 %, 쿨다운)를 보유.
@MainActor
public final class EventEngine {
    public var thresholds: [Int] = [70, 90]
    public var spikeMultiplier: Double = 3.0
    public var spikeCooldown: TimeInterval = 30 * 60
    public var resetDropFloor: Double = 10  // 이 미만으로 떨어지면 리셋으로 간주
    public var resetDropFrom: Double = 30   // 직전 값이 이 이상이었을 때만
    /// depletionRisk 서비스별 쿨다운 (기본 30분).
    public var depletionCooldown: TimeInterval = 30 * 60

    private var lastPercent: [ServiceID: [LimitWindow.Kind: Double]] = [:]
    private var lastSpikeAt: Date = .distantPast
    private struct DepletionKey: Hashable { let service: ServiceID; let kind: LimitWindow.Kind }
    private var lastDepletionAt: [DepletionKey: Date] = [:]

    public init() {}

    /// - Parameters:
    ///   - burnRate: `UsageStore.tokensPerMinute(windowMinutes: 10)` 값 (현재 분당 토큰 소모율)
    ///   - baseline: `UsageStore.activeBaselineRate()` 값 (평소 활동 시의 기준 소모율)
    ///   - depletions: 서비스별 소진 예측 목록(윈도우당 0~2개). `willDepleteBeforeReset`인 것만 depletionRisk 발화 ((서비스, kind)별 30분 쿨다운). 기본 `[:]`.
    ///   - reportProvider: windowReset 발화 시 subtitle을 교체할 세션 요약 공급자. non-nil 문자열을 주면 그 값을 subtitle로 사용. 기본 nil.
    /// 우선순위: threshold > depletionRisk > reset > spike.
    /// 참고: 임계 근처 오실레이션(71→69→71 재발화)은 의도된 MVP 단순화로 미보호.
    public func evaluate(limits: [ServiceID: [LimitWindow]],
                         burnRate: Double, baseline: Double, now: Date,
                         depletions: [ServiceID: [Depletion]] = [:],
                         reportProvider: ((ServiceID) -> String?)? = nil) -> [HUDEvent] {
        var thresholdEvents: [HUDEvent] = []
        var resetEvents: [HUDEvent] = []

        for (service, windows) in limits {
            for window in windows {
                // previous 기본값 0: nil이면 0으로 간주하여 첫 관측값이 이미 임계값 이상이면 발화
                let previous = lastPercent[service]?[window.kind] ?? 0
                defer { lastPercent[service, default: [:]][window.kind] = window.usedPercent }

                for threshold in thresholds.sorted(by: >) {
                    if previous < Double(threshold), window.usedPercent >= Double(threshold) {
                        thresholdEvents.append(HUDEvent(
                            kind: .limitThreshold(service, threshold),
                            title: "\(service.displayName) 한도 임박",
                            subtitle: "\(window.kind.label) 윈도우 \(Int(window.usedPercent))%"
                                + (window.resetsAt.map { " · \(Self.countdown(to: $0, from: now)) 후 리셋" } ?? ""),
                            percent: window.usedPercent))
                        break // 한 윈도우당 최고 임계값 하나만
                    }
                }
                if previous >= resetDropFrom, window.usedPercent < resetDropFloor {
                    let defaultSubtitle = "\(window.kind.label) 한도가 리셋되었습니다"
                    let subtitle = reportProvider?(service) ?? defaultSubtitle
                    resetEvents.append(HUDEvent(
                        kind: .windowReset(service),
                        title: "\(service.displayName) 새 윈도우 시작",
                        subtitle: subtitle,
                        percent: window.usedPercent))
                }
            }
        }

        var depletionEvents: [HUDEvent] = []
        // 서비스는 결정적 순서로, 같은 서비스 안에서는 5h를 주간보다 먼저.
        for service in ServiceID.allCases {
            guard let list = depletions[service] else { continue }
            let ordered = list.filter { $0.willDepleteBeforeReset }
                .sorted { kindOrder($0.kind) < kindOrder($1.kind) }
            for depletion in ordered {
                let key = DepletionKey(service: service, kind: depletion.kind)
                let last = lastDepletionAt[key] ?? .distantPast
                guard now.timeIntervalSince(last) >= depletionCooldown else { continue }
                lastDepletionAt[key] = now
                let subtitle: String
                switch depletion.kind {
                case .weekly:
                    let days = Self.daysUntil(depletion.etaTo100, from: now)
                    subtitle = "이 추세면 약 \(days)일 후 주간 한도 소진"
                default:
                    subtitle = "이 속도면 \(Self.countdown(to: depletion.etaTo100, from: now)) 후 5h 한도 소진"
                }
                depletionEvents.append(HUDEvent(
                    kind: .depletionRisk(service),
                    title: "⚠️ \(service.displayName) 소진 임박",
                    subtitle: subtitle,
                    percent: nil))
            }
        }

        var spikeEvents: [HUDEvent] = []
        if baseline > 0, burnRate > baseline * spikeMultiplier,
           now.timeIntervalSince(lastSpikeAt) >= spikeCooldown {
            lastSpikeAt = now
            let ratio = burnRate / baseline
            spikeEvents.append(HUDEvent(
                kind: .burnSpike,
                title: "토큰 사용량 급증",
                subtitle: String(format: "평소의 %.1f배 속도로 소모 중", ratio),
                percent: nil))
        }

        // 우선순위: threshold > depletionRisk > reset > spike
        return thresholdEvents + depletionEvents + resetEvents + spikeEvents
    }

    private func kindOrder(_ kind: LimitWindow.Kind) -> Int {
        switch kind {
        case .session5h: return 0
        case .daily:     return 1
        case .weekly:    return 2
        }
    }

    /// 올림한 일수 (최소 1일). 주간 소진 "~N일" 표시용.
    public static func daysUntil(_ date: Date, from now: Date) -> Int {
        let seconds = max(0, date.timeIntervalSince(now))
        return max(1, Int(ceil(seconds / (24 * 3600))))
    }

    public static func countdown(to date: Date, from now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let totalHours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if totalHours >= 24 {
            let days = totalHours / 24
            let hours = totalHours % 24
            return "\(days)d \(hours)h \(minutes)m"
        }
        return totalHours > 0 ? "\(totalHours)h \(minutes)m" : "\(minutes)m"
    }
}
