import XCTest
@testable import OpenUsage

@MainActor
final class MultiAccountLayoutTests: XCTestCase {
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "MultiAccountLayoutTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeRegistry() -> WidgetRegistry {
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let work = Provider(id: "claude@work", displayName: "Claude · Work", icon: .providerMark("claude"))
        func metric(_ id: String, _ provider: Provider) -> WidgetDescriptor {
            WidgetDescriptor(
                id: id, providerID: provider.id, metricLabel: "Metric",
                sample: WidgetData(title: "Metric", icon: provider.icon, kind: .percent, used: 0, limit: 100)
            )
        }
        return WidgetRegistry(
            providers: [claude, work],
            descriptors: [
                metric("claude.session", claude), metric("claude.weekly", claude),
                metric("claude@work.session", work), metric("claude@work.weekly", work)
            ]
        )
    }

    private func seedBaseLayout(_ defaults: UserDefaults) {
        let placed = [PlacedWidget(descriptorID: "claude.session"), PlacedWidget(descriptorID: "claude.weekly")]
        defaults.set(try! JSONEncoder().encode(placed), forKey: "layout")
    }

    func testNewAccountSeedsMirroringBase() {
        let defaults = makeDefaults("Seed")
        seedBaseLayout(defaults)
        let store = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        XCTAssertTrue(store.placed.contains { $0.descriptorID == "claude@work.session" })
        XCTAssertTrue(store.placed.contains { $0.descriptorID == "claude@work.weekly" })
    }

    func testDisablingAllAccountMetricsIsNotResurrectedOnReload() {
        let defaults = makeDefaults("NoResurrect")
        seedBaseLayout(defaults)
        let store = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        for widget in store.placed where widget.descriptorID.hasPrefix("claude@work.") {
            store.remove(widget.id)
        }
        XCTAssertFalse(store.placed.contains { $0.descriptorID.hasPrefix("claude@work.") })

        let reloaded = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        XCTAssertFalse(reloaded.placed.contains { $0.descriptorID.hasPrefix("claude@work.") })
    }

    func testDuplicateEmailAccountHiddenFromDashboardAndCustomize() {
        let defaults = makeDefaults("Dedup")
        seedBaseLayout(defaults)
        let store = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        store.accountEmailLookup = { ($0 == "claude" || $0 == "claude@work") ? "same@example.com" : nil }

        XCTAssertFalse(store.visiblePlaced.contains { $0.descriptorID.hasPrefix("claude@work.") })
        XCTAssertFalse(store.customizeGroups.contains { $0.provider.id == "claude@work" })
        XCTAssertFalse(store.customizeProviderRows.contains { $0.provider.id == "claude@work" })
        XCTAssertTrue(store.visiblePlaced.contains { $0.descriptorID == "claude.session" })
    }

    func testDistinctEmailAccountsBothVisible() {
        let defaults = makeDefaults("Distinct")
        seedBaseLayout(defaults)
        let store = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        store.accountEmailLookup = { $0 == "claude" ? "a@example.com" : ($0 == "claude@work" ? "b@example.com" : nil) }

        XCTAssertTrue(store.visiblePlaced.contains { $0.descriptorID.hasPrefix("claude@work.") })
        XCTAssertTrue(store.customizeGroups.contains { $0.provider.id == "claude@work" })
    }
}
