import XCTest
@testable import OpenUsage

final class CursorAuthStoreTests: XCTestCase {
    func testPrefersKeychainWhenSQLiteLooksFreeAndSubjectsDiffer() {
        let sqliteToken = makeUnsignedCursorJWT(sub: "google-oauth2|sqlite-user")
        let keychainToken = makeUnsignedCursorJWT(sub: "auth0|keychain-user")
        let sqlite = KeyValueSQLite(values: [
            CursorAuthStore.accessTokenKey: sqliteToken,
            CursorAuthStore.refreshTokenKey: "sqlite-refresh",
            CursorAuthStore.membershipTypeKey: "free"
        ])
        let keychain = ServiceKeychain(values: [
            CursorAuthStore.keychainAccessTokenService: keychainToken,
            CursorAuthStore.keychainRefreshTokenService: "keychain-refresh"
        ])
        let store = CursorAuthStore(sqlite: sqlite, keychain: keychain)

        guard case .available(.owned(let state)) = store.loadAuthState(allowInteraction: false) else {
            return XCTFail("Expected an owned Cursor credential")
        }

        XCTAssertEqual(state.source, .keychain)
        XCTAssertEqual(state.accessToken, keychainToken)
        XCTAssertEqual(state.refreshToken, "keychain-refresh")
    }

    func testLegacyCredentialsTakePrecedenceOverGrokBot() throws {
        let legacyToken = makeUnsignedCursorJWT(sub: "google-oauth2|legacy-user")
        let fixture = try makeGrokBotCursorFixture(accessToken: "borrowed-token")
        let store = CursorAuthStore(
            sqlite: KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: legacyToken]),
            keychain: FakeKeychain(),
            grokBot: fixture.store
        )

        guard case .available(.owned(let state)) = store.loadAuthState(allowInteraction: false) else {
            return XCTFail("Expected the legacy Cursor credential")
        }

        XCTAssertEqual(state.accessToken, legacyToken)
        XCTAssertEqual(state.source, .sqlite)
        XCTAssertTrue(fixture.keyReader.calls.isEmpty)
    }

    func testPersistsSQLiteAccessToken() throws {
        let sqlite = KeyValueSQLite()
        let store = CursorAuthStore(sqlite: sqlite, keychain: FakeKeychain())

        try store.saveAccessToken("fresh-token", source: .sqlite)

        XCTAssertEqual(sqlite.writtenValues[CursorAuthStore.accessTokenKey], "fresh-token")
    }
}

final class CursorUsageMapperTests: XCTestCase {
    func testMapsGrokBotWeeklyUsageAndItsOwnResetWindow() throws {
        let line = try XCTUnwrap(CursorUsageMapper.mapGrokBotUsage([
            "usagePercent": 37.5,
            "currentPeriodStart": "2026-08-20T00:00:00Z",
            "nextResetTimestampUtc": "2026-08-27T00:00:00Z",
            "hasNonZeroIncludedLimit": true
        ]))

        let usage = try XCTUnwrap(progress([line], "Grok Bot usage"))
        XCTAssertEqual(usage.used, 37.5)
        XCTAssertEqual(usage.limit, 100)
        XCTAssertEqual(usage.resetsAt, OpenUsageISO8601.date(from: "2026-08-27T00:00:00Z"))
        XCTAssertEqual(usage.periodDurationMs, MetricPeriod.weekMs)
    }

    func testGrokBotUsageAllowsZeroAndClampsOverages() throws {
        let zero = try XCTUnwrap(CursorUsageMapper.mapGrokBotUsage(["usagePercent": 0]))
        let overage = try XCTUnwrap(CursorUsageMapper.mapGrokBotUsage(["usagePercent": 125]))

        XCTAssertEqual(progress([zero], "Grok Bot usage")?.used, 0)
        XCTAssertEqual(progress([zero], "Grok Bot usage")?.periodDurationMs, MetricPeriod.weekMs)
        XCTAssertEqual(progress([overage], "Grok Bot usage")?.used, 100)
    }

