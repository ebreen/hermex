import Foundation

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
    /// Readiness transition (cold, loading, freshReady, freshEmpty,
    /// staleRefreshing, staleFailed, coldFailed(category)).
    case state(CatalogCacheState)
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
            _ = await startOperation(startingGateEpoch: authoritativeEpoch)
            if let visible = visibleContextKey, cache[visible] != nil {
                setState(.staleRefreshing)
            } else {
                setState(.loading)
            }
            return
        }

        // Completed cache for the visible context: fresh hit or stale refresh.
        if let visible = visibleContextKey, let entry = cache[visible] {
            let age = configuration.now().timeIntervalSince(entry.publishedAt)
            if age < configuration.freshnessInterval,
               cache.count < configuration.completedContextLimit {
                // Fresh cache hit: republish the last-known rows, rebound to
                // the context's last-known operation metadata. No network.
                publish(
                    .base(
                        CatalogBaseSnapshot(
                            metadata: entry.lastKnownMetadata,
                            groups: entry.groups,
                            defaultModel: entry.defaultModel,
                            activeProvider: entry.activeProvider
                        )
                    )
                )
                setState(entry.groups.isEmpty ? .freshEmpty : .freshReady)
                return
            }
            // Stale (or at capacity): publish stale rows immediately, then
            // start one refresh.
            let provisional = await startOperation(startingGateEpoch: authoritativeEpoch)
            publish(
                .base(
                    CatalogBaseSnapshot(
                        metadata: provisional,
                        groups: entry.groups,
                        defaultModel: entry.defaultModel,
                        activeProvider: entry.activeProvider
                    )
                )
            )
            setState(.staleRefreshing)
            return
        }

        // Cold start.
        _ = await startOperation(startingGateEpoch: authoritativeEpoch)
        setState(.loading)
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
        switch metadata.identity {
        case let .provisional(key):
            let gate = ProfileContextGateRegistry.shared.gate(for: key.gateKey)
            return await gate.gateEpoch == key.startingGateEpoch
        case let .verified(key):
            let gate = ProfileContextGateRegistry.shared.gate(for: key.gateKey)
            return await gate.gateEpoch == key.gateEpoch
        }
    }

    // MARK: Network event handling

    /// Actor-serialized handler for one network event. Every event is fenced
    /// twice: once against the current operation identity (UUID/generation)
    /// and once against the authoritative gate epoch and the operation's own
    /// context key.
    private func handleNetworkEvent(operationID: UUID, event: CatalogNetworkEvent) async {
        guard let op = currentOperation,
              op.operationID == operationID,
              !op.isTerminal
        else { return }

        let gate = ProfileContextGateRegistry.shared.gate(for: op.operationKey.gateKey)
        let authoritativeEpoch = await gate.gateEpoch

        // Re-read after the await: the actor may have been reentered (e.g. a
        // supersede replaced the operation) while we awaited the gate.
        guard let op = currentOperation,
              op.operationID == operationID,
              !op.isTerminal,
              event.metadata.operationID == op.operationID,
              event.metadata.operationGeneration == op.operationGeneration
        else { return }

        switch event.metadata.identity {
        case let .provisional(key):
            guard key == op.operationKey, key.startingGateEpoch == authoritativeEpoch else { return }
        case let .verified(key):
            guard key == op.verifiedContextKey, key.gateEpoch == authoritativeEpoch else { return }
        }

        switch event {
        case let .contextVerified(metadata, context):
            guard case let .verified(contextKey) = metadata.identity else { return }
            currentOperation?.verifiedContextKey = contextKey
            currentOperation?.profileContext = context
            if let visible = visibleContextKey, visible != contextKey {
                // A different context is about to become visible: reset the
                // subscriber rows before the new context's rows.
                publish(.contextReset(metadata))
            }
            visibleContextKey = contextKey
            publish(.contextVerified(metadata, context))
            emitTelemetry(
                surface: .context,
                phase: .ended,
                outcome: .success,
                operationID: metadata.operationID
            )

        case let .base(snapshot):
            guard let contextKey = op.verifiedContextKey,
                  case .verified = snapshot.metadata.identity,
                  snapshot.metadata.operationID == op.operationID
            else { return }
            // Cache the projection without event metadata; the last-known
            // operation metadata is retained for future rebinding.
            cache[contextKey] = CachedContext(
                groups: snapshot.groups,
                defaultModel: snapshot.defaultModel,
                activeProvider: snapshot.activeProvider,
                publishedAt: configuration.now(),
                lastKnownMetadata: snapshot.metadata
            )
            cacheOrder.removeAll { $0 == contextKey }
            cacheOrder.append(contextKey)
            evictIfNeeded()
            publish(.base(snapshot))
            currentOperation?.basePublished = true
            currentOperation?.lastBaseActiveProvider = snapshot.activeProvider
            setState(snapshot.groups.isEmpty ? .freshEmpty : .freshReady)
            // A live that arrived out of order is flushed now that the base
            // is visible.
            if let pending = currentOperation?.pendingLive {
                currentOperation?.pendingLive = nil
                if liveProviderMatches(pending, baseActiveProvider: snapshot.activeProvider) {
                    publish(.live(pending))
                }
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
            guard snapshot.metadata.operationID == op.operationID else { return }
            if op.basePublished {
                // Live must agree with the visible base's provider; a
                // mismatched live is discarded, never published.
                if liveProviderMatches(snapshot, baseActiveProvider: op.lastBaseActiveProvider) {
                    publish(.live(snapshot))
                    emitTelemetry(
                        surface: .live,
                        phase: .ended,
                        outcome: .success,
                        operationID: snapshot.metadata.operationID,
                        rowCount: snapshot.groups.reduce(0) { $0 + $1.models.count }
                    )
                }
            } else {
                // Out-of-order live: buffer it until the base lands. A
                // live-only publication is forbidden.
                currentOperation?.pendingLive = snapshot
            }

        case let .liveFailed(metadata, category):
            // The base stays the visible catalog; the failure is non-terminal.
            publish(.liveFailed(metadata, category))
            emitTelemetry(
                surface: .live,
                phase: .ended,
                outcome: .failure(category),
                operationID: metadata.operationID
            )

        case let .failed(metadata, phase, category):
            // Terminal. A previously verified snapshot for the same context
            // is republished read-only as staleFailed; otherwise the catalog
            // is cold-failed and loading is cleared.
            currentOperation?.isTerminal = true
            currentOperation?.pendingLive = nil
            publish(.failed(metadata, phase, category))
            if let contextKey = op.verifiedContextKey, cache[contextKey] != nil {
                publishCachedRows(for: contextKey, metadata: metadata)
                setState(.staleFailed)
            } else {
                setState(.coldFailed(category))
            }
            emitTelemetry(
                surface: phase == .context ? .context : (phase == .live ? .live : .models),
                phase: .failed,
                outcome: .failure(category),
                operationID: metadata.operationID
            )

        case let .finished(metadata):
            currentOperation?.isTerminal = true
            currentOperation?.pendingLive = nil
            publish(.finished(metadata))

        case let .cancelled(metadata):
            currentOperation?.isTerminal = true
            currentOperation?.pendingLive = nil
            publish(.cancelled(metadata))
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
        if currentOperation?.operationID == operationID {
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

    // MARK: Cache policy

    /// Republishes the completed projection for a context, rebound to the
    /// given (current operation) metadata.
    private func publishCachedRows(for contextKey: CatalogContextKey, metadata: CatalogEventMetadata) {
        guard let entry = cache[contextKey] else { return }
        publish(
            .base(
                CatalogBaseSnapshot(
                    metadata: metadata,
                    groups: entry.groups,
                    defaultModel: entry.defaultModel,
                    activeProvider: entry.activeProvider
                )
            )
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

    private func publish(_ event: CatalogEvent) {
        multicast.publish(event)
    }

    private func setState(_ newState: CatalogCacheState) {
        guard newState != state else { return }
        state = newState
        publish(.state(newState))
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

/// Completed context entry: the projection WITHOUT event metadata, plus the
/// last-known operation metadata used to rebind cache publications.
private struct CachedContext: Sendable {
    let groups: [ModelCatalogGroup]
    let defaultModel: String?
    let activeProvider: String?
    let publishedAt: Date
    let lastKnownMetadata: CatalogEventMetadata
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

    func publish(_ event: CatalogEvent) {
        lock.lock()
        let continuations = Array(continuations.values)
        lock.unlock()
        for continuation in continuations {
            continuation.yield(event)
        }
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
