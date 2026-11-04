import Foundation
import SQLite3
import Testing
@testable import AIGlassCore

// MARK: - 실제 와이어 경로 재현 빌더 (테스트 전용)

private func varint(_ value: UInt64) -> [UInt8] {
    var v = value
    var bytes: [UInt8] = []
    repeat {
        var b = UInt8(v & 0x7F)
        v >>= 7
        if v != 0 { b |= 0x80 }
        bytes.append(b)
    } while v != 0
    return bytes
}

private func tag(_ field: Int, _ wireType: Int) -> [UInt8] {
    varint(UInt64((field << 3) | wireType))
}

private func varintField(_ field: Int, _ value: UInt64) -> [UInt8] {
    tag(field, 0) + varint(value)
}

private func lenField(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
    tag(field, 2) + varint(UInt64(payload.count)) + payload
}

/// 실측 경로를 그대로 합성:
/// top f1 { f4 { f2:input, f3:output }, f9 { f4 { f1:epoch } }, f21:model }
private func buildGenMetadata(input: Int, output: Int, epoch: Int, model: String) -> Data {
    let f4Tokens = varintField(2, UInt64(input)) + varintField(3, UInt64(output))
    let f9Inner = lenField(4, varintField(1, UInt64(epoch)))
    let f1 = lenField(4, f4Tokens) + lenField(9, f9Inner) + lenField(21, Array(model.utf8))
    return Data(lenField(1, f1))
}

// MARK: - 임시 sqlite 헬퍼

private let SQLITE_TRANSIENT_T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// gen_metadata(idx, data, size) 테이블을 만들고 레코드를 넣은 임시 db 경로 반환.
@discardableResult
private func makeTempDB(records: [(idx: Int, data: Data, size: Int)]) throws -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("agy-conv-\(UUID().uuidString).db").path
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    let create = "CREATE TABLE gen_metadata(idx INTEGER, data BLOB, size INTEGER)"
    #expect(sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK)
    let sql = "INSERT INTO gen_metadata(idx, data, size) VALUES (?, ?, ?)"
    var stmt: OpaquePointer?
    #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
    defer { sqlite3_finalize(stmt) }
    for r in records {
        sqlite3_bind_int64(stmt, 1, Int64(r.idx))
        _ = r.data.withUnsafeBytes { buf in
            sqlite3_bind_blob(stmt, 2, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT_T)
        }
        sqlite3_bind_int64(stmt, 3, Int64(r.size))
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
        sqlite3_reset(stmt)
    }
    return path
}

// MARK: - 테스트

@Test func conversationParserExtractsGenerationFields() throws {
    let epoch = 1_780_000_000
    let blob = buildGenMetadata(input: 3800, output: 231, epoch: epoch, model: "Gemini 3.5 Flash (High)")
    let path = try makeTempDB(records: [(idx: 0, data: blob, size: blob.count)])
    defer { try? FileManager.default.removeItem(atPath: path) }

    let gens = AntigravityConversationParser.generations(dbPath: path)
    #expect(gens.count == 1)
    let g = try #require(gens.first)
    #expect(g.idx == 0)
    #expect(g.inputTokens == 3800)
    #expect(g.outputTokens == 231)
    #expect(g.model == "Gemini 3.5 Flash (High)")
    #expect(abs(g.timestamp.timeIntervalSince1970 - Double(epoch)) < 0.001)
}

@Test func conversationParserDefaultsModelWhenMissing() throws {
    // f21 없는 레코드: f1 { f4 { f2, f3 }, f9 { f4 { f1 } } }
    let f4Tokens = varintField(2, 100) + varintField(3, 20)
    let f9Inner = lenField(4, varintField(1, 1_780_000_000))
    let f1 = lenField(4, f4Tokens) + lenField(9, f9Inner)
    let blob = Data(lenField(1, f1))
    let path = try makeTempDB(records: [(idx: 1, data: blob, size: blob.count)])
    defer { try? FileManager.default.removeItem(atPath: path) }

    let gens = AntigravityConversationParser.generations(dbPath: path)
    #expect(gens.count == 1)
    #expect(gens.first?.model == "antigravity")
}