    func testGrokBotUsageRejectsPooledAndInvalidPersonalMeters() {
        XCTAssertNil(CursorUsageMapper.mapGrokBotUsage([
            "usagePercent": 42,
            "usesPooledEnterpriseAllowance": true
        ]))
        XCTAssertNil(CursorUsageMapper.mapGrokBotUsage([
            "usagePercent": 0,
            "hasNonZeroIncludedLimit": false
        ]))
        XCTAssertNil(CursorUsageMapper.mapGrokBotUsage([
            "usagePercent": 0,
            "includedLimitZero": true
        ]))
        XCTAssertNil(CursorUsageMapper.mapGrokBotUsage(["usagePercent": true]))
        XCTAssertNil(CursorUsageMapper.mapGrokBotUsage(["usagePercent": -1]))
        XCTAssertNil(CursorUsageMapper.mapGrokBotUsage(["hasNonZeroIncludedLimit": true]))
    }

    func testMapsCreditsUsageBreakdownAndOnDemand() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1_770_000_000_000,
                "billingCycleEnd": 1_772_592_000_000,
                "planUsage": [
                    "limit": 40_000,
                    "remaining": 32_000,
                    "totalPercentUsed": 20,
                    "autoPercentUsed": 12.5,
                    "apiPercentUsed": 7.5
                ],
                "spendLimitUsage": [
                    "individualLimit": 5_000,
                    "individualRemaining": 1_000
                ]
            ],
            planName: "pro plan",
            creditGrants: [
                "hasCreditGrants": true,
                "totalCents": "1000000",
                "usedCents": "264729"
            ],
            stripeBalanceCents: 991_544
        )

        XCTAssertEqual(mapped.plan, "Pro Plan")
        XCTAssertEqual(try XCTUnwrap(dollarValue(mapped.lines, "Credits")), 17268.15, accuracy: 0.001)
        XCTAssertEqual(progress(mapped.lines, "Total usage")?.used, 20)
        XCTAssertEqual(progress(mapped.lines, "Cursor Models")?.used, 12.5)
        XCTAssertEqual(progress(mapped.lines, "Other Models")?.used, 7.5)
        XCTAssertEqual(progress(mapped.lines, "On-demand")?.used, 40)
    }

    func testBoundedOnDemandDoesNotLetZeroSpendMaskPositiveUsage() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1_770_000_000_000,
                "billingCycleEnd": 1_772_592_000_000,
                "planUsage": [
                    "limit": 40_000,
                    "totalPercentUsed": 20
                ],
                "spendLimitUsage": [
                    "individualLimit": 5_000,
                    "individualRemaining": 4_500,
                    "individualUsed": 0,
                    "totalSpend": 1_200
                ]
            ],
            planName: "Ultra",
            creditGrants: nil,
            stripeBalanceCents: 0
        )

        XCTAssertEqual(progress(mapped.lines, "On-demand")?.used, 12)
    }

    func testMapsSpendOnlyOnDemandAsUnboundedUsage() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1_781_438_541_000,
                "billingCycleEnd": 1_784_030_541_000,
                "planUsage": [
                    "limit": 40_000,
                    "totalPercentUsed": 26.346,
                    "totalSpend": 52_692
                ],
                "spendLimitUsage": [
                    "individualUsed": 16_474,
                    "limitType": "user",
                    "totalSpend": 16_474
                ]
            ],
            planName: "Ultra",
            creditGrants: nil,
            stripeBalanceCents: 790_964
        )

        XCTAssertNil(progress(mapped.lines, "On-demand"))
        XCTAssertEqual(try XCTUnwrap(dollarValue(mapped.lines, "On-demand")), 164.74, accuracy: 0.001)
    }

    func testMapsRequestBasedFallback() throws {
        let mapped = try CursorUsageMapper.mapRequestBasedUsage(
            [
                "gpt-4": [
                    "numRequests": 39,
                    "maxRequestUsage": 500
                ],
                "startOfMonth": "2026-02-09T17:36:37.000Z"
            ],
            planName: "Team",
            unavailableMessage: "unavailable"
        )

        XCTAssertEqual(mapped.plan, "Team")
        XCTAssertEqual(progress(mapped.lines, "Requests")?.used, 39)
        XCTAssertEqual(progress(mapped.lines, "Requests")?.limit, 500)
        XCTAssertEqual(progress(mapped.lines, "Requests")?.periodDurationMs, CursorUsageMapper.billingPeriodMs)
    }

    func testTeamAccountEmitsDollarTotalUsageAndNoOrphanedBonusSpendLine() throws {
        // Team accounts report Total usage as a dollar meter and may carry a `bonusSpend` field. No
        // widget descriptor matches a "Bonus spend" label, so emitting one produced a line that could
        // never render. Regression: the mapper must not emit that orphaned line even when bonusSpend > 0.
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1_770_000_000_000,
                "billingCycleEnd": 1_772_592_000_000,
                "planUsage": [
                    "limit": 40_000,
                    "totalSpend": 10_000,
                    "bonusSpend": 2_500
                ]
            ],
            planName: "Team",
            creditGrants: nil,
            stripeBalanceCents: 0
        )

        XCTAssertEqual(mapped.plan, "Team")
        let total = try XCTUnwrap(progress(mapped.lines, "Total usage"))
        XCTAssertEqual(total.used, 100, accuracy: 0.001)    // $100.00 spent (totalSpend, cents → dollars)
        XCTAssertEqual(total.limit, 400, accuracy: 0.001)   // of a $400.00 limit
        XCTAssertFalse(mapped.lines.contains { $0.label == "Bonus spend" })
    }

    func testTeamBooleanTotalSpendFallsBackToLimitMinusRemaining() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "planUsage": [
                    "limit": 40_000,
                    "remaining": 32_000,
                    "totalSpend": true
                ]
            ],
            planName: "Team",
            creditGrants: nil,
            stripeBalanceCents: 0
        )

        let total = try XCTUnwrap(progress(mapped.lines, "Total usage"))
        XCTAssertEqual(total.used, 80, accuracy: 0.001)
        XCTAssertEqual(total.limit, 400, accuracy: 0.001)
    }
}

