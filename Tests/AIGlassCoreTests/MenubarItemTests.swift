import Testing
@testable import AIGlass

@MainActor @Test func menubarMigrationMapsEachMode() {
    #expect(AppSettings.migratedItems(from: .todayTokens) == [.todayTokens])
    #expect(AppSettings.migratedItems(from: .burnRate) == [.burnRate])
    #expect(AppSettings.migratedItems(from: .maxPercent) == [.maxPercent])
    #expect(AppSettings.migratedItems(from: .wavePill) == [.wave])
    #expect(AppSettings.migratedItems(from: .iconOnly) == [])  // 빈 집합 = ✦ fallback
}

@MainActor @Test func menubarItemsOrderedFollowsCanonicalOrder() {
    // 입력 순서 무관, allCases 고정 순(wave→todayTokens→burnRate→maxPercent)으로 정렬.
    let set: Set<MenubarItem> = [.maxPercent, .wave, .todayTokens]
    #expect(MenubarItem.ordered(set) == [.wave, .todayTokens, .maxPercent])
}
