# AI Glass MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Code · Codex · Gemini 사용량을 liquid glass 플로팅 HUD(펄스 웨이브 알약)와 메뉴바 대시보드로 보여주는 macOS 네이티브 앱의 MVP.

**Architecture:** SPM 실행 파일 하나(`swift run AIGlass`). 로컬 로그 증분 파싱(3개 Collector) → `UsageStore`(@Observable 단일 상태) → SwiftUI UI(메뉴바 팝오버 + non-activating NSPanel HUD). Claude 한도는 Keychain OAuth 토큰으로 사용량 API 폴링, Codex 한도는 로그에 포함된 rate limit 스냅샷, Gemini는 일일 요청 수 추정.

**Tech Stack:** Swift 6 toolchain(언어 모드 v5), SwiftUI, Swift Charts, FSEvents, Swift Testing(`import Testing`), macOS 26+ (`glassEffect` 네이티브 liquid glass).

**MVP에서 의도적으로 미룬 것 (스펙 대비):** 비용($) 추적, SQLite 캐시(시작 시 최근 8일 로그 재파싱으로 대체), Settings UI(상수로 하드코딩), HUD 드래그 위치 저장(기본 우상단 고정 + `isMovableByWindowBackground`).

**실측 로그 포맷 (2026-06-10 이 Mac에서 확인):**
- Claude: `~/.claude/projects/**/*.jsonl` — 라인별 `{timestamp, requestId, message: {id, model, usage: {input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens}}}`
- Codex: `~/.codex/sessions/YYYY/MM/DD/*.jsonl` — `{timestamp, type:"event_msg", payload: {type:"token_count", info: {last_token_usage: {input_tokens, cached_input_tokens, output_tokens}}, rate_limits: {primary: {used_percent, window_minutes:299, resets_in_seconds}, secondary: {used_percent, window_minutes:10079, resets_in_seconds}}}}`
- Gemini: `~/.gemini/tmp/<hash>/logs.json` — `[{type:"user", timestamp, ...}]` 배열. **토큰 정보 없음** → 일일 요청 수만 추적.

---

### Task 1: SPM 스캐폴드 + 메뉴바 골격

**Files:**
- Create: `Package.swift`
- Create: `Sources/AIGlassCore/Placeholder.swift`
- Create: `Sources/AIGlass/main.swift`
- Create: `Tests/AIGlassCoreTests/SmokeTests.swift`
- Modify: `.gitignore`