@MainActor
final class CursorProviderTests: XCTestCase {
    func testModelCategoryDescriptorsMatchDashboardAndKeepStableIdentifiers() throws {
        let descriptors = CursorProvider().widgetDescriptors
        XCTAssertEqual(Array(descriptors.prefix(4).map(\.id)), [
            "cursor.usage", "cursor.auto", "cursor.api", "cursor.grokBot"
        ])

        let totalUsage = try XCTUnwrap(descriptors.first { $0.id == "cursor.usage" })
        XCTAssertEqual(totalUsage.title, "Total Usage")

        let grokBot = try XCTUnwrap(descriptors.first { $0.id == "cursor.grokBot" })
        XCTAssertEqual(grokBot.title, "Grok Bot")
        XCTAssertEqual(grokBot.limitResources.map(\.key), ["grokBot"])

        let cursorModels = try XCTUnwrap(descriptors.first { $0.id == "cursor.auto" })
        XCTAssertEqual(cursorModels.title, "Cursor Models")
        XCTAssertEqual(cursorModels.metricLabel, "Cursor Models")
        XCTAssertEqual(cursorModels.limitResources.map(\.key), ["autoUsage"])

        let otherModels = try XCTUnwrap(descriptors.first { $0.id == "cursor.api" })
        XCTAssertEqual(otherModels.title, "Other Models")
        XCTAssertEqual(otherModels.metricLabel, "Other Models")
        XCTAssertEqual(otherModels.limitResources.map(\.key), ["apiUsage"])
    }

