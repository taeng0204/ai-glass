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
/// **포맷 변경 대응(2026-11 실측)** — agy 업데이트로 `gen_metadata`에서 타임스탬프 경로(`f1→f9→f4→f1`)가 사라졌다.
/// 토큰·모델 경로는 그대로이고, 시각은 `steps(idx, metadata)`에 있다:
/// - gen_metadata top `f4` = 생성 ID(문자열) ↔ steps.metadata `f12` = 같은 생성 ID
/// - steps.metadata `f8.f1`(응답 완료) → `f7.f1` → `f1.f1`(생성) = epoch 초
/// 옛 포맷은 기존 경로를 먼저 시도하므로 그대로 읽힌다.
/// (모델은 이제 Gemini뿐 아니라 "Claude Opus 5.5 (Medium)" 같은 Claude 모델도 `f21`에 들어온다.)
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
        // 새 포맷은 시각이 steps에 있다 — 필요할 때 1회만 읽는다.
        var stepTimes: [String: UInt64]?
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idx = Int(sqlite3_column_int64(stmt, 0))
            guard let blobPtr = sqlite3_column_blob(stmt, 1) else { continue }
            let blobLen = Int(sqlite3_column_bytes(stmt, 1))
            guard blobLen > 0 else { continue }
            let data = Data(bytes: blobPtr, count: blobLen)
            guard let raw = parseRaw(data: data) else { continue }
            var epoch = raw.epoch
            if epoch == nil, let genID = raw.generationID {
                if stepTimes == nil { stepTimes = loadStepTimes(db: db) }
                epoch = stepTimes?[genID]
            }
            guard let epoch, epoch > 0 else { continue }
            result.append(Generation(idx: idx,
                                     timestamp: Date(timeIntervalSince1970: Double(epoch)),
                                     model: raw.model,
                                     inputTokens: raw.input,
                                     outputTokens: raw.output))
        }
        return result
    }

    /// steps.metadata에서 생성 ID(f12) → epoch 초 맵을 만든다. 테이블이 없거나 깨지면 빈 맵.
    private static func loadStepTimes(db: OpaquePointer?) -> [String: UInt64] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT metadata FROM steps WHERE metadata IS NOT NULL", -1, &stmt, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }
        var map: [String: UInt64] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ptr = sqlite3_column_blob(stmt, 0) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 0))
            guard len > 0 else { continue }
            let top = ProtoWire.fields(Data(bytes: ptr, count: len))
            guard case .bytes(let idData) = top[12]?.first,
                  let genID = String(data: idData, encoding: .utf8), !genID.isEmpty else { continue }
            // 응답 완료(f8) → 시작(f7) → 생성(f1) 순으로 첫 유효 epoch를 쓴다.
            for field in [8, 7, 1] {
                if case .bytes(let tsData) = top[field]?.first,
                   case .varint(let epoch) = ProtoWire.fields(tsData)[1]?.first, epoch > 0 {
                    map[genID] = epoch
                    break
                }
            }
        }
        return map
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

    /// gen_metadata 한 레코드에서 뽑은 원시 값. 시각은 옛 포맷에만 들어 있다(`epoch`).
    struct RawGeneration {
        let input: Int
        let output: Int
        let model: String
        /// 옛 포맷의 인라인 타임스탬프(f1→f9→f4→f1). 없으면 nil — steps에서 찾는다.
        let epoch: UInt64?
        /// 최상위 f4 — steps.metadata f12와 같은 생성 ID.
        let generationID: String?
    }

    /// 토큰·모델·(있으면) 시각·생성 ID를 뽑는다. 토큰이 없으면 nil.
    static func parseRaw(data: Data) -> RawGeneration? {
        let top = ProtoWire.fields(data)
        guard case .bytes(let f1Data) = top[1]?.first else { return nil }
        let f1 = ProtoWire.fields(f1Data)

        // 토큰: f1 → f4 → f2(input), f3(output)
        guard case .bytes(let f4Data) = f1[4]?.first else { return nil }
        let f4 = ProtoWire.fields(f4Data)
        guard case .varint(let input) = f4[2]?.first,
              case .varint(let output) = f4[3]?.first else { return nil }

        // 옛 포맷 타임스탬프: f1 → f9 → f4 → f1(epoch sec). 없어도 실패가 아니다.
        var epoch: UInt64?
        if case .bytes(let f9Data) = f1[9]?.first,
           case .bytes(let tsF4Data) = ProtoWire.fields(f9Data)[4]?.first,
           case .varint(let e) = ProtoWire.fields(tsF4Data)[1]?.first, e > 0 {
            epoch = e
        }

        // 모델: f1 → f21 (str). 없으면 "antigravity".
        var model = "antigravity"
        if case .bytes(let modelData) = f1[21]?.first,
           let s = String(data: modelData, encoding: .utf8), !s.isEmpty {
            model = s
        }

        // 새 포맷의 시각 조인 키: 최상위 f4 (문자열)
        var generationID: String?
        if case .bytes(let idData) = top[4]?.first,
           let s = String(data: idData, encoding: .utf8), !s.isEmpty {
            generationID = s
        }

        return RawGeneration(input: Int(input), output: Int(output), model: model,
                             epoch: epoch, generationID: generationID)
    }

    /// 단일 blob에서 Generation을 파싱한다 (옛 포맷: 인라인 타임스탬프 필수). 토큰/타임스탬프 누락 시 nil.
    static func parseGeneration(idx: Int, data: Data) -> Generation? {
        guard let raw = parseRaw(data: data), let epoch = raw.epoch else { return nil }
        return Generation(idx: idx,
                          timestamp: Date(timeIntervalSince1970: Double(epoch)),
                          model: raw.model,
                          inputTokens: raw.input,
                          outputTokens: raw.output)
    }
}
