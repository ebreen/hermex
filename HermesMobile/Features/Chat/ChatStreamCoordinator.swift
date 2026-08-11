import CryptoKit
import Foundation
import Observation
import OSLog
import SwiftData

private let chatStreamCoordinatorLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
    category: "ChatStreamCoordinator"
)

struct ChatStreamCoordinatorTiming: Equatable {
    let checkingInterval: TimeInterval
    let reconnectInterval: TimeInterval
    let runningToolReconnectInterval: TimeInterval
    let statusPollCooldown: TimeInterval
    // Transport quieter than this is treated as provably alive; must sit above
    // the server's ~5s SSE heartbeat cadence and below reconnectInterval (#227).
    let transportFreshInterval: TimeInterval

    static let standard = ChatStreamCoordinatorTiming(
        checkingInterval: 5,
        reconnectInterval: 18,
        runningToolReconnectInterval: 25,
        statusPollCooldown: 4,
        transportFreshInterval: 12
    )
}

struct ChatStreamLoadPreparation: Equatable {
    let activeStreamIDBeforeLoad: String?
    let shouldPrepareSuspendedStreamResume: Bool
}

/// Identity of one logical run of a chat stream. A replacement run for the
/// same stream ID is a new logical generation: the identity changes even
/// though the stream ID does not (#18 Slice 1). The logical generation is
/// persisted through `ChatRunGenerationStore` so cross-relaunch reconnect
/// dedupes deterministically (#18 §473).
struct ChatRunIdentity: Equatable, Hashable {
    let sessionID: String
    let streamID: String
    let generation: Int

    /// Slice 3/4 compatibility alias: the logical run generation.
    var logicalGeneration: Int { generation }
}

/// The outcome of a finalized chat run, committed exactly once by the
/// centralized terminal transition. The FIRST valid terminal candidate for a
/// run wins; every later candidate is a no-op (#18 Slice 2). The one-byte
/// stable code is part of the run-status-v1 terminal event key encoding
/// (#18 §471): completed = 0x01, failed = 0x02, cancelled = 0x03.
enum ChatRunTerminalOutcome: Equatable, Hashable {
    case completed
    case cancelled
    case failed

    /// The single outcome byte in the canonical run-status-v1 byte stream.
    var fixedV1Code: UInt8 {
        switch self {
        case .completed: return 0x01
        case .failed: return 0x02
        case .cancelled: return 0x03
        }
    }
}

/// Stable identity of one terminal transcript event (#18 §446-471): the
/// complete logical run identity plus the winning outcome. The `messageID` is
/// `run-status-v1-` + lowercase-hex SHA-256 over the contract's exact
/// canonical bytes — domain `hermex.chat.run-status-terminal/v1\0`, 4-byte BE
/// session-byte length + session UTF-8, 4-byte BE stream-byte length + stream
/// UTF-8, 8-byte BE logical generation, and one outcome byte. The encoding is
/// fixed and versioned; `connectionGeneration`, timestamps, UUIDs, localized
/// text, and callback names are excluded, so reconnect/replay produces the
/// same ID while a same-stream replacement (new logical generation) or a
/// different outcome produces a different one.
struct ChatRunStatusTerminalEventKey: Hashable {
    let identity: ChatRunIdentity
    let outcome: ChatRunTerminalOutcome

    var messageID: String {
        let domain = Data("hermex.chat.run-status-terminal/v1".utf8) + Data([0])
        let session = Data(identity.sessionID.utf8)
        let stream = Data(identity.streamID.utf8)
        var bytes = domain
        bytes.append(contentsOf: UInt32(session.count).bigEndianBytes)
        bytes.append(session)
        bytes.append(contentsOf: UInt32(stream.count).bigEndianBytes)
        bytes.append(stream)
        bytes.append(contentsOf: UInt64(identity.generation).bigEndianBytes)
        bytes.append(outcome.fixedV1Code)
        let digest = SHA256.hash(data: bytes)
        return "run-status-v1-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// One finalized run's complete terminal commit: the logical run identity, the
/// winning outcome, the stable event key, and the server session/stream IDs
/// the event is cached under (#18 §500-509). Constructed exactly once by the
/// centralized terminal transition and delivered through
/// `streamCoordinatorDidCommitTerminal(commit:)`.
struct ChatRunTerminalCommit: Equatable, Hashable {
    let identity: ChatRunIdentity
    let outcome: ChatRunTerminalOutcome
    let eventKey: ChatRunStatusTerminalEventKey
    let serverSessionID: String
    let serverStreamID: String
}

/// One persisted logical-generation record for a `(sessionID, streamID)` run
/// (#18 §473): `lastIssuedGeneration` is monotonic across replacements and
/// relaunches; `activeGeneration` is the exact generation of the run the
/// server currently reports active. A terminal commit retains
/// `lastIssuedGeneration` and clears only `activeGeneration`. Writes replace
/// the whole record atomically.
struct ChatRunGenerationRecord: Equatable, Codable {
    let sessionID: String
    let streamID: String
    let lastIssuedGeneration: Int
    let activeGeneration: Int?
}

/// Persistence seam for the logical run generation (#18 §473): the coordinator
/// persists max(lastIssuedGeneration, current) + 1 BEFORE opening a
/// same-stream replacement connection, restores the exact persisted active
/// generation on reconnect/relaunch, and clears only the active generation on
/// terminal commit. Production uses the UserDefaults-backed
/// `UserDefaultsRunGenerationStore`; tests inject in-memory implementations.
protocol ChatRunGenerationStore {
    func record(for sessionID: String, streamID: String) -> ChatRunGenerationRecord?
    func replace(_ record: ChatRunGenerationRecord)
}

/// In-memory `ChatRunGenerationStore` for tests and previews: whole-record
/// replacement keyed by `(sessionID, streamID)`.
final class InMemoryRunGenerationStore: ChatRunGenerationStore {
    private var records: [String: ChatRunGenerationRecord] = [:]

    func record(for sessionID: String, streamID: String) -> ChatRunGenerationRecord? {
        records[Self.key(sessionID: sessionID, streamID: streamID)]
    }

    func replace(_ record: ChatRunGenerationRecord) {
        records[Self.key(sessionID: record.sessionID, streamID: record.streamID)] = record
    }

    private static func key(sessionID: String, streamID: String) -> String {
        "\(sessionID)|\(streamID)"
    }
}

/// Production `ChatRunGenerationStore` backed by `UserDefaults` under the
/// fixed namespace `hermex.chat.run-status-generation.v1` (#18 §473). Each
/// `(sessionID, streamID)` key holds exactly one complete JSON record;
/// `replace` swaps it atomically.
struct UserDefaultsRunGenerationStore: ChatRunGenerationStore {
    private static let namespace = "hermex.chat.run-status-generation.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func record(for sessionID: String, streamID: String) -> ChatRunGenerationRecord? {
        guard let data = defaults.data(forKey: Self.key(sessionID: sessionID, streamID: streamID)) else {
            return nil
        }
        return try? JSONDecoder().decode(ChatRunGenerationRecord.self, from: data)
    }

    func replace(_ record: ChatRunGenerationRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key(sessionID: record.sessionID, streamID: record.streamID))
    }

    private static func key(sessionID: String, streamID: String) -> String {
        "\(namespace)|\(sessionID)|\(streamID)"
    }
}

