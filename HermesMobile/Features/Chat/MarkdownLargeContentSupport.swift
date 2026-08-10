//  MarkdownLargeContentSupport.swift
//  HermesMobile
//
//  #17 Slice A GREEN (route policy): producer metadata, O(1) base-route policy,
//  append admission, owner-lived snapshot box, and observation probe
//  (contract §1.1, §3.1, §3.3, §3.6, §5.3; executable handoff §6). Slice 0
//  registered this file in the app target. The scanner/plan/coordinator
//  machinery (LazyVStack, plan states, generation-keyed dispositions) is
//  deferred to slices D/F.

import Foundation

/// Namespace placeholder for large-content Markdown support (issue #17).
/// The producer metadata types and the O(1) route seam live at file scope;
/// later slices add the scanner/plan/coordinator machinery.
public enum MarkdownLargeContentSupport {}

// MARK: - Producer metadata

/// Producer-issued metadata for one exact source snapshot. Every count is an
/// absolute value computed by the producer at ingestion time; the renderer
/// reads these integers only and never re-derives counts from the source.
/// A `sourceRevision` of 0 marks the never-produced (absent) sentinel.
struct MarkdownSourceMetadata {
    let sourceRevision: UInt64
    let utf8Length: Int
    let characterCount: Int
    let logicalLineCount: Int
    let isWhitespaceOnly: Bool

    init(
        sourceRevision: UInt64,
        utf8Length: Int,
        characterCount: Int,
        logicalLineCount: Int,
        isWhitespaceOnly: Bool
    ) {
        self.sourceRevision = sourceRevision
        self.utf8Length = utf8Length
        self.characterCount = characterCount
        self.logicalLineCount = logicalLineCount
        self.isWhitespaceOnly = isWhitespaceOnly
    }
}

/// Stable render identity for one markdown stream/source. Opaque to the
/// renderer: compared for equality only, never decomposed.
struct MarkdownStreamIdentity: Equatable, Sendable {
    let opaqueValue: String

    init(opaqueValue: String) {
        self.opaqueValue = opaqueValue
    }
}

/// One exact producer snapshot: the source, its producer-issued UTF-8 buffer,
/// and the producer metadata. Deliberately NOT Equatable on the whole source —
/// body observation compares only generation-key fields and metadata integers.
struct MarkdownContentSnapshot {
    let identity: MarkdownStreamIdentity
    let epoch: UInt64
    let appendRevision: UInt64
    let source: String
    let utf8Buffer: Data
    let metadata: MarkdownSourceMetadata

    init(
        identity: MarkdownStreamIdentity,
        epoch: UInt64,
        appendRevision: UInt64,
        source: String,
        utf8Buffer: Data,
        metadata: MarkdownSourceMetadata
    ) {
        self.identity = identity
        self.epoch = epoch
        self.appendRevision = appendRevision
        self.source = source
        self.utf8Buffer = utf8Buffer
        self.metadata = metadata
    }

    /// Compact O(1) generation key; renderer body observation is keyed on
    /// this only (never on source bytes).
    var generation: MarkdownContentGeneration {
        MarkdownContentGeneration(
            streamID: identity,
            epoch: epoch,
            sourceRevision: metadata.sourceRevision,
            appendRevision: appendRevision
        )
    }
}

/// Compact O(1) generation key: stream identity, epoch, source revision, and
/// append revision. Two snapshots with equal generations describe the same
/// producer state; no source bytes participate in the comparison.
struct MarkdownContentGeneration {
    let streamID: MarkdownStreamIdentity
    let epoch: UInt64
    let sourceRevision: UInt64
    let appendRevision: UInt64

    init(
        streamID: MarkdownStreamIdentity,
        epoch: UInt64,
        sourceRevision: UInt64,
        appendRevision: UInt64
    ) {
        self.streamID = streamID
        self.epoch = epoch
        self.sourceRevision = sourceRevision
        self.appendRevision = appendRevision
    }
}

/// Key for renderer body observation: generation fields only, so repeated
/// body recomputation performs zero source-byte comparisons.
struct MarkdownRenderObservationKey {
    let generation: MarkdownContentGeneration

    init(generation: MarkdownContentGeneration) {
        self.generation = generation
    }
}

