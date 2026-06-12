import Foundation
import Testing
@testable import AIGlassCore

@Test func updateParseLatestReleaseExtractsVersionAndURL() throws {
    let json = #"{"tag_name":"v0.11.0","html_url":"https://github.com/taeng0204/ai-glass/releases/tag/v0.11.0","name":"v0.11.0"}"#
    let release = try #require(UpdateChecker.parseLatestRelease(jsonData: Data(json.utf8)))
    #expect(release.version == "0.11.0")
    #expect(release.url.absoluteString.hasSuffix("/tag/v0.11.0"))
}

@Test func updateParseToleratesTagWithoutVPrefix() throws {
    let json = #"{"tag_name":"1.2.3","html_url":"https://example.com/r"}"#
    let release = try #require(UpdateChecker.parseLatestRelease(jsonData: Data(json.utf8)))
    #expect(release.version == "1.2.3")
}

@Test func updateParseRejectsMalformedJSON() {
    #expect(UpdateChecker.parseLatestRelease(jsonData: Data("not json".utf8)) == nil)
    #expect(UpdateChecker.parseLatestRelease(jsonData: Data("{}".utf8)) == nil)
    let noURL = #"{"tag_name":"v1.0.0"}"#
    #expect(UpdateChecker.parseLatestRelease(jsonData: Data(noURL.utf8)) == nil)
}

@Test func updateIsNewerComparesSemverNumerically() {
    #expect(UpdateChecker.isNewer("0.11.0", than: "0.10.0"))
    #expect(UpdateChecker.isNewer("1.0.0", than: "0.99.99"))
    #expect(UpdateChecker.isNewer("0.10.1", than: "0.10.0"))
    // 같거나 낮으면 false
    #expect(!UpdateChecker.isNewer("0.10.0", than: "0.10.0"))
    #expect(!UpdateChecker.isNewer("0.9.0", than: "0.10.0"))
    // 자리수 부족은 0 채움
    #expect(!UpdateChecker.isNewer("0.10", than: "0.10.0"))
    #expect(UpdateChecker.isNewer("0.10.1", than: "0.10"))
}
