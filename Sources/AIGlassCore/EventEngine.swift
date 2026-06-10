import Foundation

public struct HUDEvent: Equatable {
    public enum Kind: Equatable {
        case limitThreshold(ServiceID, Int)  // 70 또는 90 교차
        case windowReset(ServiceID)
        case burnSpike
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
public final class EventEngine {
    public var thresholds: [Int] = [70, 90]
    public var spikeMultiplier: Double = 3.0
    public var spikeCooldown: TimeInterval = 30 * 60
    public var resetDropFloor: Double = 10  // 이 미만으로 떨어지면 리셋으로 간주
    public var resetDropFrom: Double = 30   // 직전 값이 이 이상이었을 때만

    private var lastPercent: [ServiceID: [LimitWindow.Kind: Double]] = [:]
    private var lastSpikeAt: Date = .distantPast

    public init() {}

    public func evaluate(limits: [ServiceID: [LimitWindow]],
                         burnRate: Double, baseline: Double, now: Date) -> [HUDEvent] {
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
                    resetEvents.append(HUDEvent(
                        kind: .windowReset(service),
                        title: "\(service.displayName) 새 윈도우 시작",
                        subtitle: "\(window.kind.label) 한도가 리셋되었습니다",
                        percent: window.usedPercent))
                }
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

        return thresholdEvents + resetEvents + spikeEvents
    }

    public static func countdown(to date: Date, from now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