/// Producer cost of one explicit metadata build. Reported in the separate
/// producer counters, never in the planner/renderer `bytesExamined` counter.
struct MarkdownProducerMetadataCost {
    let sourceBytesExamined: Int
    let characterUnitsExamined: Int
    let logicalLineUnitsExamined: Int

    init(
        sourceBytesExamined: Int,
        characterUnitsExamined: Int,
        logicalLineUnitsExamined: Int
    ) {
        self.sourceBytesExamined = sourceBytesExamined
        self.characterUnitsExamined = characterUnitsExamined
        self.logicalLineUnitsExamined = logicalLineUnitsExamined
    }
}

// MARK: - Append admission

/// Producer-issued append admission. Carries the absolute counts of the prior
/// and new snapshots plus the appended suffix bytes; the renderer validates
/// only O(1) generation/revision/UTF-8 equations (see
/// `MarkdownLargeContentPolicy.validateAppendAdmission`). Character and
/// logical-line values are audit data carried by the admission — producer
/// authority, never operands in renderer-side additive equations.
struct MarkdownAppendAdmission {
    let streamID: MarkdownStreamIdentity
    let epoch: UInt64
    let priorSourceRevision: UInt64
    let sourceRevision: UInt64
    let priorAppendRevision: UInt64
    let appendRevision: UInt64
    let priorUTF8Length: Int
    let newUTF8Length: Int
    let priorCharacterCount: Int
    let newCharacterCount: Int
    let priorLogicalLineCount: Int
    let newLogicalLineCount: Int
    let appendedUTF8: Data
    let appendedCharacterCount: Int
    let appendedLogicalLineDelta: Int
    let producerMetadataCost: MarkdownProducerMetadataCost

    init(
        streamID: MarkdownStreamIdentity,
        epoch: UInt64,
        priorSourceRevision: UInt64,
        sourceRevision: UInt64,
        priorAppendRevision: UInt64,
        appendRevision: UInt64,
        priorUTF8Length: Int,
        newUTF8Length: Int,
        priorCharacterCount: Int,
        newCharacterCount: Int,
        priorLogicalLineCount: Int,
        newLogicalLineCount: Int,
        appendedUTF8: Data,
        appendedCharacterCount: Int,
        appendedLogicalLineDelta: Int,
        producerMetadataCost: MarkdownProducerMetadataCost
    ) {
        self.streamID = streamID
        self.epoch = epoch
        self.priorSourceRevision = priorSourceRevision
        self.sourceRevision = sourceRevision
        self.priorAppendRevision = priorAppendRevision
        self.appendRevision = appendRevision
        self.priorUTF8Length = priorUTF8Length
        self.newUTF8Length = newUTF8Length
        self.priorCharacterCount = priorCharacterCount
        self.newCharacterCount = newCharacterCount
        self.priorLogicalLineCount = priorLogicalLineCount
        self.newLogicalLineCount = newLogicalLineCount
        self.appendedUTF8 = appendedUTF8
        self.appendedCharacterCount = appendedCharacterCount
        self.appendedLogicalLineDelta = appendedLogicalLineDelta
        self.producerMetadataCost = producerMetadataCost
    }
}

// MARK: - Base route

/// Base size/policy route. Exactly three cases; there is no raw case —
/// size/policy never selects the plain `Text` fallback. `.largePolicyEnabled`
/// is the planned large route (LazyVStack/coordinator machinery lands in
/// slices D/F); `.largePolicyDisabledStructured` is the §10 rollback seam and
/// the absent/invalid-metadata route — both render the structured
/// whole-document `ChatMarkdownView` in Slice A.
enum MarkdownLargeContentBaseRoute: Equatable {
    case ordinary
    case largePolicyEnabled
    case largePolicyDisabledStructured
}

// MARK: - Policy

/// O(1) size/policy route seam — the only size/policy route seam. The
/// generation-keyed plan disposition (`largeContentRoute(...planState:...)`)
/// remains a separate seam owned by the coordinator in slices D/F.
enum MarkdownLargeContentPolicy {
    /// Strict `>` character threshold: 80_000 is ordinary, 80_001 is large.
    static let maxMarkdownCharacterCount = 80_000
    /// Strict `>` logical-line threshold (locked line definition,
    /// `MarkdownHighlightPolicy.lineCount(in:)`): 2_000 is ordinary,
    /// 2_001 is large.
    static let maxMarkdownLineCount = 2_000

