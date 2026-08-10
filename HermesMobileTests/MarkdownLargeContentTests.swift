// MarkdownLargeContentTests.swift
//
// #17 Slice A RED (tests-only): producer metadata, O(1) route policy, and exact
// threshold/line-ending behavior (contract §1.1, §3.1, §3.3, §3.6, §5.3;
// executable handoff /tmp/hermex-issue17-sliceA-red-handoff.md §3).
//
// RED expectation on the frozen code: every support-seam symbol referenced
// below (MarkdownSourceMetadata, MarkdownContentSnapshot, MarkdownAppendAdmission,
// MarkdownLargeContentBaseRoute, MarkdownLargeContentPolicy, MarkdownSourceSnapshotBox,
// MarkdownSnapshotObservationProbe, MarkdownRenderObservationKey, MarkdownStreamIdentity,
// MarkdownContentGeneration, MarkdownProducerMetadataCost) is absent from the repo at
// the frozen SHA, so the native run is a compile RED limited to "cannot find 'X' in
// scope" diagnostics confined to this file. No production declaration is added here.
//
// Determinism discipline (contract §5.8, §10; handoff §3-§4): every test below is fully
// synchronous — no Task.sleep, usleep, polling loops, wall-clock delays, file I/O,
// randomness, shared mutable statics, or cross-test ordering. Slice A needs no async
// seam, so no continuation barrier is required; every test releases all state before
// returning and is safe under parallel worker execution.

import Foundation
import XCTest

@testable import HermesMobile

final class MarkdownLargeContentTests: XCTestCase {
    // MARK: - Threshold policy (handoff rows 1-4, 9)

