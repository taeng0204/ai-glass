import Foundation
import Testing
@testable import AIGlassCore

// Claude Code를 Z.ai(GLM Coding Plan)로 돌리면 로그는 ~/.claude/projects에 그대로 쌓이고 모델명만 glm-*이다.
private let glmLine = """
{"cwd":"/Users/x/dev/bugbounty","type":"assistant","requestId":"req_g","timestamp":"2026-11-27T02:57:27.239Z","message":{"id":"msg_g","model":"glm-5.4","usage":{"input_tokens":17797,"cache_creation_input_tokens":0,"cache_read_input_tokens":128,"output_tokens":103}}}
"""

@Test func claudeLogLineWithGLMModelBelongsToGLM() throws {
    let (event, key) = try #require(ClaudeLogParser.parse(line: glmLine))
    #expect(event.service == .glm)
    #expect(event.model == "glm-5.4")
    #expect(event.inputTokens == 17797)
    #expect(event.outputTokens == 103)
    #expect(event.cacheReadTokens == 128)
    #expect(event.project == "bugbounty")
    #expect(key == "msg_g:req_g")
}

@Test func claudeLogLineWithClaudeModelStaysClaude() throws {
    let line = glmLine.replacingOccurrences(of: "glm-5.4", with: "claude-opus-5-5")
    #expect(try #require(ClaudeLogParser.parse(line: line)).event.service == .claude)
}

// MARK: - 한도 API (`/api/monitor/usage/quota/limit`)

/// 실제 응답(lite 플랜) 그대로. unit 3 × 5 = 5시간, unit 6 × 1 = 1주.
private let quotaResponse = """
{"code":200,"msg":"Operation successful","data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":23,"remaining":1976,"percentage":1,"nextResetTime":1795765923427},{"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":23,"remaining":9976,"percentage":1,"nextResetTime":1796352061983}],"level":"lite"},"success":true}
"""

@Test func zaiQuotaParsesFiveHourAndWeeklyWindows() throws {
    let windows = try #require(ZaiUsageAPI.parse(Data(quotaResponse.utf8)))
    #expect(windows.count == 2)
    let session = try #require(windows.first { $0.kind == .session5h })
    // 정수 percentage(1)보다 정밀한 currentValue / usage를 쓴다.
    #expect(abs(session.usedPercent - 1.15) < 0.0001)
    #expect(session.resetsAt == Date(timeIntervalSince1970: 1_795_765_923.427))
    let weekly = try #require(windows.first { $0.kind == .weekly })
    #expect(abs(weekly.usedPercent - 0.23) < 0.0001)
    #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_796_352_061.983))
}

@Test func zaiQuotaUsesPercentageWhenCountsAreMissing() throws {
    let json = #"{"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":42,"nextResetTime":1795765923427}]},"success":true}"#
    let windows = try #require(ZaiUsageAPI.parse(Data(json.utf8)))
    #expect(windows == [LimitWindow(kind: .session5h, usedPercent: 42,
                                    resetsAt: Date(timeIntervalSince1970: 1_795_765_923.427))])
}

@Test func zaiQuotaIgnoresToolCallLimitAndUnknownWindows() {
    // TIME_LIMIT는 웹 검색·리더 같은 MCP 도구 호출 횟수 한도라 모델 사용량 게이지가 아니다.
    // 길이를 모르는 창(unit 9)은 5h/주간으로 잘못 보이느니 버린다.
    let json = #"{"code":200,"data":{"limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"usage":100,"currentValue":90,"percentage":90},{"type":"CREDIT_LIMIT","unit":9,"number":1,"usage":10,"currentValue":5,"percentage":50}]},"success":true}"#
    #expect(ZaiUsageAPI.parse(Data(json.utf8)) == nil)
}

@Test func zaiQuotaReturnsNilForErrorResponse() {
    let json = #"{"code":401,"msg":"token expired or incorrect","success":false}"#
    #expect(ZaiUsageAPI.parse(Data(json.utf8)) == nil)
    #expect(ZaiUsageAPI.parse(Data("not json".utf8)) == nil)
}

// MARK: - 설정 탐색 (`~/.claude/*.json`의 Z.ai 설정)

private func makeClaudeHome(_ files: [String: String]) throws -> URL {
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aiglass-zai-\(UUID().uuidString)")
    let dir = home.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, body) in files {
        try Data(body.utf8).write(to: dir.appendingPathComponent(name))
    }
    return home
}