@Test func conversationParserSkipsRecordsMissingTimestampOrTokens() throws {
    // 토큰만 있고 타임스탬프(f9) 없음 → 스킵.
    let noTs = Data(lenField(1, lenField(4, varintField(2, 100) + varintField(3, 20))))
    // 타임스탬프만 있고 토큰(f4) 없음 → 스킵.
    let noTok = Data(lenField(1, lenField(9, lenField(4, varintField(1, 1_780_000_000)))))
    let good = buildGenMetadata(input: 50, output: 5, epoch: 1_780_000_001, model: "X")
    let path = try makeTempDB(records: [
        (idx: 0, data: noTs, size: noTs.count),
        (idx: 1, data: noTok, size: noTok.count),
        (idx: 2, data: good, size: good.count),
    ])
    defer { try? FileManager.default.removeItem(atPath: path) }

    let gens = AntigravityConversationParser.generations(dbPath: path)
    #expect(gens.count == 1)
    #expect(gens.first?.idx == 2)
}

@Test func conversationParserExcludesLargeRecords() throws {
    let big = buildGenMetadata(input: 9999, output: 999, epoch: 1_780_000_002, model: "Big")
    let small = buildGenMetadata(input: 100, output: 10, epoch: 1_780_000_003, model: "Small")
    let path = try makeTempDB(records: [
        (idx: 0, data: big, size: 50000), // size >= 50000 → SQL WHERE에서 제외
        (idx: 1, data: small, size: small.count),
    ])
    defer { try? FileManager.default.removeItem(atPath: path) }

    let gens = AntigravityConversationParser.generations(dbPath: path)
    #expect(gens.count == 1)
    #expect(gens.first?.inputTokens == 100)
}

@Test func conversationParserToleratesGarbageBlob() throws {
    let garbage = Data([0xFF, 0xFF, 0xFF, 0x00, 0x80, 0x42])
    let good = buildGenMetadata(input: 77, output: 7, epoch: 1_780_000_004, model: "Y")
    let path = try makeTempDB(records: [
        (idx: 0, data: garbage, size: garbage.count),
        (idx: 1, data: good, size: good.count),
    ])
    defer { try? FileManager.default.removeItem(atPath: path) }

    let gens = AntigravityConversationParser.generations(dbPath: path)
    #expect(gens.count == 1)
    #expect(gens.first?.inputTokens == 77)
}

@Test func conversationParserReturnsEmptyForMissingDB() {
    let gens = AntigravityConversationParser.generations(dbPath: "/nonexistent/path/x.db")
    #expect(gens.isEmpty)
}

@Test func conversationParserToleratesTrailingUnknownFields() throws {
    // 실데이터 회귀: 정상 경로 뒤에 미지의 trailing 필드(field 81 등)가 붙은 blob —
    // 부분-유지 파싱으로 여전히 레코드를 추출해야 한다.
    var blob = buildGenMetadata(input: 1234, output: 56, epoch: 1_780_000_005, model: "Z")
    blob.append(contentsOf: varintField(81, 7)) // top 레벨 trailing 미지 필드
    let path = try makeTempDB(records: [(idx: 0, data: blob, size: blob.count)])
    defer { try? FileManager.default.removeItem(atPath: path) }

    let gens = AntigravityConversationParser.generations(dbPath: path)
    #expect(gens.count == 1)
    #expect(gens.first?.inputTokens == 1234)
    #expect(gens.first?.outputTokens == 56)
}

// MARK: - workspace 추출

/// 실측 경로 재현: top f1 { f1: uri, f4: branch }, f7: uri
private func buildTrajectoryMetadata(uri: String, includeF1: Bool = true, includeF7: Bool = true) -> Data {
    var top: [UInt8] = []
    if includeF1 {
        let f1 = lenField(1, Array(uri.utf8)) + lenField(4, Array("master".utf8))
        top += lenField(1, f1)
    }
    if includeF7 {
        top += lenField(7, Array(uri.utf8))
    }
    return Data(top)
}