    /// Strict `>` character threshold: 79_999/80_000 ordinary, 80_001 large.
    /// RED: old code yields `.tooManyCharacters` -> `PlainMarkdownFallbackView` for
    /// 80_001 (proven by `testMarkdownContentRenderingPolicyFallsBackForVeryLargeMarkdown`).
    func testCharacterThresholdsSelectExactRoutes() {
        let belowLimit = String(repeating: "a", count: 79_999)
        let atLimit = String(repeating: "a", count: 80_000)
        let overLimit = String(repeating: "a", count: 80_001)

        XCTAssertEqual(belowLimit.count, 79_999)
        XCTAssertEqual(atLimit.count, 80_000)
        XCTAssertEqual(overLimit.count, 80_001)

        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: makeMetadata(source: belowLimit, revision: 1),
                isPolicyEnabled: true
            ),
            .ordinary
        )
        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: makeMetadata(source: atLimit, revision: 2),
                isPolicyEnabled: true
            ),
            .ordinary
        )
        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: makeMetadata(source: overLimit, revision: 3),
                isPolicyEnabled: true
            ),
            .largePolicyEnabled
        )
    }

    /// Strict `>` logical-line threshold with the locked line definition
    /// (`MarkdownHighlightPolicy.lineCount(in:)`, MarkdownRenderer.swift:1002):
    /// 1_999/2_000 ordinary, 2_001 large. RED: old code yields `.tooManyLines` at 2_001.
    func testLogicalLineThresholdsSelectExactRoutes() {
        let belowLimit = Array(repeating: "line", count: 1_999).joined(separator: "\n")
        let atLimit = Array(repeating: "line", count: 2_000).joined(separator: "\n")
        let overLimit = Array(repeating: "line", count: 2_001).joined(separator: "\n")

        XCTAssertEqual(lockedLineCount(of: belowLimit), 1_999)
        XCTAssertEqual(lockedLineCount(of: atLimit), 2_000)
        XCTAssertEqual(lockedLineCount(of: overLimit), 2_001)

        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: makeMetadata(source: belowLimit, revision: 1),
                isPolicyEnabled: true
            ),
            .ordinary
        )
        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: makeMetadata(source: atLimit, revision: 2),
                isPolicyEnabled: true
            ),
            .ordinary
        )
        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: makeMetadata(source: overLimit, revision: 3),
                isPolicyEnabled: true
            ),
            .largePolicyEnabled
        )
    }

    /// One limit exceeded while the other stays below selects the large route;
    /// the route reads only producer-issued metadata integers, never re-derived counts.
    func testSingleThresholdExceededSelectsLargeRoute() {
        // 80_001 characters / 1 logical line: character limit exceeded alone.
        let manyCharactersFewLines = String(repeating: "a", count: 80_001)
        XCTAssertEqual(manyCharactersFewLines.count, 80_001)
        XCTAssertEqual(lockedLineCount(of: manyCharactersFewLines), 1)
        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: makeMetadata(source: manyCharactersFewLines, revision: 1),
                isPolicyEnabled: true
            ),
            .largePolicyEnabled
        )

        // 10_004 characters / 2_001 logical lines: line limit exceeded alone.
        let fewCharactersManyLines = Array(repeating: "line", count: 2_001).joined(separator: "\n")
        XCTAssertEqual(fewCharactersManyLines.count, 10_004)
        XCTAssertEqual(lockedLineCount(of: fewCharactersManyLines), 2_001)
        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: makeMetadata(source: fewCharactersManyLines, revision: 2),
                isPolicyEnabled: true
            ),
            .largePolicyEnabled
        )

        // Control: both limits below selects ordinary.
        let ordinary = Array(repeating: "line", count: 100).joined(separator: "\n")
        XCTAssertEqual(ordinary.count, 499)
        XCTAssertEqual(lockedLineCount(of: ordinary), 100)
        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: makeMetadata(source: ordinary, revision: 3),
                isPolicyEnabled: true
            ),
            .ordinary
        )
    }

    /// LF, CR, CRLF (one line ending), U+2028, U+2029, and mixed endings produce
    /// exact logical-line counts; exact trailing-separator behavior matches
    /// `MarkdownHighlightPolicy.lineCount(in:)`. U+2028/U+2029 update producer counts
    /// but are never asserted as semantic split points here (scanner owns that in Slice D).
    func testLineEndingVariantsAndTrailingSeparatorBehavior() {
        // Single line endings.
        XCTAssertEqual(lockedLineCount(of: "a\nb"), 2)
        XCTAssertEqual(lockedLineCount(of: "a\rb"), 2)
        XCTAssertEqual(lockedLineCount(of: "a\r\nb"), 2) // CRLF is ONE line ending
        XCTAssertEqual(lockedLineCount(of: "a\u{2028}b"), 2)
        XCTAssertEqual(lockedLineCount(of: "a\u{2029}b"), 2)

        // Mixed endings.
        XCTAssertEqual(lockedLineCount(of: "a\nb\rc\r\nd\u{2028}e\u{2029}f"), 6)

        // Exact trailing-separator behavior.
        XCTAssertEqual(lockedLineCount(of: "a\n"), 2)
        XCTAssertEqual(lockedLineCount(of: "a\r"), 2)
        XCTAssertEqual(lockedLineCount(of: "a\r\n"), 2)
        XCTAssertEqual(lockedLineCount(of: "a\n\n"), 3)
        XCTAssertEqual(lockedLineCount(of: "a\r\n\r\n"), 3)
        XCTAssertEqual(lockedLineCount(of: ""), 0)

        // A trailing separator is a logical line: 2_000 lines plus a trailing LF
        // crosses the threshold, while the identical source without it stays ordinary.
        let withTrailingSeparator = Array(repeating: "line", count: 2_000).joined(separator: "\n") + "\n"
        XCTAssertEqual(lockedLineCount(of: withTrailingSeparator), 2_001)
        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: makeMetadata(source: withTrailingSeparator, revision: 1),
                isPolicyEnabled: true
            ),
            .largePolicyEnabled
        )

        let withoutTrailingSeparator = Array(repeating: "line", count: 2_000).joined(separator: "\n")
        XCTAssertEqual(lockedLineCount(of: withoutTrailingSeparator), 2_000)
        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: makeMetadata(source: withoutTrailingSeparator, revision: 2),
                isPolicyEnabled: true
            ),
            .ordinary
        )

        // U+2028/U+2029 update producer logical-line counts.
        let separatorOnly = "a\u{2028}b\u{2029}"
        XCTAssertEqual(lockedLineCount(of: separatorOnly), 3)
        XCTAssertEqual(makeMetadata(source: separatorOnly, revision: 3).logicalLineCount, 3)
    }

    /// Metadata over either threshold with `isPolicyEnabled: false` selects
    /// `.largePolicyDisabledStructured` (whole-document structured route — the §10
    /// rollback seam; production default enabled, injectable test override). The base
    /// route enum has exactly three cases and no raw case: size/policy never selects raw.
    func testPolicyDisabledLargeContentIsStructuredWholeDocumentRoute() {
        let overCharacters = String(repeating: "a", count: 80_001)
        XCTAssertEqual(overCharacters.count, 80_001)
        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: makeMetadata(source: overCharacters, revision: 1),
                isPolicyEnabled: false
            ),
            .largePolicyDisabledStructured
        )

        let overLines = Array(repeating: "line", count: 2_001).joined(separator: "\n")
        XCTAssertEqual(lockedLineCount(of: overLines), 2_001)
        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: makeMetadata(source: overLines, revision: 2),
                isPolicyEnabled: false
            ),
            .largePolicyDisabledStructured
        )

        // Same metadata with the policy enabled takes the large planned route.
        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: makeMetadata(source: overCharacters, revision: 3),
                isPolicyEnabled: true
            ),
            .largePolicyEnabled
        )

        // Ordinary metadata never enters the large route regardless of policy.
        let ordinary = "**Hello** world"
        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: makeMetadata(source: ordinary, revision: 4),
                isPolicyEnabled: false
            ),
            .ordinary
        )
        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: makeMetadata(source: ordinary, revision: 5),
                isPolicyEnabled: true
            ),
            .ordinary
        )
    }

    // MARK: - O(1) metadata-only body recomputation (handoff row 5)

    /// Publish producer metadata once; recompute the route/body many times; assert zero
    /// additional `String.count`/`lineCount`/source-byte comparison calls via the injected
    /// `MarkdownSnapshotObservationProbe` and zero `indexConversionBytes`/`prefixValidationBytes`.
    /// Body observation is keyed on `MarkdownRenderObservationKey`/generation only.
    /// RED: the old renderer calls `fallbackReason(for:)`, which counts/scans on every body
    /// evaluation.
    func testRouteBodyRecomputationIsO1MetadataReadOnly() {
        let probe = MarkdownSnapshotObservationProbe()
        let box = MarkdownSourceSnapshotBox(recordingIn: probe)

        let fixture = String(repeating: "a", count: 80_001)
        XCTAssertEqual(fixture.count, 80_001)

        // Producer publishes metadata once; the one producer metadata build is measured
        // in the separate producer counters, never in planner counters.
        box.publish(source: fixture, revision: 1)
        let snapshot = box.snapshot
        XCTAssertEqual(snapshot.metadata.characterCount, 80_001)
        XCTAssertEqual(snapshot.metadata.sourceRevision, 1)
        XCTAssertEqual(snapshot.metadata.utf8Length, fixture.utf8.count)
        let producerBytesAfterPublish = probe.producerMetadataBytesExamined
        XCTAssertEqual(producerBytesAfterPublish, fixture.utf8.count)
        XCTAssertEqual(probe.bytesExamined, 0)

        // Repeated SwiftUI route/body recomputation: O(1) metadata reads and compact
        // generation-key comparisons only.
        for _ in 0..<1_000 {
            let route = MarkdownLargeContentPolicy.baseRoute(
                metadata: snapshot.metadata,
                isPolicyEnabled: true
            )
            XCTAssertEqual(route, .largePolicyEnabled)

            let key = MarkdownRenderObservationKey(generation: snapshot.generation)
            XCTAssertEqual(key.generation.streamID, snapshot.identity)
            XCTAssertEqual(key.generation.epoch, snapshot.epoch)
            XCTAssertEqual(key.generation.sourceRevision, snapshot.metadata.sourceRevision)
            XCTAssertEqual(key.generation.appendRevision, snapshot.appendRevision)
        }

        // Republishing the same revision performs no additional producer work.
        box.publish(source: fixture, revision: 1)
        XCTAssertEqual(probe.producerMetadataBytesExamined, producerBytesAfterPublish)

        // Zero additional counting/scanning/source-byte comparison anywhere in the loop.
        XCTAssertEqual(probe.stringCountCalls, 0)
        XCTAssertEqual(probe.logicalLineCountCalls, 0)
        XCTAssertEqual(probe.sourceByteComparisons, 0)
        XCTAssertEqual(probe.indexConversionBytes, 0)
        XCTAssertEqual(probe.prefixValidationBytes, 0)
        XCTAssertEqual(probe.committedPrefixBytesExamined, 0)
        XCTAssertEqual(probe.bytesExamined, 0)
    }

    // MARK: - Append admission (handoff row 6)

    /// A valid `MarkdownAppendAdmission` carries producer-issued absolute UTF-8/Character/
    /// logical-line counts; the renderer validates only O(1) generation/revision/UTF-8
    /// equations and adds no Character/line deltas. Split graphemes and split CRLF are
    /// producer-authority cases, not renderer arithmetic cases.
    func testAppendAdmissionValidatesOnlyGenerationRevisionUTF8Equations() {
        let probe = MarkdownSnapshotObservationProbe()
        let identity = MarkdownStreamIdentity(opaqueValue: "slice-a-append")

        // Fixture A: a ZWJ family split across the append boundary. Character counts are
        // NOT additive across the split (7 + 1 != 7 — the appended family is one grapheme
        // cluster under Swift semantics); UTF-8 byte counts are (13 + 18 == 31).
        let priorSource = "Hello \u{1F468}\u{200D}"
        let appendedSource = "\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let combinedSource = priorSource + appendedSource
        XCTAssertEqual(priorSource.count, 7)
        XCTAssertEqual(appendedSource.count, 1)
        XCTAssertEqual(combinedSource.count, 7)
        XCTAssertNotEqual(priorSource.count + appendedSource.count, combinedSource.count)
        XCTAssertEqual(priorSource.utf8.count + appendedSource.utf8.count, combinedSource.utf8.count)

        let prior = makeSnapshot(
            identity: identity, epoch: 1, appendRevision: 0,
            source: priorSource, sourceRevision: 1
        )
        let current = makeSnapshot(
            identity: identity, epoch: 1, appendRevision: 1,
            source: combinedSource, sourceRevision: 2
        )

        let admission = makeAdmission(
            identity: identity, epoch: 1, prior: prior, current: current,
            appendedUTF8: Data(appendedSource.utf8),
            appendedCharacterCount: 1,
            appendedLogicalLineDelta: 0
        )

        // Producer-issued absolute counts are authoritative and match exact counts.
        XCTAssertEqual(admission.priorCharacterCount, priorSource.count)
        XCTAssertEqual(admission.newCharacterCount, combinedSource.count)
        XCTAssertEqual(admission.newCharacterCount, current.metadata.characterCount)
        XCTAssertEqual(admission.newLogicalLineCount, current.metadata.logicalLineCount)

        // Renderer-validated equations: UTF-8 length equation and snapshot metadata only.
        XCTAssertEqual(admission.newUTF8Length, admission.priorUTF8Length + admission.appendedUTF8.count)
        XCTAssertEqual(admission.newUTF8Length, current.metadata.utf8Length)
        XCTAssertEqual(admission.streamID, current.identity)
        XCTAssertEqual(admission.epoch, current.epoch)
        XCTAssertEqual(admission.sourceRevision, current.metadata.sourceRevision)
        XCTAssertEqual(admission.appendRevision, current.appendRevision)

        XCTAssertTrue(
            MarkdownLargeContentPolicy.validateAppendAdmission(
                admission, prior: prior, current: current, recordingIn: probe
            )
        )

        // Fixture B: CR/LF split across the append boundary. Logical-line counts are NOT
        // additive across the split (CRLF is one line ending: 2 + 2 != 2); UTF-8 stays additive.
        let crlfIdentity = MarkdownStreamIdentity(opaqueValue: "slice-a-append-crlf")
        let crPriorSource = "alpha\r"
        let lfAppendedSource = "\nbeta"
        let crlfCombinedSource = "alpha\r\nbeta"
        XCTAssertEqual(lockedLineCount(of: crPriorSource), 2)
        XCTAssertEqual(lockedLineCount(of: lfAppendedSource), 2)
        XCTAssertEqual(lockedLineCount(of: crlfCombinedSource), 2)
        XCTAssertNotEqual(2 + 2, lockedLineCount(of: crlfCombinedSource))
        XCTAssertEqual(crPriorSource.utf8.count + lfAppendedSource.utf8.count, crlfCombinedSource.utf8.count)

        let crPrior = makeSnapshot(
            identity: crlfIdentity, epoch: 1, appendRevision: 0,
            source: crPriorSource, sourceRevision: 1
        )
        let crlfCurrent = makeSnapshot(
            identity: crlfIdentity, epoch: 1, appendRevision: 1,
            source: crlfCombinedSource, sourceRevision: 2
        )
        let crlfAdmission = makeAdmission(
            identity: crlfIdentity, epoch: 1, prior: crPrior, current: crlfCurrent,
            appendedUTF8: Data(lfAppendedSource.utf8),
            appendedCharacterCount: 5,
            appendedLogicalLineDelta: 1
        )
        XCTAssertEqual(crlfAdmission.newLogicalLineCount, 2)
        XCTAssertNotEqual(
            crlfAdmission.priorLogicalLineCount + crlfAdmission.appendedLogicalLineDelta,
            crlfAdmission.newLogicalLineCount
        )
        XCTAssertEqual(
            crlfAdmission.newUTF8Length,
            crlfAdmission.priorUTF8Length + crlfAdmission.appendedUTF8.count
        )

        XCTAssertTrue(
            MarkdownLargeContentPolicy.validateAppendAdmission(
                crlfAdmission, prior: crPrior, current: crlfCurrent, recordingIn: probe
            )
        )

        // Renderer recorded only O(1) admission facts: admission bytes equal the exact
        // appended suffixes; zero prefix/index/late-child work; planner bytesExamined is
        // zero; producer metadata counters are reported separately.
        XCTAssertEqual(
            probe.appendAdmissionBytes,
            appendedSource.utf8.count + lfAppendedSource.utf8.count
        )
        XCTAssertEqual(probe.prefixValidationBytes, 0)
        XCTAssertEqual(probe.committedPrefixBytesExamined, 0)
        XCTAssertEqual(probe.indexConversionBytes, 0)
        XCTAssertEqual(probe.lateChildPrefixBytes, 0)
        XCTAssertEqual(probe.bytesExamined, 0)
        XCTAssertEqual(
            probe.producerMetadataBytesExamined,
            combinedSource.utf8.count + crlfCombinedSource.utf8.count
        )
        XCTAssertEqual(
            probe.producerMetadataCharacterUnits,
            combinedSource.count + crlfCombinedSource.count
        )
        XCTAssertEqual(
            probe.producerMetadataLogicalLineUnits,
            lockedLineCount(of: combinedSource) + lockedLineCount(of: crlfCombinedSource)
        )
    }

    // MARK: - Absent/invalid metadata (handoff row 7)

    /// Absent token, stale revision, wrong prior length, wrong identity, and wrong epoch are
    /// each classified as a replacement — never an inferred append, never raw — and no
    /// full-prefix comparison is used to "validate" them. The replacement snapshot carries an
    /// incremented producer epoch and exactly one explicit O(N) producer metadata rebuild,
    /// measured in the separate producer counters; the route stays structured whole-document.
    func testAbsentOrInvalidMetadataIsStructuredReplacementRoute() {
        let probe = MarkdownSnapshotObservationProbe()
        let identity = MarkdownStreamIdentity(opaqueValue: "slice-a-replacement")

        let firstSource = String(repeating: "a", count: 80_001)
        let appendedSource = "suffix"
        let secondSource = firstSource + appendedSource
        let first = makeSnapshot(
            identity: identity, epoch: 7, appendRevision: 0,
            source: firstSource, sourceRevision: 1
        )
        let second = makeSnapshot(
            identity: identity, epoch: 7, appendRevision: 1,
            source: secondSource, sourceRevision: 2
        )

        // Absent token: no admission is never inferred as an append.
        XCTAssertFalse(
            MarkdownLargeContentPolicy.validateAppendAdmission(
                nil, prior: first, current: second, recordingIn: probe
            )
        )

        // Stale source revision: the admission does not advance past the prior revision.
        let staleRevision = makeAdmission(
            identity: identity, epoch: 7, prior: first, current: second,
            appendedUTF8: Data(appendedSource.utf8),
            appendedCharacterCount: 6,
            appendedLogicalLineDelta: 0,
            sourceRevision: 1
        )
        XCTAssertFalse(
            MarkdownLargeContentPolicy.validateAppendAdmission(
                staleRevision, prior: first, current: second, recordingIn: probe
            )
        )

        // Wrong prior length: the admission's prior UTF-8 length does not match the checkpoint.
        let wrongPriorLength = makeAdmission(
            identity: identity, epoch: 7, prior: first, current: second,
            appendedUTF8: Data(appendedSource.utf8),
            appendedCharacterCount: 6,
            appendedLogicalLineDelta: 0,
            priorUTF8Length: first.metadata.utf8Length + 1
        )
        XCTAssertFalse(
            MarkdownLargeContentPolicy.validateAppendAdmission(
                wrongPriorLength, prior: first, current: second, recordingIn: probe
            )
        )

        // Wrong identity: the admission claims a different stream than the snapshot.
        let wrongIdentity = MarkdownStreamIdentity(opaqueValue: "other-stream")
        let wrongIdentityAdmission = makeAdmission(
            identity: wrongIdentity, epoch: 7, prior: first, current: second,
            appendedUTF8: Data(appendedSource.utf8),
            appendedCharacterCount: 6,
            appendedLogicalLineDelta: 0
        )
        XCTAssertFalse(
            MarkdownLargeContentPolicy.validateAppendAdmission(
                wrongIdentityAdmission, prior: first, current: second, recordingIn: probe
            )
        )

        // Wrong epoch: the admission's epoch does not match the snapshot's generation.
        let wrongEpochAdmission = makeAdmission(
            identity: identity, epoch: 8, prior: first, current: second,
            appendedUTF8: Data(appendedSource.utf8),
            appendedCharacterCount: 6,
            appendedLogicalLineDelta: 0
        )
        XCTAssertFalse(
            MarkdownLargeContentPolicy.validateAppendAdmission(
                wrongEpochAdmission, prior: first, current: second, recordingIn: probe
            )
        )

        // Wrong prior append revision: the admission does not chain onto the checkpoint.
        let wrongPriorAppendRevision = makeAdmission(
            identity: identity, epoch: 7, prior: first, current: second,
            appendedUTF8: Data(appendedSource.utf8),
            appendedCharacterCount: 6,
            appendedLogicalLineDelta: 0,
            priorAppendRevision: 99
        )
        XCTAssertFalse(
            MarkdownLargeContentPolicy.validateAppendAdmission(
                wrongPriorAppendRevision, prior: first, current: second, recordingIn: probe
            )
        )

        // No rejection used a full-prefix comparison, and nothing was admitted.
        XCTAssertEqual(probe.prefixValidationBytes, 0)
        XCTAssertEqual(probe.committedPrefixBytesExamined, 0)
        XCTAssertEqual(probe.appendAdmissionBytes, 0)
        XCTAssertEqual(probe.bytesExamined, 0)

        // Replacement: the producer issues a wholesale new snapshot with an incremented epoch
        // and a fresh source revision. Any admission bound to the old generation is rejected.
        let replacementSource = String(repeating: "b", count: 80_001)
        XCTAssertEqual(replacementSource.count, 80_001)
        let replacement = makeSnapshot(
            identity: identity, epoch: 8, appendRevision: 0,
            source: replacementSource, sourceRevision: 3
        )
        XCTAssertEqual(replacement.epoch, first.epoch + 1)
        XCTAssertEqual(replacement.metadata.sourceRevision, first.metadata.sourceRevision + 2)

        let oldGenerationAdmission = makeAdmission(
            identity: identity, epoch: 7, prior: first, current: second,
            appendedUTF8: Data(appendedSource.utf8),
            appendedCharacterCount: 6,
            appendedLogicalLineDelta: 0
        )
        XCTAssertFalse(
            MarkdownLargeContentPolicy.validateAppendAdmission(
                oldGenerationAdmission, prior: first, current: replacement, recordingIn: probe
            )
        )

        // The replacement's one explicit O(N) producer metadata rebuild is measured in the
        // separate producer counters; the planner never scanned.
        let box = MarkdownSourceSnapshotBox(recordingIn: probe)
        box.publish(source: replacementSource, revision: 3)
        XCTAssertEqual(probe.producerMetadataBytesExamined, replacementSource.utf8.count)
        XCTAssertEqual(probe.producerMetadataCharacterUnits, replacementSource.count)
        XCTAssertEqual(probe.producerMetadataLogicalLineUnits, lockedLineCount(of: replacementSource))
        XCTAssertEqual(probe.bytesExamined, 0)

        // The route for the large replacement metadata is the structured whole-document
        // route; the base route enum has no raw case.
        XCTAssertEqual(
            MarkdownLargeContentPolicy.baseRoute(
                metadata: replacement.metadata,
                isPolicyEnabled: true
            ),
            .largePolicyEnabled
        )
    }

    // MARK: - Producer metadata exactness (handoff row 8)

    /// Every emitted snapshot's `characterCount` equals the exact Swift `String.count` and
    /// `logicalLineCount` equals the locked definition, across combining-mark,
    /// variation-selector, regional-indicator, ZWJ, CR/LF-split, and trailing-separator
    /// fixtures. Producer metadata bytes/units are recorded in separate counters, excluded
    /// from planner `bytesExamined`.
    func testProducerMetadataMatchesExactStringCountAndLockedLineCount() {
        let probe = MarkdownSnapshotObservationProbe()
        let box = MarkdownSourceSnapshotBox(recordingIn: probe)

        let fixtures: [(source: String, revision: UInt64, characters: Int, lines: Int)] = [
            ("e\u{0301}", 1, 1, 1), // combining mark (e + U+0301)
            ("\u{2764}\u{FE0F}", 2, 1, 1), // heart + variation selector
            ("\u{1F1F3}\u{1F1F4}", 3, 1, 1), // regional indicator pair
            ("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", 4, 1, 1), // ZWJ family
            ("alpha\r", 5, 6, 2), // CR trailing separator
            ("alpha\r\nbeta", 6, 10, 2), // CRLF is one line ending and one grapheme cluster (10 Characters, 11 UTF-8 bytes)
            ("line one\nline two\n", 7, 18, 3), // trailing LF counts a line
        ]

        for fixture in fixtures {
            box.publish(source: fixture.source, revision: fixture.revision)
            let snapshot = box.snapshot

            XCTAssertEqual(snapshot.metadata.characterCount, fixture.characters)
            XCTAssertEqual(snapshot.metadata.characterCount, fixture.source.count)
            XCTAssertEqual(snapshot.metadata.logicalLineCount, fixture.lines)
            XCTAssertEqual(snapshot.metadata.logicalLineCount, lockedLineCount(of: fixture.source))
            XCTAssertEqual(snapshot.metadata.utf8Length, fixture.source.utf8.count)
            XCTAssertEqual(snapshot.metadata.sourceRevision, fixture.revision)
            XCTAssertEqual(snapshot.metadata.isWhitespaceOnly, false)
        }

        // Producer metadata bytes/units are recorded in separate counters and are excluded
        // from planner bytesExamined; no renderer-side counting tripwire fired.
        XCTAssertEqual(
            probe.producerMetadataBytesExamined,
            fixtures.reduce(0) { $0 + $1.source.utf8.count }
        )
        XCTAssertEqual(
            probe.producerMetadataCharacterUnits,
            fixtures.reduce(0) { $0 + $1.source.count }
        )
        XCTAssertEqual(
            probe.producerMetadataLogicalLineUnits,
            fixtures.reduce(0) { $0 + $1.lines }
        )
        XCTAssertEqual(probe.bytesExamined, 0)
        XCTAssertEqual(probe.stringCountCalls, 0)
        XCTAssertEqual(probe.logicalLineCountCalls, 0)
        XCTAssertEqual(probe.sourceByteComparisons, 0)
    }
}