- [ ] **Step 1: Package.swift 작성**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIGlass",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "AIGlassCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AIGlass",
            dependencies: ["AIGlassCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AIGlassCoreTests",
            dependencies: ["AIGlassCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

`.macOS("26.0")`이 현재 toolchain에서 거부되면 `.macOS(.v26)`, 그것도 안 되면 사용 가능한 최고 버전으로 내리고 코드의 glass API에 `if #available(macOS 26.0, *)` 가드를 추가한다.

- [ ] **Step 2: 최소 소스 작성**

`Sources/AIGlassCore/Placeholder.swift`:
```swift
public enum AIGlassCoreInfo {
    public static let version = "0.1.0"
}
```

`Sources/AIGlass/main.swift`:
```swift
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "✦ –"
        statusItem = item
    }
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

`Tests/AIGlassCoreTests/SmokeTests.swift`:
```swift
import Testing
@testable import AIGlassCore

@Test func versionExists() {
    #expect(AIGlassCoreInfo.version == "0.1.0")
}
```

- [ ] **Step 3: 빌드/테스트/실행 확인**

Run: `swift test`
Expected: PASS (1 test)

Run: `swift run AIGlass &` 후 메뉴바 우측에 `✦ –` 표시 확인, `kill %1`로 종료.

- [ ] **Step 4: .gitignore에 빌드 산출물 추가 후 커밋**

`.gitignore`에 `.build/` 줄 추가.

```bash
git add -A && git commit -m "feat: SPM 스캐폴드 + 메뉴바 골격"
```

---

### Task 2: 도메인 모델

**Files:**
- Create: `Sources/AIGlassCore/Models.swift`
- Create: `Sources/AIGlassCore/ISO8601.swift`
- Create: `Tests/AIGlassCoreTests/ModelsTests.swift`
- Delete: `Sources/AIGlassCore/Placeholder.swift`, `Tests/AIGlassCoreTests/SmokeTests.swift`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/AIGlassCoreTests/ModelsTests.swift`:
```swift
import Foundation
import Testing
@testable import AIGlassCore

@Test func tokenEventTotal() {
    let e = TokenEvent(service: .claude, timestamp: Date(), model: "claude-opus-4-8",
                       inputTokens: 100, outputTokens: 50, cacheReadTokens: 1000, cacheCreationTokens: 200)
    #expect(e.totalTokens == 1350)
}

@Test func iso8601ParsesFractionalAndPlain() {
    #expect(ISO8601.date("2026-06-10T10:52:36.739Z") != nil)
    #expect(ISO8601.date("2026-06-10T10:52:36Z") != nil)
    #expect(ISO8601.date("not-a-date") == nil)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test`
Expected: FAIL — `TokenEvent`, `ISO8601` 미정의 컴파일 에러.

- [ ] **Step 3: 구현**

`Sources/AIGlassCore/Models.swift`:
```swift
import Foundation

public enum ServiceID: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude, codex, gemini
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }
}

public struct LimitWindow: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case session5h, weekly, daily
        public var label: String {
            switch self {
            case .session5h: return "5h"
            case .weekly: return "주간"
            case .daily: return "일일"
            }
        }
    }
    public let kind: Kind
    public let usedPercent: Double // 0...100
    public let resetsAt: Date?
    public init(kind: Kind, usedPercent: Double, resetsAt: Date?) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct TokenEvent: Equatable, Sendable {
    public let service: ServiceID
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    public init(service: ServiceID, timestamp: Date, model: String,
                inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheCreationTokens: Int) {
        self.service = service
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }
    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
}
```

`Sources/AIGlassCore/ISO8601.swift`:
```swift
import Foundation

public enum ISO8601 {
    private static let withFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    public static func date(_ s: String) -> Date? {
        withFrac.date(from: s) ?? plain.date(from: s)
    }
}
```

Placeholder.swift와 SmokeTests.swift 삭제 (main.swift의 참조 없음 확인).

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test`
Expected: PASS (2 tests)

- [ ] **Step 5: 커밋**

```bash
git add -A && git commit -m "feat: 도메인 모델 (ServiceID, LimitWindow, TokenEvent)"
```

---

### Task 3: UsageStore 집계

**Files:**
- Create: `Sources/AIGlassCore/UsageStore.swift`
- Create: `Tests/AIGlassCoreTests/UsageStoreTests.swift`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/AIGlassCoreTests/UsageStoreTests.swift`:
```swift
import Foundation
import Testing
@testable import AIGlassCore

@MainActor
private func makeStore(now: Date) -> UsageStore {
    let store = UsageStore()
    func ev(minutesAgo: Double, model: String, total: Int, service: ServiceID = .claude) -> (TokenEvent, String?) {
        let e = TokenEvent(service: service, timestamp: now.addingTimeInterval(-minutesAgo * 60),
                           model: model, inputTokens: total, outputTokens: 0,
                           cacheReadTokens: 0, cacheCreationTokens: 0)
        return (e, nil)
    }
    store.addEvents([
        ev(minutesAgo: 5, model: "claude-opus-4-8", total: 1000),
        ev(minutesAgo: 8, model: "claude-fable-5", total: 2000),
        ev(minutesAgo: 60 * 26, model: "claude-opus-4-8", total: 500), // 어제
    ])
    return store
}

@MainActor @Test func dedupSkipsSameKey() {
    let store = UsageStore()
    let e = TokenEvent(service: .claude, timestamp: Date(), model: "m",
                       inputTokens: 1, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
    store.addEvents([(e, "k1"), (e, "k1"), (e, nil), (e, nil)])
    #expect(store.events.count == 3) // 키 중복 1개만 제거, nil 키는 중복 허용
}

@MainActor @Test func dailyTotalsAndModelBreakdown() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = makeStore(now: now)
    let days = store.dailyTotals(days: 7, now: now)
    #expect(days.count == 7)
    #expect(days.last!.tokens == 3000)         // 오늘
    #expect(days[5].tokens == 500)             // 어제
    let models = store.modelBreakdown(days: 7, now: now)
    // opus 합계 1000+500=1500, fable 2000 → fable이 1위
    #expect(models.first!.model == "claude-fable-5")
    #expect(models.first!.tokens == 2000)
}

@MainActor @Test func burnRateUsesRecentWindow() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = makeStore(now: now)
    // 최근 10분: 5분 전 1000 + 8분 전 2000 = 3000 → 300 tokens/min
    #expect(abs(store.tokensPerMinute(windowMinutes: 10, now: now) - 300.0) < 0.01)
    // 활동 레벨은 0...1로 클램프
    #expect(store.activityLevel(now: now) > 0)
    #expect(store.activityLevel(now: now) <= 1)
}

@MainActor @Test func maxUsedPercentAcrossServices() {
    let store = UsageStore()
    store.setLimits([LimitWindow(kind: .session5h, usedPercent: 38, resetsAt: nil)], for: .claude)
    store.setLimits([LimitWindow(kind: .session5h, usedPercent: 72, resetsAt: nil),
                     LimitWindow(kind: .weekly, usedPercent: 54, resetsAt: nil)], for: .codex)
    #expect(store.maxUsedPercent == 72)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test`
Expected: FAIL — `UsageStore` 미정의.

- [ ] **Step 3: 구현**

`Sources/AIGlassCore/UsageStore.swift`:
```swift
import Foundation
import Observation

@MainActor
@Observable
public final class UsageStore {
    public private(set) var limits: [ServiceID: [LimitWindow]] = [:]
    public private(set) var events: [TokenEvent] = []
    public private(set) var geminiRequestDates: [Date] = []
    public private(set) var lastActivityAt: Date?
    private var dedupKeys: Set<String> = []

    public init() {}

    public func setLimits(_ windows: [LimitWindow], for service: ServiceID) {
        limits[service] = windows
    }

    public func addEvents(_ batch: [(event: TokenEvent, dedupKey: String?)]) {
        var added = false
        for (event, key) in batch {
            if let key {
                if dedupKeys.contains(key) { continue }
                dedupKeys.insert(key)
            }
            events.append(event)
            added = true
        }
        if added { lastActivityAt = Date() }
    }

    public func setGeminiRequests(_ dates: [Date]) {
        geminiRequestDates = dates
    }

    public var maxUsedPercent: Double {
        limits.values.flatMap { $0 }.map(\.usedPercent).max() ?? 0
    }

    public func dailyTotals(days: Int, now: Date, calendar: Calendar = .current) -> [(day: Date, tokens: Int)] {
        let today = calendar.startOfDay(for: now)
        var buckets: [Date: Int] = [:]
        for e in events {
            buckets[calendar.startOfDay(for: e.timestamp), default: 0] += e.totalTokens
        }
        return (0..<days).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            return (day, buckets[day] ?? 0)
        }
    }

    public func modelBreakdown(days: Int, now: Date, calendar: Calendar = .current) -> [(model: String, tokens: Int)] {
        let cutoff = calendar.date(byAdding: .day, value: -days, to: now)!
        var byModel: [String: Int] = [:]
        for e in events where e.timestamp >= cutoff {
            byModel[e.model, default: 0] += e.totalTokens
        }
        return byModel.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    public func todayTokens(now: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: now)
        return events.filter { $0.timestamp >= start }.reduce(0) { $0 + $1.totalTokens }
    }

    public func todayRequests(now: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: now)
        let tokenReqs = events.filter { $0.timestamp >= start }.count
        let geminiReqs = geminiRequestDates.filter { $0 >= start }.count
        return tokenReqs + geminiReqs
    }

    public func tokensPerMinute(windowMinutes: Int, now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-Double(windowMinutes) * 60)
        let total = events.filter { $0.timestamp >= cutoff && $0.timestamp <= now }
            .reduce(0) { $0 + $1.totalTokens }
        return Double(total) / Double(windowMinutes)
    }

    /// 최근 24h 중 활동이 있던 분 단위 버킷들의 평균 tokens/min (burn spike 기저선)
    public func activeBaselineRate(now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-24 * 3600)
        var buckets: [Int: Int] = [:]
        for e in events where e.timestamp >= cutoff {
            buckets[Int(e.timestamp.timeIntervalSince1970) / 60, default: 0] += e.totalTokens
        }
        guard !buckets.isEmpty else { return 0 }
        return Double(buckets.values.reduce(0, +)) / Double(buckets.count)
    }

    /// 펄스 웨이브 진폭 (0...1). 100k tokens/min에서 최대.
    public func activityLevel(now: Date) -> Double {
        min(1.0, tokensPerMinute(windowMinutes: 2, now: now) / 100_000.0)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test`
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add -A && git commit -m "feat: UsageStore 집계 (일별/모델별/burn rate/dedup)"
```

---

### Task 4: ClaudeLogParser

**Files:**
- Create: `Sources/AIGlassCore/ClaudeLogParser.swift`
- Create: `Tests/AIGlassCoreTests/ClaudeLogParserTests.swift`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/AIGlassCoreTests/ClaudeLogParserTests.swift`:
```swift
import Foundation
import Testing
@testable import AIGlassCore

private let claudeLine = """
{"parentUuid":"x","cwd":"/tmp","sessionId":"s1","version":"2.0.0","gitBranch":"main","type":"assistant","requestId":"req_1","timestamp":"2026-06-10T10:52:36.739Z","uuid":"u1","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":15207,"cache_creation_input_tokens":100,"cache_read_input_tokens":29789,"output_tokens":962}}}
"""

@Test func parsesUsageLine() {
    let parsed = ClaudeLogParser.parse(line: claudeLine)
    #expect(parsed != nil)
    let (event, key) = parsed!
    #expect(event.service == .claude)
    #expect(event.model == "claude-opus-4-8")
    #expect(event.inputTokens == 15207)
    #expect(event.outputTokens == 962)
    #expect(event.cacheReadTokens == 29789)
    #expect(event.cacheCreationTokens == 100)
    #expect(key == "msg_1:req_1")
    #expect(event.timestamp == ISO8601.date("2026-06-10T10:52:36.739Z"))
}

@Test func skipsLinesWithoutUsage() {
    #expect(ClaudeLogParser.parse(line: #"{"type":"user","timestamp":"2026-06-10T10:00:00Z","message":{"role":"user","content":"hi"}}"#) == nil)
    #expect(ClaudeLogParser.parse(line: "not json") == nil)
    #expect(ClaudeLogParser.parse(line: "") == nil)
}

@Test func skipsSyntheticModel() {
    let line = claudeLine.replacingOccurrences(of: "claude-opus-4-8", with: "<synthetic>")
    #expect(ClaudeLogParser.parse(line: line) == nil)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter ClaudeLogParser`
Expected: FAIL — 미정의 컴파일 에러.

- [ ] **Step 3: 구현**

`Sources/AIGlassCore/ClaudeLogParser.swift`:
```swift
import Foundation

public enum ClaudeLogParser {
    /// 한 JSONL 라인 → 토큰 이벤트. usage가 없는 라인(user 메시지 등)은 nil.
    public static func parse(line: String) -> (event: TokenEvent, dedupKey: String?)? {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let tsString = obj["timestamp"] as? String,
              let timestamp = ISO8601.date(tsString)
        else { return nil }

        let model = (message["model"] as? String) ?? "unknown"
        guard model != "<synthetic>" else { return nil }

        func intValue(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }

        let event = TokenEvent(
            service: .claude,
            timestamp: timestamp,
            model: model,
            inputTokens: intValue("input_tokens"),
            outputTokens: intValue("output_tokens"),
            cacheReadTokens: intValue("cache_read_input_tokens"),
            cacheCreationTokens: intValue("cache_creation_input_tokens")
        )

        let messageID = message["id"] as? String
        let requestID = obj["requestId"] as? String
        let dedupKey: String? = (messageID != nil || requestID != nil)
            ? "\(messageID ?? ""):\(requestID ?? "")" : nil
        return (event, dedupKey)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter ClaudeLogParser`
Expected: PASS (3 tests)

- [ ] **Step 5: 커밋**

```bash
git add -A && git commit -m "feat: Claude JSONL 파서 (usage 추출 + dedup 키)"
```

---

### Task 5: CodexLogParser

**Files:**
- Create: `Sources/AIGlassCore/CodexLogParser.swift`
- Create: `Tests/AIGlassCoreTests/CodexLogParserTests.swift`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/AIGlassCoreTests/CodexLogParserTests.swift`:
```swift
import Foundation
import Testing
@testable import AIGlassCore

private let codexLine = """
{"timestamp":"2026-06-10T14:10:20.726Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10693227,"cached_input_tokens":10102400,"output_tokens":89540,"reasoning_output_tokens":40000,"total_tokens":10782767},"last_token_usage":{"input_tokens":93100,"cached_input_tokens":1920,"output_tokens":541,"reasoning_output_tokens":256,"total_tokens":93641},"model_context_window":272000},"rate_limits":{"primary":{"used_percent":34.5,"window_minutes":299,"resets_in_seconds":17940},"secondary":{"used_percent":12.0,"window_minutes":10079,"resets_in_seconds":561809}}}}
"""

private let codexLineNullInfo = """
{"timestamp":"2026-06-10T14:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":10.0,"window_minutes":299,"resets_in_seconds":1000},"secondary":{"used_percent":5.0,"window_minutes":10079,"resets_in_seconds":2000}}}}
"""

@Test func parsesTokenCountWithInfo() {
    let parsed = CodexLogParser.parse(line: codexLine)
    #expect(parsed != nil)
    let p = parsed!
    #expect(p.event != nil)
    // input은 캐시 제외분: 93100 - 1920 = 91180
    #expect(p.event!.inputTokens == 91180)
    #expect(p.event!.cacheReadTokens == 1920)
    #expect(p.event!.outputTokens == 541)
    #expect(p.event!.service == .codex)
    #expect(p.limits.count == 2)
    let session = p.limits.first { $0.kind == .session5h }!
    #expect(session.usedPercent == 34.5)
    #expect(session.resetsAt == p.timestamp.addingTimeInterval(17940))
    #expect(p.limits.contains { $0.kind == .weekly && $0.usedPercent == 12.0 })
}

@Test func parsesTokenCountWithNullInfo() {
    let parsed = CodexLogParser.parse(line: codexLineNullInfo)
    #expect(parsed != nil)
    #expect(parsed!.event == nil)
    #expect(parsed!.limits.count == 2)
}

@Test func skipsNonTokenCountLines() {
    #expect(CodexLogParser.parse(line: #"{"timestamp":"2026-06-10T14:00:00Z","type":"event_msg","payload":{"type":"agent_message"}}"#) == nil)
    #expect(CodexLogParser.parse(line: "garbage") == nil)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter CodexLogParser`
Expected: FAIL — 미정의 컴파일 에러.

- [ ] **Step 3: 구현**

`Sources/AIGlassCore/CodexLogParser.swift`:
```swift
import Foundation

public struct CodexParsed: Equatable {
    public let timestamp: Date
    public let event: TokenEvent?       // info가 null이면 nil
    public let limits: [LimitWindow]    // primary→session5h, secondary→weekly
}

public enum CodexLogParser {
    public static func parse(line: String) -> CodexParsed? {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let tsString = obj["timestamp"] as? String,
              let timestamp = ISO8601.date(tsString)
        else { return nil }

        var limits: [LimitWindow] = []
        if let rateLimits = payload["rate_limits"] as? [String: Any] {
            func window(_ key: String, kind: LimitWindow.Kind) -> LimitWindow? {
                guard let w = rateLimits[key] as? [String: Any],
                      let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                let resets = (w["resets_in_seconds"] as? NSNumber).map {
                    timestamp.addingTimeInterval($0.doubleValue)
                }
                return LimitWindow(kind: kind, usedPercent: used, resetsAt: resets)
            }
            if let p = window("primary", kind: .session5h) { limits.append(p) }
            if let s = window("secondary", kind: .weekly) { limits.append(s) }
        }

        var event: TokenEvent?
        if let info = payload["info"] as? [String: Any],
           let last = info["last_token_usage"] as? [String: Any] {
            func intValue(_ key: String) -> Int { (last[key] as? NSNumber)?.intValue ?? 0 }
            let cached = intValue("cached_input_tokens")
            event = TokenEvent(
                service: .codex,
                timestamp: timestamp,
                model: "gpt-codex",
                inputTokens: max(0, intValue("input_tokens") - cached),
                outputTokens: intValue("output_tokens"),
                cacheReadTokens: cached,
                cacheCreationTokens: 0
            )
        }
        return CodexParsed(timestamp: timestamp, event: event, limits: limits)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter CodexLogParser`
Expected: PASS (3 tests)

- [ ] **Step 5: 커밋**

```bash
git add -A && git commit -m "feat: Codex 세션 로그 파서 (rate limit + 토큰)"
```

---

### Task 6: GeminiLogParser

**Files:**
- Create: `Sources/AIGlassCore/GeminiLogParser.swift`
- Create: `Tests/AIGlassCoreTests/GeminiLogParserTests.swift`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/AIGlassCoreTests/GeminiLogParserTests.swift`:
```swift
import Foundation
import Testing
@testable import AIGlassCore

private let geminiJSON = """
[
 {"sessionId":"s1","messageId":0,"type":"user","message":"hello","timestamp":"2026-06-10T05:41:43.169Z"},
 {"sessionId":"s1","messageId":1,"type":"user","message":"/exit","timestamp":"2026-06-10T05:42:00.000Z"},
 {"sessionId":"s1","messageId":2,"type":"assistant","message":"bye","timestamp":"2026-06-10T05:42:01.000Z"}
]
"""

@Test func countsUserMessages() {
    let dates = GeminiLogParser.userMessageDates(jsonData: Data(geminiJSON.utf8))
    #expect(dates.count == 2)
    #expect(dates[0] == ISO8601.date("2026-06-10T05:41:43.169Z"))
}

@Test func toleratesMalformedJSON() {
    #expect(GeminiLogParser.userMessageDates(jsonData: Data("nope".utf8)).isEmpty)
    #expect(GeminiLogParser.userMessageDates(jsonData: Data("{}".utf8)).isEmpty)
}

@Test func dailyLimitFromRequestCount() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let today = [now.addingTimeInterval(-3600), now.addingTimeInterval(-60)]
    let yesterday = [now.addingTimeInterval(-26 * 3600)]
    let window = GeminiLogParser.dailyWindow(requestDates: today + yesterday, quota: 100, now: now, calendar: cal)
    #expect(window.kind == .daily)
    #expect(window.usedPercent == 2.0) // 오늘 2건 / 100
    #expect(window.resetsAt == cal.startOfDay(for: now).addingTimeInterval(24 * 3600))
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter GeminiLogParser`
Expected: FAIL — 미정의 컴파일 에러.

- [ ] **Step 3: 구현**

`Sources/AIGlassCore/GeminiLogParser.swift`:
```swift
import Foundation

public enum GeminiLogParser {
    /// logs.json(배열) → user 메시지 타임스탬프 목록
    public static func userMessageDates(jsonData: Data) -> [Date] {
        guard let arr = (try? JSONSerialization.jsonObject(with: jsonData)) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { entry in
            guard entry["type"] as? String == "user",
                  let ts = entry["timestamp"] as? String else { return nil }
            return ISO8601.date(ts)
        }
    }

    /// 일일 요청 수 → 쿼터 % 추정 윈도우. 리셋은 다음 자정(로컬).
    public static func dailyWindow(requestDates: [Date], quota: Int, now: Date,
                                   calendar: Calendar = .current) -> LimitWindow {
        let start = calendar.startOfDay(for: now)
        let todayCount = requestDates.filter { $0 >= start && $0 <= now }.count
        let percent = quota > 0 ? Double(todayCount) / Double(quota) * 100.0 : 0
        return LimitWindow(kind: .daily, usedPercent: min(100, percent),
                           resetsAt: start.addingTimeInterval(24 * 3600))
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter GeminiLogParser`
Expected: PASS (3 tests)

- [ ] **Step 5: 커밋**

```bash
git add -A && git commit -m "feat: Gemini logs.json 파서 (일일 요청 쿼터 추정)"
```

---

### Task 7: 증분 리더 + 파일 로케이터

**Files:**
- Create: `Sources/AIGlassCore/IncrementalLineReader.swift`
- Create: `Sources/AIGlassCore/LogLocator.swift`
- Create: `Tests/AIGlassCoreTests/IncrementalLineReaderTests.swift`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/AIGlassCoreTests/IncrementalLineReaderTests.swift`:
```swift
import Foundation
import Testing
@testable import AIGlassCore

@Test func readsOnlyNewCompleteLines() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aiglass-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("log.jsonl")

    try Data("line1\nline2\n".utf8).write(to: file)
    let reader = IncrementalLineReader()
    #expect(reader.newLines(of: file) == ["line1", "line2"])
    #expect(reader.newLines(of: file) == []) // 같은 내용 재호출 → 없음

    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("line3\npartial".utf8)) // 마지막 줄 미완성
    try handle.close()
    #expect(reader.newLines(of: file) == ["line3"]) // 완성된 줄만

    let handle2 = try FileHandle(forWritingTo: file)
    try handle2.seekToEnd()
    try handle2.write(contentsOf: Data("-done\n".utf8))
    try handle2.close()
    #expect(reader.newLines(of: file) == ["partial-done"])
}

@Test func locatorFindsRecentFilesRecursively() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aiglass-loc-\(UUID().uuidString)")
    let sub = dir.appendingPathComponent("a/b")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("x\n".utf8).write(to: sub.appendingPathComponent("new.jsonl"))
    try Data("x\n".utf8).write(to: sub.appendingPathComponent("skip.txt"))
    let old = sub.appendingPathComponent("old.jsonl")
    try Data("x\n".utf8).write(to: old)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-30 * 24 * 3600)], ofItemAtPath: old.path)

    let found = LogLocator.recentFiles(under: dir, suffix: ".jsonl", modifiedWithinDays: 8)
    #expect(found.map(\.lastPathComponent) == ["new.jsonl"])
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter IncrementalLineReader`
Expected: FAIL — 미정의 컴파일 에러.

- [ ] **Step 3: 구현**

`Sources/AIGlassCore/IncrementalLineReader.swift`:
```swift
import Foundation

/// 파일별 바이트 오프셋을 기억해 새로 추가된 완성 라인만 돌려준다.
public final class IncrementalLineReader {
    private var offsets: [String: UInt64] = [:]

    public init() {}

    public func newLines(of url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let key = url.path
        let size = (try? handle.seekToEnd()) ?? 0
        var start = offsets[key] ?? 0
        if start > size { start = 0 } // 파일이 줄었다 = 교체/순환 → 처음부터
        guard size > start else { offsets[key] = size; return [] }

        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

        // 완성된 줄(\n까지)만 소비하고 오프셋 전진
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let consumed = data[data.startIndex...lastNewline]
        offsets[key] = start + UInt64(consumed.count)
        return String(decoding: consumed, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
```

`Sources/AIGlassCore/LogLocator.swift`:
```swift
import Foundation

public enum LogLocator {
    /// dir 아래를 재귀 탐색해 suffix로 끝나고 최근 N일 내 수정된 파일을 반환.
    public static func recentFiles(under dir: URL, suffix: String,
                                   modifiedWithinDays: Int = 8) -> [URL] {
        let cutoff = Date().addingTimeInterval(-Double(modifiedWithinDays) * 24 * 3600)
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasSuffix(suffix),
                  let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate,
                  mod >= cutoff else { continue }
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter IncrementalLineReader`
Expected: PASS (2 tests)

- [ ] **Step 5: 커밋**

```bash
git add -A && git commit -m "feat: 증분 라인 리더 + 최근 로그 파일 로케이터"
```

---

### Task 8: Collector 3종

**Files:**
- Create: `Sources/AIGlassCore/Collectors.swift`
- Create: `Tests/AIGlassCoreTests/CollectorsTests.swift`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/AIGlassCoreTests/CollectorsTests.swift`:
```swift
import Foundation
import Testing
@testable import AIGlassCore

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aiglass-col-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let claudeLine = """
{"type":"assistant","requestId":"req_1","timestamp":"2026-06-10T10:52:36.739Z","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
"""

private let codexLine = """
{"timestamp":"2026-06-10T14:10:20.726Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":30}},"rate_limits":{"primary":{"used_percent":34.5,"window_minutes":299,"resets_in_seconds":17940},"secondary":{"used_percent":12.0,"window_minutes":10079,"resets_in_seconds":561809}}}}
"""

@MainActor @Test func claudeCollectorFeedsStore() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data((claudeLine + "\n").utf8).write(to: dir.appendingPathComponent("a.jsonl"))

    let store = UsageStore()
    let collector = ClaudeCollector(root: dir)
    collector.collect(into: store)
    #expect(store.events.count == 1)
    #expect(store.events[0].model == "claude-opus-4-8")

    collector.collect(into: store) // 증분 — 중복 누적 없음
    #expect(store.events.count == 1)
}

@MainActor @Test func codexCollectorFeedsStoreAndLimits() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data((codexLine + "\n").utf8).write(to: dir.appendingPathComponent("rollout.jsonl"))

    let store = UsageStore()
    let collector = CodexCollector(root: dir)
    collector.collect(into: store)
    #expect(store.events.count == 1)
    #expect(store.limits[.codex]?.count == 2)
    #expect(store.limits[.codex]?.first { $0.kind == .session5h }?.usedPercent == 34.5)
}

@MainActor @Test func geminiCollectorEstimatesDailyQuota() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let hashDir = dir.appendingPathComponent("abc123")
    try FileManager.default.createDirectory(at: hashDir, withIntermediateDirectories: true)
    let now = Date()
    let iso = ISO8601DateFormatter()
    let json = """
    [{"type":"user","timestamp":"\(iso.string(from: now))","message":"hi","messageId":0,"sessionId":"s"}]
    """
    try Data(json.utf8).write(to: hashDir.appendingPathComponent("logs.json"))

    let store = UsageStore()
    let collector = GeminiCollector(root: dir, dailyQuota: 100)
    collector.collect(into: store)
    #expect(store.geminiRequestDates.count == 1)
    #expect(store.limits[.gemini]?.first?.usedPercent == 1.0)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter Collectors`
Expected: FAIL — 미정의 컴파일 에러.

- [ ] **Step 3: 구현**

`Sources/AIGlassCore/Collectors.swift`:
```swift
import Foundation

@MainActor
public final class ClaudeCollector {
    private let root: URL
    private let reader = IncrementalLineReader()

    public init(root: URL) { self.root = root }

    public func collect(into store: UsageStore) {
        var batch: [(TokenEvent, String?)] = []
        for file in LogLocator.recentFiles(under: root, suffix: ".jsonl") {
            for line in reader.newLines(of: file) {
                if let parsed = ClaudeLogParser.parse(line: line) {
                    batch.append(parsed)
                }
            }
        }
        if !batch.isEmpty { store.addEvents(batch) }
    }
}

@MainActor
public final class CodexCollector {
    private let root: URL
    private let reader = IncrementalLineReader()
    private var latestLimitsTimestamp: Date = .distantPast

    public init(root: URL) { self.root = root }

    public func collect(into store: UsageStore) {
        var batch: [(TokenEvent, String?)] = []
        var latestLimits: [LimitWindow]?
        for file in LogLocator.recentFiles(under: root, suffix: ".jsonl") {
            for line in reader.newLines(of: file) {
                guard let parsed = CodexLogParser.parse(line: line) else { continue }
                if let event = parsed.event { batch.append((event, nil)) }
                if !parsed.limits.isEmpty, parsed.timestamp > latestLimitsTimestamp {
                    latestLimitsTimestamp = parsed.timestamp
                    latestLimits = parsed.limits
                }
            }
        }
        if !batch.isEmpty { store.addEvents(batch) }
        if let latestLimits { store.setLimits(latestLimits, for: .codex) }
    }
}

@MainActor
public final class GeminiCollector {
    private let root: URL
    private let dailyQuota: Int

    public init(root: URL, dailyQuota: Int = 1000) {
        self.root = root
        self.dailyQuota = dailyQuota
    }

    public func collect(into store: UsageStore, now: Date = Date()) {
        var allDates: [Date] = []
        for file in LogLocator.recentFiles(under: root, suffix: "logs.json", modifiedWithinDays: 8) {
            guard let data = try? Data(contentsOf: file) else { continue }
            allDates.append(contentsOf: GeminiLogParser.userMessageDates(jsonData: data))
        }
        store.setGeminiRequests(allDates)
        let window = GeminiLogParser.dailyWindow(requestDates: allDates, quota: dailyQuota, now: now)
        store.setLimits([window], for: .gemini)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter Collectors`
Expected: PASS (3 tests)

- [ ] **Step 5: 전체 테스트 + 커밋**

Run: `swift test`
Expected: 전부 PASS

```bash
git add -A && git commit -m "feat: Claude/Codex/Gemini Collector"
```

---

### Task 9: Claude 한도 — Keychain + OAuth 사용량 API

**Files:**
- Create: `Sources/AIGlassCore/ClaudeLimits.swift`
- Create: `Tests/AIGlassCoreTests/ClaudeLimitsTests.swift`
- Modify: `Sources/AIGlass/main.swift` (`--check-claude` 플래그)

주의: API 응답 스키마는 OSS 추적 앱들이 쓰는 형태를 가정한 것이다. **Step 5의 실기기 확인이 필수**이며, 실제 응답이 다르면 `parse(_:)`를 실측 스키마에 맞게 수정하고 fixture를 갈아끼운다.

- [ ] **Step 1: 응답 파서의 실패하는 테스트 작성**

`Tests/AIGlassCoreTests/ClaudeLimitsTests.swift`:
```swift
import Foundation
import Testing
@testable import AIGlassCore

private let usageJSON = """
{"five_hour":{"utilization":38.5,"resets_at":"2026-06-10T15:00:00Z"},"seven_day":{"utilization":21.0,"resets_at":"2026-06-15T00:00:00Z"}}
"""

@Test func parsesUsageResponse() {
    let windows = ClaudeUsageAPI.parse(Data(usageJSON.utf8))
    #expect(windows != nil)
    #expect(windows!.count == 2)
    let session = windows!.first { $0.kind == .session5h }!
    #expect(session.usedPercent == 38.5)
    #expect(session.resetsAt == ISO8601.date("2026-06-10T15:00:00Z"))
    #expect(windows!.contains { $0.kind == .weekly && $0.usedPercent == 21.0 })
}

@Test func parseFailsGracefully() {
    #expect(ClaudeUsageAPI.parse(Data("{}".utf8)) == nil)
    #expect(ClaudeUsageAPI.parse(Data("nope".utf8)) == nil)
}

@Test func keychainPayloadParsing() {
    let payload = #"{"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r","expiresAt":1780000000000}}"#
    #expect(ClaudeCredentials.parse(Data(payload.utf8))?.accessToken == "tok-123")
    #expect(ClaudeCredentials.parse(Data("{}".utf8)) == nil)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter ClaudeLimits`
Expected: FAIL — 미정의 컴파일 에러.

- [ ] **Step 3: 구현**

`Sources/AIGlassCore/ClaudeLimits.swift`:
```swift
import Foundation
import Security

public struct ClaudeCredentials {
    public let accessToken: String

    /// Keychain 항목 "Claude Code-credentials"의 JSON payload 파싱
    public static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return ClaudeCredentials(accessToken: token)
    }

    /// macOS Keychain에서 Claude Code OAuth 자격증명 읽기 (최초 1회 사용자 허용 다이얼로그 표시됨)
    public static func fromKeychain() -> ClaudeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return parse(data)
    }
}

public enum ClaudeUsageAPI {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public static func parse(_ data: Data) -> [LimitWindow]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        func window(_ key: String, kind: LimitWindow.Kind) -> LimitWindow? {
            guard let w = obj[key] as? [String: Any],
                  let used = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (w["resets_at"] as? String).flatMap(ISO8601.date)
            return LimitWindow(kind: kind, usedPercent: used, resetsAt: resets)
        }
        var windows: [LimitWindow] = []
        if let five = window("five_hour", kind: .session5h) { windows.append(five) }
        if let week = window("seven_day", kind: .weekly) { windows.append(week) }
        return windows.isEmpty ? nil : windows
    }

    /// raw 응답도 함께 돌려줘서 --check-claude에서 실제 스키마를 눈으로 확인할 수 있게 한다.
    public static func fetch(token: String) async throws -> (windows: [LimitWindow]?, raw: Data) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: request)
        return (parse(data), data)
    }
}
```

- [ ] **Step 4: 파서 테스트 통과 확인**

Run: `swift test --filter ClaudeLimits`
Expected: PASS (3 tests)

- [ ] **Step 5: `--check-claude` 수동 확인 플래그 추가 + 실기기 검증**

`Sources/AIGlass/main.swift` 상단 (NSApplication 설정 전)에 추가:
```swift
import AIGlassCore
import Foundation

if CommandLine.arguments.contains("--check-claude") {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        defer { semaphore.signal() }
        guard let creds = ClaudeCredentials.fromKeychain() else {
            print("Keychain에서 Claude Code 자격증명을 찾지 못했습니다.")
            return
        }
        do {
            let (windows, raw) = try await ClaudeUsageAPI.fetch(token: creds.accessToken)
            print("RAW:", String(decoding: raw, as: UTF8.self))
            print("PARSED:", windows ?? "파싱 실패 — parse(_:)를 실제 스키마에 맞춰 수정할 것")
        } catch {
            print("API 호출 실패:", error)
        }
    }
    semaphore.wait()
    exit(0)
}
```

Run: `swift run AIGlass --check-claude`
Expected: RAW JSON과 PARSED 윈도우 2개(5h/주간) 출력. Keychain 다이얼로그가 뜨면 "허용".
**파싱이 실패하면**: RAW 출력의 실제 키 이름으로 `parse(_:)`와 테스트 fixture를 수정하고 Step 4 재실행.

- [ ] **Step 6: 커밋**

```bash
git add -A && git commit -m "feat: Claude 한도 조회 (Keychain OAuth + 사용량 API)"
```

---

### Task 10: EventEngine

**Files:**
- Create: `Sources/AIGlassCore/EventEngine.swift`
- Create: `Tests/AIGlassCoreTests/EventEngineTests.swift`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/AIGlassCoreTests/EventEngineTests.swift`:
```swift
import Foundation
import Testing
@testable import AIGlassCore

@Test func firesOnThresholdCrossing() {
    let engine = EventEngine()
    let now = Date()
    let below: [ServiceID: [LimitWindow]] = [.codex: [LimitWindow(kind: .session5h, usedPercent: 65, resetsAt: nil)]]
    let above: [ServiceID: [LimitWindow]] = [.codex: [LimitWindow(kind: .session5h, usedPercent: 73, resetsAt: nil)]]

    #expect(engine.evaluate(limits: below, burnRate: 0, baseline: 0, now: now).isEmpty)
    let events = engine.evaluate(limits: above, burnRate: 0, baseline: 0, now: now)
    #expect(events.count == 1)
    guard case .limitThreshold(.codex, 70) = events[0].kind else {
        Issue.record("expected limitThreshold(.codex, 70), got \(events[0].kind)")
        return
    }
    // 같은 상태 재평가 → 재발화 없음
    #expect(engine.evaluate(limits: above, burnRate: 0, baseline: 0, now: now).isEmpty)
}

@Test func firesOnWindowReset() {
    let engine = EventEngine()
    let now = Date()
    let high: [ServiceID: [LimitWindow]] = [.claude: [LimitWindow(kind: .session5h, usedPercent: 80, resetsAt: nil)]]
    let reset: [ServiceID: [LimitWindow]] = [.claude: [LimitWindow(kind: .session5h, usedPercent: 2, resetsAt: nil)]]
    _ = engine.evaluate(limits: high, burnRate: 0, baseline: 0, now: now)
    let events = engine.evaluate(limits: reset, burnRate: 0, baseline: 0, now: now)
    #expect(events.count == 1)
    guard case .windowReset(.claude) = events[0].kind else {
        Issue.record("expected windowReset(.claude), got \(events[0].kind)")
        return
    }
}

@Test func firesBurnSpikeWithCooldown() {
    let engine = EventEngine()
    let now = Date()
    let spike = engine.evaluate(limits: [:], burnRate: 9000, baseline: 1000, now: now)
    #expect(spike.count == 1)
    guard case .burnSpike = spike[0].kind else {
        Issue.record("expected burnSpike, got \(spike[0].kind)")
        return
    }
    // 쿨다운(30분) 내 재발화 없음
    #expect(engine.evaluate(limits: [:], burnRate: 9000, baseline: 1000, now: now.addingTimeInterval(60)).isEmpty)
    // 쿨다운 지나면 재발화
    #expect(engine.evaluate(limits: [:], burnRate: 9000, baseline: 1000, now: now.addingTimeInterval(31 * 60)).count == 1)
}

@Test func priorityOrdersThresholdFirst() {
    let engine = EventEngine()
    let now = Date()
    let limits: [ServiceID: [LimitWindow]] = [.codex: [LimitWindow(kind: .session5h, usedPercent: 95, resetsAt: nil)]]
    let events = engine.evaluate(limits: limits, burnRate: 9000, baseline: 1000, now: now)
    #expect(events.count == 2)
    guard case .limitThreshold = events[0].kind else {
        Issue.record("threshold should come first")
        return
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter EventEngine`
Expected: FAIL — 미정의 컴파일 에러.

- [ ] **Step 3: 구현**

`Sources/AIGlassCore/EventEngine.swift`:
```swift
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
                let previous = lastPercent[service]?[window.kind]
                defer { lastPercent[service, default: [:]][window.kind] = window.usedPercent }
                guard let previous else { continue }

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
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter EventEngine`
Expected: PASS (4 tests)

- [ ] **Step 5: 커밋**

```bash
git add -A && git commit -m "feat: EventEngine (임계/리셋/급증 규칙 + 쿨다운)"
```

---

### Task 11: 메뉴바 팝오버 대시보드 UI

**Files:**
- Create: `Sources/AIGlass/UI/Theme.swift`
- Create: `Sources/AIGlass/UI/DashboardView.swift`
- Modify: `Sources/AIGlass/main.swift`

UI 코드는 단위 테스트 대신 수동 검증(빌드 + 실행 + 눈 확인). 데이터가 비어도 죽지 않아야 한다.

- [ ] **Step 1: 테마/공용 뷰 작성**

`Sources/AIGlass/UI/Theme.swift`:
```swift
import SwiftUI
import AIGlassCore

enum Theme {
    static func color(for service: ServiceID) -> Color {
        switch service {
        case .claude: return Color(red: 0.35, green: 0.82, blue: 0.54)  // green
        case .codex: return Color(red: 0.96, green: 0.73, blue: 0.26)   // amber
        case .gemini: return Color(red: 0.30, green: 0.55, blue: 0.96)  // blue
        }
    }
    static func statusColor(percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return Color(red: 0.35, green: 0.82, blue: 0.54)
    }
}

struct GaugeBar: View {
    let percent: Double
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(4, geo.size.width * min(1, percent / 100)))
            }
        }
        .frame(height: 6)
        .animation(.spring(duration: 0.5), value: percent)
    }
}
```

- [ ] **Step 2: 대시보드 작성**

`Sources/AIGlass/UI/DashboardView.swift`:
```swift
import SwiftUI
import Charts
import AIGlassCore

struct DashboardView: View {
    let store: UsageStore
    @State private var tab: Tab = .overview

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "개요", trends = "추이", models = "모델별"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .overview: OverviewTab(store: store)
            case .trends: TrendsTab(store: store)
            case .models: ModelsTab(store: store)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct OverviewTab: View {
    let store: UsageStore
    var body: some View {
        VStack(spacing: 10) {
            ForEach(ServiceID.allCases) { service in
                ServiceRow(service: service, windows: store.limits[service] ?? [])
            }
            HStack(spacing: 8) {
                StatCard(value: formatTokens(store.todayTokens(now: Date())), label: "오늘 토큰")
                StatCard(value: "\(store.todayRequests(now: Date()))", label: "오늘 요청")
                StatCard(value: "\(Int(store.maxUsedPercent))%", label: "최고 사용률")
            }
        }
    }
    private func formatTokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }
}

private struct ServiceRow: View {
    let service: ServiceID
    let windows: [LimitWindow]

    private var primary: LimitWindow? {
        windows.first { $0.kind == .session5h } ?? windows.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(Theme.color(for: service)).frame(width: 8, height: 8)
                Text(service.displayName).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(primary.map { "\(Int($0.usedPercent))%" } ?? "–")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(primary.map { Theme.statusColor(percent: $0.usedPercent) } ?? .secondary)
            }
            GaugeBar(percent: primary?.usedPercent ?? 0, tint: Theme.color(for: service))
            Text(subline)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var subline: String {
        guard !windows.isEmpty else { return "데이터 없음" }
        return windows.map { window in
            var part = "\(window.kind.label) \(Int(window.usedPercent))%"
            if let resets = window.resetsAt {
                part += " · 리셋 \(EventEngine.countdown(to: resets, from: Date()))"
            }
            return part
        }.joined(separator: "  ·  ")
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 14, weight: .bold).monospacedDigit())
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct TrendsTab: View {
    let store: UsageStore
    var body: some View {
        let data = store.dailyTotals(days: 7, now: Date())
        Chart(data, id: \.day) { item in
            BarMark(x: .value("날짜", item.day, unit: .day), y: .value("토큰", item.tokens))
                .foregroundStyle(.linearGradient(colors: [.blue, .purple],
                                                 startPoint: .bottom, endPoint: .top))
                .cornerRadius(3)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) {
                AxisValueLabel(format: .dateTime.day(), centered: true)
            }
        }
        .frame(height: 160)
    }
}

