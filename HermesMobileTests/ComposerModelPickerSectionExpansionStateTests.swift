import XCTest
@testable import HermesMobile

final class ComposerModelPickerSectionExpansionStateTests: XCTestCase {
    func testSectionsStartCollapsedWhenSearchIsEmpty() {
        let state = ComposerModelPickerSectionExpansionState()

        XCTAssertFalse(state.isExpanded(groupID: "openai"))
    }

    func testManualExpansionPersistsWhileSearchIsEmpty() {
        var state = ComposerModelPickerSectionExpansionState()

        state.setExpanded(true, groupID: "openai")

        XCTAssertTrue(state.isExpanded(groupID: "openai"))

        state.setExpanded(false, groupID: "openai")

        XCTAssertFalse(state.isExpanded(groupID: "openai"))
    }

    func testSearchAutoExpandsAllSections() {
        var state = ComposerModelPickerSectionExpansionState()

        state.updateSearchText("gpt")

        XCTAssertTrue(state.isExpanded(groupID: "openai"))
        XCTAssertTrue(state.isExpanded(groupID: "anthropic"))
    }

    func testManualCollapseDuringSearchDoesNotChangeEmptySearchState() {
        var state = ComposerModelPickerSectionExpansionState()
        state.setExpanded(true, groupID: "openai")
        state.updateSearchText("gpt")

        state.setExpanded(false, groupID: "openai")

        XCTAssertFalse(state.isExpanded(groupID: "openai"))

        state.updateSearchText("")

        XCTAssertTrue(state.isExpanded(groupID: "openai"))
    }

    func testChangingSearchQueryReexpandsCollapsedSearchSections() {
        var state = ComposerModelPickerSectionExpansionState()
        state.updateSearchText("gpt")
        state.setExpanded(false, groupID: "openai")
        state.setExpanded(false, groupID: "anthropic")

        XCTAssertFalse(state.isExpanded(groupID: "openai"))
        XCTAssertFalse(state.isExpanded(groupID: "anthropic"))

        state.updateSearchText("gpt 5")

        XCTAssertTrue(state.isExpanded(groupID: "openai"))
        XCTAssertTrue(state.isExpanded(groupID: "anthropic"))
    }

    func testGroupExpansionStateIsIndependentAcrossSearchBoundary() {
        var state = ComposerModelPickerSectionExpansionState()
        state.setExpanded(true, groupID: "openai")

        XCTAssertTrue(state.isExpanded(groupID: "openai"))
        XCTAssertFalse(state.isExpanded(groupID: "anthropic"))

        state.updateSearchText("claude")
        state.setExpanded(false, groupID: "anthropic")

        XCTAssertTrue(state.isExpanded(groupID: "openai"))
        XCTAssertFalse(state.isExpanded(groupID: "anthropic"))

        state.updateSearchText("")

        XCTAssertTrue(state.isExpanded(groupID: "openai"))
        XCTAssertFalse(state.isExpanded(groupID: "anthropic"))
    }

    func testWhitespaceOnlySearchUsesEmptySearchState() {
        var state = ComposerModelPickerSectionExpansionState()
        state.setExpanded(true, groupID: "openai")
        state.updateSearchText("gpt")
        state.setExpanded(false, groupID: "openai")

        XCTAssertFalse(state.isExpanded(groupID: "openai"))

        state.updateSearchText("   ")

        XCTAssertTrue(state.isExpanded(groupID: "openai"))
        XCTAssertFalse(state.isExpanded(groupID: "anthropic"))
    }

    func testFirstNonEmptyGroupAutoExpandsWhenNoUsefulRow() {
        var state = ComposerModelPickerSectionExpansionState()
        let groups = [
            ModelCatalogGroup(id: "openai", name: "OpenAI", providerID: "openai", models: [
                ModelCatalogOption(id: "gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
            ]),
            ModelCatalogGroup(id: "anthropic", name: "Anthropic", providerID: "anthropic", models: [
                ModelCatalogOption(id: "claude", displayName: "Claude", providerID: "anthropic")
            ])
        ]

        state.autoExpandFirstNonEmptyGroup(in: groups, usefulRowPresent: false)

        XCTAssertTrue(state.isExpanded(groupID: "openai"))
        XCTAssertFalse(state.isExpanded(groupID: "anthropic"))
    }

    func testEmptyFirstGroupSkipsToNextNonEmptyGroup() {
        var state = ComposerModelPickerSectionExpansionState()
        let groups = [
            ModelCatalogGroup(id: "empty", name: "Empty", providerID: "empty", models: []),
            ModelCatalogGroup(id: "openai", name: "OpenAI", providerID: "openai", models: [
                ModelCatalogOption(id: "gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
            ])
        ]

        state.autoExpandFirstNonEmptyGroup(in: groups, usefulRowPresent: false)

        XCTAssertFalse(state.isExpanded(groupID: "empty"))
        XCTAssertTrue(state.isExpanded(groupID: "openai"))
    }

    func testUsefulFallbackRowPreventsAutoExpansion() {
        var state = ComposerModelPickerSectionExpansionState()
        let groups = [
            ModelCatalogGroup(id: "openai", name: "OpenAI", providerID: "openai", models: [
                ModelCatalogOption(id: "gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
            ])
        ]

        state.autoExpandFirstNonEmptyGroup(in: groups, usefulRowPresent: true)

        XCTAssertFalse(state.isExpanded(groupID: "openai"))
    }

    func testUserTogglePreventsLaterAutomaticOverride() {
        var state = ComposerModelPickerSectionExpansionState()
        let groups = [
            ModelCatalogGroup(id: "openai", name: "OpenAI", providerID: "openai", models: [
                ModelCatalogOption(id: "gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
            ])
        ]

        state.autoExpandFirstNonEmptyGroup(in: groups, usefulRowPresent: false)
        XCTAssertTrue(state.isExpanded(groupID: "openai"))

        state.setExpanded(false, groupID: "openai")
        state.autoExpandFirstNonEmptyGroup(in: groups, usefulRowPresent: false)

        XCTAssertFalse(state.isExpanded(groupID: "openai"))
    }
}
