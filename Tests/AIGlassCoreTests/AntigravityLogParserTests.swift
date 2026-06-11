import Foundation
import Testing
@testable import AIGlassCore

@Test func antigravityParsesNormalEntries() {
    let json = """
    {"display":"first prompt","timestamp":1780910341188,"workspace":"/Users/taeng02/Desktop/dev/hack-nas","conversationId":"c1"}
    {"display":"second","timestamp":1780910400000,"workspace":"/Users/taeng02/Desktop/dev/ai-glass","conversationId":"c2"}
    """
    let entries = AntigravityLogParser.entries(jsonData: Data(json.utf8))
    #expect(entries.count == 2)
    #expect(entries[0].project == "hack-nas")
    #expect(entries[1].project == "ai-glass")
}

@Test func antigravityConvertsMillisecondsToDate() {
    let json = #"{"display":"x","timestamp":1780910341188,"workspace":"/a/b"}"#
    let entries = AntigravityLogParser.entries(jsonData: Data(json.utf8))
    #expect(entries.count == 1)
    // 1780910341188 ms == 1780910341.188 s
    #expect(abs(entries[0].date.timeIntervalSince1970 - 1780910341.188) < 0.001)
}

@Test func antigravityHandlesMissingWorkspace() {
    let json = #"{"display":"x","timestamp":1780910341188}"#
    let entries = AntigravityLogParser.entries(jsonData: Data(json.utf8))
    #expect(entries.count == 1)
    #expect(entries[0].project == nil)
}

@Test func antigravityWorkspaceMatchingHomeReturnsTilde() {
    let prev = AntigravityLogParser.homeDirectoryOverride
    defer { AntigravityLogParser.homeDirectoryOverride = prev }
    AntigravityLogParser.homeDirectoryOverride = "/Users/me"
    let json = #"{"display":"x","timestamp":1780910341188,"workspace":"/Users/me"}"#
    let entries = AntigravityLogParser.entries(jsonData: Data(json.utf8))
    #expect(entries.count == 1)
    #expect(entries[0].project == "~")
}

@Test func antigravityIgnoresGarbageLines() {
    let json = """
    {"display":"ok","timestamp":1780910341188,"workspace":"/a/proj"}
    this is not json
    {"display":"no timestamp","workspace":"/a/x"}
    {invalid
    """
    let entries = AntigravityLogParser.entries(jsonData: Data(json.utf8))
    #expect(entries.count == 1)
    #expect(entries[0].project == "proj")
}