/// trajectory_metadata_blob(id, data) 테이블이 있는 임시 db 생성.
private func makeTempDBWithTrajectoryBlob(data: Data?) throws -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("agy-traj-\(UUID().uuidString).db").path
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    let create = "CREATE TABLE trajectory_metadata_blob(id INTEGER, data BLOB)"
    #expect(sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK)
    if let data {
        let sql = "INSERT INTO trajectory_metadata_blob(id, data) VALUES (1, ?)"
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        _ = data.withUnsafeBytes { buf in
            sqlite3_bind_blob(stmt, 1, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT_T)
        }
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
    }
    return path
}

@Test func workspaceExtractsDirectoryNameFromFileURI() throws {
    let blob = buildTrajectoryMetadata(uri: "file:///Users/me/Desktop/dev/nypc")
    let path = try makeTempDBWithTrajectoryBlob(data: blob)
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(AntigravityConversationParser.workspace(dbPath: path) == "nypc")
}

@Test func workspaceFallsBackToF7WhenF1Missing() {
    let blob = buildTrajectoryMetadata(uri: "file:///Users/me/dev/hack-nas", includeF1: false)
    #expect(AntigravityConversationParser.parseWorkspace(data: blob) == "hack-nas")
}

@Test func workspaceAcceptsPlainAbsolutePath() {
    let blob = buildTrajectoryMetadata(uri: "/Users/me/dev/tmp", includeF7: false)
    #expect(AntigravityConversationParser.parseWorkspace(data: blob) == "tmp")
}

@Test func workspaceRejectsNonAbsolutePath() {
    let blob = buildTrajectoryMetadata(uri: "not-a-path")
    #expect(AntigravityConversationParser.parseWorkspace(data: blob) == nil)
}

@Test func workspaceReturnsNilForEmptyTableOrMissingDB() throws {
    #expect(AntigravityConversationParser.workspace(dbPath: "/nonexistent/x.db") == nil)
    let path = try makeTempDBWithTrajectoryBlob(data: nil)
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(AntigravityConversationParser.workspace(dbPath: path) == nil)
}

// MARK: - 새 포맷 (2026-11 agy 업데이트: gen_metadata에 시각이 없고 steps에 있음)

/// 새 포맷 레코드: 타임스탬프(f9) 없이 최상위 f4=생성 ID.
/// top { f4:genID, f1 { f4 { f2:input, f3:output }, f21:model } }
private func buildNewGenMetadata(genID: String, input: Int, output: Int, model: String) -> Data {
    let f4Tokens = varintField(2, UInt64(input)) + varintField(3, UInt64(output))
    let f1 = lenField(4, f4Tokens) + lenField(21, Array(model.utf8))
    return Data(lenField(4, Array(genID.utf8)) + lenField(1, f1))
}

/// steps.metadata: f12=생성 ID, f1/f7/f8 = { f1: epoch } (생성·시작·완료). nil이면 그 필드를 넣지 않는다.
private func buildStepMetadata(genID: String, created: Int?, started: Int?, finished: Int?) -> Data {
    var bytes: [UInt8] = []
    if let created { bytes += lenField(1, varintField(1, UInt64(created))) }
    if let started { bytes += lenField(7, varintField(1, UInt64(started))) }
    if let finished { bytes += lenField(8, varintField(1, UInt64(finished))) }
    bytes += lenField(12, Array(genID.utf8))
    return Data(bytes)
}

private func addStepsTable(path: String, rows: [Data]) throws {
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    #expect(sqlite3_exec(db, "CREATE TABLE steps(idx INTEGER, metadata BLOB)", nil, nil, nil) == SQLITE_OK)
    var stmt: OpaquePointer?
    #expect(sqlite3_prepare_v2(db, "INSERT INTO steps(idx, metadata) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK)
    defer { sqlite3_finalize(stmt) }
    for (i, r) in rows.enumerated() {
        sqlite3_bind_int64(stmt, 1, Int64(i))
        _ = r.withUnsafeBytes { buf in
            sqlite3_bind_blob(stmt, 2, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT_T)
        }
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
        sqlite3_reset(stmt)
    }
}

