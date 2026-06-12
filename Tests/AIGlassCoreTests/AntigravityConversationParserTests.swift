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
