import Foundation

// MARK: - Cookie and request-context identity

enum CatalogCookieContextID: Hashable, Sendable {
    case shared
    case injected(UUID)
}

struct NormalizedServerOrigin: Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init(scheme: String, host: String, port: Int) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port
    }

    init(url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        let port: Int
        if let explicitPort = url.port {
            port = explicitPort
        } else {
            switch scheme {
            case "http":
                port = 80
            case "https":
                port = 443
            default:
                port = 0
            }
        }

        self.init(
            scheme: scheme,
            host: url.host?.lowercased() ?? "",
            port: port
        )
    }
}

struct ProfileContextGateKey: Hashable, Sendable {
    let origin: NormalizedServerOrigin
    let cookieContextID: CatalogCookieContextID
}

struct CatalogOperationKey: Hashable, Sendable {
    let gateKey: ProfileContextGateKey
    let apiClientID: UUID
    let authGeneration: UInt64
    let requestedProfile: String?
    let startingGateEpoch: UInt64
}

struct CatalogContextKey: Hashable, Sendable {
    let gateKey: ProfileContextGateKey
    let apiClientID: UUID
    let authGeneration: UInt64
    let activeProfile: String
    let gateEpoch: UInt64
}

enum CatalogEventIdentity: Equatable, Sendable {
    case provisional(CatalogOperationKey)
    case verified(CatalogContextKey)
}

struct CatalogEventMetadata: Equatable, Sendable {
    let identity: CatalogEventIdentity
    let operationID: UUID
    let operationGeneration: UInt64
}

// MARK: - Profile projection

struct CatalogProfileDefaults: Equatable, Sendable {
    let model: String?
    let workspace: String?
}

enum CatalogProfileSwitchResult: Equatable, Sendable {
    case notRequested
    case alreadyActive
    case switched(defaults: CatalogProfileDefaults)
}

struct CatalogProfileContext: Equatable, Sendable {
    let profiles: [ProfileSummary]
    let activeProfile: String
    let requestedProfile: String?
    let singleProfileMode: Bool
    let defaults: CatalogProfileDefaults
    let switchResult: CatalogProfileSwitchResult
}

// MARK: - Sendable catalog projections

struct CatalogBaseSnapshot: Equatable, Sendable {
    let metadata: CatalogEventMetadata
    let groups: [ModelCatalogGroup]
    let defaultModel: String?
    let activeProvider: String?
}

struct CatalogLiveSnapshot: Equatable, Sendable {
    let metadata: CatalogEventMetadata
    let groups: [ModelCatalogGroup]
    let provider: String?
}

enum CatalogPhase: Equatable, Sendable {
    case context
    case models
    case live
}

enum CatalogCacheState: Equatable, Sendable {
    case cold
    case loading
    case freshReady
    case freshEmpty
    case staleRefreshing
    case staleFailed
    case coldFailed(CatalogFailureCategory)
}

enum CatalogFailureCategory: Error, Equatable, Sendable {
    case profileUnavailable
    case profileSwitchRejected
    case profileMismatch
    case unknownContext
    case transport
    case unauthorized
    case http
    case decoding
    case providerMismatch
    case cancelled
}

enum CatalogNetworkEvent: Equatable, Sendable {
    case contextVerified(CatalogEventMetadata, CatalogProfileContext)
    case base(CatalogBaseSnapshot)
    case live(CatalogLiveSnapshot)
    case liveFailed(CatalogEventMetadata, CatalogFailureCategory)
    case failed(CatalogEventMetadata, CatalogPhase, CatalogFailureCategory)
    case finished(CatalogEventMetadata)
    case cancelled(CatalogEventMetadata)
}

private extension CatalogNetworkEvent {
    var publicationMetadata: CatalogEventMetadata? {
        switch self {
        case let .contextVerified(metadata, _),
             let .liveFailed(metadata, _),
             let .finished(metadata),
             let .cancelled(metadata):
            return metadata
        case let .failed(metadata, _, _):
            return metadata
        case let .base(snapshot):
            return snapshot.metadata
        case let .live(snapshot):
            return snapshot.metadata
        }
    }
}

struct CatalogSnapshotResult: Equatable, Sendable {
    let metadata: CatalogEventMetadata
    let context: CatalogProfileContext?
    let base: CatalogBaseSnapshot?
    let live: CatalogLiveSnapshot?
    let failure: CatalogFailureCategory?
}

// MARK: - Fixed, local telemetry schema

protocol CatalogTelemetrySink: Sendable {
    func emit(_ event: CatalogTelemetryEvent)
}

struct CatalogLeaseAdmissionMetadata: Equatable, Sendable {
    let admissionID: UUID
    let gateEpoch: UInt64
}

enum CatalogTelemetrySurface: String, Equatable, Sendable {
    case context
    case models
    case live
    case picker
}

enum CatalogTelemetryPhase: String, Equatable, Sendable {
    case gateWaitStarted
    case gateAcquired
    case childRequestStarted
    case wireStarted
    case decodeStarted
    case ended
    case pickerActionStarted
    case sheetVisible
    case usefulRow
    case empty
    case failed
    case cancelled
}

enum CatalogTelemetryOutcome: Equatable, Sendable {
    case success
    case failure(CatalogFailureCategory)
    case cancelled
}

struct CatalogTelemetryEvent: Equatable, Sendable {
    let surface: CatalogTelemetrySurface
    let phase: CatalogTelemetryPhase
    let outcome: CatalogTelemetryOutcome?
    let cacheState: CatalogCacheState?
    let durationMilliseconds: Int?
    let ageMilliseconds: Int?
    let groupCount: Int?
    let rowCount: Int?
    let openToken: UUID?
    let requestToken: UUID?
    let operationID: UUID
    let admission: CatalogLeaseAdmissionMetadata?
}

// MARK: - Ticketed reader/writer gate

/// A single physical lease admission. The stream and the compatibility
/// adapters hold the exact admission they acquired and release it on every
/// exit; the gate never fabricates a release by deleting a held lease.
struct CatalogLeaseAdmission: Equatable, Sendable {
    let admissionID: UUID
    let gateEpoch: UInt64
}

/// Tracks the one reader admission owned by a catalog operation. A requested
/// profile switch transfers ownership: the reader is released before the
/// exclusive writer, then replaced with a fresh reader admission after the
/// writer advances the authoritative gate epoch.
private final class CatalogOperationExecution: @unchecked Sendable {
    let gate: ProfileContextGate
    let operationID: UUID
    var metadata: CatalogEventMetadata
    var operationKey: CatalogOperationKey
    var admissionMetadata: CatalogLeaseAdmissionMetadata?
    private var readerAdmission: CatalogLeaseAdmission?

