import Testing
@testable import AIGlass

@MainActor @Test func menubarMigrationMapsEachMode() {
    #expect(AppSettings.migratedItems(from: .todayTokens) == [.todayTokens])
    #expect(AppSettings.migratedItems(from: .burnRate) == [.burnRate])
    #expect(AppSettings.migratedItems(from: .maxPercent) == [.usagePercent])  // 최고% → 사용률
    #expect(AppSettings.migratedItems(from: .wavePill) == [.wave])
    #expect(AppSettings.migratedItems(from: .iconOnly) == [])  // 빈 집합 = ✦ fallback
}

@MainActor @Test func menubarItemsOrderedFollowsCanonicalOrder() {
    // 입력 순서 무관, allCases 고정 순(wave→todayTokens→burnRate→usagePercent→resetCountdown)으로 정렬.
    let set: Set<MenubarItem> = [.resetCountdown, .wave, .todayTokens]
    #expect(MenubarItem.ordered(set) == [.wave, .todayTokens, .resetCountdown])
}