    func testRefreshFetchesLiveCursorUsage() async {
        let accessToken = makeUnsignedCursorJWT(sub: "google-oauth2|user_abc123")
        let http = RoutingHTTPClient { request in
            let url = request.url.absoluteString
            if url.contains("GetCurrentPeriodUsage") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "enabled": true,
                  "billingCycleEnd": 1772592000000,
                  "planUsage": {
                    "limit": 40000,
                    "remaining": 32000,
                    "totalPercentUsed": 20,
                    "autoPercentUsed": 12.5,
                    "apiPercentUsed": 7.5
                  },
                  "spendLimitUsage": {
                    "individualLimit": 5000,
                    "individualRemaining": 1000
                  }
                }
                """.utf8))
            }
            if url.contains("GetPlanInfo") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"pro plan"}}"#.utf8))
            }
            if url.contains("GetSandUsageStatus") {
                XCTAssertEqual(request.method, "POST")
                XCTAssertEqual(request.headers["Authorization"], "Bearer \(accessToken)")
                XCTAssertEqual(request.headers["Connect-Protocol-Version"], "1")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "usagePercent": 37.5,
                  "currentPeriodStart": "2026-08-20T00:00:00Z",
                  "nextResetTimestampUtc": "2026-08-27T00:00:00Z",
                  "hasNonZeroIncludedLimit": true
                }
                """.utf8))
            }
            if url.contains("GetCreditGrantsBalance") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"hasCreditGrants":false}"#.utf8))
            }
            if url.contains("/api/auth/stripe") {
                XCTAssertEqual(request.headers["Cookie"], "WorkosCursorSessionToken=user_abc123%3A%3A\(accessToken)")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"customerBalance":"-50000"}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: accessToken]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro Plan")
        XCTAssertEqual(dollarValue(snapshot.lines, "Credits") ?? -1, 500)
        XCTAssertEqual(progress(snapshot.lines, "Total usage")?.used, 20)
        XCTAssertEqual(progress(snapshot.lines, "Grok Bot usage")?.used, 37.5)
        XCTAssertEqual(
            progress(snapshot.lines, "Grok Bot usage")?.resetsAt,
            OpenUsageISO8601.date(from: "2026-08-27T00:00:00Z")
        )
        XCTAssertEqual(progress(snapshot.lines, "Cursor Models")?.used, 12.5)
        XCTAssertEqual(progress(snapshot.lines, "Other Models")?.used, 7.5)
        XCTAssertEqual(progress(snapshot.lines, "On-demand")?.used, 40)
    }

    func testBorrowedTokenWithoutExpiryIsUsedWithoutRefreshOrWrites() async throws {
        let accessToken = makeUnsignedCursorJWT(sub: "google-oauth2|borrowed-user", exp: nil)
        let fixture = try makeGrokBotCursorFixture(accessToken: accessToken)
        let sqlite = KeyValueSQLite()
        let keychain = ServiceKeychain()
        let originalFiles = fixture.files.files
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CursorUsageClient.usageURL:
                XCTAssertEqual(request.headers["Authorization"], "Bearer \(accessToken)")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "enabled": true,
                  "billingCycleEnd": 1772592000000,
                  "planUsage": {
                    "limit": 40000,
                    "remaining": 32000,
                    "totalPercentUsed": 20
                  }
                }
                """.utf8))
            case CursorUsageClient.planURL:
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"planInfo":{"planName":"Pro"}}"#.utf8)
                )
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: sqlite,
                keychain: keychain,
                grokBot: fixture.store
            ),
            usageClient: CursorUsageClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(progress(snapshot.lines, "Total usage")?.used, 20)
        XCTAssertFalse(http.requests.contains { $0.url == CursorUsageClient.refreshURL })
        XCTAssertTrue(sqlite.writtenValues.isEmpty)
        XCTAssertTrue(keychain.values.isEmpty)
        XCTAssertEqual(fixture.files.files, originalFiles)
    }

    func testRejectedBorrowedTokenReportsGrokBotRecoveryWithoutRefresh() async throws {
        let accessToken = makeUnsignedCursorJWT(sub: "google-oauth2|borrowed-user", exp: nil)
        let fixture = try makeGrokBotCursorFixture(accessToken: accessToken)
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.url, CursorUsageClient.usageURL)
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: KeyValueSQLite(),
                keychain: FakeKeychain(),
                grokBot: fixture.store
            ),
            usageClient: CursorUsageClient(http: http)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(
            badgeText(snapshot.lines),
            CursorAuthError.grokBotAuthenticationRequired.errorDescription
        )
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertFalse(http.requests.contains { $0.url == CursorUsageClient.refreshURL })
    }

    func testNextRefreshRereadsRejectedGrokBotCredential() async throws {
        let first = try makeGrokBotCursorFixture(accessToken: "first-borrowed-token")
        let second = try makeGrokBotCursorFixture(accessToken: "second-borrowed-token")
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: KeyValueSQLite(),
                keychain: FakeKeychain(),
                grokBot: first.store
            ),
            usageClient: CursorUsageClient(http: http)
        )

        _ = await provider.refresh()
        first.files.files[GrokBotCursorAuthStore.secretsPath] =
            second.files.files[GrokBotCursorAuthStore.secretsPath]
        _ = await provider.refresh()

        XCTAssertEqual(
            http.requests.compactMap { $0.headers["Authorization"] },
            ["Bearer first-borrowed-token", "Bearer second-borrowed-token"]
        )
        XCTAssertFalse(http.requests.contains { $0.url == CursorUsageClient.refreshURL })
    }
}

private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
    guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (used, limit, resetsAt, periodDurationMs)
}

private func dollarValue(_ lines: [MetricLine], _ label: String) -> Double? {
    guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return values.first { $0.kind == .dollars }?.number
}

private func badgeText(_ lines: [MetricLine]) -> String? {
    guard case .badge(_, let text, _, _) = lines.first else { return nil }
    return text
}