/// The identity-keyed persistence handoff the ViewModel sends to the injected
/// `ChatTerminalCacheWriter` AFTER appending the stable local notice: the
/// complete commit, the immutable post-append message snapshot, and the
/// monotonic handoff generation (#18 §521). One handoff per terminal event key;
/// a failed write retains the exact handoff for retry.
struct ChatTerminalPersistenceHandoff {
    let commit: ChatRunTerminalCommit
    let postAppendMessages: [ChatMessage]
    let handoffGeneration: Int
}

/// Persistence seam for terminal commits (#18 §522-523). The session-scoped
/// ViewModel is the sole owner of `pendingTerminalPersistenceByKey` and
/// routes exactly one keyed handoff per attempt through this writer; a
/// throwing writer keeps the handoff pending for retry, records the error
/// against that key, and never re-appends the local notice. Production
/// injects the CacheStore-backed writer; unit tests inject recording/throwing
/// spies.
protocol ChatTerminalCacheWriter {
    func persistPendingTerminalPersistence(
        for handoff: ChatTerminalPersistenceHandoff,
        modelContext: ModelContext?
    ) throws
}

private extension FixedWidthInteger {
    /// Big-endian byte representation of this integer, used by the canonical
    /// run-status-v1 terminal event key encoding (#18 §471).
    var bigEndianBytes: Data {
        var value = bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

/// Identity of one connection of a chat run: the logical run identity plus
/// the connection generation. A replay/reconnect start keeps the logical
/// generation and bumps only the connection generation; a replacement run
/// bumps both (#18 Slice 3).
struct ChatRunConnectionIdentity: Equatable, Sendable {
    let streamID: String
    let logicalGeneration: Int
    let connectionGeneration: Int
}

/// Identity token for a recovery transcript load (#18 Slice 4). Captured
/// when a run connection starts; a transcript load that completes after the
/// run was replaced or finalized is stale and must not mutate the
/// replacement run.
struct ChatRunRecoveryLoadToken: Equatable, Sendable {
    let identity: ChatRunConnectionIdentity
}

/// Resolution of the server's recovery journal for an inactive stream
/// (#18 Slice 4). The journal is the ONLY terminal authority: `.terminal`
/// commits the documented outcome; `.nonTerminal` keeps the run suspended
/// and never infers completion from a refreshed transcript.
enum ChatRunRecoveryJournalResolution: Equatable {
    case terminal(ChatRunTerminalOutcome)
    case nonTerminal(reason: String)
}

/// Exactly-once cancellation acceptance ticket (#18 Slice 3): the accepted
/// cancel's connection identity and a stable message ID. Reference type so
/// the consuming boundary (view model / feedback helper) and the
/// coordinator share the consumed state; all mutation happens on the main
/// actor.
final class ChatCancellationTicket: @unchecked Sendable {
    let identity: ChatRunConnectionIdentity
    let messageID: String
    private(set) var isConsumed = false

    init(identity: ChatRunConnectionIdentity, messageID: String) {
        self.identity = identity
        self.messageID = messageID
    }

    /// Consumes the ticket exactly once: the first call returns true, every
    /// later call returns false.
    @discardableResult
    func consume() -> Bool {
        guard !isConsumed else { return false }
        isConsumed = true
        return true
    }
}

/// Outcome of a cancel request, resolved against the run identity captured
/// before the request was sent (#18 Slice 3). A superseded request (the run
/// was replaced or finalized while the request was in flight) is `.stale`
/// regardless of the server's response: it must never surface as a current
/// success, rejection, or error.
enum ChatCancelDisposition: Equatable, Sendable {
    case accepted(ChatCancellationTicket)
    case stale
    case rejected(ChatCancelResponse)
    case thrown(Error)
    case unconfirmed

    static func == (lhs: ChatCancelDisposition, rhs: ChatCancelDisposition) -> Bool {
        switch (lhs, rhs) {
        case (.accepted(let lhsTicket), .accepted(let rhsTicket)):
            return lhsTicket === rhsTicket
        case (.stale, .stale):
            return true
        case (.rejected(let lhsResponse), .rejected(let rhsResponse)):
            return lhsResponse == rhsResponse
        case (.thrown(let lhsError), .thrown(let rhsError)):
            return String(reflecting: lhsError) == String(reflecting: rhsError)
        case (.unconfirmed, .unconfirmed):
            return true
        default:
            return false
        }
    }
}

extension ChatCancelResponse: Sendable {}

protocol ChatStreamCoordinatorDelegate: AnyObject {
    var streamCoordinatorSessionID: String? { get }
    var streamCoordinatorDisplayTitle: String { get }
    var streamCoordinatorHasRunningLiveToolCall: Bool { get }
    var streamCoordinatorHasPendingPrompt: Bool { get }
    var streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser: Bool { get }
    var streamCoordinatorStreamingAssistantMessageID: String? { get set }

    func streamCoordinatorLoadMessages(modelContext: ModelContext?) async
    func streamCoordinatorLatestAssistantMessageID() -> String?
    func streamCoordinatorStartAuxiliaryMonitoring()
    func streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: Bool)
    func streamCoordinatorSaveSnapshotIfNeeded()
    @discardableResult
    func streamCoordinatorRestoreSnapshotIfAvailable(streamID: String) -> String?
    func streamCoordinatorRemoveSnapshot(streamID: String?)
    func streamCoordinatorFlushPinnedLocalNoticesToTranscript()
    func streamCoordinatorDrainQueuedSlashMessageIfIdle()
    func streamCoordinatorRefreshCompletedResponseTitleIfNeeded()
    func streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: Bool)
    func streamCoordinatorDidFinishStream()
    func streamCoordinatorDidReceiveErrorMessage(_ message: String)
    func streamCoordinatorDidReceiveRecoveryError(_ error: Error)
    func streamCoordinatorDidStartConnection(isReplay: Bool)
    func streamCoordinatorDidResetRecoveryState()

