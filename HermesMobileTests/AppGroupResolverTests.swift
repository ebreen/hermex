import XCTest
@testable import HermesMobile

final class AppGroupResolverTests: XCTestCase {
    private let canonical = HermesAppGroupResolver.canonicalIdentifier

    func testAbsentALTAppGroupsFallsBackToCanonical() throws {
        let info: [String: Any] = ["HermesAppGroupIdentifier": canonical]
        let resolved = try HermesAppGroupResolver.effectiveAppGroupIdentifier(infoDictionary: info)
        XCTAssertEqual(resolved, canonical)
    }

    func testEmptyInfoDictionaryFallsBackToCanonical() throws {
        let resolved = try HermesAppGroupResolver.effectiveAppGroupIdentifier(infoDictionary: [:])
        XCTAssertEqual(resolved, canonical)
    }

    func testProductionSeamUsesCanonicalFallbackWhenALTAppGroupsIsAbsent() throws {
        let resolved = try HermesShareDraft.resolvedAppGroupIdentifier(
            infoDictionary: ["HermesAppGroupIdentifier": canonical]
        )
        XCTAssertEqual(resolved, canonical)
    }

    func testProductionSeamFailsClosedForInvalidPresentALTAppGroups() {
        let info: [String: Any] = [
            "ALTAppGroups": ["group.altstore.unrelated"],
        ]
        XCTAssertThrowsError(
            try HermesShareDraft.resolvedAppGroupIdentifier(infoDictionary: info)
        ) { error in
            guard case HermesAppGroupResolver.Error.unrelatedSideStoreGroups = error else {
                return XCTFail("expected unrelatedSideStoreGroups, got \(error)")
            }
        }
    }

    func testSideStoreRemappedGroupIsSelectedBySuffix() throws {
        let remapped = "group.altstore.3F2A91C0-D5E6-4B7A-9C1E-2F8A0B6D4E5F.\(canonical)"
        let info: [String: Any] = [
            "ALTAppGroups": [remapped],
        ]
        let resolved = try HermesAppGroupResolver.effectiveAppGroupIdentifier(infoDictionary: info)
        XCTAssertEqual(resolved, remapped)
    }

    func testSideStoreListWithUnrelatedGroupsOnlyFails() {
        let info: [String: Any] = [
            "ALTAppGroups": ["group.altstore.ABC123.other.group", "group.altstore.DEF456.another"],
        ]
        XCTAssertThrowsError(
            try HermesAppGroupResolver.effectiveAppGroupIdentifier(infoDictionary: info)
        ) { error in
            guard case HermesAppGroupResolver.Error.unrelatedSideStoreGroups = error else {
                return XCTFail("expected unrelatedSideStoreGroups, got \(error)")
            }
        }
    }

    func testAmbiguousMatchingGroupsFail() {
        let info: [String: Any] = [
            "ALTAppGroups": [
                "group.altstore.AAAA.\(canonical)",
                "group.altstore.BBBB.\(canonical)",
            ],
        ]
        XCTAssertThrowsError(
            try HermesAppGroupResolver.effectiveAppGroupIdentifier(infoDictionary: info)
        ) { error in
            guard case HermesAppGroupResolver.Error.ambiguousMatchingGroups = error else {
                return XCTFail("expected ambiguousMatchingGroups, got \(error)")
            }
        }
    }

    func testMalformedALTAppGroupsFail() {
        let nonArray: [String: Any] = ["ALTAppGroups": canonical]
        XCTAssertThrowsError(
            try HermesAppGroupResolver.effectiveAppGroupIdentifier(infoDictionary: nonArray)
        ) { error in
            guard case HermesAppGroupResolver.Error.malformedSideStoreGroups = error else {
                return XCTFail("expected malformedSideStoreGroups, got \(error)")
            }
        }

        let nonStringEntries: [String: Any] = ["ALTAppGroups": [42, canonical]]
        XCTAssertThrowsError(
            try HermesAppGroupResolver.effectiveAppGroupIdentifier(infoDictionary: nonStringEntries)
        ) { error in
            guard case HermesAppGroupResolver.Error.malformedSideStoreGroups = error else {
                return XCTFail("expected malformedSideStoreGroups, got \(error)")
            }
        }
    }

    func testEmptyALTAppGroupsFailVisibly() {
        let info: [String: Any] = ["ALTAppGroups": [String]()]
        XCTAssertThrowsError(
            try HermesAppGroupResolver.effectiveAppGroupIdentifier(infoDictionary: info)
        ) { error in
            guard case HermesAppGroupResolver.Error.unrelatedSideStoreGroups = error else {
                return XCTFail("expected unrelatedSideStoreGroups, got \(error)")
            }
        }
    }

    func testCanonicalIdentifierIsUnchanged() {
        XCTAssertEqual(canonical, "group.no.gior.hermex")
    }
}