// MARK: - Deterministic fixture builders (producer role; contract §5.3, §5.8 item 3)

private func lockedLineCount(of text: String) -> Int {
    MarkdownHighlightPolicy.lineCount(in: text)
}

private func makeMetadata(source: String, revision: UInt64) -> MarkdownSourceMetadata {
    MarkdownSourceMetadata(
        sourceRevision: revision,
        utf8Length: source.utf8.count,
        characterCount: source.count,
        logicalLineCount: MarkdownHighlightPolicy.lineCount(in: source),
        isWhitespaceOnly: source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    )
}

private func makeSnapshot(
    identity: MarkdownStreamIdentity,
    epoch: UInt64,
    appendRevision: UInt64,
    source: String,
    sourceRevision: UInt64
) -> MarkdownContentSnapshot {
    MarkdownContentSnapshot(
        identity: identity,
        epoch: epoch,
        appendRevision: appendRevision,
        source: source,
        utf8Buffer: Data(source.utf8),
        metadata: makeMetadata(source: source, revision: sourceRevision)
    )
}

/// Builds an admission that is valid unless an override is supplied. The renderer validates
/// only generation/revision/UTF-8 equations; Character/line values are audit data carried
/// by the admission, never operands in renderer-side additive equations (§3.6).
private func makeAdmission(
    identity: MarkdownStreamIdentity,
    epoch: UInt64,
    prior: MarkdownContentSnapshot,
    current: MarkdownContentSnapshot,
    appendedUTF8: Data,
    appendedCharacterCount: Int,
    appendedLogicalLineDelta: Int,
    sourceRevision: UInt64? = nil,
    appendRevision: UInt64? = nil,
    priorSourceRevision: UInt64? = nil,
    priorAppendRevision: UInt64? = nil,
    priorUTF8Length: Int? = nil,
    newUTF8Length: Int? = nil
) -> MarkdownAppendAdmission {
    MarkdownAppendAdmission(
        streamID: identity,
        epoch: epoch,
        priorSourceRevision: priorSourceRevision ?? prior.metadata.sourceRevision,
        sourceRevision: sourceRevision ?? current.metadata.sourceRevision,
        priorAppendRevision: priorAppendRevision ?? prior.appendRevision,
        appendRevision: appendRevision ?? current.appendRevision,
        priorUTF8Length: priorUTF8Length ?? prior.metadata.utf8Length,
        newUTF8Length: newUTF8Length ?? current.metadata.utf8Length,
        priorCharacterCount: prior.metadata.characterCount,
        newCharacterCount: current.metadata.characterCount,
        priorLogicalLineCount: prior.metadata.logicalLineCount,
        newLogicalLineCount: current.metadata.logicalLineCount,
        appendedUTF8: appendedUTF8,
        appendedCharacterCount: appendedCharacterCount,
        appendedLogicalLineDelta: appendedLogicalLineDelta,
        producerMetadataCost: MarkdownProducerMetadataCost(
            sourceBytesExamined: current.source.utf8.count,
            characterUnitsExamined: current.source.count,
            logicalLineUnitsExamined: current.metadata.logicalLineCount
        )
    )
}
