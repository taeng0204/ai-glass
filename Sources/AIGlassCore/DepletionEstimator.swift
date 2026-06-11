import Foundation

/// 한도 소진 예측 결과.
public struct Depletion: Equatable, Sendable {
    /// 현재 추세로 100%에 도달할 추정 시각.
    public let etaTo100: Date
    /// 리셋보다 먼저 소진될지 여부 (resetsAt이 있고 etaTo100 < resetsAt).
    public let willDepleteBeforeReset: Bool
    public init(etaTo100: Date, willDepleteBeforeReset: Bool) {
        self.etaTo100 = etaTo100
        self.willDepleteBeforeReset = willDepleteBeforeReset
    }
}

/// 사용률(%) 시계열에서 선형 추세로 소진 시점을 추정하는 순수 함수 묶음.
public enum DepletionEstimator {
    /// 최소제곱 선형 회귀로 %/min 기울기를 구해 100% 도달 시각을 추정한다.
    ///
    /// 추정 조건 (하나라도 불충족 시 nil):
    /// - 샘플 ≥ 3
    /// - 시간 범위 ≥ 5분
    /// - 기울기 > 0.05 %/min
    ///
    /// `etaTo100 = now + (100 - 최신%) / slope` 분.
    /// `willDepleteBeforeReset = resetsAt != nil && etaTo100 < resetsAt`.
    public static func estimate(samples: [(Date, Double)], resetsAt: Date?, now: Date) -> Depletion? {
        guard samples.count >= 3 else { return nil }
        let sorted = samples.sorted { $0.0 < $1.0 }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let rangeMinutes = last.0.timeIntervalSince(first.0) / 60
        guard rangeMinutes >= 5 else { return nil }

        // x = 분(첫 샘플 기준), y = percent
        let xs = sorted.map { $0.0.timeIntervalSince(first.0) / 60 }
        let ys = sorted.map { $0.1 }
        let n = Double(sorted.count)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }
        let denom = n * sumXX - sumX * sumX
        guard denom != 0 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denom  // %/min
        guard slope > 0.05 else { return nil }

        let latest = ys.last!
        let minutesTo100 = (100 - latest) / slope
        guard minutesTo100 > 0 else { return nil }
        let eta = now.addingTimeInterval(minutesTo100 * 60)
        let willDeplete = resetsAt.map { eta < $0 } ?? false
        return Depletion(etaTo100: eta, willDepleteBeforeReset: willDeplete)
    }
}
