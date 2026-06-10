import Testing
import AIGlassCore
@testable import AIGlass

// allocateBars: share 비율로 7개 바에 서비스 색을 배분 (floor + 잔여는 share 큰 순서).

@Test func allocateBarsEmptyShareAllNil() {
    let result = allocateBars(share: [:], barCount: 7)
    #expect(result == Array<ServiceID?>(repeating: nil, count: 7))
}

@Test func allocateBarsSingleServiceFillsAll() {
    let result = allocateBars(share: [.codex: 1.0], barCount: 7)
    #expect(result == Array<ServiceID?>(repeating: .codex, count: 7))
}

@Test func allocateBarsSplit75_25Yields5And2() {
    // claude 0.75 → 5.25 floor 5 (rem 0.25); codex 0.25 → 1.75 floor 1 (rem 0.75)
    // assigned 6, leftover 1 → codex(rem 0.75) +1 → claude 5, codex 2
    // 좌→우 share 큰 순서: claude 먼저.
    let result = allocateBars(share: [.claude: 0.75, .codex: 0.25], barCount: 7)
    let expected: [ServiceID?] = [.claude, .claude, .claude, .claude, .claude, .codex, .codex]
    #expect(result == expected)
}
