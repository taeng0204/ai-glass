import Foundation

/// 최소 protobuf 와이어 포맷 파서.
///
/// 비공개 포맷(Antigravity 대화 DB의 protobuf blob)을 스키마 없이 읽기 위한 방어적 워커.
/// 정상 경로만 파싱하고, 조금이라도 이상하면(필드 0/과대, 길이 초과, 잘린 varint 등)
/// **빈 결과**를 돌려 호출자가 조용히 스킵하도록 한다.
public enum ProtoWire {
    public enum ProtoValue: Equatable {
        case varint(UInt64)
        case bytes(Data)
    }

    /// 와이어 바이트를 필드번호 → 값들(반복 필드 대비 배열)로 파싱한다.
    /// 비정상 데이터는 빈 dict 반환 (부분 결과를 신뢰하지 않음).
    public static func fields(_ data: Data) -> [Int: [ProtoValue]] {
        var result: [Int: [ProtoValue]] = [:]
        let bytes = [UInt8](data)
        var i = 0
        let n = bytes.count

        while i < n {
            guard let (tag, tagLen) = readVarint(bytes, i) else { return [:] }
            i += tagLen
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x7)
            // 비정상 필드 번호 → 전체 실패.
            guard fieldNumber >= 1, fieldNumber <= 80 else { return [:] }

            switch wireType {
            case 0: // varint
                guard let (v, len) = readVarint(bytes, i) else { return [:] }
                i += len
                result[fieldNumber, default: []].append(.varint(v))
            case 1: // i64 (8 bytes) — varint로 정규화
                guard i + 8 <= n else { return [:] }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(bytes[i + k]) << (8 * k) }
                i += 8
                result[fieldNumber, default: []].append(.varint(v))
            case 2: // length-delimited
                guard let (lenU, lenLen) = readVarint(bytes, i) else { return [:] }
                i += lenLen
                let len = Int(lenU)
                guard len >= 0, i + len <= n else { return [:] }
                result[fieldNumber, default: []].append(.bytes(Data(bytes[i..<(i + len)])))
                i += len
            case 5: // i32 (4 bytes) — varint로 정규화
                guard i + 4 <= n else { return [:] }
                var v: UInt32 = 0
                for k in 0..<4 { v |= UInt32(bytes[i + k]) << (8 * k) }
                i += 4
                result[fieldNumber, default: []].append(.varint(UInt64(v)))
            default: // 3/4(group, deprecated) 등 미지원 → 전체 실패
                return [:]
            }
        }
        return result
    }

    /// `bytes[offset...]`에서 varint를 읽어 (값, 소비 바이트 수)를 반환. 잘리면 nil.
    private static func readVarint(_ bytes: [UInt8], _ offset: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = offset
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            // 64비트 초과 방지
            guard shift < 64 else { return nil }
            result |= UInt64(b & 0x7F) << shift
            i += 1
            if b & 0x80 == 0 { return (result, i - offset) }
            shift += 7
        }
        return nil // 종료 바이트 없이 끝남
    }
}
