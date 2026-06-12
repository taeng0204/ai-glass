import Foundation
import Testing
@testable import AIGlassCore

// MARK: - 수제 protobuf 와이어 바이트 빌더 (테스트 전용)

/// varint 인코딩.
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

/// 태그 = (field << 3) | wireType.
private func tag(_ field: Int, _ wireType: Int) -> [UInt8] {
    varint(UInt64((field << 3) | wireType))
}

private func varintField(_ field: Int, _ value: UInt64) -> [UInt8] {
    tag(field, 0) + varint(value)
}

private func lenField(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
    tag(field, 2) + varint(UInt64(payload.count)) + payload
}

private func i64Field(_ field: Int, _ value: UInt64) -> [UInt8] {
    var v = value
    var bytes = tag(field, 1)
    for _ in 0..<8 { bytes.append(UInt8(v & 0xFF)); v >>= 8 }
    return bytes
}

private func i32Field(_ field: Int, _ value: UInt32) -> [UInt8] {
    var v = value
    var bytes = tag(field, 5)
    for _ in 0..<4 { bytes.append(UInt8(v & 0xFF)); v >>= 8 }
    return bytes
}

// MARK: - 테스트

@Test func protoWireParsesVarintField() {
    let bytes = varintField(2, 1234)
    let fields = ProtoWire.fields(Data(bytes))
    #expect(fields[2]?.count == 1)
    if case .varint(let v) = fields[2]?.first {
        #expect(v == 1234)
    } else {
        Issue.record("expected varint")
    }
}

@Test func protoWireParsesLenDelimitedField() {
    let payload: [UInt8] = Array("Gemini".utf8)
    let bytes = lenField(21, payload)
    let fields = ProtoWire.fields(Data(bytes))
    if case .bytes(let d) = fields[21]?.first {
        #expect(String(data: d, encoding: .utf8) == "Gemini")
    } else {
        Issue.record("expected bytes")
    }
}

@Test func protoWireParsesI64AndI32() {
    let bytes = i64Field(1, 0xDEAD_BEEF) + i32Field(3, 0xCAFE)
    let fields = ProtoWire.fields(Data(bytes))
    if case .varint(let v) = fields[1]?.first { #expect(v == 0xDEAD_BEEF) }
    else { Issue.record("expected i64 as varint") }
    if case .varint(let v) = fields[3]?.first { #expect(v == 0xCAFE) }
    else { Issue.record("expected i32 as varint") }
}

@Test func protoWireGroupsRepeatedFields() {
    let bytes = varintField(2, 10) + varintField(2, 20) + varintField(2, 30)
    let fields = ProtoWire.fields(Data(bytes))
    #expect(fields[2]?.count == 3)
    let values = fields[2]?.compactMap { v -> UInt64? in
        if case .varint(let n) = v { return n } else { return nil }
    }
    #expect(values == [10, 20, 30])
}

@Test func protoWireRejectsFieldZero() {
    // tag 0 (field 0, wire 0) → 비정상, 빈 결과.
    let bytes: [UInt8] = [0x00, 0x05]
    let fields = ProtoWire.fields(Data(bytes))
    #expect(fields.isEmpty)
}

@Test func protoWireRejectsHugeFieldNumber() {
    // field 81 (> 80) → 비정상, 빈 결과.
    let bytes = varintField(81, 1)
    let fields = ProtoWire.fields(Data(bytes))
    #expect(fields.isEmpty)
}

@Test func protoWireRejectsTruncatedLength() {
    // len-delimited 길이가 남은 바이트를 초과 → 빈 결과.
    var bytes = tag(5, 2) + varint(100) // 길이 100인데 페이로드 없음
    bytes += [0x01, 0x02]
    let fields = ProtoWire.fields(Data(bytes))
    #expect(fields.isEmpty)
}

@Test func protoWireEmptyDataReturnsEmpty() {
    #expect(ProtoWire.fields(Data()).isEmpty)
}

@Test func protoWireNestedRoundTrip() {
    // top f1 { f4 { f2: varint, f3: varint } } 같은 중첩 경로.
    let inner = varintField(2, 3800) + varintField(3, 231)
    let f4 = lenField(4, inner)
    let f1 = lenField(1, f4)
    let top = ProtoWire.fields(Data(f1))
    guard case .bytes(let f1Data) = top[1]?.first else {
        Issue.record("missing f1"); return
    }
    let f1Fields = ProtoWire.fields(f1Data)
    guard case .bytes(let f4Data) = f1Fields[4]?.first else {
        Issue.record("missing f4"); return
    }
    let f4Fields = ProtoWire.fields(f4Data)
    if case .varint(let input) = f4Fields[2]?.first { #expect(input == 3800) }
    else { Issue.record("missing f2") }
    if case .varint(let output) = f4Fields[3]?.first { #expect(output == 231) }
    else { Issue.record("missing f3") }
}
