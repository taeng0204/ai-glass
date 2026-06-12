import Foundation
import SQLite3

/// Antigravity(agy) CLI 대화 DB(`~/.gemini/antigravity-cli/conversations/<id>.db`) 파서.
///
/// **비공개 포맷 리버스 엔지니어링(2026-06-12 실측)** — 모든 결과는 추정치다.
/// `gen_metadata(idx, data, size)`의 `data`가 protobuf blob이고, 작은 레코드(요약)에서
/// 다음 경로로 토큰·타임스탬프·모델을 뽑는다 (필드 번호는 buf 스키마 없이 실측):
/// - top `f1` → `f4` → `f2` = 입력 토큰, `f3` = 출력 토큰
/// - top `f1` → `f9` → `f4` → `f1` = epoch 초 타임스탬프
/// - top `f1` → `f21` = 모델 표시명 ("Gemini 3.5 Flash (High)")
///
/// `trajectory_metadata_blob(id, data)`의 단일 행에는 워크스페이스가 들어 있다:
/// - top `f1` → `f1` = workspace URI ("file:///Users/…/dev/nypc"), top `f7`도 동일 값
///
/// 모든 파싱은 방어적 — 경로가 깨지면 해당 레코드를 조용히 스킵한다.
/// **DB는 READONLY로만 연다** (agy 실행 중 잠금 가능) + busy_timeout 짧게.
public enum AntigravityConversationParser {
    public struct Generation: Equatable, Sendable {
        public let idx: Int
        public let timestamp: Date
        public let model: String
        public let inputTokens: Int
        public let outputTokens: Int
    }

    private static let SQLITE_OPEN_READONLY_FLAG: Int32 = 0x00000001 // SQLITE_OPEN_READONLY

    /// READONLY로 db를 열어 작은(size < 50000) gen_metadata 레코드만 파싱한다.
    /// `afterIdx`보다 큰 idx만 SQL에서 거른다 (매 주기 전체 재파싱 방지).
    /// 열기 실패·잠금·파싱 실패 시 빈 배열(혹은 가능한 레코드만).
    public static func generations(dbPath: String, afterIdx: Int = -1) -> [Generation] {
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        var db: OpaquePointer?
        // READONLY + (잠금 시) 50ms만 기다리고 포기.
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY_FLAG, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)

        let sql = "SELECT idx, data FROM gen_metadata WHERE size < 50000 AND idx > ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(afterIdx))

        var result: [Generation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idx = Int(sqlite3_column_int64(stmt, 0))
            guard let blobPtr = sqlite3_column_blob(stmt, 1) else { continue }
            let blobLen = Int(sqlite3_column_bytes(stmt, 1))
            guard blobLen > 0 else { continue }
            let data = Data(bytes: blobPtr, count: blobLen)
            if let gen = parseGeneration(idx: idx, data: data) {
                result.append(gen)
            }
        }
        return result
    }

    /// READONLY로 db를 열어 trajectory_metadata_blob에서 워크스페이스 디렉토리 이름을 추출한다.
    /// (예: "file:///Users/me/dev/nypc" → "nypc") 추출 실패 시 nil.
    public static func workspace(dbPath: String) -> String? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY_FLAG, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)

        let sql = "SELECT data FROM trajectory_metadata_blob LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let blobPtr = sqlite3_column_blob(stmt, 0) else { return nil }
        let blobLen = Int(sqlite3_column_bytes(stmt, 0))
        guard blobLen > 0 else { return nil }
        return parseWorkspace(data: Data(bytes: blobPtr, count: blobLen))
    }

    /// trajectory_metadata_blob의 protobuf에서 워크스페이스 디렉토리 이름을 뽑는다.
    /// 경로: top f1 → f1 (워크스페이스 URI), 폴백 top f7.
    static func parseWorkspace(data: Data) -> String? {
        let top = ProtoWire.fields(data)
        var uri: String?
        if case .bytes(let f1Data) = top[1]?.first {
            let f1 = ProtoWire.fields(f1Data)
            if case .bytes(let uriData) = f1[1]?.first {
                uri = String(data: uriData, encoding: .utf8)
            }
        }
        if uri == nil, case .bytes(let f7Data) = top[7]?.first {
            uri = String(data: f7Data, encoding: .utf8)
        }
        guard var path = uri, !path.isEmpty else { return nil }
        if path.hasPrefix("file://") { path = String(path.dropFirst("file://".count)) }
        // URI일 수도 일반 경로일 수도 — 절대 경로만 신뢰한다.
        guard path.hasPrefix("/") else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// 단일 blob에서 Generation을 파싱한다. 토큰/타임스탬프 누락 시 nil.
    static func parseGeneration(idx: Int, data: Data) -> Generation? {
        let top = ProtoWire.fields(data)
        guard case .bytes(let f1Data) = top[1]?.first else { return nil }
        let f1 = ProtoWire.fields(f1Data)

        // 토큰: f1 → f4 → f2(input), f3(output)
        guard case .bytes(let f4Data) = f1[4]?.first else { return nil }
        let f4 = ProtoWire.fields(f4Data)
        guard case .varint(let input) = f4[2]?.first,
              case .varint(let output) = f4[3]?.first else { return nil }

        // 타임스탬프: f1 → f9 → f4 → f1(epoch sec)
        guard case .bytes(let f9Data) = f1[9]?.first else { return nil }
        let f9 = ProtoWire.fields(f9Data)
        guard case .bytes(let tsF4Data) = f9[4]?.first else { return nil }
        let tsF4 = ProtoWire.fields(tsF4Data)
        guard case .varint(let epoch) = tsF4[1]?.first, epoch > 0 else { return nil }

        // 모델: f1 → f21 (str). 없으면 "antigravity".
        var model = "antigravity"
        if case .bytes(let modelData) = f1[21]?.first,
           let s = String(data: modelData, encoding: .utf8), !s.isEmpty {
            model = s
        }

        return Generation(idx: idx,
                          timestamp: Date(timeIntervalSince1970: Double(epoch)),
                          model: model,
                          inputTokens: Int(input),
                          outputTokens: Int(output))
    }
}