    @discardableResult
    func streamCoordinatorAppendToken(_ text: String) -> Bool
    @discardableResult
    func streamCoordinatorAppendInterimAssistant(_ payload: InterimAssistantStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorAppendReasoning(_ text: String) -> Bool
    @discardableResult
    func streamCoordinatorAppendToolCall(_ payload: ToolStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorCompleteToolCall(_ payload: ToolStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorUpdateTitle(_ payload: TitleStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorApplyDone(_ payload: DoneStreamEvent) -> Bool
    func streamCoordinatorApplyApprovalUpdate(_ update: ApprovalPendingResponse)
    func streamCoordinatorApplyClarificationUpdate(_ update: ClarificationPendingResponse)
    @discardableResult
    func streamCoordinatorEnqueuePendingSteerLeftover(_ text: String) -> Bool

    /// Centralized terminal-event callback (#18 Slice 2): invoked exactly
    /// once per committed terminal transition with the winning outcome and
    /// the finalized run's identity. Conformers that do not observe terminal
    /// transitions inherit the default no-op implementation.
    func streamCoordinatorDidCommitTerminalOutcome(
        _ outcome: ChatRunTerminalOutcome,
        identity: ChatRunIdentity
    )

    /// Terminal-commit callback (#18 Slice 5, v7): invoked EXACTLY once by the
    /// centralized terminal transition after the first-valid compare-and-set,
    /// with the complete run commit (identity, outcome, stable event key,
    /// server IDs). Even if invoked for an already-terminal state, the
    /// conformer performs no second commit.
    func streamCoordinatorDidCommitTerminal(_ commit: ChatRunTerminalCommit)
}

extension ChatStreamCoordinatorDelegate {
    /// Default no-op: only observers that care about terminal transitions
    /// (e.g. the coordinator test spy) need to implement this (#18 Slice 2).
    func streamCoordinatorDidCommitTerminalOutcome(
        _ outcome: ChatRunTerminalOutcome,
        identity: ChatRunIdentity
    ) {}

    /// Default no-op (#18 Slice 5): only the view model persists terminal
    /// commits (append stable event, keyed handoff, one-writer retry).
    func streamCoordinatorDidCommitTerminal(_ commit: ChatRunTerminalCommit) {}
}

@MainActor
@Observable
final class ChatStreamCoordinator {
    @ObservationIgnored private weak var delegate: (any ChatStreamCoordinatorDelegate)?
    private let client: APIClient
    private let streamClient: SSEStreamingClient
    private let liveActivityManager: any AgentLiveActivityManaging
    private let timing: ChatStreamCoordinatorTiming
    private var showsLiveActivityResponseExcerpts: Bool

    private(set) var activeStreamID: String?
    private(set) var recoveryState: ActiveStreamRecoveryState = .idle
    private(set) var isConnectionSuspended = false
    private(set) var hasCompletedCurrentResponse = false
    private(set) var lastEventID: String?
    private(set) var lastProgressDate: Date?
    private(set) var lastTransportActivityDate: Date?
    private(set) var liveTokensPerSecond: Double?
    private var lastRecoveryStatusCheckDate: Date?
    private(set) var isReplayConnection = false
    // Bumped whenever the active run starts or finalizes. Captured before an async
    // transcript load so a concurrent cancel/completion during the load can't be
    // double-finalized (PR #266 review #2).
    private var runGeneration = 0

    // Connection-scoped identity counters (#18 Slice 3). The logical run
    // generation bumps when a NEW logical run starts; the connection
    // generation bumps on every connection — a replay/reconnect start keeps
    // the logical generation and changes only the connection generation.
    // The logical generation is persisted through `runGenerationStore` so a
    // same-stream replacement allocates max(lastIssued, current) + 1 BEFORE
    // the connection opens and a reconnect/relaunch restores the exact
    // persisted active generation (#18 §473).
    private var logicalRunGeneration = 0
    private var connectionGeneration = 0
    private let runGenerationStore: any ChatRunGenerationStore

    /// Stream ID whose persisted `activeGeneration` the next non-replay
    /// `start` must RESTORE instead of allocating (#18 §473). Set when an
    /// authoritative session load (or reconnect status) confirms the same
    /// non-empty active stream ID the store records as active; consumed by
    /// the next `start` for that stream.
    private var pendingResumeStreamID: String?

    /// Identity of the run finalized by an accepted `.done` (or a transcript
    /// refresh). The completing connection's own terminal events arrive AFTER
    /// finalization — when `runIdentity` is already nil — and must still pass
    /// the generation fence so `finishStream()` (title refresh, Live Activity
    /// teardown) runs for the completed run. Every other (superseded)
    /// connection stays fenced (#18 Slice 1).
    private var completedRunIdentity: ChatRunIdentity?

    /// The current logical run identity, or nil while no run is active.
    /// Derived from the active stream ID, the delegate session ID, and the
    /// persisted logical generation so it stays consistent with every
    /// start/finalize transition. Each connection captures its own identity
    /// at creation; a callback whose captured identity no longer matches this
    /// value is fenced before any mutation (#18 Slice 1).
    var runIdentity: ChatRunIdentity? {
        guard let activeStreamID else { return nil }
        return ChatRunIdentity(
            sessionID: delegate?.streamCoordinatorSessionID ?? "",
            streamID: activeStreamID,
            generation: logicalRunGeneration
        )
    }

    /// The current connection-scoped run identity, or nil while no run is
    /// active. Adds the connection generation to `runIdentity` so a delayed
    /// cancel result can distinguish a superseded connection from the
    /// current one (#18 Slice 3).
    var runConnectionIdentity: ChatRunConnectionIdentity? {
        guard let activeStreamID else { return nil }
        return ChatRunConnectionIdentity(
            streamID: activeStreamID,
            logicalGeneration: logicalRunGeneration,
            connectionGeneration: connectionGeneration
        )
    }

    /// Armed when a `.done` commits the terminal transition with the stream
    /// finish deferred to the completing connection's own terminal event
    /// (`.streamEnd`, `.cancelled`, or `.error`). The finishing event is
    /// admitted by the generation fence and performs no transition work —
    /// it only runs the deferred `finishStream()` exactly once, so the
    /// stream client is not stopped before that event is delivered and a
    /// `.done` without a trailing terminal event leaves the view-model
    /// transcript-refresh flag untouched (Slice 2 regression guards).
    private var pendingDeferredStreamFinish = false
    /// Set when the terminal transition already cleared auxiliary monitoring
    /// (`.completed`), so the deferred `finishStream()` does not clear twice.
    private var monitoringClearedAtTerminal = false
    /// Whether `finishStream()` should refresh the completed response title
    /// (journal-authority terminal commits suppress the extra session GET).
    private var refreshesCompletedTitleOnFinish = true

    init(
        client: APIClient,
        streamClient: SSEStreamingClient,
        liveActivityManager: any AgentLiveActivityManaging,
        showsLiveActivityResponseExcerpts: Bool,
        timing: ChatStreamCoordinatorTiming = .standard,
        runGenerationStore: any ChatRunGenerationStore = InMemoryRunGenerationStore()
    ) {
        self.client = client
        self.streamClient = streamClient
        self.liveActivityManager = liveActivityManager
        self.showsLiveActivityResponseExcerpts = showsLiveActivityResponseExcerpts
        self.timing = timing
        self.runGenerationStore = runGenerationStore
    }

    func attach(delegate: any ChatStreamCoordinatorDelegate) {
        self.delegate = delegate
    }

    func setShowsLiveActivityResponseExcerpts(_ shows: Bool) {
        guard showsLiveActivityResponseExcerpts != shows else { return }

        showsLiveActivityResponseExcerpts = shows
        if !shows, activeStreamID != nil {
            liveActivityManager.update(.clearResponseExcerpt)
        }
    }

    func prepareForNewResponse() {
        hasCompletedCurrentResponse = false
        isConnectionSuspended = false
        liveTokensPerSecond = nil
    }

    func start(
        streamID: String,
        replayAfterSeq: Int? = nil,
        recoveryState: ActiveStreamRecoveryState = .idle
    ) {
        hasCompletedCurrentResponse = false
        liveTokensPerSecond = nil
        // A new logical run bumps the run-generation fence epoch (every
        // start AND every finish). The logical identity generation is
        // persisted BEFORE the connection opens: a same-stream replacement
        // allocates max(lastIssued, current) + 1, while a resume after an
        // authoritative session load restores the exact persisted active
        // generation (#18 §473).
        runGeneration &+= 1
        if replayAfterSeq == nil {
            logicalRunGeneration = allocateLogicalGeneration(streamID: streamID)
        }
        openConnection(
            streamID: streamID,
            replayAfterSeq: replayAfterSeq,
            recoveryState: recoveryState
        )
    }

    /// Allocates the logical generation for a new run on `streamID` (#18
    /// §473). When the last authoritative session load confirmed the same
    /// non-empty active stream ID the store records as active, the persisted
    /// active generation is RESTORED (reconnect/relaunch reattaches the same
    /// logical run — no new allocation). Otherwise a first run or a
    /// same-stream-ID replacement persists max(lastIssuedGeneration,
    /// currentGeneration) + 1 BEFORE the connection opens.
    private func allocateLogicalGeneration(streamID: String) -> Int {
        let sessionID = delegate?.streamCoordinatorSessionID ?? ""
        if pendingResumeStreamID == streamID {
            pendingResumeStreamID = nil
            if let activeGeneration = runGenerationStore.record(for: sessionID, streamID: streamID)?.activeGeneration {
                return activeGeneration
            }
        }

        let lastIssued = runGenerationStore.record(for: sessionID, streamID: streamID)?.lastIssuedGeneration ?? 0
        let next = max(lastIssued, logicalRunGeneration) + 1
        runGenerationStore.replace(ChatRunGenerationRecord(
            sessionID: sessionID,
            streamID: streamID,
            lastIssuedGeneration: next,
            activeGeneration: next
        ))
        return next
    }

    /// Replay/resume entry point (#18 Slice 4): opens a NEW connection
    /// generation for the SAME logical run. Unlike `start`, it keeps the
    /// logical identity — the run-generation fence epoch and the logical
    /// generation are untouched — and creates no pending state: the run was
    /// already active and merely suspended.
    func openConnection(
        streamID: String,
        replayAfterSeq: Int? = nil,
        recoveryState: ActiveStreamRecoveryState = .idle
    ) {
        // A stale deferred finish from a previous run must never be consumed
        // by this run's terminal events.
        pendingDeferredStreamFinish = false
        connectionGeneration &+= 1
        let connectionIdentity = ChatRunIdentity(
            sessionID: delegate?.streamCoordinatorSessionID ?? "",
            streamID: streamID,
            generation: logicalRunGeneration
        )
        activeStreamID = streamID
        isConnectionSuspended = false
        if replayAfterSeq == nil {
            lastEventID = nil
        }

        markConnectionStarted(
            isReplay: replayAfterSeq != nil,
            recoveryState: recoveryState
        )
        startLiveActivity(streamID: streamID)
        streamClient.start(
            url: client.chatStreamURL(
                streamID: streamID,
                replayAfterSeq: replayAfterSeq
            )
        ) { [weak self] event in
            // Connection-generation fencing (#18 Slice 1): every connection
            // captures the identity of the run it was opened for. A callback
            // delivered by a superseded connection (older logical generation,
            // or a different stream's run) returns BEFORE any delegate,
            // live-activity, transcript, or terminal mutation — a late event
            // from an old connection can never mutate the replacement run.
            //
            // Sole exception: the connection that delivered the accepted
            // `.done` owns the run's completion, and its own terminal events
            // (.streamEnd / .cancelled / .error) arrive AFTER the run was
            // finalized (runIdentity is nil). They are admitted so
            // finishStream() — title refresh, Live Activity teardown — still
            // runs for the completed run; payload-carrying events (.token,
            // .done, …) stay fenced once the run is finalized.
            guard let self,
                  self.runIdentity == connectionIdentity
                    || (self.runIdentity == nil
                        && connectionIdentity == self.completedRunIdentity
                        && isTerminalEvent(event))
            else { return }
            self.handle(event)
        }
        delegate?.streamCoordinatorStartAuxiliaryMonitoring()
    }

    func cancelActiveStream() async -> ChatCancelDisposition {
        guard let activeStreamID,
              let connectionIdentity = runConnectionIdentity
        else {
            return .unconfirmed
        }
        let streamID = activeStreamID

        let response: ChatCancelResponse
        do {
            response = try await client.cancelChat(streamID: streamID)
        } catch {
            // A superseded request's failure is swallowed as stale: only the
            // current identity's transport failure is a real `.thrown` error.
            guard isCurrentConnection(streamID: streamID, identity: connectionIdentity) else {
                return .stale
            }
            return .thrown(error)
        }

        // Generation gate (#18 Slice 3): the run was replaced or finalized
        // while the request was in flight. The delayed result is stale
        // regardless of its content — never surface it as a current success,
        // rejection, or error.
        guard isCurrentConnection(streamID: streamID, identity: connectionIdentity) else {
            return .stale
        }

        // Envelope precedence: stream-identity mismatch ⇒ stale; trimmed
        // non-empty error ⇒ rejected; explicit ok:false ⇒ rejected; ok:true
        // ⇒ accepted; nil/nil ⇒ unconfirmed. Contradictory booleans resolve
        // by the same precedence.
        if let responseStreamID = response.streamId, responseStreamID != streamID {
            return .stale
        }
        let trimmedError = response.error?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedError, !trimmedError.isEmpty {
            return .rejected(ChatCancelResponse(
                ok: response.ok,
                cancelled: response.cancelled,
                streamId: response.streamId,
                error: trimmedError
            ))
        }
        if response.ok == false {
            return .rejected(response)
        }
        guard response.ok == true else {
            return .unconfirmed
        }

        // Explicit cancel terminal candidate: routed through the centralized
        // transition so the first-valid-outcome-wins rule and idempotent
        // cleanup apply (#18 Slice 2).
        if let identity = runIdentity {
            transitionToTerminal(outcome: .cancelled, identity: identity)
        } else {
            liveActivityManager.end(status: .cancelled, activity: String(localized: "Response cancelled"), errorSummary: nil)
            finishStream()
        }
        return .accepted(ChatCancellationTicket(
            identity: connectionIdentity,
            messageID: "cancelled-\(UUID().uuidString)"
        ))
    }

    /// Whether the run connection that issued a cancel request is still the
    /// current one — same active stream AND same connection identity. Any
    /// replacement (new logical generation), replay (new connection
    /// generation), or finalization makes the request stale (#18 Slice 3).
    private func isCurrentConnection(streamID: String, identity: ChatRunConnectionIdentity) -> Bool {
        activeStreamID == streamID && runConnectionIdentity == identity
    }

    /// Closed journal-authority mapping (#18 Slice 4). Only the documented
    /// vocabulary — after whitespace/ASCII-case normalization — resolves to a
    /// terminal outcome, and only while the journal reports the run inactive.
    /// `lost-worker-bookkeeping` is the one documented exception that is
    /// authoritative even when `journal.terminal == false`. Every other
    /// authority absence (nil/true active, missing journal, missing/nil
    /// terminalState, terminal != true, unknown vocabulary, aliases) stays
    /// non-terminal: completion is never inferred from a refreshed
    /// transcript.
    func resolveRecoveryJournal(
        active: Bool?,
        journal: RunJournalStatus?
    ) -> ChatRunRecoveryJournalResolution {
        guard active == false else {
            return .nonTerminal(reason: "active is not false")
        }
        guard let journal else {
            return .nonTerminal(reason: "missing journal")
        }
        guard let rawTerminalState = journal.terminalState else {
            return .nonTerminal(reason: "missing terminalState")
        }

        let terminalState = rawTerminalState
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Documented bookkeeping exception: authoritative failure even when
        // journal.terminal == false.
        if terminalState == "lost-worker-bookkeeping" {
            return .terminal(.failed)
        }

        guard journal.terminal == true else {
            return .nonTerminal(reason: "terminal is not true")
        }

        switch terminalState {
        case "completed":
            return .terminal(.completed)
        case "errored", "interrupted-by-crash":
            return .terminal(.failed)
        case "interrupted-by-user":
            return .terminal(.cancelled)
        default:
            return .nonTerminal(reason: "unknown terminalState vocabulary")
        }
    }

    /// Finalizes the suspended run from journal authority (#18 Slice 4):
    /// one centralized terminal transition (outcome, terminal event, Live
    /// Activity end, cleanup) with NO transcript reload consulted.
    private func finalizeFromJournal(outcome: ChatRunTerminalOutcome) {
        if let identity = runIdentity {
            transitionToTerminal(
                outcome: outcome,
                identity: identity,
                refreshesCompletedTitle: false
            )
        }
    }

    func suspendActiveStreamConnection() {
        guard activeStreamID != nil, !hasCompletedCurrentResponse, !isConnectionSuspended else { return }

        lastEventID = streamClient.lastEventID ?? lastEventID
        delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        liveActivityManager.markStale()
        isConnectionSuspended = true
        streamClient.stop()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
    }

    func prepareForSessionLoad() -> ChatStreamLoadPreparation {
        liveTokensPerSecond = nil
        let activeStreamIDBeforeLoad = activeStreamID
        if activeStreamIDBeforeLoad != nil, !hasCompletedCurrentResponse {
            delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        }

        return ChatStreamLoadPreparation(
            activeStreamIDBeforeLoad: activeStreamIDBeforeLoad,
            shouldPrepareSuspendedStreamResume: activeStreamID == nil || isConnectionSuspended
        )
    }

    func reconcileSessionLoad(
        loadedActiveStreamID rawLoadedActiveStreamID: String?,
        preparation: ChatStreamLoadPreparation,
        usedCacheFallback: Bool
    ) {
        hasCompletedCurrentResponse = false
        liveTokensPerSecond = nil

        if usedCacheFallback {
            activeStreamID = nil
            isConnectionSuspended = false
            delegate?.streamCoordinatorStreamingAssistantMessageID = nil
            resetRecoveryState()
            return
        }

        let loadedActiveStreamID = rawLoadedActiveStreamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if preparation.shouldPrepareSuspendedStreamResume {
            delegate?.streamCoordinatorStreamingAssistantMessageID = nil
            if let streamID = loadedActiveStreamID, !streamID.isEmpty {
                activeStreamID = streamID
                // Authoritative session response: the server still reports
                // this stream active. The next `start` restores the persisted
                // active generation instead of allocating a new one (#18
                // §473).
                pendingResumeStreamID = streamID
                delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                isConnectionSuspended = true
                restoreSnapshotIfAvailable(streamID: streamID)
            } else {
                activeStreamID = nil
                isConnectionSuspended = false
                resetRecoveryState()
            }
        } else {
            let streamID = loadedActiveStreamID?.isEmpty == false
                ? loadedActiveStreamID
                : preparation.activeStreamIDBeforeLoad
            if let streamID {
                activeStreamID = streamID
                delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                restoreSnapshotIfAvailable(streamID: streamID)
                if delegate?.streamCoordinatorStreamingAssistantMessageID == nil {
                    delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                }
            }
            isConnectionSuspended = false
        }
    }

    func reconnectIfNeeded(modelContext: ModelContext? = nil) async {
        guard let activeStreamID, isConnectionSuspended else { return }
        let generation = runGeneration

        do {
            let response = try await client.chatStreamStatus(streamID: activeStreamID)
            guard self.activeStreamID == activeStreamID, isConnectionSuspended else { return }

            if response.active == true {
                await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
                guard self.activeStreamID == activeStreamID, isConnectionSuspended else { return }

                let streamIDToResume = activeStreamID
                if delegate?.streamCoordinatorStreamingAssistantMessageID == nil {
                    restoreSnapshotIfAvailable(streamID: streamIDToResume)
                }
                if delegate?.streamCoordinatorStreamingAssistantMessageID == nil {
                    delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                }
                isConnectionSuspended = false
                // The status response confirms the same active stream: the
                // resume start restores the persisted active generation
                // (#18 §473).
                pendingResumeStreamID = streamIDToResume
                start(streamID: streamIDToResume)
            } else if response.replayAvailable == true {
                // #18 Slice 4: journal authority resolves BEFORE any replay —
                // a terminal journal entry finalizes the run instead of
                // reconnecting it.
                switch resolveRecoveryJournal(active: response.active, journal: response.journal) {
                case .terminal(let outcome):
                    finalizeFromJournal(outcome: outcome)
                case .nonTerminal:
                    let replayAfterSeq = Self.runJournalReplayAfterSeq(from: lastEventID) ?? 0
                    self.activeStreamID = activeStreamID
                    isConnectionSuspended = false
                    start(streamID: activeStreamID, replayAfterSeq: replayAfterSeq)
                }
            } else {
                // #18 Slice 4: the journal is the ONLY terminal authority for
                // an inactive run. A documented terminal entry commits the
                // outcome WITHOUT a transcript reload; every authority-absent
                // case stays non-terminal and suspended — completion is never
                // inferred from a refreshed transcript.
                switch resolveRecoveryJournal(active: response.active, journal: response.journal) {
                case .terminal(let outcome):
                    finalizeFromJournal(outcome: outcome)
                case .nonTerminal:
                    return
                }
            }
        } catch {
            if (error as? APIError)?.indicatesMissingStream == true,
               self.activeStreamID == activeStreamID,
               isConnectionSuspended {
                await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
                guard canFinalizeRunAfterLoad(streamID: activeStreamID, capturedGeneration: generation) else { return }
                finalizeInactiveStream(streamID: activeStreamID)
                return
            }
            delegate?.streamCoordinatorDidReceiveRecoveryError(error)
        }
    }

    func refreshTranscriptIfCompleted(
        streamID expectedStreamID: String,
        modelContext: ModelContext? = nil
    ) async {
        guard activeStreamID == expectedStreamID, !isConnectionSuspended else { return }
        let generation = runGeneration

        do {
            let response = try await client.chatStreamStatus(streamID: expectedStreamID)
            guard response.active == false else { return }

            await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
            // Bail if a concurrent completion/cancel/new run finalized or replaced
            // this run during the load (see canFinalizeRunAfterLoad).
            guard canFinalizeRunAfterLoad(streamID: expectedStreamID, capturedGeneration: generation) else { return }

            guard delegate?.streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser == true else {
                // Foreground safety net: the live SSE is still connected and owns
                // completion, so a status poll that briefly reports inactive must
                // not finalize the run — keep waiting for the real `.done`. (This
                // is why #246's finalize-on-reopen fix deliberately excludes this
                // path; see finalizeInactiveStream.)
                activeStreamID = expectedStreamID
                isConnectionSuspended = false
                return
            }

            completeResponseFromRefreshedTranscriptAndFinishStream(streamID: expectedStreamID)
        } catch {
            // This is a foreground safety net. The primary SSE path owns visible
            // stream errors; a failed status poll should not interrupt it.
            chatStreamCoordinatorLogger.warning(
                "Active stream status refresh failed category=\(APIError.privacySafeLogCategory(for: error), privacy: .public)"
            )
        }
    }

    func recoverStaleStreamIfNeeded(
        now: Date = Date(),
        modelContext: ModelContext? = nil
    ) async {
        guard let activeStreamID,
              !isConnectionSuspended,
              !hasCompletedCurrentResponse
        else {
            recoveryState = .idle
            return
        }

        guard delegate?.streamCoordinatorHasPendingPrompt != true else {
            recoveryState = .idle
            return
        }

        let reconnectInterval = delegate?.streamCoordinatorHasRunningLiveToolCall == true
            ? timing.runningToolReconnectInterval
            : timing.reconnectInterval
        guard let lastProgressDate else {
            guard let lastTransportActivityDate,
                  now.timeIntervalSince(lastTransportActivityDate) >= reconnectInterval
            else {
                recoveryState = .idle
                return
            }

            recoveryState = .checking
            lastRecoveryStatusCheckDate = now
            await recoverStaleStream(
                streamID: activeStreamID,
                forceReconnect: true,
                modelContext: modelContext
            )
            return
        }

        let elapsed = now.timeIntervalSince(lastProgressDate)
        guard elapsed >= timing.checkingInterval else {
            recoveryState = .idle
            return
        }

        let transportElapsed = now.timeIntervalSince(lastTransportActivityDate ?? lastProgressDate)
        guard transportElapsed >= timing.transportFreshInterval else {
            // #227: heartbeats prove the connection is alive during a
            // semantically quiet window (model thinking / slow tool call), so
            // stay idle and skip status polls. A genuinely silent transport
            // still escalates below once past transportFreshInterval.
            recoveryState = .idle
            return
        }

        recoveryState = .checking
        let shouldForceReconnect = transportElapsed >= reconnectInterval
        guard shouldForceReconnect || shouldPollStatus(now: now) else { return }

        lastRecoveryStatusCheckDate = now
        await recoverStaleStream(
            streamID: activeStreamID,
            forceReconnect: shouldForceReconnect,
            modelContext: modelContext
        )
    }

    func markProgress(now: Date = Date()) {
        lastProgressDate = now
        lastTransportActivityDate = now
        lastRecoveryStatusCheckDate = nil
        recoveryState = .idle
    }

    func clearReplayConnection() {
        isReplayConnection = false
    }

    nonisolated static func runJournalReplayAfterSeq(from eventID: String?) -> Int? {
        guard let eventID = eventID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !eventID.isEmpty
        else {
            return nil
        }

        let sequenceText: Substring
        if let delimiterIndex = eventID.lastIndex(of: ":") {
            sequenceText = eventID[eventID.index(after: delimiterIndex)...]
        } else {
            sequenceText = Substring(eventID)
        }

        guard let sequence = Int(sequenceText) else {
            return nil
        }

        return max(0, sequence)
    }

    private func handle(_ event: SSEEvent) {
        lastEventID = streamClient.lastEventID ?? lastEventID
        lastTransportActivityDate = Date()

        switch event {
        case .token(let text):
            if showsLiveActivityResponseExcerpts {
                liveActivityManager.update(.token(text))
            }
            if delegate?.streamCoordinatorAppendToken(text) == true {
                markProgress()
            }
        case .interimAssistant(let payload):
            if showsLiveActivityResponseExcerpts,
               payload.alreadyStreamed != true,
               let text = payload.text {
                liveActivityManager.update(.interimAssistant(text))
            }
            if delegate?.streamCoordinatorAppendInterimAssistant(payload) == true {
                markProgress()
            }
        case .reasoning(let text):
            liveActivityManager.update(.reasoning(text))
            if delegate?.streamCoordinatorAppendReasoning(text) == true {
                markProgress()
            }
        case .toolStarted(let payload):
            liveActivityManager.update(.toolStarted(name: payload.name))
            if delegate?.streamCoordinatorAppendToolCall(payload) == true {
                markProgress()
            }
        case .toolCompleted(let payload):
            liveActivityManager.update(.toolCompleted)
            if delegate?.streamCoordinatorCompleteToolCall(payload) == true {
                markProgress()
            }
        case .title(let payload):
            if delegate?.streamCoordinatorUpdateTitle(payload) == true {
                markProgress()
            }
        case .metering(let payload):
            guard payload.sessionId == nil || payload.sessionId == delegate?.streamCoordinatorSessionID else {
                break
            }
            liveTokensPerSecond = payload.displayableTokensPerSecond
        case .done(let payload):
            let hasCompletedTranscript = delegate?.streamCoordinatorApplyDone(payload) == true
            if let identity = runIdentity {
                // The `.done` commits the terminal transition but defers
                // `finishStream()` to the completing connection's own terminal
                // event: stopping the client here would drop that event before
                // delivery, and finishing here would clear the view-model
                // transcript-refresh flag a bare `.done` must leave visible
                // (Slice 2 regression guards).
                transitionToTerminal(
                    outcome: .completed,
                    identity: identity,
                    needsTranscriptRefresh: !hasCompletedTranscript,
                    defersStreamFinish: true
                )
            }
        case .approvalPending(let update):
            liveActivityManager.update(.waitingForApproval)
            delegate?.streamCoordinatorApplyApprovalUpdate(update)
            markProgress()
        case .clarificationPending(let update):
            liveActivityManager.update(.waitingForClarification)
            delegate?.streamCoordinatorApplyClarificationUpdate(update)
            markProgress()
        case .pendingSteerLeftover(let text):
            if delegate?.streamCoordinatorEnqueuePendingSteerLeftover(text) == true {
                markProgress()
            }
        case .streamEnd:
            // Server closed the stream: a terminal `.completed` candidate. A
            // late `.streamEnd` from the completing connection after
            // finalization is admitted by the fence but no-ops in the
            // centralized transition (first outcome wins). A bare `.streamEnd`
            // (no `.done`) finishes the stream WITHOUT marking the response
            // completed — the pre-#18 semantics the queued-message drain and
            // title-refresh paths rely on.
            if let identity = runIdentity {
                transitionToTerminal(
                    outcome: .completed,
                    identity: identity,
                    marksResponseCompleted: false
                )
            }
            finishDeferredStreamIfPending()
        case .cancelled:
            if let identity = runIdentity {
                transitionToTerminal(outcome: .cancelled, identity: identity)
            }
            finishDeferredStreamIfPending()
        case .error(let message):
            // The failure message is surfaced only when THIS call commits the
            // transition — a late error after a cancelled/completed outcome is
            // a no-op and must not surface a message or finish twice.
            if let identity = runIdentity,
               transitionToTerminal(outcome: .failed, identity: identity) {
                delegate?.streamCoordinatorDidReceiveErrorMessage(message)
            }
            finishDeferredStreamIfPending()
        case .terminal(let commit):
            // An explicit terminal commit carried by the SSE stream (#18
            // Slice 5). A commit matching the ACTIVE run commits the
            // centralized transition exactly once (first outcome wins); the
            // ViewModel observes it through `streamCoordinatorDidCommitTerminal`
            // invoked by the transition. A commit admitted after finalization
            // (the completing connection's own late terminal event) performs
            // no transition and emits no second commit.
            if let identity = runIdentity, identity == commit.identity {
                transitionToTerminal(outcome: commit.outcome, identity: identity)
            }
        case .transportError(let message):
            handleTransportError(message)
        case .heartbeat:
            // #227: a heartbeat proves the transport is alive without carrying
            // semantic progress — drop an already-shown "Checking stream" state
            // immediately. Never demote .reconnecting; that chip is owned by
            // the reconnect flow until real progress lands.
            if recoveryState == .checking {
                recoveryState = .idle
            }
        case .ignored:
            break
        }
    }

    private func handleTransportError(_ message: String) {
        liveTokensPerSecond = nil
        guard activeStreamID != nil, !hasCompletedCurrentResponse else {
            if !hasCompletedCurrentResponse {
                delegate?.streamCoordinatorDidReceiveErrorMessage(message)
            }
            finishStream()
            return
        }

        guard !isConnectionSuspended else { return }

        lastEventID = streamClient.lastEventID ?? lastEventID
        delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        liveActivityManager.markStale()
        isConnectionSuspended = true
        streamClient.stop()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)

        Task { @MainActor [weak self] in
            await self?.reconnectIfNeeded()
        }
    }

    private func shouldPollStatus(now: Date) -> Bool {
        guard let lastRecoveryStatusCheckDate else { return true }

        return now.timeIntervalSince(lastRecoveryStatusCheckDate) >= timing.statusPollCooldown
    }

    private func recoverStaleStream(
        streamID expectedStreamID: String,
        forceReconnect: Bool,
        modelContext: ModelContext?
    ) async {
        guard activeStreamID == expectedStreamID, !isConnectionSuspended else { return }
        let generation = runGeneration

        do {
            let response = try await client.chatStreamStatus(streamID: expectedStreamID)
            guard activeStreamID == expectedStreamID, !isConnectionSuspended else { return }

            if response.active == false {
                await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
                // Same generation/clobber guard as the reconnect and refresh paths;
                // the extra `!isConnectionSuspended` keeps the reconnect path owning
                // a stream that was suspended mid-load. (PR #266 review #3)
                guard canFinalizeRunAfterLoad(streamID: expectedStreamID, capturedGeneration: generation),
                      !isConnectionSuspended else { return }

                finalizeInactiveStream(streamID: expectedStreamID)
                return
            }

            // PR #238 review: recoveryState was set to .checking before this
            // await. If it changed mid-flight (a heartbeat or real progress
            // demoted it to .idle), the transport just proved itself alive —
            // don't resurrect the chip or churn a live connection; the next
            // recovery tick re-evaluates from scratch.
            guard recoveryState == .checking, forceReconnect else { return }

            reconnectStaleStream(
                streamID: expectedStreamID,
                usesReplay: response.replayAvailable == true
            )
        } catch {
            chatStreamCoordinatorLogger.warning(
                "Stale stream recovery status check failed category=\(APIError.privacySafeLogCategory(for: error), privacy: .public)"
            )

            if (error as? APIError)?.indicatesMissingStream == true,
               activeStreamID == expectedStreamID,
               !isConnectionSuspended {
                await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
                guard canFinalizeRunAfterLoad(streamID: expectedStreamID, capturedGeneration: generation),
                      !isConnectionSuspended else { return }
                finalizeInactiveStream(streamID: expectedStreamID)
                return
            }

            // Same mid-flight demotion guard as the success path (PR #238
            // review): only a still-.checking state may escalate.
            guard recoveryState == .checking,
                  forceReconnect,
                  activeStreamID == expectedStreamID,
                  !isConnectionSuspended
            else { return }

            reconnectStaleStream(streamID: expectedStreamID, usesReplay: true)
        }
    }

    private func reconnectStaleStream(streamID: String, usesReplay: Bool) {
        guard activeStreamID == streamID, !isConnectionSuspended else { return }

        lastEventID = streamClient.lastEventID ?? lastEventID
        let replayAfterSeq = usesReplay ? Self.runJournalReplayAfterSeq(from: lastEventID) ?? 0 : nil
        delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        liveActivityManager.markStale()
        recoveryState = .reconnecting
        streamClient.stop()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
        start(
            streamID: streamID,
            replayAfterSeq: replayAfterSeq,
            recoveryState: .reconnecting
        )
    }

    /// Centralized terminal transition (#18 Slice 2). Every terminal candidate
    /// — `.done`, `.streamEnd`, `.cancelled`, `.error`, and the explicit
    /// recovery/cancel finalize paths — funnels through here. The FIRST valid
    /// candidate for a run commits: Live Activity end, terminal delegate
    /// callback, snapshot removal, monitoring stop, and coordinator cleanup
    /// all happen exactly once. Later candidates — duplicate terminal events
    /// or terminal events from the completing connection arriving after
    /// finalization — are no-ops.
    ///
    /// `.completed` has two refinements preserving pre-#18 semantics:
    /// - `marksResponseCompleted: false` (bare `.streamEnd`): finishes the
    ///   stream without firing `streamCoordinatorDidCompleteCurrentResponse`
    ///   or marking the response completed, so the queued-message drain and
    ///   title refresh keep their legacy behavior.
    /// - `defersStreamFinish: true` (`.done`): the terminal transition is
    ///   committed but `finishStream()` waits for the completing connection's
    ///   own terminal event, so the client is not stopped before that event
    ///   is delivered and a `.done` with no trailing terminal event leaves
    ///   the view-model transcript-refresh flag untouched.
    ///
    /// Transport errors are NOT terminal candidates and never reach this
    /// transition. Returns whether this call committed.
    @discardableResult
    private func transitionToTerminal(
        outcome: ChatRunTerminalOutcome,
        identity: ChatRunIdentity,
        needsTranscriptRefresh: Bool = true,
        marksResponseCompleted: Bool = true,
        defersStreamFinish: Bool = false,
        refreshesCompletedTitle: Bool = true
    ) -> Bool {
        guard runIdentity == identity else { return false }

        // Capture the completing run's identity BEFORE the active stream is
        // cleared: the completing connection's own terminal events arrive
        // after finalization and must still pass the generation fence.
        completedRunIdentity = identity
        runGeneration &+= 1
        pendingDeferredStreamFinish = defersStreamFinish
        refreshesCompletedTitleOnFinish = refreshesCompletedTitle

        switch outcome {
        case .completed:
            if marksResponseCompleted, !hasCompletedCurrentResponse {
                hasCompletedCurrentResponse = true
                delegate?.streamCoordinatorDidCompleteCurrentResponse(
                    needsTranscriptRefresh: needsTranscriptRefresh
                )
            }
            // The approval/clarification prompt is resolved by the completed
            // response even when the stream finish is deferred (pre-#18
            // `.done` finished immediately and cleared the prompt here). The
            // deferred `finishStream()` skips its own clear when this flag is
            // set, so the prompt clears exactly once.
            monitoringClearedAtTerminal = true
            delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
            liveActivityManager.end(status: .complete, activity: String(localized: "Response complete"), errorSummary: nil)
        case .cancelled:
            liveActivityManager.end(status: .cancelled, activity: String(localized: "Response cancelled"), errorSummary: nil)
        case .failed:
            liveActivityManager.end(status: .failed, activity: String(localized: "Response failed"), errorSummary: nil)
        }

        delegate?.streamCoordinatorDidCommitTerminalOutcome(outcome, identity: identity)

        // Exactly-once terminal commit (#18 §500-520): the centralized
        // transition constructs ONE complete ChatRunTerminalCommit (identity,
        // outcome, stable event key, server IDs) and invokes the commit
        // delegate exactly once — after the first-valid compare-and-set, so
        // an already-terminal state never emits a second commit. The
        // ViewModel appends the stable local event and persists the keyed
        // handoff from this callback; no pre-append handoff is ever emitted.
        let commit = ChatRunTerminalCommit(
            identity: identity,
            outcome: outcome,
            eventKey: ChatRunStatusTerminalEventKey(identity: identity, outcome: outcome),
            serverSessionID: identity.sessionID,
            serverStreamID: identity.streamID
        )
        delegate?.streamCoordinatorDidCommitTerminal(commit)
        clearActiveGeneration(for: identity)

        activeStreamID = nil
        lastEventID = nil
        liveTokensPerSecond = nil
        delegate?.streamCoordinatorStreamingAssistantMessageID = nil
        if !defersStreamFinish {
            finishStream()
        }
        return true
    }

    /// Terminal commit retains `lastIssuedGeneration` and clears only
    /// `activeGeneration` (#18 §473): a subsequent same-stream run allocates
    /// max(lastIssued, current) + 1 instead of restoring the finished run's
    /// generation.
    private func clearActiveGeneration(for identity: ChatRunIdentity) {
        guard let record = runGenerationStore.record(for: identity.sessionID, streamID: identity.streamID) else {
            return
        }
        runGenerationStore.replace(ChatRunGenerationRecord(
            sessionID: record.sessionID,
            streamID: record.streamID,
            lastIssuedGeneration: record.lastIssuedGeneration,
            activeGeneration: nil
        ))
    }

    private func completeCurrentResponse(needsTranscriptRefresh: Bool) {
        if let identity = runIdentity {
            transitionToTerminal(
                outcome: .completed,
                identity: identity,
                needsTranscriptRefresh: needsTranscriptRefresh
            )
        } else {
            // No active run identity (e.g. the run was reconciled to nil
            // during a transcript load): fall back to the pre-#18 completion
            // bookkeeping without a terminal transition record.
            completedRunIdentity = nil
            runGeneration &+= 1
            liveActivityManager.end(status: .complete, activity: String(localized: "Response complete"), errorSummary: nil)
            delegate?.streamCoordinatorRemoveSnapshot(streamID: activeStreamID)
            delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
            activeStreamID = nil
            lastEventID = nil
            liveTokensPerSecond = nil
            delegate?.streamCoordinatorStreamingAssistantMessageID = nil
            hasCompletedCurrentResponse = true
            delegate?.streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: needsTranscriptRefresh)
            resetRecoveryState()
        }
    }

    /// Terminal SSE events that may legitimately arrive from the completing
    /// connection after the run was finalized by its accepted `.done`.
    /// Payload events (.token, .done, …) are deliberately excluded: a late
    /// `.done` must never finalize twice, and stale payload must never mutate
    /// a completed transcript (#18 Slice 1).
    private func isTerminalEvent(_ event: SSEEvent) -> Bool {
        switch event {
        case .streamEnd, .cancelled, .error, .terminal:
            return true
        default:
            return false
        }
    }

    private func completeResponseFromRefreshedTranscriptAndFinishStream(streamID completedStreamID: String?) {
        if let identity = runIdentity {
            // The transition commits completion AND finishes the stream in one
            // idempotent pass (single snapshot removal, single stream stop).
            transitionToTerminal(
                outcome: .completed,
                identity: identity,
                needsTranscriptRefresh: false
            )
        } else {
            // No active run identity (the run was reconciled to nil during the
            // transcript load): the run still completed, so end the Live
            // Activity and notify the response-completion observers exactly as
            // the pre-#18 completion path did — a foreground-reconnect
            // completion must never leave the Live Activity on "running".
            liveActivityManager.end(status: .complete, activity: String(localized: "Response complete"), errorSummary: nil)
            delegate?.streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: false)
            delegate?.streamCoordinatorRemoveSnapshot(streamID: completedStreamID)
            finishStream()
        }
    }

    /// Whether `self` may still finalize the run captured before an awaited
    /// transcript load. Returns false (bail) when a concurrent completion / cancel
    /// / new run bumped the generation — finalizing would double-finalize — or when
    /// a *different* run is now active — finalizing would clobber the newer stream.
    /// A run reconciled to `nil` during the load still passes: it should be
    /// finalized from the refreshed transcript so its Live Activity can't dangle on
    /// "running" (#246). Shared by all three post-load finalize paths
    /// (reconnect-after-suspend, foreground refresh, stale recovery) so they stay in
    /// lockstep — recoverStaleStream previously used a stricter, hand-rolled guard.
    /// (PR #266 review #3)
    private func canFinalizeRunAfterLoad(streamID: String, capturedGeneration: Int) -> Bool {
        guard runGeneration == capturedGeneration else { return false }
        return activeStreamID == nil || activeStreamID == streamID
    }

    /// The server reports this stream is no longer active. Complete from the
    /// just-refreshed transcript when an assistant reply surfaced, otherwise
    /// finalize as failed. Either branch ends the Live Activity, so it can never
    /// dangle on "running" after the run is over (#246). Shared by the two paths
    /// with no live SSE behind them — reconnect-after-suspend and stale recovery.
    /// The foreground transcript-refresh safety net deliberately keeps waiting
    /// instead, because its live SSE still owns completion.
    private func finalizeInactiveStream(streamID: String?) {
        if delegate?.streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser == true {
            completeResponseFromRefreshedTranscriptAndFinishStream(streamID: streamID)
        } else if let identity = runIdentity {
            // Recovery terminal candidate: no assistant reply surfaced, so the
            // inactive run finalizes as failed through the central transition.
            transitionToTerminal(outcome: .failed, identity: identity)
        } else {
            liveActivityManager.end(status: .failed, activity: String(localized: "Response failed"), errorSummary: nil)
            finishStream()
        }
    }

    /// Runs the deferred `finishStream()` when the completing connection's own
    /// terminal event arrives after a `.done` committed the transition. The
    /// event performs no transition work (first outcome wins) but must still
    /// finish the stream exactly once.
    private func finishDeferredStreamIfPending() {
        guard pendingDeferredStreamFinish else { return }
        finishStream()
    }

    private func finishStream() {
        pendingDeferredStreamFinish = false
        runGeneration &+= 1
        let completedNormally = hasCompletedCurrentResponse
        let finishedStreamID = activeStreamID
        streamClient.stop()
        if !monitoringClearedAtTerminal {
            delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
        }
        monitoringClearedAtTerminal = false
        delegate?.streamCoordinatorFlushPinnedLocalNoticesToTranscript()
        delegate?.streamCoordinatorRemoveSnapshot(streamID: finishedStreamID)
        activeStreamID = nil
        lastEventID = nil
        liveTokensPerSecond = nil
        delegate?.streamCoordinatorStreamingAssistantMessageID = nil
        hasCompletedCurrentResponse = false
        delegate?.streamCoordinatorDidFinishStream()
        isConnectionSuspended = false
        resetRecoveryState()
        delegate?.streamCoordinatorDrainQueuedSlashMessageIfIdle()
        if completedNormally, refreshesCompletedTitleOnFinish {
            delegate?.streamCoordinatorRefreshCompletedResponseTitleIfNeeded()
        }
        refreshesCompletedTitleOnFinish = true
    }

    private func markConnectionStarted(
        isReplay: Bool,
        recoveryState: ActiveStreamRecoveryState
    ) {
        let startedAt = Date()
        lastProgressDate = isReplay ? startedAt : nil
        lastTransportActivityDate = startedAt
        lastRecoveryStatusCheckDate = nil
        self.recoveryState = recoveryState
        isReplayConnection = isReplay
        delegate?.streamCoordinatorDidStartConnection(isReplay: isReplay)
    }

    private func resetRecoveryState() {
        recoveryState = .idle
        lastProgressDate = nil
        lastTransportActivityDate = nil
        lastRecoveryStatusCheckDate = nil
        isReplayConnection = false
        delegate?.streamCoordinatorDidResetRecoveryState()
    }

    private func startLiveActivity(streamID: String) {
        guard let sessionID = delegate?.streamCoordinatorSessionID else { return }

        liveActivityManager.start(
            sessionID: sessionID,
            sessionTitle: delegate?.streamCoordinatorDisplayTitle ?? String(localized: "Untitled Session"),
            streamID: streamID
        )
    }

    private func restoreSnapshotIfAvailable(streamID: String) {
        guard lastEventID == nil else {
            _ = delegate?.streamCoordinatorRestoreSnapshotIfAvailable(streamID: streamID)
            return
        }

        lastEventID = delegate?.streamCoordinatorRestoreSnapshotIfAvailable(streamID: streamID) ?? lastEventID
    }
}