@Test func zaiConfigFoundFromSettingsWithKeychainHelper() throws {
    let home = try makeClaudeHome([
        "settings.json": #"{"model":"opus"}"#,
        "glm.json": #"{"apiKeyHelper":"/usr/bin/security find-generic-password -s zai-coding-plan -w","env":{"ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic"}}"#,
    ])
    let config = try #require(ZaiConfig.find(home: home))
    #expect(config.quotaURL == URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!)
    #expect(config.keySource == .keychain(service: "zai-coding-plan", account: nil))
}

@Test func zaiConfigUsesAuthTokenAndChinaHost() throws {
    let home = try makeClaudeHome([
        "settings.json": #"{"env":{"ANTHROPIC_BASE_URL":"https://open.bigmodel.cn/api/anthropic","ANTHROPIC_AUTH_TOKEN":"abc.def"}}"#,
    ])
    let config = try #require(ZaiConfig.find(home: home))
    #expect(config.quotaURL == URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!)
    #expect(config.keySource == .token("abc.def"))
}

@Test func zaiConfigReadsKeychainAccountFromHelper() {
    #expect(ZaiConfig.keychainItem(fromHelper: "security find-generic-password -a me -s 'zai key' -w")
            == .keychain(service: "zai key", account: "me"))
    // 설정에 적힌 임의 명령은 실행하지 않는다 — security 조회 형태만 해석한다.
    #expect(ZaiConfig.keychainItem(fromHelper: "cat ~/.zai-key") == nil)
    #expect(ZaiConfig.keychainItem(fromHelper: "security find-generic-password -s x -w; rm -rf ~") == nil)
}

@Test func zaiConfigIgnoresOtherProviders() throws {
    let home = try makeClaudeHome([
        "settings.json": #"{"env":{"ANTHROPIC_BASE_URL":"https://api.moonshot.ai/anthropic","ANTHROPIC_AUTH_TOKEN":"k"}}"#,
        "evil.json": #"{"env":{"ANTHROPIC_BASE_URL":"https://api.z.ai.attacker.example/api/anthropic","ANTHROPIC_AUTH_TOKEN":"k"}}"#,
    ])
    #expect(ZaiConfig.find(home: home) == nil)
}

@Test func zaiConfigDetectedEvenWithoutUsableKey() throws {
    // 키를 못 읽는 설정이어도 GLM을 쓰는 Mac인 건 맞다 (온보딩 감지용). 대신 keySource가 nil.
    let home = try makeClaudeHome([
        "glm.json": #"{"apiKeyHelper":"cat ~/.zai-key","env":{"ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic"}}"#,
    ])
    let config = try #require(ZaiConfig.find(home: home))
    #expect(config.keySource == nil)
}

// MARK: - 비용 · 통계 이전

@Test func glmCostUsesPublicApiRate() {
    // GLM-5.3 공개 API 단가 입력 $1.40 / 출력 $4.40 (per 1M) — 구독 실비 아님.
    let e = TokenEvent(service: .glm, timestamp: Date(), model: "glm-5.4",
                       inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 0, cacheCreationTokens: 0)
    #expect(abs(CostEstimator.cost(of: e) - 5.80) < 0.0001)
}

@MainActor @Test func statsMoveGLMRowsOutOfClaude() throws {
    let path = NSTemporaryDirectory() + "aiglass-test-\(UUID().uuidString)/stats.db"
    let store = try #require(DailyStatsStore(path: path))
    let now = ISO8601.date("2026-11-27T03:00:00Z")!
    // 이전 버전은 GLM 줄을 Claude로 저장했다.
    store.upsert(events: [
        TokenEvent(service: .claude, timestamp: now, model: "glm-5.4",
                   inputTokens: 100, outputTokens: 10, cacheReadTokens: 0, cacheCreationTokens: 0, project: "p"),
        TokenEvent(service: .claude, timestamp: now, model: "claude-opus-5-5",
                   inputTokens: 1000, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0, project: "p"),
        // 새 버전이 이미 같은 날 GLM 행을 일부 썼을 수도 있다 (최댓값 병합).
        TokenEvent(service: .glm, timestamp: now, model: "glm-5.4",
                   inputTokens: 60, outputTokens: 20, cacheReadTokens: 0, cacheCreationTokens: 0, project: "p"),
    ], calendar: .utc)

    store.moveGLMRowsOutOfClaude()
    store.moveGLMRowsOutOfClaude() // 멱등

    let totals = store.dailyTotalsByService(days: 2, now: now, calendar: .utc)
    #expect(totals.first { $0.service == .claude }?.tokens == 1000)
    #expect(totals.first { $0.service == .glm }?.tokens == 120) // max(100,60) + max(10,20)
}