/// 회귀: 인라인 타임스탬프가 없는 새 포맷도 steps의 시각으로 읽혀야 한다 (이전엔 전부 버려져 Antigravity가 통계에 안 잡혔다).
@Test func conversationParserReadsTimestampFromStepsInNewFormat() throws {
    let blob = buildNewGenMetadata(genID: "gen-1", input: 5653, output: 203, model: "Claude Opus 5.5 (Medium)")
    let path = try makeTempDB(records: [(idx: 0, data: blob, size: blob.count)])
    defer { try? FileManager.default.removeItem(atPath: path) }
    try addStepsTable(path: path, rows: [
        buildStepMetadata(genID: "gen-1", created: 1_793_774_750, started: 1_793_774_754, finished: 1_793_774_755),
    ])

    let gens = AntigravityConversationParser.generations(dbPath: path)
    let g = try #require(gens.first)
    #expect(gens.count == 1)
    #expect(g.inputTokens == 5653)
    #expect(g.outputTokens == 203)
    #expect(g.model == "Claude Opus 5.5 (Medium)")
    // 완료 시각(f8)을 우선 사용
    #expect(g.timestamp.timeIntervalSince1970 == 1_793_774_755)
}

@Test func conversationParserStepTimePrefersFinishedThenStartedThenCreated() throws {
    let a = buildNewGenMetadata(genID: "only-created", input: 1, output: 1, model: "M")
    let b = buildNewGenMetadata(genID: "started-no-finish", input: 2, output: 2, model: "M")
    let path = try makeTempDB(records: [
        (idx: 0, data: a, size: a.count),
        (idx: 1, data: b, size: b.count),
    ])
    defer { try? FileManager.default.removeItem(atPath: path) }
    try addStepsTable(path: path, rows: [
        buildStepMetadata(genID: "only-created", created: 1_700_000_100, started: nil, finished: nil),
        buildStepMetadata(genID: "started-no-finish", created: 1_700_000_200, started: 1_700_000_300, finished: nil),
    ])

    let gens = AntigravityConversationParser.generations(dbPath: path)
    #expect(gens.count == 2)
    #expect(gens.first { $0.idx == 0 }?.timestamp.timeIntervalSince1970 == 1_700_000_100)
    #expect(gens.first { $0.idx == 1 }?.timestamp.timeIntervalSince1970 == 1_700_000_300)
}

@Test func conversationParserSkipsNewFormatRecordsWithoutAnyTimestamp() throws {
    // steps 테이블이 없거나 생성 ID가 안 맞으면 시각을 알 수 없으니 조용히 스킵한다 (크래시 금지).
    let blob = buildNewGenMetadata(genID: "gen-x", input: 10, output: 5, model: "M")
    let noSteps = try makeTempDB(records: [(idx: 0, data: blob, size: blob.count)])
    defer { try? FileManager.default.removeItem(atPath: noSteps) }
    #expect(AntigravityConversationParser.generations(dbPath: noSteps).isEmpty)

    let mismatch = try makeTempDB(records: [(idx: 0, data: blob, size: blob.count)])
    defer { try? FileManager.default.removeItem(atPath: mismatch) }
    try addStepsTable(path: mismatch, rows: [buildStepMetadata(genID: "other", created: 1_700_000_000, started: nil, finished: nil)])
    #expect(AntigravityConversationParser.generations(dbPath: mismatch).isEmpty)
}

@Test func conversationParserPrefersInlineTimestampOverSteps() throws {
    // 옛 포맷(인라인 시각)은 steps가 있어도 인라인을 쓴다.
    let blob = buildGenMetadata(input: 100, output: 10, epoch: 1_780_000_000, model: "Gemini 3.5 Flash (High)")
    let path = try makeTempDB(records: [(idx: 0, data: blob, size: blob.count)])
    defer { try? FileManager.default.removeItem(atPath: path) }
    try addStepsTable(path: path, rows: [buildStepMetadata(genID: "x", created: 1_111_111_111, started: nil, finished: nil)])
    let g = try #require(AntigravityConversationParser.generations(dbPath: path).first)
    #expect(g.timestamp.timeIntervalSince1970 == 1_780_000_000)
}
