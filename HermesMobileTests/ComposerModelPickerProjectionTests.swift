import XCTest
@testable import HermesMobile

// MARK: - Slice 5 RED contract: canonical picker projection (issue #16)
//
// These tests define the pure, non-SwiftUI seam before the production projection
// exists. The sheet and compact menu must consume the same canonical rows; this
// suite therefore asserts projection output rather than reaching into either UI.
// All barriers in this slice are synchronous pure-policy calls: no sleeps,
// polling, semaphores, or wall-clock assertions are permitted.

final class ComposerModelPickerProjectionTests: XCTestCase {
    func testProviderNilDoesNotChooseFirstProvider() {
        let openAI = option(id: "shared/model", displayName: "OpenAI Shared", providerID: "openai")
        let anthropic = option(id: "shared/model", displayName: "Anthropic Shared", providerID: "anthropic")
        let unresolved = option(id: "shared/model", displayName: "shared/model", providerID: nil)
        let projection = makeProjection(
            groups: [
                group(id: "openai", name: "OpenAI", providerID: "openai", models: [openAI]),
                group(id: "anthropic", name: "Anthropic", providerID: "anthropic", models: [anthropic])
            ],
            selectedModelID: unresolved.id,
            selectedModelProviderID: nil
        )

        XCTAssertEqual(projection.currentCustomRows, [unresolved])
        XCTAssertNil(projection.selectedCatalogOption)
        XCTAssertTrue(projection.sheetRows.contains(openAI))
        XCTAssertTrue(projection.sheetRows.contains(anthropic))
        XCTAssertTrue(projection.compactRows.contains(openAI))
        XCTAssertTrue(projection.compactRows.contains(anthropic))
    }

    func testSheetAndCompactProjectionHaveSameCanonicalRowIdentity() {
        let current = option(id: "current", displayName: "Current", providerID: "openai")
        let favorite = option(id: "favorite", displayName: "Favorite", providerID: "anthropic")
        let recent = option(id: "recent", displayName: "Recent", providerID: "google")
        let projection = makeProjection(
            groups: [group(id: "catalog", name: "Catalog", providerID: "local", models: [current, favorite, recent])],
            selectedModelID: current.id,
            selectedModelProviderID: current.providerID,
            favoriteKeys: [favorite.favoriteKey],
            recentKeys: [recent.favoriteKey]
        )

        XCTAssertEqual(
            projection.sheetRows.map(\.favoriteKey),
            projection.compactRows.map(\.favoriteKey),
            "both picker consumers must expose the same canonical row identity"
        )
    }