private struct ModelsTab: View {
    let store: UsageStore
    var body: some View {
        let models = store.modelBreakdown(days: 7, now: Date())
        let total = max(1, models.reduce(0) { $0 + $1.tokens })
        VStack(spacing: 8) {
            if models.isEmpty {
                Text("최근 7일 데이터 없음").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            ForEach(models.prefix(6), id: \.model) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.model).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text("\(Int(Double(item.tokens) / Double(total) * 100))%")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    GaugeBar(percent: Double(item.tokens) / Double(total) * 100, tint: .purple)
                }
            }
        }
    }
}
```

- [ ] **Step 3: main.swift에 팝오버 배선**

`Sources/AIGlass/main.swift`의 AppDelegate를 다음으로 교체:
```swift
import AppKit
import SwiftUI
import AIGlassCore

// (--check-claude 블록은 그대로 유지)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    lazy var claudeCollector = ClaudeCollector(
        root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"))
    lazy var codexCollector = CodexCollector(
        root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"))
    lazy var geminiCollector = GeminiCollector(
        root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/tmp"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "✦ –"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: DashboardView(store: store))
        popover = pop

        refresh()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        claudeCollector.collect(into: store)
        codexCollector.collect(into: store)
        geminiCollector.collect(into: store)
        let percent = store.maxUsedPercent
        statusItem?.button?.title = percent > 0 ? "✦ \(Int(percent))%" : "✦ –"
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 4: 수동 검증**

Run: `swift test` → 전부 PASS 확인 (countdown public 변경 영향 포함).
Run: `swift run AIGlass &`

확인 사항:
1. 메뉴바에 `✦ N%` 표시 (Codex 로그가 최근 8일 내 있으면 실제 %)
2. 클릭 → 팝오버에 서비스 3줄 게이지 + 통계 카드 3개
3. 추이 탭 → 7일 바 차트, 모델별 탭 → 모델 목록
4. `kill %1`로 종료

- [ ] **Step 5: 커밋**

```bash
git add -A && git commit -m "feat: 메뉴바 팝오버 대시보드 (개요/추이/모델별)"
```

---

### Task 12: 플로팅 HUD — 펄스 웨이브 + 이벤트 카드

**Files:**
- Create: `Sources/AIGlass/UI/HUDView.swift`
- Create: `Sources/AIGlass/HUDPanel.swift`
- Modify: `Sources/AIGlass/main.swift`

- [ ] **Step 1: HUD 상태와 뷰 작성**

`Sources/AIGlass/UI/HUDView.swift`:
```swift
import SwiftUI
import AIGlassCore

@MainActor
@Observable
final class HUDState {
    var currentEvent: HUDEvent?
    private var dismissTask: Task<Void, Never>?

    func show(_ event: HUDEvent) {
        dismissTask?.cancel()
        withAnimation(.spring(duration: 0.55, bounce: 0.25)) { currentEvent = event }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.45)) { self?.currentEvent = nil }
        }
    }
}

struct HUDView: View {
    let store: UsageStore
    let state: HUDState
    var onTap: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let event = state.currentEvent {
                EventCard(event: event)
            } else {
                WavePill(store: store)
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: state.currentEvent != nil ? 18 : 22))
        .onTapGesture { onTap() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(10)
    }
}

struct WavePill: View {
    let store: UsageStore

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = store.activityLevel(now: context.date) // 0...1
            let amplitude = 0.15 + 0.85 * level               // idle에도 잔물결
            HStack(spacing: 8) {
                HStack(spacing: 2.5) {
                    ForEach(0..<7, id: \.self) { i in
                        let phase = t * (2.2 + Double(i) * 0.13) + Double(i) * 0.9
                        let h = 4 + 12 * amplitude * (0.5 + 0.5 * sin(phase))
                        Capsule()
                            .fill(LinearGradient(colors: [.purple.opacity(0.9), .blue.opacity(0.7)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 3, height: h)
                    }
                }
                .frame(height: 16)
                Text("\(Int(store.maxUsedPercent))%")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.statusColor(percent: store.maxUsedPercent))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
        }
    }
}

struct EventCard: View {
    let event: HUDEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(event.title).font(.system(size: 12, weight: .bold))
            }
            Text(event.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
            if let percent = event.percent {
                GaugeBar(percent: percent, tint: Theme.statusColor(percent: percent))
            }
        }
        .padding(12)
        .frame(width: 230, alignment: .leading)
    }

    private var icon: String {
        switch event.kind {
        case .limitThreshold: return "exclamationmark.triangle.fill"
        case .windowReset: return "sparkles"
        case .burnSpike: return "flame.fill"
        }
    }
    private var iconColor: Color {
        switch event.kind {
        case .limitThreshold: return .orange
        case .windowReset: return .green
        case .burnSpike: return .pink
        }
    }
}
```

`.glassEffect`가 컴파일되지 않으면(SDK 미지원) `.background(.ultraThinMaterial, in: ...)`으로 대체하고 README에 기록.

- [ ] **Step 2: HUD 패널 작성**

`Sources/AIGlass/HUDPanel.swift`:
```swift
import AppKit
import SwiftUI
import AIGlassCore

@MainActor
final class HUDPanelController {
    let panel: NSPanel

    init(store: UsageStore, state: HUDState, onTap: @escaping () -> Void) {
        let size = NSSize(width: 280, height: 130)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // 그림자는 glassEffect가 그림
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(
            rootView: HUDView(store: store, state: state, onTap: onTap))

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - size.width - 8, y: frame.maxY - 4))
        }
        panel.orderFrontRegardless()
    }
}
```

- [ ] **Step 3: main.swift 배선 — HUD + EventEngine**

AppDelegate에 프로퍼티 추가:
```swift
    let hudState = HUDState()
    let eventEngine = EventEngine()
    var hudController: HUDPanelController?
```

`applicationDidFinishLaunching` 끝에 추가:
```swift
        hudController = HUDPanelController(store: store, state: hudState) { [weak self] in
            self?.togglePopover()
        }
```

`refresh()` 끝에 추가:
```swift
        let now = Date()
        let events = eventEngine.evaluate(
            limits: store.limits,
            burnRate: store.tokensPerMinute(windowMinutes: 10, now: now),
            baseline: store.activeBaselineRate(now: now),
            now: now)
        if let first = events.first { hudState.show(first) }
```

주의: HUD 클릭 → `togglePopover()`는 status item 버튼 기준으로 팝오버를 연다 (기존 메서드 재사용).

- [ ] **Step 4: 수동 검증**

Run: `swift test` → PASS 유지 확인.
Run: `swift run AIGlass &`

확인 사항:
1. 화면 우상단에 glass 알약 — 파형이 잔잔하게 움직임
2. Claude Code로 아무 작업 실행 → 30초 내 파형이 커짐 (activityLevel 반응)
3. 알약 클릭 → 메뉴바 팝오버 열림
4. 드래그로 위치 이동 가능
5. 이벤트 강제 확인: `refresh()` 직후 `hudState.show(HUDEvent(kind: .burnSpike, title: "테스트", subtitle: "이벤트 카드 모핑 확인", percent: 72))`를 임시로 1회 호출하는 코드 추가 → 카드 확장/6초 후 수축 확인 → 임시 코드 제거
6. `kill %1`로 종료

- [ ] **Step 5: 커밋**

```bash
git add -A && git commit -m "feat: 플로팅 HUD (펄스 웨이브 알약 + 이벤트 카드 모핑)"
```

---

### Task 13: 실시간성 — FSEvents 워처 + Claude 한도 폴링 + 마무리

**Files:**
- Create: `Sources/AIGlassCore/DirectoryWatcher.swift`
- Modify: `Sources/AIGlass/main.swift`
- Create: `README.md`

- [ ] **Step 1: DirectoryWatcher 작성**

`Sources/AIGlassCore/DirectoryWatcher.swift`:
```swift
import Foundation
import CoreServices

/// FSEvents로 디렉토리들을 감시. 변경 시 콜백 (메인 큐, 1초 디바운스 내장 latency).
public final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let callback: () -> Void

    public init?(paths: [String], onChange: @escaping () -> Void) {
        self.callback = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                DispatchQueue.main.async { watcher.callback() }
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // latency: 1초 코얼레싱
            flags) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
```

- [ ] **Step 2: main.swift 최종 배선**

AppDelegate에 추가:
```swift
    var watcher: DirectoryWatcher?
```

`applicationDidFinishLaunching` 끝에 추가:
```swift
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        watcher = DirectoryWatcher(paths: [
            home + "/.claude/projects",
            home + "/.codex/sessions",
            home + "/.gemini/tmp",
        ]) { [weak self] in
            self?.refresh()
        }

        // Claude 한도: 60초 폴링 (Keychain 접근은 최초 1회 허용 필요)
        pollClaudeLimits()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollClaudeLimits() }
        }
```

AppDelegate에 메서드 추가:
```swift
    func pollClaudeLimits() {
        Task { @MainActor in
            guard let creds = ClaudeCredentials.fromKeychain() else { return }
            guard let (windows, _) = try? await ClaudeUsageAPI.fetch(token: creds.accessToken),
                  let windows else { return }
            store.setLimits(windows, for: .claude)
            statusItem?.button?.title = "✦ \(Int(store.maxUsedPercent))%"
        }
    }
```

- [ ] **Step 3: 통합 수동 검증 (최종 시나리오)**

Run: `swift test`
Expected: 전부 PASS

Run: `swift run AIGlass &`

체크리스트:
1. HUD 알약 + 메뉴바 `✦ N%` 표시
2. 다른 터미널에서 `claude -p "1+1?"` 실행 → 수 초 내 파형 반응 (FSEvents 경로 동작)
3. 팝오버 개요에서 Claude 5h/주간 % 표시 (Keychain 허용 후)
4. Codex 게이지에 로그 기반 % 표시 (최근 8일 내 codex 사용 이력이 있을 때)
5. CPU 사용률이 idle에서 5% 미만인지 Activity Monitor로 확인 (TimelineView 30fps 비용 점검 — 높으면 minimumInterval을 1/15로)
6. `kill %1`

- [ ] **Step 4: README 작성**

`README.md`:
```markdown
# AI Glass

Claude Code · Codex · Gemini 사용량을 liquid glass 플로팅 HUD와 메뉴바 대시보드로 보여주는 macOS 앱.

## 실행

​```bash
swift run AIGlass            # 앱 실행 (메뉴바 + 플로팅 HUD)
swift run AIGlass --check-claude  # Claude 한도 API 연결 진단
swift test                   # 단위 테스트
​```

요구사항: macOS 26+, Claude Code / Codex / Gemini CLI 중 1개 이상 로그인 상태.

## 데이터 소스
- Claude: `~/.claude/projects/**/*.jsonl` + Keychain OAuth → 사용량 API (5h/주간 %)
- Codex: `~/.codex/sessions/**/*.jsonl` (rate limit 스냅샷 포함)
- Gemini: `~/.gemini/tmp/**/logs.json` (일일 요청 수 기반 추정)

모든 처리는 로컬. 외부 전송은 Anthropic 사용량 API 호출뿐.
```

(README의 코드펜스는 실제 작성 시 일반 백틱으로.)

- [ ] **Step 5: 최종 커밋**

```bash
git add -A && git commit -m "feat: FSEvents 실시간 감지 + Claude 한도 폴링 + README"
```

---

## 실행 중 막혔을 때

- `glassEffect` 컴파일 실패 → `.background(.ultraThinMaterial, in: Shape)` 대체 후 진행, README에 기록.
- Claude 사용량 API 404/스키마 불일치 → Task 9 Step 5의 RAW 출력 기준으로 `ClaudeUsageAPI.parse` + fixture 수정. 그래도 실패하면 Claude 게이지는 `–` 처리하고 토큰 통계만 표시 (스펙의 degrade 정책).
- Keychain 접근 거부 → Claude 한도만 비활성, 나머지 동작 유지.
- Swift Testing(`import Testing`) 미지원 toolchain → XCTest로 전환 (`XCTestCase` + `XCTAssertEqual`).