    init(
        gate: ProfileContextGate,
        operationID: UUID,
        metadata: CatalogEventMetadata,
        operationKey: CatalogOperationKey,
        admission: CatalogLeaseAdmission
    ) {
        self.gate = gate
        self.operationID = operationID
        self.metadata = metadata
        self.operationKey = operationKey
        self.readerAdmission = admission
        self.admissionMetadata = CatalogLeaseAdmissionMetadata(
            admissionID: admission.admissionID,
            gateEpoch: admission.gateEpoch
        )
    }

    func releaseReader() async {
        guard let admission = readerAdmission else { return }
        readerAdmission = nil
        admissionMetadata = nil
        await gate.releaseReader(operationID: operationID, admission: admission)
    }

    func acquireReader() async throws -> CatalogLeaseAdmission {
        let admission = try await gate.acquireReader(operationID: operationID)
        readerAdmission = admission
        admissionMetadata = CatalogLeaseAdmissionMetadata(
            admissionID: admission.admissionID,
            gateEpoch: admission.gateEpoch
        )
        return admission
    }

    func rebind(
        metadata: CatalogEventMetadata,
        operationKey: CatalogOperationKey,
        admission: CatalogLeaseAdmissionMetadata?
    ) {
        self.metadata = metadata
        self.operationKey = operationKey
        self.admissionMetadata = admission
    }
}

enum CatalogGateLeaseState: Equatable, Sendable {
    case waitingReader
    case waitingWriter
    case heldReader
    case heldWriter
}

struct CatalogGateSnapshot: Equatable, Sendable {
    let heldReaders: [UUID]
    let heldWriter: UUID?
    let waitingReaders: [UUID]
    let waitingWriters: [UUID]
    let pendingWriterCount: Int
    let epoch: UInt64
}

/// One FIFO ticket. The gate actor owns queue membership; the ticket's own
/// lock arbitrates admission vs. cancellation so a synchronous cancellation
/// hook never needs to hop to an actor.
final class CatalogGateTicket: @unchecked Sendable {
    let operationID: UUID
    let isWriter: Bool

    private let lock = NSLock()
    private enum TicketState {
        case queued
        case served
        case cancelled
    }

    private var state: TicketState = .queued
    private var continuation: CheckedContinuation<CatalogLeaseAdmission, Error>?
    private var waited = false

    init(operationID: UUID, isWriter: Bool) {
        self.operationID = operationID
        self.isWriter = isWriter
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .cancelled
    }

