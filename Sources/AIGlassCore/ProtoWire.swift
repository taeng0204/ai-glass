import Foundation

/// 최소 protobuf 와이어 포맷 파서.
///
/// 비공개 포맷(Antigravity 대화 DB의 protobuf blob)을 스키마 없이 읽기 위한 방어적 워커.
/// 비정상 지점(필드 0/과대, 길이 초과, 잘린 varint, 미지원 wire type)을 만나면
/// 거기서 멈추고 **그때까지 파싱한 필드를 유지**한다 — 실제 blob은 끝부분에
/// 미지의 trailing 필드가 흔해서, 전체를 버리면 정상 레코드 대부분이 유실된다.
public enum ProtoWire {
    public enum ProtoValue: Equatable {
        case varint(UInt64)
        case bytes(Data)
    }

    /// 와이어 바이트를 필드번호 → 값들(반복 필드 대비 배열)로 파싱한다.
    /// 비정상 지점에서 멈추되 그 전까지의 부분 결과는 반환한다.
    public static func fields(_ data: Data) -> [Int: [ProtoValue]] {
        var result: [Int: [ProtoValue]] = [:]
        let bytes = [UInt8](data)
        var i = 0
        let n = bytes.count

        while i < n {
            guard let (tag, tagLen) = readVarint(bytes, i) else { return result }
            i += tagLen
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x7)
            // 비정상 필드 번호 → 여기서 중단 (이후 바이트는 신뢰 불가).
            guard fieldNumber >= 1, fieldNumber <= 80 else { return result }

            switch wireType {
            case 0: // varint
                guard let (v, len) = readVarint(bytes, i) else { return result }
                i += len
                result[fieldNumber, default: []].append(.varint(v))
            case 1: // i64 (8 bytes) — varint로 정규화
                guard i + 8 <= n else { return result }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(bytes[i + k]) << (8 * k) }
                i += 8
                result[fieldNumber, default: []].append(.varint(v))
            case 2: // length-delimited
                guard let (lenU, lenLen) = readVarint(bytes, i) else { return result }
                i += lenLen
                let len = Int(lenU)
                guard len >= 0, i + len <= n else { return result }
                result[fieldNumber, default: []].append(.bytes(Data(bytes[i..<(i + len)])))
                i += len
            case 5: // i32 (4 bytes) — varint로 정규화
                guard i + 4 <= n else { return result }
                var v: UInt32 = 0
                for k in 0..<4 { v |= UInt32(bytes[i + k]) << (8 * k) }
                i += 4
                result[fieldNumber, default: []].append(.varint(UInt64(v)))
            default: // 3/4(group, deprecated) 등 미지원 → 여기서 중단
                return result
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
