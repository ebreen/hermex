import XCTest
@testable import HermesMobile

final class AppGroupResolverTests: XCTestCase {
    private let canonical = HermesAppGroupResolver.canonicalIdentifier
    private let configuredOverride = "group.example.hermex"
    private let teamIdentifier = "TEAM123"

    func testAbsentALTAppGroupsUsesConfiguredHermesAppGroupIdentifier() throws {
        let info: [String: Any] = [
            "HermesAppGroupIdentifier": configuredOverride,
        ]
        let resolved = try HermesAppGroupResolver.effectiveAppGroupIdentifier(infoDictionary: info)
        XCTAssertEqual(resolved, configuredOverride)
    }

    func testAbsentALTAppGroupsFallsBackToCanonicalWhenConfigurationIsMissing() throws {
        let resolved = try HermesAppGroupResolver.effectiveAppGroupIdentifier(infoDictionary: [:])
        XCTAssertEqual(resolved, canonical)
    }

    func testInvalidConfiguredHermesAppGroupIdentifierFallsBackToCanonical() throws {
        let invalidValues: [Any] = [
            "",
            "group.example..hermex",
            "com.example.hermex",
            "group.example hermex",
            42,
        ]

        for invalidValue in invalidValues {
            let info: [String: Any] = [
                "HermesAppGroupIdentifier": invalidValue,
            ]
            let resolved = try HermesAppGroupResolver.effectiveAppGroupIdentifier(infoDictionary: info)
            XCTAssertEqual(resolved, canonical, "unexpected base for \(invalidValue)")
        }
    }

    func testConfiguredOverrideIsUsedForSideStoreRemap() throws {
        let remapped = "\(configuredOverride).\(teamIdentifier)"
        let info: [String: Any] = [
            "HermesAppGroupIdentifier": configuredOverride,
            "ALTAppGroups": [remapped],
        ]
        let resolved = try HermesAppGroupResolver.effectiveAppGroupIdentifier(infoDictionary: info)
        XCTAssertEqual(resolved, remapped)
    }

    func testProductionSeamUsesConfiguredBaseWhenALTAppGroupsIsAbsent() throws {
        let resolved = try HermesShareDraft.resolvedAppGroupIdentifier(
            infoDictionary: ["HermesAppGroupIdentifier": configuredOverride]
        )
        XCTAssertEqual(resolved, configuredOverride)
    }

    func testProductionSeamFailsClosedForInvalidPresentALTAppGroups() {
        let info: [String: Any] = [
            "HermesAppGroupIdentifier": configuredOverride,
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

    func testAppImportAttemptSurfacesInvalidPresentMetadataAsUnavailable() {
        let info: [String: Any] = [
            "HermesAppGroupIdentifier": canonical,
            "ALTAppGroups": [
                "\(canonical).\(teamIdentifier)",
                "",
            ],
        ]

        let attempt = HermesShareDraft.pendingImportAttempt(infoDictionary: info)
        guard case .unavailable = attempt else {
            return XCTFail("expected invalid present app-group metadata to be unavailable")
        }
    }

    func testSideStoreRemapUsesCanonicalBaseThenOneTeamComponent() throws {
        let remapped = "\(canonical).\(teamIdentifier)"
        let info: [String: Any] = [
            "ALTAppGroups": [remapped],
        ]
        let resolved = try HermesAppGroupResolver.effectiveAppGroupIdentifier(infoDictionary: info)
        XCTAssertEqual(resolved, remapped)
    }

    func testExactBaseIsRejectedWhenALTAppGroupsIsPresent() {
        let info: [String: Any] = [
            "ALTAppGroups": [canonical],
        ]
        XCTAssertThrowsError(
            try HermesAppGroupResolver.effectiveAppGroupIdentifier(infoDictionary: info)
        ) { error in
            guard case HermesAppGroupResolver.Error.unrelatedSideStoreGroups = error else {
                return XCTFail("expected unrelatedSideStoreGroups, got \(error)")
            }
        }
    }

    func testSyntheticAltStorePrefixEndingInCanonicalBaseIsRejected() {
        let synthetic = "group.altstore.3F2A91C0-D5E6-4B7A-9C1E-2F8A0B6D4E5F.\(canonical)"
        assertUnrelated([synthetic])
    }

    func testCanonicalPrefixCollisionIsRejected() {
        assertUnrelated(["\(canonical)evil.\(teamIdentifier)"])
    }

    func testMixedALTAppGroupsWithEmptyEntryFailsClosed() {
        assertUnrelated([
            "\(canonical).\(teamIdentifier)",
            "",
        ])
    }

    func testMixedALTAppGroupsWithCanonicalPrefixCollisionFailsClosed() {
        assertUnrelated([
            "\(canonical).\(teamIdentifier)",
            "group.no.gior.hermexevil.TEAM999",
        ])
    }

    func testMixedALTAppGroupsWithReversedSyntheticEntryFailsClosed() {
        assertUnrelated([
            "\(canonical).\(teamIdentifier)",
            "group.altstore.3F2A91C0-D5E6-4B7A-9C1E-2F8A0B6D4E5F.\(canonical)",
        ])
    }

    func testMixedALTAppGroupsWithWellFormedUnrelatedGroupFailsClosed() {
        assertUnrelated([
            "\(canonical).\(teamIdentifier)",
            "group.example.unrelated.TEAM999",
        ])
    }

    func testMixedALTAppGroupsWithMalformedRelatedEntryFailsClosed() {
        assertUnrelated(["\(canonical).\(teamIdentifier)", "\(canonical)."])
    }

    func testEmptyTeamComponentIsRejected() {
        assertUnrelated(["\(canonical)."])
    }

    func testMultiComponentTeamSuffixIsRejected() {
        assertUnrelated(["\(canonical).\(teamIdentifier).extra"])
    }

    func testInvalidTeamComponentIsRejected() {
        assertUnrelated([
            "\(canonical).TEAM_ID",
            "\(canonical).TEAM/ID",
            "\(canonical).TEAM ID",
        ])
    }

    func testUnrelatedGroupsOnlyFail() {
        assertUnrelated([
            "group.altstore.ABC123.other.group",
            "group.altstore.DEF456.another",
        ])
    }

    func testAmbiguousMatchingGroupsFail() {
        let info: [String: Any] = [
            "ALTAppGroups": [
                "\(canonical).AAAA",
                "\(canonical).BBBB",
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
        XCTAssertThrowsError(
            try HermesAppGroupResolver.effectiveAppGroupIdentifier(infoDictionary: ["ALTAppGroups": [String]()])
        ) { error in
            guard case HermesAppGroupResolver.Error.unrelatedSideStoreGroups = error else {
                return XCTFail("expected unrelatedSideStoreGroups, got \(error)")
            }
        }
    }

    func testCanonicalIdentifierIsUnchanged() {
        XCTAssertEqual(canonical, "group.no.gior.hermex")
    }

    private func assertUnrelated(_ groups: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(
            try HermesAppGroupResolver.effectiveAppGroupIdentifier(infoDictionary: ["ALTAppGroups": groups]),
            file: file,
            line: line
        ) { error in
            guard case HermesAppGroupResolver.Error.unrelatedSideStoreGroups = error else {
                return XCTFail("expected unrelatedSideStoreGroups, got \(error)", file: file, line: line)
            }
        }
    }
}