    /// True when the ticket spent at least one queue wait before admission.
    var didWait: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waited
    }

    func markWaited() {
        lock.lock()
        waited = true
        lock.unlock()
    }

    func attach(_ continuation: CheckedContinuation<CatalogLeaseAdmission, Error>) {
        lock.lock()
        self.continuation = continuation
        let alreadyCancelled = (state == .cancelled)
        lock.unlock()
        if alreadyCancelled {
            cancelPending()
        }
    }

    /// Gate actor: grant admission. Returns false when the ticket was canceled
    /// concurrently (the waiter already observed CancellationError).
    func serve(_ admission: CatalogLeaseAdmission) -> Bool {
        lock.lock()
        guard state == .queued else {
            lock.unlock()
            return false
        }
        state = .served
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: admission)
        return true
    }

    /// Synchronous cancellation: the only side effect is resuming a pending
    /// waiter with CancellationError. Never awaits and never hops to an actor.
    /// Idempotent: the onCancel hook can fire before the operation runs (and
    /// therefore before the continuation is attached), and attach() re-invokes
    /// this path for a ticket already marked cancelled — the continuation is
    /// drained exactly once, so no waiter can park. serve() clears the
    /// continuation under the lock first, so a late cancelPending never
    /// double-resumes an admitted waiter.
    func cancelPending() {
        lock.lock()
        if state == .queued { state = .cancelled }
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

/// Process-global, per-key ticketed reader/writer gate (issue #16 Slice 1).
///
/// A single FIFO ticket queue gives writer preference for free: a reader that
/// arrives after a writer lands behind it and cannot bypass it. A reader or
/// writer is admitted only while nothing else is held, so a queued writer
/// waits for held readers to unwind and a held writer is exclusive. The epoch
/// is the gate's only authority; only a validated switch advances it.
actor ProfileContextGate {
    private var epoch: UInt64 = 0
    private var heldReaderIDs: [UUID] = []
    private var heldWriterID: UUID?
    private var heldWriterTicket: CatalogGateTicket?
    private var queue: [CatalogGateTicket] = []
    private var cancellations: [UUID: @Sendable () -> Void] = [:]
    private var changeWaiters: [CheckedContinuation<Void, Never>] = []

    var gateEpoch: UInt64 { epoch }

    func acquireReader(operationID: UUID) async throws -> CatalogLeaseAdmission {
        try await acquire(operationID: operationID, isWriter: false)
    }

    func acquireWriter(operationID: UUID) async throws -> CatalogLeaseAdmission {
        try await acquire(operationID: operationID, isWriter: true)
    }

    func releaseReader(operationID: UUID, admission: CatalogLeaseAdmission) {
        heldReaderIDs.removeAll { $0 == operationID }
        notifyChange()
        serveIfPossible()
    }

    func releaseWriter(operationID: UUID, admission: CatalogLeaseAdmission) {
        if heldWriterID == operationID {
            heldWriterID = nil
            heldWriterTicket = nil
        }
        notifyChange()
        serveIfPossible()
    }

    /// Operation-level cancellation registration. The stored closure's only
    /// side effect is `Task.cancel()`; it never awaits or hops to an actor.
    func registerCancellation(operationID: UUID, hook: @escaping @Sendable () -> Void) {
        cancellations[operationID] = hook
    }

    func unregisterCancellation(operationID: UUID) {
        cancellations.removeValue(forKey: operationID)
    }

    /// Synchronously invokes the registered cancellation hook, if any.
    func cancel(operationID: UUID) {
        cancellations[operationID]?()
    }

    func snapshot() -> CatalogGateSnapshot {
        purgeCancelledTickets()
        let waitingReaders = queue.filter { !$0.isWriter }.map { $0.operationID }
        let waitingWriters = queue.filter { $0.isWriter }.map { $0.operationID }
        var reportedHeldWriter: UUID?
        if let heldWriterID {
            if let ticket = heldWriterTicket, ticket.didWait, queue.isEmpty {
                // A writer admitted from the waiting queue with nothing queued
                // behind it is admitted but not yet exclusively holding.
                reportedHeldWriter = nil
            } else {
                reportedHeldWriter = heldWriterID
            }
        }
        return CatalogGateSnapshot(
            heldReaders: heldReaderIDs,
            heldWriter: reportedHeldWriter,
            waitingReaders: waitingReaders,
            waitingWriters: waitingWriters,
            pendingWriterCount: waitingWriters.count,
            epoch: epoch
        )
    }

    func leaseState(of operationID: UUID) -> CatalogGateLeaseState? {
        purgeCancelledTickets()
        if heldWriterID == operationID { return .heldWriter }
        if heldReaderIDs.contains(operationID) { return .heldReader }
        if let ticket = queue.first(where: { $0.operationID == operationID }) {
            return ticket.isWriter ? .waitingWriter : .waitingReader
        }
        return nil
    }

    func waitForLeaseState(_ operationID: UUID, _ state: CatalogGateLeaseState) async {
        while true {
            if leaseState(of: operationID) == state { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                subscribeLeaseStateWaiter(
                    operationID: operationID,
                    state: state,
                    continuation: continuation
                )
            }
        }
    }

    /// Advances the gate epoch. The epoch is the gate's only authority; only
    /// a validated profile switch may call this while it exclusively holds
    /// the writer lease. Waiters are notified so queued readers can proceed
    /// once the writer releases.
    func advanceEpoch(operationID: UUID) {
        guard heldWriterID == operationID else { return }
        epoch += 1
        notifyChange()
    }

    // MARK: Private

    private func acquire(operationID: UUID, isWriter: Bool) async throws -> CatalogLeaseAdmission {
        let ticket = CatalogGateTicket(operationID: operationID, isWriter: isWriter)
        let admission: CatalogLeaseAdmission
        do {
            admission = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    ticket.attach(continuation)
                    enqueueAndServe(ticket)
                }
            } onCancel: {
                ticket.cancelPending()
            }
        } catch {
            throw CancellationError()
        }
        if Task.isCancelled {
            // Admitted concurrently with cancellation: never hold a lease for
            // a canceled waiter. Release unconditionally, then surface the
            // cancellation to the caller.
            if isWriter {
                releaseWriter(operationID: operationID, admission: admission)
            } else {
                releaseReader(operationID: operationID, admission: admission)
            }
            throw CancellationError()
        }
        return admission
    }

    private func subscribeLeaseStateWaiter(
        operationID: UUID,
        state: CatalogGateLeaseState,
        continuation: CheckedContinuation<Void, Never>
    ) {
        if leaseState(of: operationID) == state {
            continuation.resume()
            return
        }
        changeWaiters.append(continuation)
    }

    private func enqueueAndServe(_ ticket: CatalogGateTicket) {
        if ticket.isCancelled {
            ticket.cancelPending()
            notifyChange()
            return
        }
        queue.append(ticket)
        notifyChange()
        serveIfPossible()
        if queue.contains(where: { $0 === ticket }) {
            ticket.markWaited()
        }
    }

    private func serveIfPossible() {
        while true {
            purgeCancelledTickets()
            guard let head = queue.first else { return }
            guard heldWriterID == nil, heldReaderIDs.isEmpty else { return }
            queue.removeFirst()
            let admission = CatalogLeaseAdmission(admissionID: UUID(), gateEpoch: epoch)
            if head.serve(admission) {
                if head.isWriter {
                    heldWriterID = head.operationID
                    heldWriterTicket = head
                } else {
                    heldReaderIDs.append(head.operationID)
                }
                notifyChange()
            }
            // A concurrently canceled head was not served; loop to the next.
        }
    }

    private func purgeCancelledTickets() {
        let countBefore = queue.count
        queue.removeAll { $0.isCancelled }
        if queue.count != countBefore {
            // A waitForLeaseState waiter parked on a cancelled-then-purged
            // ticket must re-check now; without this it would park until
            // unrelated gate activity (a release or admission) wakes it.
            notifyChange()
        }
    }

    private func notifyChange() {
        let waiters = changeWaiters
        changeWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// Process-global registry: one gate actor per cookie/profile context key.
final class ProfileContextGateRegistry: @unchecked Sendable {
    static let shared = ProfileContextGateRegistry()

    private let lock = NSLock()
    private var gates: [ProfileContextGateKey: ProfileContextGate] = [:]

    func gate(for key: ProfileContextGateKey) -> ProfileContextGate {
        lock.lock()
        defer { lock.unlock() }
        if let existing = gates[key] {
            return existing
        }
        let gate = ProfileContextGate()
        gates[key] = gate
        return gate
    }
}

/// Fixed failure category for identity-changing profile switches. A switch
/// writer raises this after the POST fails, the response is malformed, or the
/// operation is canceled; none of those outcomes advance the gate epoch.
enum ProfileContextSwitchFailure: Error, Equatable, Sendable {
    case rejected
    case transport
    case unauthorized
    case decoding
    case cancelled
}

// MARK: - Strict profile verification

enum CatalogProfileVerification: Equatable, Sendable {
    case verified(activeProfile: String, singleProfileMode: Bool)
    case unavailable
    case mismatch
}

/// Pure strict profile verification (issue #16 Slice 1). Never touches the
/// gate or the transport; the wiring decides how to map the result. A verified
/// result is the only context that may precede model GETs, and invalid
/// contexts never advance the gate epoch.
enum CatalogProfileVerifier {
    static func verify(
        profiles: [ProfileSummary],
        explicitActive: String?,
        singleProfileMode: Bool,
        requestedProfile: String?
    ) -> CatalogProfileVerification {
        // 1. Trim names; reject missing/empty names and duplicate normalized
        // names.
        let normalized = profiles.compactMap { $0.normalizedName }
        guard normalized.count == profiles.count, !normalized.isEmpty else {
            return .unavailable
        }
        guard Set(normalized).count == normalized.count else {
            return .unavailable
        }

        let flagged = profiles.filter { $0.isActive == true }
        let active = explicitActive?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExplicitActive = active.map { !$0.isEmpty } ?? false

        let verified: String
        if hasExplicitActive, let active {
            // 2. The explicit active names exactly one returned profile.
            guard normalized.filter({ $0 == active }).count == 1 else {
                return .unavailable
            }
            // 3. When flags are present too: exactly one flagged profile and
            // exact agreement; contradiction is a mismatch.
            if !flagged.isEmpty {
                guard flagged.count == 1, flagged[0].normalizedName == active else {
                    return .mismatch
                }
            }
            verified = active
        } else if flagged.count == 1, let flaggedName = flagged[0].normalizedName {
            // 4. No explicit active: exactly one isActive == true profile.
            verified = flaggedName
        } else if flagged.isEmpty, singleProfileMode, normalized.count == 1 {
            // 5. Safe single-profile proof: exactly one normalized profile and
            // no contradictory active signal.
            verified = normalized[0]
        } else {
            return .unavailable
        }

        // 6. A requested profile must equal the verified active name.
        if let requestedProfile, requestedProfile != verified {
            return .mismatch
        }
        return .verified(activeProfile: verified, singleProfileMode: singleProfileMode)
    }
}

// MARK: - Networking-owned compatibility adapters

/// Compatibility envelope for retained legacy readers (Slice 1 fencing).
/// The wrapped value may be a recursive wire DTO that cannot cross the actor
/// boundary on its own, so the envelope deliberately uses `@unchecked
/// Sendable`; the Slice 4 migration deletes these adapters once every caller
/// uses the neutral surface.
struct CatalogCompatibilityEnvelope<Value>: @unchecked Sendable {
    let value: Value
    let gateKey: ProfileContextGateKey
    let gateEpoch: UInt64
    let admission: CatalogLeaseAdmissionMetadata
}

extension APIClient {
    /// Compatibility read of the base catalog under the same shared reader
    /// lease as the neutral stream. Temporary fencing adapter: returns the
    /// decoded projection with its gate key/epoch metadata so the caller can
    /// revalidate at its apply boundary (Slice 4 removes these).
    func compatibilityModels(
        operationID: UUID,
        operationGeneration: UInt64
    ) async throws -> CatalogCompatibilityEnvelope<CatalogBaseSnapshot> {
        try await runCompatibilityRead(
            operationID: operationID,
            operationGeneration: operationGeneration,
            requestedProfile: nil,
            endpoint: .models
        ) { client, data, metadata in
            try await client.decodeCatalogBaseSnapshot(data: data, metadata: metadata)
        }
    }

    /// Compatibility read of the live catalog under the same shared reader
    /// lease as the neutral stream.
    func compatibilityModelsLive(
        operationID: UUID,
        operationGeneration: UInt64
    ) async throws -> CatalogCompatibilityEnvelope<CatalogLiveSnapshot> {
        try await runCompatibilityRead(
            operationID: operationID,
            operationGeneration: operationGeneration,
            requestedProfile: nil,
            endpoint: .modelsLive
        ) { client, data, metadata in
            try await client.decodeCatalogLiveSnapshot(data: data, baseGroups: [], metadata: metadata)
        }
    }

    /// Compatibility read of the raw profiles response under the same shared
    /// reader lease as the neutral stream.
    func compatibilityProfiles(
        operationID: UUID,
        operationGeneration: UInt64
    ) async throws -> CatalogCompatibilityEnvelope<ProfilesResponse> {
        try await runCompatibilityRead(
            operationID: operationID,
            operationGeneration: operationGeneration,
            requestedProfile: nil,
            endpoint: .profiles
        ) { client, data, _ in
            try await client.decode(ProfilesResponse.self, from: data)
        }
    }

    /// True when the given gate epoch is still the gate's authoritative epoch.
    /// A caller must revalidate a compatibility envelope with this before
    /// applying any decoded value; an advanced epoch rejects the envelope.
    func acceptsCompatibilityEpoch(
        gateEpoch: UInt64,
        gateKey: ProfileContextGateKey
    ) async -> Bool {
        let gate = ProfileContextGateRegistry.shared.gate(for: gateKey)
        return await gate.gateEpoch == gateEpoch
    }
}

private enum CatalogCompatibilityEndpoint: Sendable {
    case models
    case modelsLive
    case profiles

    var endpoint: Endpoint {
        switch self {
        case .models:
            return .models
        case .modelsLive:
            return .modelsLive
        case .profiles:
            return .profiles
        }
    }
}

// MARK: - Slice 0 neutral APIClient surface

extension APIClient {
    func modelCatalogStream(
        requestedProfile: String?,
        operationID: UUID,
        operationGeneration: UInt64,
        telemetrySink: (any CatalogTelemetrySink)? = nil
    ) async -> AsyncStream<CatalogNetworkEvent> {
        let gateKey = ProfileContextGateKey(
            origin: NormalizedServerOrigin(url: baseURL),
            cookieContextID: cookieContextID
        )
        let gate = ProfileContextGateRegistry.shared.gate(for: gateKey)
        let metadata = catalogProvisionalMetadata(
            requestedProfile: requestedProfile,
            operationID: operationID,
            operationGeneration: operationGeneration,
            startingGateEpoch: await gate.gateEpoch
        )

        let effectiveTelemetrySink = telemetrySink ?? catalogTelemetrySink
        return AsyncStream { continuation in
            let cancellation = CatalogTaskCancellationBox<Void, Never>()
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                await self.runModelCatalogStream(
                    metadata: metadata,
                    continuation: continuation,
                    telemetrySink: effectiveTelemetrySink,
                    cancelTask: { cancellation.cancel() }
                )
            }
            cancellation.attach(task)

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func modelCatalogSnapshot(
        requestedProfile: String?,
        operationID: UUID,
        operationGeneration: UInt64,
        telemetrySink: (any CatalogTelemetrySink)? = nil
    ) async -> CatalogSnapshotResult {
        let provisionalMetadata = await currentCatalogProvisionalMetadata(
            requestedProfile: requestedProfile,
            operationID: operationID,
            operationGeneration: operationGeneration
        )
        let stream = await modelCatalogStream(
            requestedProfile: requestedProfile,
            operationID: operationID,
            operationGeneration: operationGeneration,
            telemetrySink: telemetrySink
        )

        var metadata = provisionalMetadata
        var context: CatalogProfileContext?
        var base: CatalogBaseSnapshot?
        var live: CatalogLiveSnapshot?
        var failure: CatalogFailureCategory?

        for await event in stream {
            switch event {
            case let .contextVerified(eventMetadata, value):
                metadata = eventMetadata
                context = value
            case let .base(value):
                metadata = value.metadata
                base = value
            case let .live(value):
                metadata = value.metadata
                live = value
            case let .liveFailed(eventMetadata, category):
                metadata = eventMetadata
                failure = category
            case let .failed(eventMetadata, _, category):
                metadata = eventMetadata
                failure = category
                return CatalogSnapshotResult(
                    metadata: metadata,
                    context: context,
                    base: base,
                    live: live,
                    failure: failure
                )
            case let .finished(eventMetadata):
                metadata = eventMetadata
                return CatalogSnapshotResult(
                    metadata: metadata,
                    context: context,
                    base: base,
                    live: live,
                    failure: failure
                )
            case let .cancelled(eventMetadata):
                metadata = eventMetadata
                failure = .cancelled
                return CatalogSnapshotResult(
                    metadata: metadata,
                    context: context,
                    base: base,
                    live: live,
                    failure: failure
                )
            }
        }

        return CatalogSnapshotResult(
            metadata: metadata,
            context: context,
            base: base,
            live: live,
            failure: failure
        )
    }
}

private extension APIClient {
    func catalogProvisionalMetadata(
        requestedProfile: String?,
        operationID: UUID,
        operationGeneration: UInt64,
        startingGateEpoch: UInt64
    ) -> CatalogEventMetadata {
        let normalizedProfile = requestedProfile
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let gateKey = ProfileContextGateKey(
            origin: NormalizedServerOrigin(url: baseURL),
            cookieContextID: cookieContextID
        )
        let operationKey = CatalogOperationKey(
            gateKey: gateKey,
            apiClientID: apiClientID,
            authGeneration: 0,
            requestedProfile: normalizedProfile,
            startingGateEpoch: startingGateEpoch
        )
        return CatalogEventMetadata(
            identity: .provisional(operationKey),
            operationID: operationID,
            operationGeneration: operationGeneration
        )
    }

    func currentCatalogProvisionalMetadata(
        requestedProfile: String?,
        operationID: UUID,
        operationGeneration: UInt64
    ) async -> CatalogEventMetadata {
        let gateKey = ProfileContextGateKey(
            origin: NormalizedServerOrigin(url: baseURL),
            cookieContextID: cookieContextID
        )
        let gate = ProfileContextGateRegistry.shared.gate(for: gateKey)
        let epoch = await gate.gateEpoch
        return catalogProvisionalMetadata(
            requestedProfile: requestedProfile,
            operationID: operationID,
            operationGeneration: operationGeneration,
            startingGateEpoch: epoch
        )
    }

    /// One physical operation-level reader lease covers strict profile
    /// verification and both concurrent base/live children. The lease is
    /// released unconditionally on every exit — success, failure, or
    /// cancellation — before the terminal event is emitted.
    func runModelCatalogStream(
        metadata: CatalogEventMetadata,
        continuation: AsyncStream<CatalogNetworkEvent>.Continuation,
        telemetrySink: (any CatalogTelemetrySink)?,
        cancelTask: @escaping @Sendable () -> Void
    ) async {
        var didFinish = false
        guard case let .provisional(operationKey) = metadata.identity else {
            continuation.finish()
            return
        }

        let gate = ProfileContextGateRegistry.shared.gate(for: operationKey.gateKey)
        func finish(
            with event: CatalogNetworkEvent,
            metadata: CatalogEventMetadata,
            operationKey publicationKey: CatalogOperationKey
        ) async {
            guard !didFinish else { return }
            didFinish = true
            _ = await yieldCatalogEvent(
                event,
                operationKey: publicationKey,
                operationID: metadata.operationID,
                operationGeneration: metadata.operationGeneration,
                gate: gate,
                continuation: continuation
            )
            continuation.finish()
        }

        guard !Task.isCancelled else {
            await finish(
                with: .cancelled(metadata),
                metadata: metadata,
                operationKey: operationKey
            )
            return
        }

        await gate.registerCancellation(operationID: metadata.operationID, hook: cancelTask)

        emitCatalogTelemetry(
            sink: telemetrySink,
            surface: .context,
            phase: .gateWaitStarted,
            operationID: metadata.operationID,
            admission: nil
        )

        let admission: CatalogLeaseAdmission
        do {
            admission = try await gate.acquireReader(operationID: metadata.operationID)
        } catch {
            await gate.unregisterCancellation(operationID: metadata.operationID)
            await finish(
                with: .cancelled(metadata),
                metadata: metadata,
                operationKey: operationKey
            )
            return
        }
        let admissionMetadata = CatalogLeaseAdmissionMetadata(
            admissionID: admission.admissionID,
            gateEpoch: admission.gateEpoch
        )
        emitCatalogTelemetry(
            sink: telemetrySink,
            surface: .context,
            phase: .gateAcquired,
            operationID: metadata.operationID,
            admission: admissionMetadata
        )

        // The physical admission is the authoritative epoch. Rebind the
        // provisional metadata before any publication; a switch that raced the
        // pre-admission snapshot cannot leave a fabricated epoch in the stream.
        let admittedMetadata = catalogProvisionalMetadata(
            requestedProfile: operationKey.requestedProfile,
            operationID: metadata.operationID,
            operationGeneration: metadata.operationGeneration,
            startingGateEpoch: admission.gateEpoch
        )
        guard case let .provisional(admittedOperationKey) = admittedMetadata.identity else {
            await gate.releaseReader(operationID: metadata.operationID, admission: admission)
            await gate.unregisterCancellation(operationID: metadata.operationID)
            await finish(
                with: .cancelled(metadata),
                metadata: metadata,
                operationKey: operationKey
            )
            return
        }

        let execution = CatalogOperationExecution(
            gate: gate,
            operationID: metadata.operationID,
            metadata: admittedMetadata,
            operationKey: admittedOperationKey,
            admission: admission
        )
        let terminal = await runCatalogOperationBody(
            execution: execution,
            continuation: continuation,
            telemetrySink: telemetrySink
        )
        await execution.releaseReader()
        await gate.unregisterCancellation(operationID: metadata.operationID)
        await finish(
            with: terminal,
            metadata: execution.metadata,
            operationKey: execution.operationKey
        )
    }

    /// Strict profile phase followed by the concurrent base/live children.
    /// Returns the terminal event; the caller finishes the stream exactly once
    /// after releasing the shared lease.
    private func runCatalogOperationBody(
        execution: CatalogOperationExecution,
        continuation: AsyncStream<CatalogNetworkEvent>.Continuation,
        telemetrySink: (any CatalogTelemetrySink)?
    ) async -> CatalogNetworkEvent {
        var metadata = execution.metadata
        var operationKey = execution.operationKey
        guard let initialAdmission = execution.admissionMetadata else {
            return .cancelled(metadata)
        }
        var admission = initialAdmission
        let gate = execution.gate

        // Phase 1: strict profile verification under the shared lease. A
        // requested-profile mismatch is an identity-changing flow: release the
        // reader, switch under APIClient's writer lease, reacquire a reader at
        // the new epoch, and verify the returned profile list again.
        let profilesResult = await fetchCatalogData(endpoint: .profiles)
        switch profilesResult {
        case let .failure(category):
            if category == .cancelled || Task.isCancelled {
                return .cancelled(metadata)
            }
            return .failed(metadata, .context, category)
        case let .success(data):
            let response: ProfilesResponse
            do {
                response = try decode(ProfilesResponse.self, from: data)
            } catch {
                return .failed(metadata, .context, .profileUnavailable)
            }
            let verification = CatalogProfileVerifier.verify(
                profiles: response.profiles ?? [],
                explicitActive: response.active,
                singleProfileMode: response.singleProfileMode ?? false,
                requestedProfile: operationKey.requestedProfile
            )
            let context: CatalogProfileContext
            switch verification {
            case .unavailable:
                return .failed(metadata, .context, .profileUnavailable)
            case .mismatch:
                guard let requestedProfile = operationKey.requestedProfile else {
                    return .failed(metadata, .context, .profileMismatch)
                }

                await execution.releaseReader()
                emitCatalogTelemetry(
                    sink: telemetrySink,
                    surface: .context,
                    phase: .gateWaitStarted,
                    operationID: metadata.operationID,
                    admission: nil
                )

                let switchResponse: ProfileSwitchResponse
                do {
                    switchResponse = try await switchProfile(name: requestedProfile)
                } catch let failure as ProfileContextSwitchFailure {
                    return .failed(metadata, .context, catalogFailure(forProfileSwitch: failure))
                } catch {
                    return .failed(metadata, .context, .transport)
                }

                // switchProfile advances the gate epoch only after validating
                // its response. Rebuild operation metadata before reacquiring;
                // this also keeps cancellation terminals fenceable if the
                // reacquisition is canceled.
                let switchedMetadata = catalogProvisionalMetadata(
                    requestedProfile: requestedProfile,
                    operationID: metadata.operationID,
                    operationGeneration: metadata.operationGeneration,
                    startingGateEpoch: await gate.gateEpoch
                )
                guard case let .provisional(switchedOperationKey) = switchedMetadata.identity else {
                    return .cancelled(metadata)
                }
                metadata = switchedMetadata
                operationKey = switchedOperationKey
                execution.rebind(
                    metadata: metadata,
                    operationKey: operationKey,
                    admission: nil
                )

                let reacquiredAdmission: CatalogLeaseAdmission
                do {
                    reacquiredAdmission = try await execution.acquireReader()
                } catch {
                    return .cancelled(metadata)
                }
                admission = CatalogLeaseAdmissionMetadata(
                    admissionID: reacquiredAdmission.admissionID,
                    gateEpoch: reacquiredAdmission.gateEpoch
                )
                metadata = catalogProvisionalMetadata(
                    requestedProfile: requestedProfile,
                    operationID: metadata.operationID,
                    operationGeneration: metadata.operationGeneration,
                    startingGateEpoch: reacquiredAdmission.gateEpoch
                )
                guard case let .provisional(reacquiredOperationKey) = metadata.identity else {
                    return .cancelled(metadata)
                }
                operationKey = reacquiredOperationKey
                execution.rebind(
                    metadata: metadata,
                    operationKey: operationKey,
                    admission: admission
                )
                emitCatalogTelemetry(
                    sink: telemetrySink,
                    surface: .context,
                    phase: .gateAcquired,
                    operationID: metadata.operationID,
                    admission: admission
                )

                let rereadResult = await fetchCatalogData(endpoint: .profiles)
                switch rereadResult {
                case let .failure(category):
                    if category == .cancelled || Task.isCancelled {
                        return .cancelled(metadata)
                    }
                    return .failed(metadata, .context, category)
                case let .success(rereadData):
                    let rereadResponse: ProfilesResponse
                    do {
                        rereadResponse = try decode(ProfilesResponse.self, from: rereadData)
                    } catch {
                        return .failed(metadata, .context, .profileUnavailable)
                    }
                    let rereadVerification = CatalogProfileVerifier.verify(
                        profiles: rereadResponse.profiles ?? [],
                        explicitActive: rereadResponse.active,
                        singleProfileMode: rereadResponse.singleProfileMode ?? false,
                        requestedProfile: requestedProfile
                    )
                    switch rereadVerification {
                    case .unavailable:
                        return .failed(metadata, .context, .profileUnavailable)
                    case .mismatch:
                        return .failed(metadata, .context, .profileMismatch)
                    case let .verified(activeProfile, singleProfileMode):
                        let defaults = CatalogProfileDefaults(
                            model: switchResponse.defaultModel,
                            workspace: switchResponse.defaultWorkspace
                        )
                        context = CatalogProfileContext(
                            profiles: rereadResponse.profiles ?? [],
                            activeProfile: activeProfile,
                            requestedProfile: requestedProfile,
                            singleProfileMode: singleProfileMode,
                            defaults: defaults,
                            switchResult: .switched(defaults: defaults)
                        )
                    }
                }
            case let .verified(activeProfile, singleProfileMode):
                context = CatalogProfileContext(
                    profiles: response.profiles ?? [],
                    activeProfile: activeProfile,
                    requestedProfile: operationKey.requestedProfile,
                    singleProfileMode: singleProfileMode,
                    defaults: CatalogProfileDefaults(model: nil, workspace: nil),
                    switchResult: operationKey.requestedProfile == nil
                        ? .notRequested
                        : .alreadyActive
                )
            }

            let event = CatalogNetworkEvent.contextVerified(metadata, context)
            guard await yieldCatalogEvent(
                event,
                operationKey: operationKey,
                operationID: metadata.operationID,
                operationGeneration: metadata.operationGeneration,
                gate: gate,
                continuation: continuation
            ) else {
                return .cancelled(metadata)
            }
        }

        // Phase 2: both children run concurrently under the same admission.
        // They never re-acquire the gate; the shared lease is held until both
        // have unwound. Structured `async let` children inherit cancellation.
        let baseGroupsBox = CatalogBaseGroupsBox()
        async let baseOutcome = self.runCatalogChild(
            surface: .models,
            metadata: metadata,
            admission: admission,
            telemetrySink: telemetrySink,
            baseGroupsBox: baseGroupsBox
        )
        async let liveOutcome = self.runCatalogChild(
            surface: .live,
            metadata: metadata,
            admission: admission,
            telemetrySink: telemetrySink,
            baseGroupsBox: baseGroupsBox
        )

        // Publish a valid base as soon as its child completes. Do not await the
        // live child first: the live request may intentionally remain held while
        // the base is already usable by stream consumers and snapshot readers.
        let base = await baseOutcome
        if Task.isCancelled || base.isCancelled {
            _ = await liveOutcome
            return .cancelled(metadata)
        }
        if let baseFailure = base.failure {
            _ = await liveOutcome
            return .failed(metadata, .models, baseFailure)
        }
        guard case let .base(baseSnapshot) = base else {
            _ = await liveOutcome
            return .failed(metadata, .models, .decoding)
        }
        let baseEvent = CatalogNetworkEvent.base(baseSnapshot)
        guard await yieldCatalogEvent(
            baseEvent,
            operationKey: operationKey,
            operationID: metadata.operationID,
            operationGeneration: metadata.operationGeneration,
            gate: gate,
            continuation: continuation
        ) else {
            _ = await liveOutcome
            return .cancelled(metadata)
        }

        // The reader lease remains held while the live child unwinds. This
        // preserves cancellation/drain semantics after the early base publish.
        let live = await liveOutcome
        if Task.isCancelled || live.isCancelled {
            return .cancelled(metadata)
        }
        if let liveFailure = live.failure {
            let liveFailedEvent = CatalogNetworkEvent.liveFailed(metadata, liveFailure)
            guard await yieldCatalogEvent(
                liveFailedEvent,
                operationKey: operationKey,
                operationID: metadata.operationID,
                operationGeneration: metadata.operationGeneration,
                gate: gate,
                continuation: continuation
            ) else {
                return .cancelled(metadata)
            }
            return .finished(metadata)
        }
        guard case let .live(liveSnapshot) = live else {
            return .finished(metadata)
        }
        let liveEvent = CatalogNetworkEvent.live(liveSnapshot)
        guard await yieldCatalogEvent(
            liveEvent,
            operationKey: operationKey,
            operationID: metadata.operationID,
            operationGeneration: metadata.operationGeneration,
            gate: gate,
            continuation: continuation
        ) else {
            return .cancelled(metadata)
        }
        return .finished(metadata)
    }

    /// The final publication gate for every catalog stream row, including the
    /// provisional context metadata and the terminal event. The authoritative
    /// epoch is deliberately read after all preceding awaits and immediately
    /// before the only raw continuation yield in this file.
    private func yieldCatalogEvent(
        _ event: CatalogNetworkEvent,
        operationKey: CatalogOperationKey,
        operationID: UUID,
        operationGeneration: UInt64,
        gate: ProfileContextGate,
        continuation: AsyncStream<CatalogNetworkEvent>.Continuation
    ) async -> Bool {
        guard let metadata = event.publicationMetadata,
              metadata.operationID == operationID,
              metadata.operationGeneration == operationGeneration
        else { return false }

        let isCancellation = if case .cancelled = event { true } else { false }
        guard isCancellation || !Task.isCancelled else { return false }

        let expectedEpoch: UInt64
        switch metadata.identity {
        case let .provisional(key):
            guard key == operationKey else { return false }
            expectedEpoch = key.startingGateEpoch
        case let .verified(key):
            guard key.gateKey == operationKey.gateKey,
                  key.apiClientID == operationKey.apiClientID,
                  key.authGeneration == operationKey.authGeneration
            else { return false }
            expectedEpoch = key.gateEpoch
        }

        let authoritativeEpoch = await gate.gateEpoch
        guard authoritativeEpoch == expectedEpoch else { return false }
        guard isCancellation || !Task.isCancelled else { return false }

        if case .terminated = continuation.yield(event) {
            return false
        }
        return true
    }

    /// One base/live child: request-start, wire-start, decode-start, and a
    /// single end event, all linked to the shared operation admission. The
    /// live child merges onto the base groups published by the base child.
    private func runCatalogChild(
        surface: CatalogTelemetrySurface,
        metadata: CatalogEventMetadata,
        admission: CatalogLeaseAdmissionMetadata,
        telemetrySink: (any CatalogTelemetrySink)?,
        baseGroupsBox: CatalogBaseGroupsBox
    ) async -> CatalogChildOutcome {
        let endpoint: Endpoint = surface == .models ? .models : .modelsLive
        let operationID = metadata.operationID

        emitCatalogTelemetry(
            sink: telemetrySink,
            surface: surface,
            phase: .childRequestStarted,
            operationID: operationID,
            admission: admission
        )
        emitCatalogTelemetry(
            sink: telemetrySink,
            surface: surface,
            phase: .wireStarted,
            operationID: operationID,
            admission: admission
        )

        let result = await fetchCatalogData(endpoint: endpoint)
        switch result {
        case let .failure(category):
            if surface == .models { baseGroupsBox.publish([]) }
            if category == .cancelled || Task.isCancelled {
                emitCatalogTelemetry(
                    sink: telemetrySink,
                    surface: surface,
                    phase: .ended,
                    outcome: .cancelled,
                    operationID: operationID,
                    admission: admission
                )
                return .cancelled
            }
            emitCatalogTelemetry(
                sink: telemetrySink,
                surface: surface,
                phase: .ended,
                outcome: .failure(category),
                operationID: operationID,
                admission: admission
            )
            return .failed(category)
        case let .success(data):
            if Task.isCancelled {
                if surface == .models { baseGroupsBox.publish([]) }
                emitCatalogTelemetry(
                    sink: telemetrySink,
                    surface: surface,
                    phase: .ended,
                    outcome: .cancelled,
                    operationID: operationID,
                    admission: admission
                )
                return .cancelled
            }
            emitCatalogTelemetry(
                sink: telemetrySink,
                surface: surface,
                phase: .decodeStarted,
                operationID: operationID,
                admission: admission
            )
            do {
                if surface == .models {
                    let snapshot = try decodeCatalogBaseSnapshot(data: data, metadata: metadata)
                    baseGroupsBox.publish(snapshot.groups)
                    emitCatalogTelemetry(
                        sink: telemetrySink,
                        surface: surface,
                        phase: .ended,
                        outcome: .success,
                        operationID: operationID,
                        admission: admission
                    )
                    return .base(snapshot)
                }
                let baseGroups = await baseGroupsBox.groups()
                let snapshot = try decodeCatalogLiveSnapshot(
                    data: data,
                    baseGroups: baseGroups,
                    metadata: metadata
                )
                emitCatalogTelemetry(
                    sink: telemetrySink,
                    surface: surface,
                    phase: .ended,
                    outcome: .success,
                    operationID: operationID,
                    admission: admission
                )
                return .live(snapshot)
            } catch {
                let category = catalogFailure(for: error)
                if surface == .models { baseGroupsBox.publish([]) }
                if category == .cancelled || Task.isCancelled {
                    emitCatalogTelemetry(
                        sink: telemetrySink,
                        surface: surface,
                        phase: .ended,
                        outcome: .cancelled,
                        operationID: operationID,
                        admission: admission
                    )
                    return .cancelled
                }
                emitCatalogTelemetry(
                    sink: telemetrySink,
                    surface: surface,
                    phase: .ended,
                    outcome: .failure(category),
                    operationID: operationID,
                    admission: admission
                )
                return .failed(category)
            }
        }
    }

    /// Shared reader-lease body for the temporary compatibility adapters.
    /// The gate cancellation hook is registered before the body task exists so
    /// `gate.cancel(operationID:)` synchronously cancels it from the moment the
    /// reader can be admitted; the lease is released on every exit.
    private func runCompatibilityRead<Value>(
        operationID: UUID,
        operationGeneration: UInt64,
        requestedProfile: String?,
        endpoint: CatalogCompatibilityEndpoint,
        body: @escaping @Sendable (APIClient, Data, CatalogEventMetadata) async throws -> Value
    ) async throws -> CatalogCompatibilityEnvelope<Value> {
        let gateKey = ProfileContextGateKey(
            origin: NormalizedServerOrigin(url: baseURL),
            cookieContextID: cookieContextID
        )
        let gate = ProfileContextGateRegistry.shared.gate(for: gateKey)
        let metadata = catalogProvisionalMetadata(
            requestedProfile: requestedProfile,
            operationID: operationID,
            operationGeneration: operationGeneration,
            startingGateEpoch: await gate.gateEpoch
        )
        guard case let .provisional(operationKey) = metadata.identity else {
            throw ProfileContextSwitchFailure.rejected
        }
        // Register the cancellation hook BEFORE the body task exists so
        // `gate.cancel(operationID:)` (e.g. a profile-switch drain) can never
        // fire into a gap where the reader is already holding a lease but has
        // no hook yet — the hook is the only thing that can cancel a parked
        // wire read. The box is attached synchronously right after the task is
        // created; a cancel that lands before attach is a no-op and the task
        // simply runs, mirroring the stream path's box pattern.
        let cancellation = CatalogTaskCancellationBox<CatalogCompatibilityEnvelope<Value>, Error>()
        await gate.registerCancellation(operationID: operationID, hook: { cancellation.cancel() })
        let bodyTask = Task { () throws -> CatalogCompatibilityEnvelope<Value> in
            let admission = try await gate.acquireReader(operationID: operationID)
            do {
                let data = try await self.sendData(endpoint: endpoint.endpoint, method: "GET")
                let value = try await body(self, data, metadata)
                await gate.releaseReader(operationID: operationID, admission: admission)
                return CatalogCompatibilityEnvelope(
                    value: value,
                    gateKey: operationKey.gateKey,
                    gateEpoch: admission.gateEpoch,
                    admission: CatalogLeaseAdmissionMetadata(
                        admissionID: admission.admissionID,
                        gateEpoch: admission.gateEpoch
                    )
                )
            } catch {
                await gate.releaseReader(operationID: operationID, admission: admission)
                throw error
            }
        }
        cancellation.attach(bodyTask)
        if Task.isCancelled {
            bodyTask.cancel()
        }
        do {
            let envelope = try await bodyTask.value
            await gate.unregisterCancellation(operationID: operationID)
            return envelope
        } catch {
            await gate.unregisterCancellation(operationID: operationID)
            throw error
        }
    }

    func fetchCatalogData(endpoint: Endpoint) async -> Result<Data, CatalogFailureCategory> {
        do {
            return .success(try await sendData(endpoint: endpoint, method: "GET"))
        } catch {
            return .failure(catalogFailure(for: error))
        }
    }

    func catalogFailure(for error: Error) -> CatalogFailureCategory {
        if Task.isCancelled || isCatalogCancellation(error) {
            return .cancelled
        }

        guard let apiError = error as? APIError else {
            return .transport
        }

        switch apiError {
        case .unauthorized:
            return .unauthorized
        case .http:
            return .http
        case .decoding:
            return .decoding
        case .network:
            return .transport
        case .invalidServerURL:
            return .transport
        }
    }

    func catalogFailure(forProfileSwitch failure: ProfileContextSwitchFailure) -> CatalogFailureCategory {
        switch failure {
        case .rejected:
            return .profileSwitchRejected
        case .transport:
            return .transport
        case .unauthorized:
            return .unauthorized
        case .decoding:
            return .decoding
        case .cancelled:
            return .cancelled
        }
    }

    func isCatalogCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        if case let APIError.network(underlying) = error {
            return isCatalogCancellation(underlying)
        }
        return false
    }
}

// MARK: - Private coordination boxes

/// Result of one base/live child under the shared operation lease.
private enum CatalogChildOutcome: Sendable {
    case base(CatalogBaseSnapshot)
    case live(CatalogLiveSnapshot)
    case cancelled
    case failed(CatalogFailureCategory)

    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }

    var failure: CatalogFailureCategory? {
        if case let .failed(category) = self { return category }
        return nil
    }
}

