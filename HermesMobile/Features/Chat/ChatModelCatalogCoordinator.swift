import Foundation

/// Every `CatalogNetworkEvent` case carries (or wraps) operation metadata.
/// This accessor is local to the coordinator; the Networking event shape is
/// untouched (Slice 1 surface preserved).
private extension CatalogNetworkEvent {
    var eventMetadata: CatalogEventMetadata? {
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

// MARK: - Slice 2: ChatModelCatalogCoordinator (issue #16)
//
// One coordinator per ChatViewModel: the Chat-facing multicast seam of the
// model catalog. It consumes only neutral `CatalogNetworkEvent` projections
// (produced by `APIClient.modelCatalogStream` in production, scripted in the
// test harness) and multicasts Chat-side `CatalogEvent`s to ordered
// subscribers.
//
// Behavior contract (issue #16 v6.5/v6.8 Slice 2):
// - In-flight operations are keyed by `CatalogOperationKey` (provisional key
//   including the starting gate epoch); duplicate opens and an
//   initial-load-plus-picker refresh with the same provisional key share ONE
//   operation and one profile phase.
// - After `.contextVerified` the operation is promoted to a verified
//   `CatalogContextKey`; completed cache entries are keyed by that context
//   key and store projections WITHOUT event metadata (the metadata used for
//   publication is rebound from the current operation or the last-known
//   operation metadata of the context).
// - Fresh age < `freshnessInterval` publishes without refresh; age >= the
//   interval publishes stale rows immediately and starts/coalesces one
//   refresh; `retry()` is the only forced refresh and may refresh a fresh
//   snapshot. A valid empty base is a successful `.freshEmpty` and clears
//   loading. Fresh cache hits are served only while the completed cache is
//   below `completedContextLimit`; once at capacity the picker refetches,
//   which is what makes LRU eviction observable.
// - At most `completedContextLimit` completed context entries are retained
//   with LRU eviction (insertion order, MRU on rewrite); an in-flight
//   operation is never evicted.
// - Before yielding any event the coordinator verifies the operation
//   UUID/generation against the current operation, the process-global
//   registry's authoritative gate epoch, and the operation's context; a
//   switch advances the epoch, drops old completions, emits a context reset
//   before the new context's rows, and an old completion's cleanup never
//   removes a replacement operation.
// - A profile-context failure with no verified cache becomes
//   `.coldFailed(.profileUnavailable/.profileMismatch)`, clears loading, and
//   leaves retry accessible; with a previously verified snapshot for the same
//   context it publishes that snapshot read-only as `.staleFailed` without
//   refreshing.

/// Chat-facing multicast event. The coordinator emits these in publication
/// order to every subscriber; terminal events carry the operation metadata
/// that produced them.
enum CatalogEvent: Equatable, Sendable {
    /// The operation's strict profile phase succeeded. A context reset
    /// precedes this event whenever the context differs from the previously
    /// visible one.
    case contextVerified(CatalogEventMetadata, CatalogProfileContext)
    /// A base catalog snapshot: fresh rows, a cached publication rebound to
    /// the current operation's metadata, or read-only stale rows.
    case base(CatalogBaseSnapshot)
    /// A live catalog snapshot whose provider matches the visible base.
    case live(CatalogLiveSnapshot)
    /// The live child failed after a valid base; the base stays the visible
    /// catalog (non-terminal for the catalog).
    case liveFailed(CatalogEventMetadata, CatalogFailureCategory)
    /// A terminal operation failure (context/models phase).
    case failed(CatalogEventMetadata, CatalogPhase, CatalogFailureCategory)
    /// The operation completed (base and, when available, live both landed).
    case finished(CatalogEventMetadata)
    /// The operation was canceled.
    case cancelled(CatalogEventMetadata)
    /// A different verified context is about to become visible; subscribers
    /// must drop previously published rows before the new rows arrive.
    case contextReset(CatalogEventMetadata)
    /// Compatibility readiness hint. The associated state has no acceptance
    /// metadata and is therefore never authoritative; consumers that need to
    /// apply readiness must use `currentStateSnapshot()`.
    case state(CatalogCacheState)
}

private extension CatalogEvent {
    var publicationMetadata: CatalogEventMetadata? {
        switch self {
        case let .contextVerified(metadata, _),
             let .liveFailed(metadata, _),
             let .finished(metadata),
             let .cancelled(metadata),
             let .contextReset(metadata):
            return metadata
        case let .failed(metadata, _, _):
            return metadata
        case let .base(snapshot):
            return snapshot.metadata
        case let .live(snapshot):
            return snapshot.metadata
        case .state:
            return nil
        }
    }
}

/// Metadata-bearing readiness projection for consumers. The compatibility
/// `CatalogEvent.state` remains available for existing state-transition tests,
/// but it is only a hint because its payload predates publication fencing.
struct CatalogStateSnapshot: Equatable, Sendable {
    let metadata: CatalogEventMetadata
    let state: CatalogCacheState
}

/// Per-VM model catalog coordinator (issue #16 Slice 2).
///
/// The actor owns the per-context state machine, the completed-context LRU
/// cache, and the multicast fan-out. Network consumption runs in a detached
/// child task that hops back to the actor for every event, so all state
/// mutation is actor-serialized and subscriber cancellation never cancels a
/// coordinator-owned operation.
actor ChatModelCatalogCoordinator {
    /// Injected coordinator configuration.
    struct Configuration: Sendable {
        /// Clock source; the coordinator uses it for cache freshness only.
        let now: @Sendable () -> Date
        /// Age at which a completed cache entry is considered stale.
        let freshnessInterval: TimeInterval
        /// Maximum number of completed context entries retained (LRU).
        let completedContextLimit: Int
        /// Optional telemetry sink for forwarded catalog telemetry.
        let telemetrySink: (any CatalogTelemetrySink)?
    }

    // MARK: Stored state

    private let gateKey: ProfileContextGateKey
    private let apiClientID: UUID
    private let authGeneration: UInt64
    private let provider: @Sendable (String?, UUID, UInt64) async -> AsyncStream<CatalogNetworkEvent>
    private let configuration: Configuration

    private let multicast = CatalogEventMulticast()

    /// Readiness state; `.coldFailed` is terminal (not loading) and leaves
    /// retry accessible.
    private(set) var state: CatalogCacheState = .cold

    /// The latest fenced readiness projection. This is the authoritative state
    /// surface for consumers; the compatibility `.state` event is only a hint.
    private(set) var stateSnapshot: CatalogStateSnapshot?

    /// Monotonic cache revision used to fence a stale projection across the
    /// authoritative gate-epoch await in the final publication check.
    private var cacheRevision: UInt64 = 0

    /// The single in-flight (or terminal-but-not-yet-drained) operation.
    private var currentOperation: CurrentOperation?

    /// The verified context of the most recently published rows.
    private var visibleContextKey: CatalogContextKey?

    /// Completed context cache: projections without event metadata, plus the
    /// last-known operation metadata used to rebind cache publications.
    private var cache: [CatalogContextKey: CachedContext] = [:]
    /// Insertion order for LRU eviction (append on write, evict from front).
    private var cacheOrder: [CatalogContextKey] = []

    /// Monotonic operation generation counter.
    private var nextOperationGeneration: UInt64 = 1

    // MARK: Init

    init(
        gateKey: ProfileContextGateKey,
        apiClientID: UUID,
        authGeneration: UInt64,
        provider: @escaping @Sendable (String?, UUID, UInt64) async -> AsyncStream<CatalogNetworkEvent>,
        configuration: Configuration
    ) {
        self.gateKey = gateKey
        self.apiClientID = apiClientID
        self.authGeneration = authGeneration
        self.provider = provider
        self.configuration = configuration
    }

    // MARK: Public API

    /// Returns a fresh ordered stream of `CatalogEvent`s. Subscribers are
    /// independent: canceling one subscription never cancels the
    /// coordinator-owned operation or other subscribers.
    func subscribe() -> AsyncStream<CatalogEvent> {
        multicast.subscribe()
    }

    /// Returns the last readiness snapshot accepted by the coordinator's
    /// publication fence. Unlike the compatibility `.state` event, this value
    /// carries the operation, generation, context, and gate-epoch token needed
    /// by a consumer before applying state to its own projection.
    func currentStateSnapshot() -> CatalogStateSnapshot? {
        stateSnapshot
    }

    /// Opens the picker for the current profile context.
    ///
    /// - Coalesces onto an in-flight operation whose starting gate epoch is
    ///   still authoritative.
    /// - Supersedes an in-flight operation started under a stale epoch.
    /// - Serves a fresh cache hit (age < `freshnessInterval`, cache below
    ///   capacity) without any network operation.
    /// - Publishes stale rows immediately and starts/coalesces one refresh
    ///   when the visible cache is stale or the cache is at capacity.
    func openPicker() async {
        let gate = ProfileContextGateRegistry.shared.gate(for: gateKey)
        let authoritativeEpoch = await gate.gateEpoch

        // An in-flight operation: coalesce under the same epoch, supersede
        // under a stale epoch.
        if let op = currentOperation, !op.isTerminal {
            if op.operationKey.startingGateEpoch == authoritativeEpoch {
                return
            }
            let provisional = await startOperation(startingGateEpoch: authoritativeEpoch)
            if let visible = visibleContextKey, cache[visible] != nil {
                _ = await setState(
                    .staleRefreshing,
                    metadata: provisional,
                    contextKey: visible
                )
            } else {
                _ = await setState(.loading, metadata: provisional)
            }
            return
        }

        // Completed cache for the visible context: fresh hit or stale refresh.
        if let visible = visibleContextKey,
           let entry = cache[visible] {
            let age = configuration.now().timeIntervalSince(entry.publishedAt)
            let revisionAtRead = cacheRevision
            if age < configuration.freshnessInterval,
               cache.count < configuration.completedContextLimit,
               visible.gateEpoch == authoritativeEpoch {
                // A fresh replay is a new fenced operation even though it does
                // does not perform network work. Cache entries contain the
                // verified context and projections, but never delivery
                // metadata such as an old operation UUID/generation.
                let replayMetadata = startCacheReplayOperation(
                    contextKey: visible,
                    startingGateEpoch: authoritativeEpoch,
                    profileContext: entry.profileContext
                )
                guard await publish(
                    .contextVerified(replayMetadata, entry.profileContext),
                    metadata: replayMetadata,
                    contextKey: visible,
                    cacheRevision: revisionAtRead
                ) else {
                    currentOperation?.isTerminal = true
                    return
                }
                guard await publish(
                    .base(
                        CatalogBaseSnapshot(
                            metadata: replayMetadata,
                            groups: entry.groups,
                            defaultModel: entry.defaultModel,
                            activeProvider: entry.activeProvider
                        )
                    ),
                    metadata: replayMetadata,
                    contextKey: visible,
                    cacheRevision: revisionAtRead
                ) else {
                    currentOperation?.isTerminal = true
                    return
                }
                guard await setState(
                    entry.groups.isEmpty ? .freshEmpty : .freshReady,
                    metadata: replayMetadata,
                    contextKey: visible,
                    cacheRevision: revisionAtRead
                ) else {
                    currentOperation?.isTerminal = true
                    return
                }
                currentOperation?.isTerminal = true
                multicast.finish()
                return
            }
            // Stale (or at capacity): publish stale rows immediately, then
            // start one refresh. Revalidate the captured cache revision after
            // the provider await and again in the final publication fence.
            let provisional = await startOperation(startingGateEpoch: authoritativeEpoch)
            guard let current = currentOperation,
                  current.operationID == provisional.operationID,
                  current.operationGeneration == provisional.operationGeneration,
                  visibleContextKey == visible,
                  cache[visible] != nil,
                  cacheRevision == revisionAtRead
            else { return }
            guard await publish(
                .base(
                    CatalogBaseSnapshot(
                        metadata: provisional,
                        groups: entry.groups,
                        defaultModel: entry.defaultModel,
                        activeProvider: entry.activeProvider
                    )
                ),
                metadata: provisional,
                contextKey: visible,
                cacheRevision: revisionAtRead
            ) else { return }
            _ = await setState(
                .staleRefreshing,
                metadata: provisional,
                contextKey: visible,
                cacheRevision: revisionAtRead
            )
            return
        }

        // Cold start.
        let provisional = await startOperation(startingGateEpoch: authoritativeEpoch)
        _ = await setState(.loading, metadata: provisional)
    }

    /// Forces a refresh of the visible catalog — the only refresh path that
    /// may refresh a fresh snapshot. Coalesces onto an in-flight operation
    /// under the same epoch; a terminal operation is replaced. The visible
    /// rows are already on screen, so nothing is republished and the
    /// readiness state is left untouched until the next transition.
    func retry(operationID: UUID? = nil) async {
        _ = operationID
        let gate = ProfileContextGateRegistry.shared.gate(for: gateKey)
        let authoritativeEpoch = await gate.gateEpoch
        if let op = currentOperation,
           !op.isTerminal,
           op.operationKey.startingGateEpoch == authoritativeEpoch {
            return
        }
        _ = await startOperation(startingGateEpoch: authoritativeEpoch)
    }

    /// ChatViewModel-facing authority check: true when the event metadata's
    /// identity is still authoritative — the operation's starting gate epoch
    /// (provisional) or the verified context's gate epoch (verified) equals
    /// the process-global registry's current epoch.
    func accepts(_ metadata: CatalogEventMetadata) async -> Bool {
        guard !Task.isCancelled,
              let operation = currentOperation,
              operation.operationID == metadata.operationID,
              operation.operationGeneration == metadata.operationGeneration
        else { return false }

        let gate: ProfileContextGate
        let expectedEpoch: UInt64
        switch metadata.identity {
        case let .provisional(key):
            guard key == operation.operationKey else { return false }
            gate = ProfileContextGateRegistry.shared.gate(for: key.gateKey)
            expectedEpoch = key.startingGateEpoch
        case let .verified(key):
            guard operation.verifiedContextKey == key else { return false }
            gate = ProfileContextGateRegistry.shared.gate(for: key.gateKey)
            expectedEpoch = key.gateEpoch
        }

        let authoritativeEpoch = await gate.gateEpoch
        guard !Task.isCancelled,
              authoritativeEpoch == expectedEpoch,
              let current = currentOperation,
              current.operationID == metadata.operationID,
              current.operationGeneration == metadata.operationGeneration
        else { return false }
        return true
    }

    // MARK: Network event handling

    /// Actor-serialized handler for one network event. Every event is fenced
    /// twice: once against the current operation identity (UUID/generation)
    /// and once against the authoritative gate epoch and the operation's own
    /// context key.
    private func handleNetworkEvent(operationID: UUID, event: CatalogNetworkEvent) async {
        guard !Task.isCancelled,
              let initial = currentOperation,
              initial.operationID == operationID,
              !initial.isTerminal
        else { return }

        let gate = ProfileContextGateRegistry.shared.gate(for: initial.operationKey.gateKey)
        let authoritativeEpoch = await gate.gateEpoch

        // This pre-handler check is intentionally not the publication fence.
        // Every branch below repeats the complete check immediately before its
        // own multicast yield.
        guard !Task.isCancelled,
              authoritativeEpoch == initial.operationKey.startingGateEpoch,
              let current = currentOperation,
              current.operationID == operationID,
              current.operationGeneration == initial.operationGeneration,
              !current.isTerminal,
              let metadata = event.eventMetadata,
              metadata.operationID == current.operationID,
              metadata.operationGeneration == current.operationGeneration
        else { return }

        switch event {
        case let .contextVerified(metadata, context):
            let contextKey: CatalogContextKey
            switch metadata.identity {
            case let .verified(key):
                contextKey = key
            case let .provisional(key):
                contextKey = CatalogContextKey(
                    gateKey: key.gateKey,
                    apiClientID: key.apiClientID,
                    authGeneration: key.authGeneration,
                    activeProfile: context.activeProfile,
                    gateEpoch: key.startingGateEpoch
                )
            }

            guard await acceptsPublication(
                metadata: metadata,
                contextKey: contextKey,
                allowUnboundVerifiedContext: true
            ) else { return }

            if let visible = visibleContextKey, visible != contextKey {
                // A different context is about to become visible: reset the
                // subscriber rows before the new context's rows.
                guard await publish(
                    .contextReset(metadata),
                    metadata: metadata,
                    contextKey: contextKey,
                    allowUnboundVerifiedContext: true
                ) else { return }
            }
            guard await publish(
                .contextVerified(metadata, context),
                metadata: metadata,
                contextKey: contextKey,
                allowUnboundVerifiedContext: true
            ) else { return }

            // The context becomes coordinator-authoritative only after the
            // fenced publications have landed.
            guard let current = currentOperation,
                  current.operationID == operationID,
                  current.operationGeneration == metadata.operationGeneration,
                  !Task.isCancelled
            else { return }
            currentOperation?.verifiedContextKey = contextKey
            currentOperation?.profileContext = context
            visibleContextKey = contextKey
            emitTelemetry(
                surface: .context,
                phase: .ended,
                outcome: .success,
                operationID: metadata.operationID
            )

        case let .base(snapshot):
            guard let current = currentOperation,
                  let contextKey = current.verifiedContextKey,
                  snapshot.metadata.operationID == operationID,
                  snapshot.metadata.operationGeneration == current.operationGeneration
            else { return }
            guard await acceptsPublication(
                metadata: snapshot.metadata,
                contextKey: contextKey
            ) else { return }

            guard let current = currentOperation,
                  current.operationID == operationID,
                  current.operationGeneration == snapshot.metadata.operationGeneration,
                  !Task.isCancelled
            else { return }

            // Cache the verified context alongside the projection. Delivery
            // metadata is always rebound from the current operation when the
            // projection is replayed.
            guard let profileContext = current.profileContext else { return }
            cache[contextKey] = CachedContext(
                profileContext: profileContext,
                groups: snapshot.groups,
                defaultModel: snapshot.defaultModel,
                activeProvider: snapshot.activeProvider,
                publishedAt: configuration.now()
            )
            cacheOrder.removeAll { $0 == contextKey }
            cacheOrder.append(contextKey)
            cacheRevision &+= 1
            evictIfNeeded()
            let revisionAfterCacheWrite = cacheRevision

            guard await publish(
                .base(snapshot),
                metadata: snapshot.metadata,
                contextKey: contextKey,
                cacheRevision: revisionAfterCacheWrite
            ) else { return }
            guard let currentAfter = currentOperation,
                  currentAfter.operationID == operationID,
                  currentAfter.operationGeneration == snapshot.metadata.operationGeneration,
                  !Task.isCancelled
            else { return }
            currentOperation?.basePublished = true
            currentOperation?.lastBaseActiveProvider = snapshot.activeProvider
            guard await setState(
                snapshot.groups.isEmpty ? .freshEmpty : .freshReady,
                metadata: snapshot.metadata,
                contextKey: contextKey,
                cacheRevision: revisionAfterCacheWrite
            ) else { return }

            // A live that arrived out of order is flushed now that the base
            // is visible. The second publication has its own final fence.
            if let pending = currentOperation?.pendingLive,
               liveProviderMatches(pending, baseActiveProvider: snapshot.activeProvider) {
                guard await publish(
                    .live(pending),
                    metadata: pending.metadata,
                    contextKey: contextKey
                ) else { return }
                currentOperation?.pendingLive = nil
            }
            emitTelemetry(
                surface: .models,
                phase: .ended,
                outcome: .success,
                operationID: snapshot.metadata.operationID,
                groupCount: snapshot.groups.count,
                rowCount: snapshot.groups.reduce(0) { $0 + $1.models.count }
            )

        case let .live(snapshot):
            guard let current = currentOperation,
                  let contextKey = current.verifiedContextKey,
                  snapshot.metadata.operationID == operationID,
                  snapshot.metadata.operationGeneration == current.operationGeneration,
                  !Task.isCancelled
            else { return }
            if current.basePublished {
                // Live must agree with the visible base's provider; a
                // mismatched live is discarded, never published.
                guard liveProviderMatches(snapshot, baseActiveProvider: current.lastBaseActiveProvider) else { return }
                guard await publish(
                    .live(snapshot),
                    metadata: snapshot.metadata,
                    contextKey: contextKey
                ) else { return }
                emitTelemetry(
                    surface: .live,
                    phase: .ended,
                    outcome: .success,
                    operationID: snapshot.metadata.operationID,
                    rowCount: snapshot.groups.reduce(0) { $0 + $1.models.count }
                )
            } else {
                // Out-of-order live: buffer it until the base lands. A
                // live-only publication is forbidden.
                currentOperation?.pendingLive = snapshot
            }

        case let .liveFailed(metadata, category):
            guard let contextKey = currentOperation?.verifiedContextKey else { return }
            guard await publish(
                .liveFailed(metadata, category),
                metadata: metadata,
                contextKey: contextKey
            ) else { return }
            emitTelemetry(
                surface: .live,
                phase: .ended,
                outcome: .failure(category),
                operationID: metadata.operationID
            )

        case let .failed(metadata, phase, category):
            // Mark terminal before the first terminal yield so late rows are
            // rejected while the failed/stale/state sequence is being fenced.
            guard let current = currentOperation,
                  current.operationID == operationID,
                  current.operationGeneration == metadata.operationGeneration
            else { return }
            currentOperation?.isTerminal = true
            currentOperation?.pendingLive = nil
            guard await publish(
                .failed(metadata, phase, category),
                metadata: metadata,
                contextKey: current.verifiedContextKey ?? visibleContextKey
            ) else { return }

            if let contextKey = current.verifiedContextKey ?? visibleContextKey,
               cache[contextKey] != nil {
                let revisionAtRead = cacheRevision
                guard await publishCachedRows(
                    for: contextKey,
                    metadata: metadata,
                    cacheRevision: revisionAtRead
                ) else { return }
                _ = await setState(
                    .staleFailed,
                    metadata: metadata,
                    contextKey: contextKey,
                    cacheRevision: revisionAtRead
                )
            } else {
                _ = await setState(.coldFailed(category), metadata: metadata)
            }
            emitTelemetry(
                surface: phase == .context ? .context : (phase == .live ? .live : .models),
                phase: .failed,
                outcome: .failure(category),
                operationID: metadata.operationID
            )

        case let .finished(metadata):
            guard let current = currentOperation,
                  current.operationID == operationID,
                  current.operationGeneration == metadata.operationGeneration
            else { return }
            currentOperation?.isTerminal = true
            currentOperation?.pendingLive = nil
            _ = await publish(.finished(metadata), metadata: metadata)

        case let .cancelled(metadata):
            guard let current = currentOperation,
                  current.operationID == operationID,
                  current.operationGeneration == metadata.operationGeneration
            else { return }
            currentOperation?.isTerminal = true
            currentOperation?.pendingLive = nil
            guard await publish(.cancelled(metadata), metadata: metadata) else { return }
            emitTelemetry(
                surface: .picker,
                phase: .cancelled,
                outcome: .cancelled,
                operationID: metadata.operationID
            )
        }
    }

    /// The operation's stream unwound. The record is removed only when it
    /// still belongs to this operation, so a superseded completion's cleanup
    /// can never remove a replacement operation.
    private func handleNetworkStreamFinished(operationID: UUID) {
        guard currentOperation?.operationID == operationID else { return }
        // Keep a terminal record until the next operation replaces it so a
        // consumer that receives a queued terminal/state event after the
        // producer stream drains can still validate its metadata. An
        // unterminated stream is not authoritative and is removed.
        if currentOperation?.isTerminal != true {
            currentOperation = nil
        }
    }

    // MARK: Operation lifecycle

    /// Creates the operation record, invokes the provider, and spawns the
    /// consume task. Returns the provisional metadata so callers can rebind
    /// immediate (stale) publications to the new operation.
    @discardableResult
    private func startOperation(startingGateEpoch: UInt64) async -> CatalogEventMetadata {
        let operationID = UUID()
        let operationGeneration = nextOperationGeneration
        nextOperationGeneration += 1
        let operationKey = CatalogOperationKey(
            gateKey: gateKey,
            apiClientID: apiClientID,
            authGeneration: authGeneration,
            requestedProfile: nil,
            startingGateEpoch: startingGateEpoch
        )
        let provisional = CatalogEventMetadata(
            identity: .provisional(operationKey),
            operationID: operationID,
            operationGeneration: operationGeneration
        )
        currentOperation = CurrentOperation(
            operationID: operationID,
            operationGeneration: operationGeneration,
            operationKey: operationKey,
            verifiedContextKey: nil,
            profileContext: nil,
            pendingLive: nil
        )
        emitTelemetry(
            surface: .picker,
            phase: .gateWaitStarted,
            outcome: nil,
            operationID: operationID
        )
        let stream = await provider(nil, operationID, operationGeneration)
        // Detached consume task: it only observes the stream and hops back to
        // this actor; canceling subscribers never cancels the operation.
        Task { [weak self] in
            for await event in stream {
                await self?.handleNetworkEvent(operationID: operationID, event: event)
            }
            await self?.handleNetworkStreamFinished(operationID: operationID)
        }
        return provisional
    }

    /// Starts a metadata-only operation for a fresh cache replay. This keeps
    /// the replay's UUID/generation distinct from the completed network
    /// operation while avoiding a second request.
    private func startCacheReplayOperation(
        contextKey: CatalogContextKey,
        startingGateEpoch: UInt64,
        profileContext: CatalogProfileContext
    ) -> CatalogEventMetadata {
        let operationID = UUID()
        let operationGeneration = nextOperationGeneration
        nextOperationGeneration += 1
        let operationKey = CatalogOperationKey(
            gateKey: gateKey,
            apiClientID: apiClientID,
            authGeneration: authGeneration,
            requestedProfile: nil,
            startingGateEpoch: startingGateEpoch
        )
        let metadata = CatalogEventMetadata(
            identity: .verified(contextKey),
            operationID: operationID,
            operationGeneration: operationGeneration
        )
        currentOperation = CurrentOperation(
            operationID: operationID,
            operationGeneration: operationGeneration,
            operationKey: operationKey,
            verifiedContextKey: contextKey,
            profileContext: profileContext,
            pendingLive: nil
        )
        return metadata
    }

    // MARK: Cache policy

    /// Republishes the completed projection for a context, rebound to the
    /// given (current operation) metadata.
    private func publishCachedRows(
        for contextKey: CatalogContextKey,
        metadata: CatalogEventMetadata,
        cacheRevision: UInt64
    ) async -> Bool {
        guard let entry = cache[contextKey], self.cacheRevision == cacheRevision else { return false }
        return await publish(
            .base(
                CatalogBaseSnapshot(
                    metadata: metadata,
                    groups: entry.groups,
                    defaultModel: entry.defaultModel,
                    activeProvider: entry.activeProvider
                )
            ),
            metadata: metadata,
            contextKey: contextKey,
            cacheRevision: cacheRevision
        )
    }

    /// LRU eviction: at most `completedContextLimit` completed entries; the
    /// in-flight operation's context is never evicted.
    private func evictIfNeeded() {
        let protected = currentOperation?.verifiedContextKey
        while cache.count > configuration.completedContextLimit {
            guard let victim = cacheOrder.first(where: { $0 != protected }) ?? cacheOrder.first else { return }
            cacheOrder.removeAll { $0 == victim }
            cache.removeValue(forKey: victim)
        }
    }

    /// A live snapshot is accepted only when it does not contradict the
    /// visible base's provider. An unknown provider on either side is
    /// tolerated.
    private func liveProviderMatches(_ live: CatalogLiveSnapshot, baseActiveProvider: String?) -> Bool {
        guard let baseProvider = baseActiveProvider, let liveProvider = live.provider else { return true }
        return baseProvider == liveProvider
    }

    // MARK: Publication and state

    /// Complete acceptance fence for one coordinator publication. The
    /// authoritative epoch is read across an actor await, then every caller
    /// rechecks operation identity, context, cancellation, and cache revision
    /// before yielding. `allowUnboundVerifiedContext` is used only for the
    /// contextVerified write site, before that event establishes the context.
    private func acceptsPublication(
        metadata: CatalogEventMetadata,
        contextKey: CatalogContextKey? = nil,
        cacheRevision expectedCacheRevision: UInt64? = nil,
        allowUnboundVerifiedContext: Bool = false
    ) async -> Bool {
        guard !Task.isCancelled,
              let operation = currentOperation,
              operation.operationID == metadata.operationID,
              operation.operationGeneration == metadata.operationGeneration
        else { return false }

        let expectedEpoch: UInt64
        let metadataGateKey: ProfileContextGateKey
        switch metadata.identity {
        case let .provisional(key):
            guard key == operation.operationKey else { return false }
            expectedEpoch = key.startingGateEpoch
            metadataGateKey = key.gateKey
        case let .verified(key):
            if allowUnboundVerifiedContext && operation.verifiedContextKey == nil {
                guard key.gateKey == operation.operationKey.gateKey,
                      key.apiClientID == operation.operationKey.apiClientID,
                      key.authGeneration == operation.operationKey.authGeneration,
                      key.gateEpoch == operation.operationKey.startingGateEpoch
                else { return false }
            } else {
                guard operation.verifiedContextKey == key else { return false }
            }
            expectedEpoch = key.gateEpoch
            metadataGateKey = key.gateKey
        }

        guard metadataGateKey == gateKey else { return false }
        if let contextKey {
            guard contextKey.gateKey == gateKey,
                  contextKey.apiClientID == apiClientID,
                  contextKey.authGeneration == authGeneration,
                  contextKey.gateEpoch == expectedEpoch
            else { return false }
            if !allowUnboundVerifiedContext,
               let verifiedContextKey = operation.verifiedContextKey {
                guard verifiedContextKey == contextKey else { return false }
            }
        }
        if let expectedCacheRevision {
            guard cacheRevision == expectedCacheRevision else { return false }
        }

        let gate = ProfileContextGateRegistry.shared.gate(for: metadataGateKey)
        let authoritativeEpoch = await gate.gateEpoch
        guard !Task.isCancelled,
              authoritativeEpoch == expectedEpoch,
              let current = currentOperation,
              current.operationID == metadata.operationID,
              current.operationGeneration == metadata.operationGeneration
        else { return false }
        switch metadata.identity {
        case let .provisional(key):
            guard current.operationKey == key else { return false }
        case let .verified(key):
            if allowUnboundVerifiedContext && current.verifiedContextKey == nil {
                guard key.gateEpoch == current.operationKey.startingGateEpoch else { return false }
            } else {
                guard current.verifiedContextKey == key else { return false }
            }
        }
        if let contextKey {
            if !allowUnboundVerifiedContext,
               let verifiedContextKey = current.verifiedContextKey {
                guard verifiedContextKey == contextKey else { return false }
            }
            guard contextKey.gateEpoch == expectedEpoch else { return false }
        }
        if let expectedCacheRevision {
            guard cacheRevision == expectedCacheRevision else { return false }
        }
        return true
    }

    /// The final multicast boundary. Continuations are snapshotted without
    /// yielding, then the complete fence is repeated immediately before each
    /// individual continuation yield.
    @discardableResult
    private func publish(
        _ event: CatalogEvent,
        metadata: CatalogEventMetadata? = nil,
        contextKey: CatalogContextKey? = nil,
        cacheRevision: UInt64? = nil,
        allowUnboundVerifiedContext: Bool = false
    ) async -> Bool {
        guard let resolvedMetadata = metadata ?? event.publicationMetadata,
              await acceptsPublication(
                  metadata: resolvedMetadata,
                  contextKey: contextKey,
                  cacheRevision: cacheRevision,
                  allowUnboundVerifiedContext: allowUnboundVerifiedContext
              )
        else { return false }

        let continuations = multicast.snapshot()
        for continuation in continuations {
            guard await acceptsPublication(
                metadata: resolvedMetadata,
                contextKey: contextKey,
                cacheRevision: cacheRevision,
                allowUnboundVerifiedContext: allowUnboundVerifiedContext
            ) else { return false }
            continuation.yield(event)
        }
        return true
    }

    @discardableResult
    private func setState(
        _ newState: CatalogCacheState,
        metadata: CatalogEventMetadata,
        contextKey: CatalogContextKey? = nil,
        cacheRevision: UInt64? = nil
    ) async -> Bool {
        guard await acceptsPublication(
            metadata: metadata,
            contextKey: contextKey,
            cacheRevision: cacheRevision
        ) else { return false }

        if newState != state {
            guard await publish(
                .state(newState),
                metadata: metadata,
                contextKey: contextKey,
                cacheRevision: cacheRevision
            ) else { return false }
            state = newState
        }
        stateSnapshot = CatalogStateSnapshot(metadata: metadata, state: newState)
        return true
    }

    private func emitTelemetry(
        surface: CatalogTelemetrySurface,
        phase: CatalogTelemetryPhase,
        outcome: CatalogTelemetryOutcome?,
        operationID: UUID,
        groupCount: Int? = nil,
        rowCount: Int? = nil
    ) {
        guard let sink = configuration.telemetrySink else { return }
        sink.emit(
            CatalogTelemetryEvent(
                surface: surface,
                phase: phase,
                outcome: outcome,
                cacheState: state,
                durationMilliseconds: nil,
                ageMilliseconds: nil,
                groupCount: groupCount,
                rowCount: rowCount,
                openToken: nil,
                requestToken: nil,
                operationID: operationID,
                admission: nil
            )
        )
    }
}

// MARK: - Supporting types

/// One coordinator-owned operation. Superseded operations are replaced by
/// newer records; their late events are fenced out by operation identity and
/// gate epoch, and their cleanup never touches the replacement.
private struct CurrentOperation: Sendable {
    let operationID: UUID
    let operationGeneration: UInt64
    let operationKey: CatalogOperationKey
    var verifiedContextKey: CatalogContextKey?
    var profileContext: CatalogProfileContext?
    /// A live snapshot that arrived before the base; flushed after the base
    /// is published, discarded on terminal failure.
    var pendingLive: CatalogLiveSnapshot?
    var basePublished = false
    var lastBaseActiveProvider: String?
    var isTerminal = false
}

/// Completed context entry: the projection WITHOUT event metadata. Delivery
/// metadata is created afresh for every current operation.
private struct CachedContext: Sendable {
    let profileContext: CatalogProfileContext
    let groups: [ModelCatalogGroup]
    let defaultModel: String?
    let activeProvider: String?
    let publishedAt: Date
}

/// Lock-protected multicast fan-out. Each subscriber receives its own
/// unbounded stream; terminating one subscription never affects the others.
private final class CatalogEventMulticast: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<CatalogEvent>.Continuation] = [:]
    private var didFinish = false

    func subscribe() -> AsyncStream<CatalogEvent> {
        let (stream, continuation) = AsyncStream<CatalogEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let id = UUID()
        lock.lock()
        let alreadyFinished = didFinish
        if !alreadyFinished {
            continuations[id] = continuation
        }
        lock.unlock()
        if alreadyFinished {
            continuation.finish()
        } else {
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.remove(id)
            }
        }
        return stream
    }

    func snapshot() -> [AsyncStream<CatalogEvent>.Continuation] {
        lock.lock()
        let continuations = Array(continuations.values)
        lock.unlock()
        return continuations
    }

    /// Finish every subscriber stream exactly once.
    func finish() {
        lock.lock()
        didFinish = true
        let continuations = Array(continuations.values)
        self.continuations.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