    /// Selects the base route from producer metadata only — O(1), reading only
    /// the metadata integers (`utf8Length`/`characterCount`/
    /// `logicalLineCount`/`isWhitespaceOnly`/`sourceRevision`), never
    /// re-deriving counts from the source. Absent (never-produced revision 0)
    /// or invalid metadata cannot prove the content is small, so it takes the
    /// structured whole-document route. Over-threshold metadata with the
    /// policy disabled takes `.largePolicyDisabledStructured` (the §10
    /// rollback seam); ordinary metadata is `.ordinary` regardless of policy.
    static func baseRoute(
        metadata: MarkdownSourceMetadata,
        isPolicyEnabled: Bool
    ) -> MarkdownLargeContentBaseRoute {
        guard metadata.sourceRevision > 0,
              metadata.utf8Length >= 0,
              metadata.characterCount >= 0,
              metadata.logicalLineCount >= 0 else {
            return .largePolicyDisabledStructured
        }

        let isLarge = metadata.characterCount > maxMarkdownCharacterCount
            || metadata.logicalLineCount > maxMarkdownLineCount
        guard isLarge else { return .ordinary }
        return isPolicyEnabled ? .largePolicyEnabled : .largePolicyDisabledStructured
    }

    /// Validates an append admission against O(1) generation/revision/UTF-8
    /// equations only (contract §3.6): stream identity/epoch match both
    /// checkpoints, prior source/append revisions and the prior UTF-8 length
    /// match the prior snapshot, revisions advance monotonically, and the new
    /// UTF-8 length equals both `prior + appended` and the current snapshot's
    /// metadata. Character and logical-line deltas are never validated, and no
    /// source bytes are compared (`content.utf8.count`/`hasPrefix`/`memcmp`/
    /// `Data.starts(with:)` are never used). A nil admission or nil prior is a
    /// replacement — never an inferred append. Valid admissions record their
    /// exact suffix byte count plus the producer cost; rejected admissions
    /// record nothing.
    static func validateAppendAdmission(
        _ admission: MarkdownAppendAdmission?,
        prior: MarkdownContentSnapshot?,
        current: MarkdownContentSnapshot,
        recordingIn probe: MarkdownSnapshotObservationProbe
    ) -> Bool {
        guard let admission, let prior else { return false }
        guard admission.streamID == current.identity,
              admission.streamID == prior.identity,
              admission.epoch == current.epoch,
              admission.epoch == prior.epoch,
              admission.priorSourceRevision == prior.metadata.sourceRevision,
              admission.sourceRevision == current.metadata.sourceRevision,
              admission.sourceRevision > admission.priorSourceRevision,
              admission.priorAppendRevision == prior.appendRevision,
              admission.appendRevision == current.appendRevision,
              admission.appendRevision > admission.priorAppendRevision,
              admission.priorUTF8Length == prior.metadata.utf8Length,
              admission.newUTF8Length == admission.priorUTF8Length + admission.appendedUTF8.count,
              admission.newUTF8Length == current.metadata.utf8Length
        else {
            return false
        }

        probe.recordAppendAdmission(bytes: admission.appendedUTF8.count)
        probe.recordProducerCost(admission.producerMetadataCost)
        return true
    }
}

// MARK: - Observation probe