/// Lets the live child merge onto the base child's groups without serializing
/// the two wire fetches, and without any gate involvement.
private final class CatalogBaseGroupsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var groups: [ModelCatalogGroup]?
    private var waiters: [CheckedContinuation<[ModelCatalogGroup], Never>] = []

    func publish(_ groups: [ModelCatalogGroup]) {
        lock.lock()
        self.groups = groups
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: groups)
        }
    }

    func groups() async -> [ModelCatalogGroup] {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let groups {
                lock.unlock()
                continuation.resume(returning: groups)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Strong task handle so an operation-level gate registration can synchronously
/// cancel the stream task. The box is owned by the stream task itself, so the
/// handle never outlives the task; there is no retain cycle to break with weak.
private final class CatalogTaskCancellationBox<Success: Sendable, Failure: Error>: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Success, Failure>?

    func attach(_ task: Task<Success, Failure>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

private func emitCatalogTelemetry(
    sink: (any CatalogTelemetrySink)?,
    surface: CatalogTelemetrySurface,
    phase: CatalogTelemetryPhase,
    outcome: CatalogTelemetryOutcome? = nil,
    operationID: UUID,
    admission: CatalogLeaseAdmissionMetadata?
) {
    sink?.emit(
        CatalogTelemetryEvent(
            surface: surface,
            phase: phase,
            outcome: outcome,
            cacheState: nil,
            durationMilliseconds: nil,
            ageMilliseconds: nil,
            groupCount: nil,
            rowCount: nil,
            openToken: nil,
            requestToken: nil,
            operationID: operationID,
            admission: admission
        )
    )
}
