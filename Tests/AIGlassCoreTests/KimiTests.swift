import Foundation
import Testing
@testable import AIGlassCore

private let usageLine = """
{"type":"usage.record","agentId":"main","model":"kimi-code/k3.1-pro","usage":{"inputOther":56191,"output":648,"inputCacheRead":6656,"inputCacheCreation":0},"usageScope":"turn","time":1793664599547}
"""

@Test func kimiParsesUsageRecord() throws {
    let p = try #require(KimiLogParser.parse(line: usageLine, fileKey: "session_a", project: "bugbounty"))
    #expect(p.event.service == .kimi)
    #expect(p.event.inputTokens == 56191)
    #expect(p.event.outputTokens == 648)
    #expect(p.event.cacheReadTokens == 6656)
    #expect(p.event.cacheCreationTokens == 0)
    #expect(p.event.model == "kimi-code/k3.1-pro")
    #expect(p.event.project == "bugbounty")
    #expect(p.event.timestamp == Date(timeIntervalSince1970: 1_793_664_599.547))
    #expect(p.key == "kimi:session_a:main:1793664599547")
}

@Test func kimiIgnoresOtherEventsAndZeroUsage() {
    #expect(KimiLogParser.parse(line: #"{"type":"llm.request","time":1}"#, fileKey: "s", project: nil) == nil)
    #expect(KimiLogParser.parse(line: #"{"type":"token_counting.measured","tokens":63495,"time":1}"#, fileKey: "s", project: nil) == nil)
    let zero = #"{"type":"usage.record","agentId":"main","model":"m","usage":{"inputOther":0,"output":0,"inputCacheRead":0,"inputCacheCreation":0},"time":1}"#
    #expect(KimiLogParser.parse(line: zero, fileKey: "s", project: nil) == nil)
    #expect(KimiLogParser.parse(line: "not json usage.record", fileKey: "s", project: nil) == nil)
}

@Test func kimiProjectNameFromState() {
    let state = #"{"id":"s","cwd":"/Users/x/Desktop/dev/bugbounty","archived":false}"#
    #expect(KimiLogParser.projectName(fromStateJSON: Data(state.utf8)) == "bugbounty")
    #expect(KimiLogParser.projectName(fromStateJSON: Data("{}".utf8)) == nil)
}

@Test func kimiCostUsesApiRate() {
    // 입력 $2 / 출력 $10 / 캐시 읽기 $0.20 (per 1M)
    let e = TokenEvent(service: .kimi, timestamp: Date(), model: "kimi-code/k3.1-pro",
                       inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 1_000_000,
                       cacheCreationTokens: 0)
    #expect(abs(CostEstimator.cost(of: e) - 12.2) < 0.0001)
}

private let usagesResponse = """
{"usages":{"limit_5h":{"used_ratio":0.25,"reset_time":"2026-11-03T14:00:00Z"},
"limit_7d":{"used_ratio":"0.5","reset_time":"2026-11-08T00:00:00.000Z"},
"limit_month_total":{"used_ratio":0.12,"reset_time":"2026-12-01T00:00:00Z"}},
"boosterWallet":null}
"""

@Test func kimiParsesUsagesResponse() throws {
    let w = try #require(KimiUsageAPI.parse(Data(usagesResponse.utf8)))
    #expect(w.count == 3)
    let five = try #require(w.first { $0.kind == .session5h })
    #expect(five.usedPercent == 25)
    #expect(five.resetsAt == ISO8601.date("2026-11-03T14:00:00Z"))
    #expect(w.first { $0.kind == .weekly }?.usedPercent == 50)
    #expect(w.first { $0.kind == .monthly }?.usedPercent == 12)
}

@Test func kimiUsagesWithoutWeeklyForNewPlans() throws {
    let json = #"{"usages":{"limit_5h":{"used_ratio":1.4},"limit_month_total":{"used_ratio":0.3}}}"#
    let w = try #require(KimiUsageAPI.parse(Data(json.utf8)))
    #expect(w.map(\.kind) == [.session5h, .monthly])
    #expect(w[0].usedPercent == 100)      // 초과값은 100으로 고정
    #expect(w[0].resetsAt == nil)
    #expect(KimiUsageAPI.parse(Data(#"{"usages":{}}"#.utf8)) == nil)
    #expect(KimiUsageAPI.parse(Data("garbage".utf8)) == nil)
}

@Test func kimiCredentialsParseSecondsAndMillis() throws {
    let sec = try #require(KimiCredentials.parse(Data(#"{"access_token":"t","expires_at":1793664599}"#.utf8)))
    let ms = try #require(KimiCredentials.parse(Data(#"{"access_token":"t","expires_at":1793664599000}"#.utf8)))
    #expect(sec.expiresAt == ms.expiresAt)
    #expect(KimiCredentials.parse(Data(#"{"access_token":""}"#.utf8)) == nil)
}

@Test func kimiLoadValidSkipsExpiredToken() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-\(UUID().uuidString)")
    let dir = home.appendingPathComponent(".kimi-code/credentials")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let now = Date(timeIntervalSince1970: 1_793_664_000)
    try Data(#"{"access_token":"tok","expires_at":1793664100}"#.utf8).write(to: dir.appendingPathComponent("a.json"))
    #expect(KimiCredentials.loadValid(home: home, now: now)?.accessToken == "tok")
    // 만료 30초 이내(leeway)면 무효.
    #expect(KimiCredentials.loadValid(home: home, now: now.addingTimeInterval(80)) == nil)
}

@Test func kimiBaseURLFromConfigOrRegion() {
    let toml = """
    default_model = "x"
    [providers."managed:kimi-code"]
    type = "kimi"
    base_url = "https://api.kimi.ai/coding/v1"
    [providers."other"]
    base_url = "https://example.com/v1"
    """
    #expect(KimiUsageAPI.baseURL(fromConfigTOML: toml)?.absoluteString == "https://api.kimi.ai/coding/v1")
    #expect(KimiUsageAPI.baseURL(fromConfigTOML: "[providers.\"other\"]\nbase_url = \"https://example.com\"") == nil)
}

@MainActor @Test func kimiCollectorReadsWireAndProject() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-\(UUID().uuidString)")
    let session = root.appendingPathComponent("wd_x/session_1")
    let agent = session.appendingPathComponent("agents/main")
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"cwd":"/a/b/myproj"}"#.utf8).write(to: session.appendingPathComponent("state.json"))
    try Data((#"{"type":"llm.request","time":1}"# + "\n" + usageLine + "\n").utf8)
        .write(to: agent.appendingPathComponent("wire.jsonl"))

    // 보관 컷오프는 주입한 시계 기준 (샘플 시각 2026-11 부근).
    let store = UsageStore(clock: { Date(timeIntervalSince1970: 1_793_664_600) })
    let collector = KimiCollector(root: root)
    #expect(collector.collect(into: store) == true)
    #expect(store.events.count == 1)
    #expect(store.events.first?.project == "myproj")
    #expect(collector.collect(into: store) == false)   // 증분: 새 줄 없음
}