/// Renderer/planner observation instrument (injected). Counters fall into
/// three groups:
/// - planner/renderer byte counters — must stay 0 for Slice A's O(1) routes
///   (`bytesExamined`, `indexConversionBytes`, `prefixValidationBytes`,
///   `committedPrefixBytesExamined`, `lateChildPrefixBytes`);
/// - tripwire counters — `String.count`/`lineCount`/source-byte comparison
///   calls that must stay 0 across repeated body recomputation;
/// - producer metadata counters — the producer's one explicit O(N) metadata
///   build per new revision is reported here, never in planner counters.
///
/// `@unchecked Sendable`: mutable by design (an observation accumulator);
/// accessed only within a single isolation domain in practice.
final class MarkdownSnapshotObservationProbe: @unchecked Sendable {
    private(set) var appendAdmissionBytes = 0
    private(set) var prefixValidationBytes = 0
    private(set) var committedPrefixBytesExamined = 0
    private(set) var indexConversionBytes = 0
    private(set) var lateChildPrefixBytes = 0
    private(set) var bytesExamined = 0
    private(set) var stringCountCalls = 0
    private(set) var logicalLineCountCalls = 0
    private(set) var sourceByteComparisons = 0
    private(set) var producerMetadataBytesExamined = 0
    private(set) var producerMetadataCharacterUnits = 0
    private(set) var producerMetadataLogicalLineUnits = 0

    init() {}

    /// Records a valid append admission's exact suffix byte count.
    func recordAppendAdmission(bytes: Int) {
        appendAdmissionBytes += bytes
    }

    /// Records the producer's explicit metadata-build cost into the separate
    /// producer counters (never into planner `bytesExamined`).
    func recordProducerMetadata(bytes: Int, characters: Int, lines: Int) {
        producerMetadataBytesExamined += bytes
        producerMetadataCharacterUnits += characters
        producerMetadataLogicalLineUnits += lines
    }

    /// Records the producer cost carried by a valid admission.
    func recordProducerCost(_ cost: MarkdownProducerMetadataCost) {
        producerMetadataBytesExamined += cost.sourceBytesExamined
        producerMetadataCharacterUnits += cost.characterUnitsExamined
        producerMetadataLogicalLineUnits += cost.logicalLineUnitsExamined
    }
}

// MARK: - Snapshot box

/// Owner-lived snapshot box for static sources. The owner (e.g. a renderer)
/// publishes a source once per revision; republishing the same revision is a
/// no-op, so repeated body recomputation never re-counts or re-scans the
/// source. `snapshot` is O(1) once published; before the first publish it
/// carries the absent sentinel (`sourceRevision` 0), which the policy
/// classifies as `.largePolicyDisabledStructured`.
///
/// `@unchecked Sendable`: mutable by design (producer-owned box); accessed
/// only within a single isolation domain in practice.
final class MarkdownSourceSnapshotBox: @unchecked Sendable {
    private let probe: MarkdownSnapshotObservationProbe
    private let identity: MarkdownStreamIdentity
    private var stored: MarkdownContentSnapshot
    private var lastPublishedRevision: UInt64

    init(recordingIn probe: MarkdownSnapshotObservationProbe) {
        self.probe = probe
        self.identity = MarkdownStreamIdentity(opaqueValue: UUID().uuidString)
        self.lastPublishedRevision = 0
        self.stored = MarkdownContentSnapshot(
            identity: identity,
            epoch: 0,
            appendRevision: 0,
            source: "",
            utf8Buffer: Data(),
            metadata: MarkdownSourceMetadata(
                sourceRevision: 0,
                utf8Length: 0,
                characterCount: 0,
                logicalLineCount: 0,
                isWhitespaceOnly: true
            )
        )
    }

    /// O(1) accessor; never re-derives counts.
    var snapshot: MarkdownContentSnapshot { stored }

    /// Publishes a new producer snapshot, rebuilding metadata only when the
    /// revision actually changes. The one explicit O(N) producer metadata
    /// build per new revision (exact `String.count`, the locked line count,
    /// and the UTF-8 byte count) is recorded in the probe's producer counters.
    func publish(source: String, revision: UInt64) {
        guard revision != lastPublishedRevision else { return }
        lastPublishedRevision = revision

        let metadata = MarkdownSourceMetadata(
            sourceRevision: revision,
            utf8Length: source.utf8.count,
            characterCount: source.count,
            logicalLineCount: MarkdownHighlightPolicy.lineCount(in: source),
            isWhitespaceOnly: source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        probe.recordProducerMetadata(
            bytes: metadata.utf8Length,
            characters: metadata.characterCount,
            lines: metadata.logicalLineCount
        )
        stored = MarkdownContentSnapshot(
            identity: identity,
            epoch: 1,
            appendRevision: 0,
            source: source,
            utf8Buffer: Data(source.utf8),
            metadata: metadata
        )
    }
}
