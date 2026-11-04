import Foundation
import Testing
@testable import AIGlassCore

/// `agy -p "/usage" --output-format json` 실제 출력 형태 (값만 샘플).
private let agyUsageJSON = """
{"conversation_id":"","status":"SUCCESS","response":"...","duration_seconds":0,"num_turns":0,
"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},
"command":{"name":"usage","data":{"description":"...","groups":[
{"name":"Gemini Models","description":"x","buckets":[
 {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-11-10T08:31:21Z"},
 {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-11-03T13:31:21Z"}]},
{"name":"Claude and GPT models","description":"x","buckets":[
 {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.95,"reset_time":"2026-11-10T01:55:29Z"}]},
{"name":"Gemini 4 Argon","description":"x","buckets":[
 {"id":"argon-weekly","name":"Gemini 4 Argon Weekly Limit","window":"weekly","remaining_fraction":0.97,"reset_time":"2026-11-09T01:08:09Z"}]}
]}}}
"""

@Test func antigravityQuotaUsesArgonGroupOnly() throws {
    let w = try #require(AntigravityQuota.parse(Data(agyUsageJSON.utf8)))
    #expect(w.count == 1)
    #expect(w[0].kind == .weekly)
    #expect(abs(w[0].usedPercent - 3.0) < 0.0001)   // remaining 97% → used 3%
    #expect(w[0].resetsAt == ISO8601.date("2026-11-09T01:08:09Z"))
}

@Test func antigravityQuotaOtherGroupAndWindows() throws {
    let w = try #require(AntigravityQuota.parse(Data(agyUsageJSON.utf8), groupMatch: "gemini models"))
    #expect(w.map(\.kind) == [.weekly, .session5h])
    #expect(w.allSatisfy { $0.usedPercent == 0 })
}

@Test func antigravityQuotaMissingGroupOrBadInputIsNil() {
    #expect(AntigravityQuota.parse(Data(agyUsageJSON.utf8), groupMatch: "nonexistent") == nil)
    #expect(AntigravityQuota.parse(Data("not json".utf8)) == nil)
    #expect(AntigravityQuota.parse(Data(#"{"command":{"data":{"groups":[]}}}"#.utf8)) == nil)
    // 알 수 없는 window는 무시.
    let odd = #"{"command":{"data":{"groups":[{"name":"Argon","buckets":[{"window":"daily","remaining_fraction":0.5}]}]}}}"#
    #expect(AntigravityQuota.parse(Data(odd.utf8)) == nil)
}

@Test func antigravityQuotaClampsRemainingFraction() throws {
    let json = #"{"command":{"data":{"groups":[{"name":"Argon","buckets":[{"window":"5h","remaining_fraction":-0.2},{"window":"weekly","remaining_fraction":1.5}]}]}}}"#
    let w = try #require(AntigravityQuota.parse(Data(json.utf8)))
    #expect(w[0].usedPercent == 100)
    #expect(w[1].usedPercent == 0)
}