    func testMissingExplicitSelectionAppearsAsCurrentCustom() {
        let explicit = option(id: "custom/missing", displayName: "custom/missing", providerID: "openrouter")
        let projection = makeProjection(
            groups: [group(id: "openai", name: "OpenAI", providerID: "openai", models: [
                option(id: "gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
            ])],
            selectedModelID: explicit.id,
            selectedModelProviderID: explicit.providerID
        )

        XCTAssertEqual(projection.currentCustomRows, [explicit])
        XCTAssertTrue(projection.sheetRows.contains(explicit))
        XCTAssertTrue(projection.compactRows.contains(explicit))
    }

    func testMissingFavoriteRemainsVisible() {
        let missing = option(id: "saved/favorite", displayName: "saved/favorite", providerID: "openrouter")
        let projection = makeProjection(
            groups: [group(id: "openai", name: "OpenAI", providerID: "openai", models: [
                option(id: "gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
            ])],
            favoriteKeys: [missing.favoriteKey]
        )

        XCTAssertEqual(projection.favoriteRows, [missing])
        XCTAssertTrue(projection.sheetRows.contains(missing))
        XCTAssertTrue(projection.compactRows.contains(missing))
    }

    func testMissingRecentRemainsVisible() {
        let missing = option(id: "saved/recent", displayName: "saved/recent", providerID: "local")
        let projection = makeProjection(
            groups: [group(id: "openai", name: "OpenAI", providerID: "openai", models: [
                option(id: "gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
            ])],
            recentKeys: [missing.favoriteKey]
        )

        XCTAssertEqual(projection.recentRows, [missing])
        XCTAssertTrue(projection.sheetRows.contains(missing))
        XCTAssertTrue(projection.compactRows.contains(missing))
    }

    func testFavoriteWinsOverDuplicateRecent() {
        let shared = option(id: "shared", displayName: "Shared", providerID: "openai")
        let projection = makeProjection(
            groups: [group(id: "openai", name: "OpenAI", providerID: "openai", models: [shared])],
            favoriteKeys: [shared.favoriteKey],
            recentKeys: [shared.favoriteKey]
        )

        XCTAssertEqual(projection.favoriteRows, [shared])
        XCTAssertTrue(projection.recentRows.isEmpty)
        XCTAssertEqual(
            projection.sheetRows.filter { $0.favoriteKey == shared.favoriteKey },
            [shared]
        )
        XCTAssertEqual(
            projection.compactRows.filter { $0.favoriteKey == shared.favoriteKey },
            [shared]
        )
    }

    func testValidEmptyRetainsCustomFavoriteAndRecentRows() {
        let current = option(id: "current/custom", displayName: "current/custom", providerID: "openrouter")
        let favorite = option(id: "saved/favorite", displayName: "saved/favorite", providerID: "openrouter")
        let recent = option(id: "saved/recent", displayName: "saved/recent", providerID: "local")
        let projection = makeProjection(
            groups: [],
            selectedModelID: current.id,
            selectedModelProviderID: current.providerID,
            favoriteKeys: [favorite.favoriteKey],
            recentKeys: [recent.favoriteKey]
        )

        XCTAssertEqual(Set(projection.currentCustomRows), Set([current]))
        XCTAssertEqual(Set(projection.favoriteRows), Set([favorite]))
        XCTAssertEqual(Set(projection.recentRows), Set([recent]))
        XCTAssertEqual(
            Set(projection.sheetRows),
            Set([current, favorite, recent]),
            "a valid empty catalog must not erase saved or explicit custom rows"
        )
        XCTAssertEqual(Set(projection.compactRows), Set([current, favorite, recent]))
    }

    func testCatalogReplacementDoesNotOverwriteExplicitSelection() {
        let explicit = option(id: "selected/custom", displayName: "selected/custom", providerID: "openrouter")
        let replacement = option(id: "replacement", displayName: "Replacement", providerID: "openai")
        let projection = makeProjection(
            groups: [group(id: "openai", name: "OpenAI", providerID: "openai", models: [replacement])],
            selectedModelID: explicit.id,
            selectedModelProviderID: explicit.providerID
        )

        XCTAssertEqual(
            projection.sheetRows.filter { $0.favoriteKey == explicit.favoriteKey },
            [explicit]
        )
        XCTAssertEqual(
            projection.compactRows.filter { $0.favoriteKey == explicit.favoriteKey },
            [explicit]
        )
    }

    private func makeProjection(
        groups: [ModelCatalogGroup],
        selectedModelID: String? = nil,
        selectedModelProviderID: String? = nil,
        favoriteKeys: [ModelFavoriteKey] = [],
        recentKeys: [ModelFavoriteKey] = [],
        savedCustomOptions: [ModelCatalogOption] = []
    ) -> ComposerModelPickerProjection {
        ComposerModelPickerProjection(
            modelGroups: groups,
            selectedModelID: selectedModelID,
            selectedModelProviderID: selectedModelProviderID,
            favoriteModelKeys: favoriteKeys,
            recentModelKeys: recentKeys,
            savedCustomOptions: savedCustomOptions
        )
    }

    private func group(
        id: String,
        name: String,
        providerID: String?,
        models: [ModelCatalogOption]
    ) -> ModelCatalogGroup {
        ModelCatalogGroup(id: id, name: name, providerID: providerID, models: models)
    }

    private func option(id: String, displayName: String, providerID: String?) -> ModelCatalogOption {
        ModelCatalogOption(id: id, displayName: displayName, providerID: providerID)
    }
}
