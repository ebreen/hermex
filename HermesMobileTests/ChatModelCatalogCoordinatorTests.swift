import Foundation
import XCTest
@testable import HermesMobile

// MARK: - Slice 2 RED contract: ChatModelCatalogCoordinator (issue #16)
//
// These tests define the per-VM coordinator's behavioral seam BEFORE the
// production file exists, so the RED failure is missing-symbol diagnostics
// only (ChatModelCatalogCoordinator / CatalogEvent). The coordinator actor
// consumes only neutral `CatalogNetworkEvent` projections from Networking and
// multicasts Chat-side `CatalogEvent`s to ordered subscribers. Contract encoded
// here (issue #16 v6 brief, v6.5/v6.8 Slice 2):
//
// - One actor per ChatViewModel, created with the profile-context gate key,
//   API-client identity, a stream provider (wired to APIClient.modelCatalogStream
//   in production), an injected clock, and an injected telemetry sink.
// - In-flight operations are keyed by `CatalogOperationKey` (provisional key
//   including starting gate epoch); duplicate opens and initial-load-plus-picker
//   refresh with the same provisional key share ONE operation and one profile
//   phase.
// - After `contextVerified`, the operation is promoted to a verified
//   `CatalogContextKey`; cache entries are keyed by that context key and store
//   projections WITHOUT event metadata. Publications rebind current operation
//   metadata.
// - Readiness state is the Networking `CatalogCacheState`: cold, loading,
//   freshReady, freshEmpty, staleRefreshing, staleFailed,
//   coldFailed(CatalogFailureCategory). `coldFailed` is not loading.
// - Fresh age < 5 minutes publishes without refresh; age >= 5 minutes publishes
//   stale rows immediately and starts/coalesces one refresh; explicit retry is
//   the only forced refresh and may refresh a fresh snapshot. A valid empty base
//   is a successful `freshEmpty` and clears loading.
// - At most four completed context entries per VM with LRU eviction; an
//   in-flight operation is never evicted.
// - Before yielding any event the coordinator verifies operation
//   UUID/generation, the process-global registry's authoritative gate epoch,
//   and the operation's context; a switch advances the epoch, drops old
//   completions, emits a context reset before new rows, and an old completion's
//   cleanup never removes a replacement operation.
// - A profile-context failure with no verified cache becomes
//   `coldFailed(.profileUnavailable/.profileMismatch)`, clears loading, and
//   leaves retry accessible; with a previously verified snapshot for the same
//   context it publishes that snapshot read-only as `staleFailed` without
//   refreshing.
//
// Every async barrier is a checked continuation; no sleep, polling, semaphore,
// or wall-clock oracle is used. `ChatViewModel` revalidates events with
// `accepts(_:)` after every await (Slice 4 integration); the coordinator-side
// epoch/generation rejection is proven here.

final class ChatModelCatalogCoordinatorTests: XCTestCase {
    private static let epochZero: UInt64 = 0

    // MARK: - Publication ordering

    func testBaseSnapshotPublishesBeforeLiveCompletes() async throws {
        let harness = makeHarness()
        let subscriber = await makeSubscriber(harness.coordinator)

        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        let call = harness.provider.call(0)
        let metadata = verifiedMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            activeProfile: "default",
            gateEpoch: Self.epochZero,
            operationID: call.operationID,
            operationGeneration: call.operationGeneration
        )

        call.continuation.yield(.contextVerified(metadata, makeProfileContext(activeProfile: "default")))
        call.continuation.yield(.base(makeBaseSnapshot(metadata: metadata, groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5"])], defaultModel: "gpt-5", activeProvider: "openai")))

        // The live child is still pending: the base must already be visible and
        // loading must be cleared.
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .base = event { return true }
                return false
            }
        }
        let baseState = await harness.coordinator.state
        XCTAssertEqual(baseState, .freshReady, "base publication clears loading before live completes")

        call.continuation.yield(.live(makeLiveSnapshot(metadata: metadata, groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5-mini"])], provider: "openai")))
        call.continuation.yield(.finished(metadata))
        call.continuation.finish()

        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }
        let events = subscriber.collector.snapshot()
        let baseIndex = try XCTUnwrap(events.firstIndex { event in
            if case .base = event { return true }
            return false
        })
        let liveIndex = try XCTUnwrap(events.firstIndex { event in
            if case .live = event { return true }
            return false
        })
        XCTAssertLessThan(baseIndex, liveIndex, "base must be multicast before live replaces groups")

        let finalState = await harness.coordinator.state
        XCTAssertEqual(finalState, .freshReady)
        await cancel(subscriber)
    }

    func testLiveBeforeBaseWaitsForBase() async throws {
        let harness = makeHarness()
        let subscriber = await makeSubscriber(harness.coordinator)

        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        let call = harness.provider.call(0)
        let metadata = verifiedMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            activeProfile: "default",
            gateEpoch: Self.epochZero,
            operationID: call.operationID,
            operationGeneration: call.operationGeneration
        )

        // Out-of-order live arrives first: it must be buffered, never published
        // as a live-only snapshot.
        call.continuation.yield(.live(makeLiveSnapshot(metadata: metadata, groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5-mini"])], provider: "openai")))
        call.continuation.yield(.base(makeBaseSnapshot(metadata: metadata, groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5"])], defaultModel: "gpt-5", activeProvider: "openai")))

        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .live = event { return true }
                return false
            }
        }
        let events = subscriber.collector.snapshot()
        let baseIndex = try XCTUnwrap(events.firstIndex { event in
            if case .base = event { return true }
            return false
        })
        let liveIndex = try XCTUnwrap(events.firstIndex { event in
            if case .live = event { return true }
            return false
        })
        XCTAssertLessThan(baseIndex, liveIndex, "live must wait for base; a live-only publication is forbidden")

        call.continuation.yield(.finished(metadata))
        call.continuation.finish()
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }
        let finalState = await harness.coordinator.state
        XCTAssertEqual(finalState, .freshReady)
        await cancel(subscriber)
    }

    func testProviderMismatchIsDiscarded() async throws {
        let harness = makeHarness()
        let subscriber = await makeSubscriber(harness.coordinator)

        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        let call = harness.provider.call(0)
        let metadata = verifiedMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            activeProfile: "default",
            gateEpoch: Self.epochZero,
            operationID: call.operationID,
            operationGeneration: call.operationGeneration
        )

        call.continuation.yield(.contextVerified(metadata, makeProfileContext(activeProfile: "default")))
        call.continuation.yield(.base(makeBaseSnapshot(metadata: metadata, groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5"])], defaultModel: "gpt-5", activeProvider: "openai")))
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .base = event { return true }
                return false
            }
        }

        // Live reports a different provider: the snapshot is discarded.
        call.continuation.yield(.live(makeLiveSnapshot(metadata: metadata, groups: [makeGroup(providerID: "anthropic", modelIDs: ["claude-4"])], provider: "anthropic")))
        call.continuation.yield(.finished(metadata))
        call.continuation.finish()
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }

        let events = subscriber.collector.snapshot()
        XCTAssertFalse(
            events.contains { event in
                if case .live = event { return true }
                return false
            },
            "a live snapshot from a mismatched provider must never be published"
        )
        let state = await harness.coordinator.state
        XCTAssertEqual(state, .freshReady, "the base snapshot stays the visible catalog")
        await cancel(subscriber)
    }

    func testBaseSuccessLiveFailureKeepsBase() async throws {
        let harness = makeHarness()
        let subscriber = await makeSubscriber(harness.coordinator)

        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        let call = harness.provider.call(0)
        let metadata = verifiedMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            activeProfile: "default",
            gateEpoch: Self.epochZero,
            operationID: call.operationID,
            operationGeneration: call.operationGeneration
        )

        call.continuation.yield(.contextVerified(metadata, makeProfileContext(activeProfile: "default")))
        call.continuation.yield(.base(makeBaseSnapshot(metadata: metadata, groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5"])], defaultModel: "gpt-5", activeProvider: "openai")))
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .base = event { return true }
                return false
            }
        }

        call.continuation.yield(.liveFailed(metadata, .transport))
        call.continuation.yield(.finished(metadata))
        call.continuation.finish()
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }

        let state = await harness.coordinator.state
        XCTAssertEqual(state, .freshReady, "a live failure after a valid base is non-terminal for the catalog")
        let events = subscriber.collector.snapshot()
        XCTAssertTrue(events.contains { event in
            if case .liveFailed = event { return true }
            return false
        })
        await cancel(subscriber)
    }

    func testBaseFailureLiveSuccessDoesNotPublishLiveOnly() async throws {
        let harness = makeHarness()
        let subscriber = await makeSubscriber(harness.coordinator)

        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        let call = harness.provider.call(0)
        let metadata = provisionalMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            startingGateEpoch: Self.epochZero,
            operationID: call.operationID,
            operationGeneration: call.operationGeneration
        )

        call.continuation.yield(.failed(metadata, .models, .transport))
        // A misbehaving provider still delivers a live event after the terminal
        // base failure: the coordinator must not publish a live-only catalog.
        call.continuation.yield(.live(makeLiveSnapshot(metadata: metadata, groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5-mini"])], provider: "openai")))
        call.continuation.finish()

        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case let .state(state) = event, state == .coldFailed(.transport) { return true }
                return false
            }
        }
        let events = subscriber.collector.snapshot()
        XCTAssertFalse(events.contains { event in
            if case .live = event { return true }
            return false
        }, "a live-only publication after base failure is forbidden")
        let state = await harness.coordinator.state
        XCTAssertEqual(state, .coldFailed(.transport))
        await cancel(subscriber)
    }

    func testValidEmptyClearsLoading() async throws {
        let harness = makeHarness()
        let subscriber = await makeSubscriber(harness.coordinator)

        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        let call = harness.provider.call(0)
        let metadata = verifiedMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            activeProfile: "default",
            gateEpoch: Self.epochZero,
            operationID: call.operationID,
            operationGeneration: call.operationGeneration
        )

        call.continuation.yield(.contextVerified(metadata, makeProfileContext(activeProfile: "default")))
        call.continuation.yield(.base(makeBaseSnapshot(metadata: metadata, groups: [], defaultModel: nil, activeProvider: nil)))
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .base = event { return true }
                return false
            }
        }

        let emptyState = await harness.coordinator.state
        XCTAssertEqual(emptyState, .freshEmpty, "a valid empty base clears loading")

        call.continuation.yield(.live(makeLiveSnapshot(metadata: metadata, groups: [], provider: nil)))
        call.continuation.yield(.finished(metadata))
        call.continuation.finish()
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }
        let finalState = await harness.coordinator.state
        XCTAssertEqual(finalState, .freshEmpty)
        await cancel(subscriber)
    }

    // MARK: - Cache freshness, TTL, and forced refresh

    func testFreshAgeJustUnderFiveMinutesDoesNotRefresh() async throws {
        let clock = ScriptedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let harness = makeHarness(clock: { clock.now() })
        let subscriber = await makeSubscriber(harness.coordinator)

        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        completeOperation(
            call: harness.provider.call(0),
            harness: harness,
            activeProfile: "default",
            groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5"])]
        )
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }

        clock.advance(by: 299)
        await harness.coordinator.openPicker()
        await subscriber.collector.waitUntil { events in
            events.filter { event in
                if case .base = event { return true }
                return false
            }.count >= 2
        }

        // Deterministic no-refresh barrier: an explicit retry must be the SECOND
        // provider call. A phantom refresh from the fresh open would make it the
        // third.
        await harness.coordinator.retry()
        await harness.provider.waitForCallCount(2)
        XCTAssertEqual(
            harness.provider.callCount(),
            2,
            "a fresh open (age < 5 minutes) must not start a refresh"
        )

        let events = subscriber.collector.snapshot()
        let cachedBase = try XCTUnwrap(lastBase(in: events))
        XCTAssertEqual(cachedBase.groups.map(\.id), ["openai"], "the fresh open publishes the cached rows")
        let state = await harness.coordinator.state
        XCTAssertEqual(state, .freshReady)

        // Drain the barrier retry operation so no coordinator task stays parked.
        harness.provider.call(1).continuation.finish()
        await cancel(subscriber)
    }

    func testAgeAtFiveMinutesPublishesStaleAndCoalescesRefresh() async throws {
        let clock = ScriptedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let harness = makeHarness(clock: { clock.now() })
        let subscriber = await makeSubscriber(harness.coordinator)

        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        let firstCall = harness.provider.call(0)
        completeOperation(
            call: firstCall,
            harness: harness,
            activeProfile: "default",
            groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5"])]
        )
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }

        clock.advance(by: 300)
        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(2)
        let refreshCall = harness.provider.call(1)

        // Stale rows are published immediately, rebound to the current
        // operation's metadata (metadata-free cache storage + rebinding).
        await subscriber.collector.waitUntil { events in
            events.filter { event in
                if case .base = event { return true }
                return false
            }.count >= 2
        }
        let staleBase = try XCTUnwrap(lastBase(in: subscriber.collector.snapshot()))
        XCTAssertEqual(staleBase.groups.map(\.id), ["openai"], "stale rows stay visible during refresh")
        XCTAssertEqual(
            staleBase.metadata.operationID,
            refreshCall.operationID,
            "a cache publication rebinds the current operation's metadata"
        )
        let refreshingState = await harness.coordinator.state
        XCTAssertEqual(refreshingState, .staleRefreshing)

        // A second open while the refresh is in flight coalesces onto it.
        await harness.coordinator.openPicker()
        XCTAssertEqual(harness.provider.callCount(), 2, "duplicate stale opens coalesce one refresh")
        let refreshMetadata = verifiedMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            activeProfile: "default",
            gateEpoch: Self.epochZero,
            operationID: refreshCall.operationID,
            operationGeneration: refreshCall.operationGeneration
        )
        refreshCall.continuation.yield(.contextVerified(refreshMetadata, makeProfileContext(activeProfile: "default")))
        refreshCall.continuation.yield(.base(makeBaseSnapshot(metadata: refreshMetadata, groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5", "gpt-4o"])], defaultModel: "gpt-5", activeProvider: "openai")))
        refreshCall.continuation.yield(.live(makeLiveSnapshot(metadata: refreshMetadata, groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5-mini"])], provider: "openai")))
        refreshCall.continuation.yield(.finished(refreshMetadata))
        refreshCall.continuation.finish()

        await subscriber.collector.waitUntil { events in
            events.filter { event in
                if case .base = event { return true }
                return false
            }.count >= 3
        }
        let events = subscriber.collector.snapshot()
        let freshBase = try XCTUnwrap(lastBase(in: events))
        XCTAssertEqual(freshBase.groups.flatMap(\.models).map(\.id), ["gpt-5", "gpt-4o"], "the refresh replaces stale rows")
        let staleIndex = try XCTUnwrap(events.firstIndex { event in
            if case let .base(snapshot) = event, snapshot.groups.map(\.id) == ["openai"] { return true }
            return false
        })
        let freshIndex = try XCTUnwrap(events.firstIndex { event in
            if case let .base(snapshot) = event, snapshot.groups.map(\.id) != ["openai"] { return true }
            return false
        })
        XCTAssertLessThan(staleIndex, freshIndex, "stale rows are published before the refresh lands")
        XCTAssertEqual(harness.provider.callCount(), 2, "the second stale open never started a third operation")
        let finalState = await harness.coordinator.state
        XCTAssertEqual(finalState, .freshReady)
        await cancel(subscriber)
    }

    func testFreshPickerOpenDoesNotForceRefresh() async throws {
        let clock = ScriptedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let harness = makeHarness(clock: { clock.now() })
        let subscriber = await makeSubscriber(harness.coordinator)

        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        completeOperation(
            call: harness.provider.call(0),
            harness: harness,
            activeProfile: "default",
            groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5"])]
        )
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }

        clock.advance(by: 100)
        await harness.coordinator.openPicker()
        await subscriber.collector.waitUntil { events in
            events.filter { event in
                if case .base = event { return true }
                return false
            }.count >= 2
        }

        // Same deterministic barrier as the under-five-minutes test: the retry
        // must be call two, proving the fresh open produced no operation.
        await harness.coordinator.retry()
        await harness.provider.waitForCallCount(2)
        XCTAssertEqual(harness.provider.callCount(), 2, "a fresh picker open must not force a network refresh")

        // Drain the barrier retry operation so no coordinator task stays parked.
        harness.provider.call(1).continuation.finish()
        await cancel(subscriber)
    }

    func testExplicitRetryForcesRefresh() async throws {
        let clock = ScriptedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let harness = makeHarness(clock: { clock.now() })
        let subscriber = await makeSubscriber(harness.coordinator)

        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        completeOperation(
            call: harness.provider.call(0),
            harness: harness,
            activeProfile: "default",
            groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5"])]
        )
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }

        clock.advance(by: 100)
        await harness.coordinator.retry()
        await harness.provider.waitForCallCount(2)
        XCTAssertEqual(harness.provider.callCount(), 2, "explicit retry is the only forced refresh path")

        let retryCall = harness.provider.call(1)
        let retryMetadata = verifiedMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            activeProfile: "default",
            gateEpoch: Self.epochZero,
            operationID: retryCall.operationID,
            operationGeneration: retryCall.operationGeneration
        )
        retryCall.continuation.yield(.contextVerified(retryMetadata, makeProfileContext(activeProfile: "default")))
        retryCall.continuation.yield(.base(makeBaseSnapshot(metadata: retryMetadata, groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5", "gpt-4o"])], defaultModel: "gpt-5", activeProvider: "openai")))
        retryCall.continuation.yield(.finished(retryMetadata))
        retryCall.continuation.finish()

        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }
        let events = subscriber.collector.snapshot()
        let refreshedBase = try XCTUnwrap(lastBase(in: events))
        XCTAssertEqual(refreshedBase.groups.flatMap(\.models).map(\.id), ["gpt-5", "gpt-4o"], "retry republishes fresh rows")
        let state = await harness.coordinator.state
        XCTAssertEqual(state, .freshReady)
        await cancel(subscriber)
    }

    func testFreshCacheHitPublishesWithLastKnownMetadata() async throws {
        let clock = ScriptedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let harness = makeHarness(clock: { clock.now() })
        let subscriber = await makeSubscriber(harness.coordinator)

        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        let originalCall = harness.provider.call(0)
        completeOperation(
            call: originalCall,
            harness: harness,
            activeProfile: "default",
            groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5"])]
        )
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }

        clock.advance(by: 299)
        await harness.coordinator.openPicker()
        await subscriber.collector.waitUntil { events in
            events.filter { event in
                if case .base = event { return true }
                return false
            }.count >= 2
        }

        // The cache stores projections without event metadata; a cache-hit
        // publication carries the last-known operation metadata for the context.
        let cachedBase = try XCTUnwrap(lastBase(in: subscriber.collector.snapshot()))
        XCTAssertEqual(cachedBase.groups.map(\.id), ["openai"])
        XCTAssertEqual(
            cachedBase.metadata.operationID,
            originalCall.operationID,
            "a fresh cache hit rebinds the last-known operation metadata"
        )
        await cancel(subscriber)
    }

    // MARK: - Provisional-key coalescing

    func testInitialLoadAndPickerRefreshShareOneOperation() async throws {
        let harness = makeHarness()
        let subscriber = await makeSubscriber(harness.coordinator)

        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)

        // Picker refresh arrives while the initial load is in flight.
        await harness.coordinator.openPicker()
        XCTAssertEqual(harness.provider.callCount(), 1, "initial load and picker refresh share one operation")

        completeOperation(
            call: harness.provider.call(0),
            harness: harness,
            activeProfile: "default",
            groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5"])]
        )
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }
        XCTAssertEqual(harness.provider.callCount(), 1, "one profile phase and one base/live pair for both opens")
        let state = await harness.coordinator.state
        XCTAssertEqual(state, .freshReady)
        await cancel(subscriber)
    }

    func testDuplicatePickerOpensShareOneOperation() async throws {
        let harness = makeHarness()
        let first = await makeSubscriber(harness.coordinator)
        let second = await makeSubscriber(harness.coordinator)

        async let firstOpen: Void = harness.coordinator.openPicker()
        async let secondOpen: Void = harness.coordinator.openPicker()
        _ = await (firstOpen, secondOpen)

        await harness.provider.waitForCallCount(1)
        XCTAssertEqual(harness.provider.callCount(), 1, "duplicate picker opens coalesce onto one operation")

        completeOperation(
            call: harness.provider.call(0),
            harness: harness,
            activeProfile: "default",
            groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5"])]
        )
        await first.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }
        await second.collector.waitUntil { events in
            events.contains { event in
                if case .base = event { return true }
                return false
            }
        }
        XCTAssertTrue(first.collector.snapshot().contains { event in
            if case .base = event { return true }
            return false
        }, "both subscribers observe the shared operation's events")
        XCTAssertEqual(harness.provider.callCount(), 1, "both opens share one operation to completion")
        let state = await harness.coordinator.state
        XCTAssertEqual(state, .freshReady)
        await cancel(first)
        await cancel(second)
    }

    // MARK: - LRU cache policy

    func testFourEntryLRUEvictsOnlyCompletedOldestContext() async throws {
        let clock = ScriptedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let harness = makeHarness(clock: { clock.now() }, completedContextLimit: 4)
        let subscriber = await makeSubscriber(harness.coordinator)

        let profiles = ["profile-a", "profile-b", "profile-c", "profile-d", "profile-e"]
        for (index, profile) in profiles.enumerated() {
            // Advance past the freshness window so each open takes the
            // stale-refresh path and starts a provider call (a fresh hit
            // would republish the cache without calling the provider).
            clock.advance(by: 300)
            await harness.coordinator.openPicker()
            await harness.provider.waitForCallCount(index + 1)
            completeOperation(
                call: harness.provider.call(index),
                harness: harness,
                activeProfile: profile,
                groups: [makeGroup(providerID: "openai", modelIDs: ["model-\(profile)"])]
            )
            await subscriber.collector.waitUntil { events in
                events.filter { event in
                    if case .finished = event { return true }
                    return false
                }.count >= index + 1
            }
        }

        // Five completed contexts against a four-entry limit: the oldest
        // (profile-a) must be evicted, so its next open refetches.
        clock.advance(by: 300)
        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(6)
        XCTAssertEqual(harness.provider.callCount(), 6, "the oldest completed context is evicted and must refetch")

        completeOperation(
            call: harness.provider.call(5),
            harness: harness,
            activeProfile: "profile-a",
            groups: [makeGroup(providerID: "openai", modelIDs: ["model-profile-a"])]
        )
        await subscriber.collector.waitUntil { events in
            events.filter { event in
                if case .finished = event { return true }
                return false
            }.count >= 6
        }

        // An in-flight operation is never evicted: start profile-f and hold its
        // live child; the live must still be multicast after other completions.
        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(7)
        let inFlightCall = harness.provider.call(6)
        let inFlightMetadata = verifiedMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            activeProfile: "profile-f",
            gateEpoch: Self.epochZero,
            operationID: inFlightCall.operationID,
            operationGeneration: inFlightCall.operationGeneration
        )
        inFlightCall.continuation.yield(.contextVerified(inFlightMetadata, makeProfileContext(activeProfile: "profile-f")))
        inFlightCall.continuation.yield(.base(makeBaseSnapshot(metadata: inFlightMetadata, groups: [makeGroup(providerID: "openai", modelIDs: ["model-profile-f"])], defaultModel: nil, activeProvider: "openai")))
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case let .base(snapshot) = event, snapshot.groups.flatMap(\.models).map(\.id) == ["model-profile-f"] { return true }
                return false
            }
        }
        inFlightCall.continuation.yield(.live(makeLiveSnapshot(metadata: inFlightMetadata, groups: [makeGroup(providerID: "openai", modelIDs: ["model-profile-f-mini"])], provider: "openai")))
        inFlightCall.continuation.yield(.finished(inFlightMetadata))
        inFlightCall.continuation.finish()
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case let .live(snapshot) = event, snapshot.metadata.operationID == inFlightCall.operationID { return true }
                return false
            }
        }
        let state = await harness.coordinator.state
        XCTAssertEqual(state, .freshReady)
        await cancel(subscriber)
    }

    // MARK: - Cancellation and cleanup

    func testFirstWaiterCancellationLeavesOwnerRunning() async throws {
        let harness = makeHarness()
        let first = await makeSubscriber(harness.coordinator)
        let second = await makeSubscriber(harness.coordinator)

        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        let call = harness.provider.call(0)
        let metadata = verifiedMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            activeProfile: "default",
            gateEpoch: Self.epochZero,
            operationID: call.operationID,
            operationGeneration: call.operationGeneration
        )
        call.continuation.yield(.contextVerified(metadata, makeProfileContext(activeProfile: "default")))
        await first.collector.waitUntil { events in
            events.contains { event in
                if case .contextVerified = event { return true }
                return false
            }
        }

        // The first waiter cancels its own subscription mid-flight.
        first.task.cancel()
        _ = await first.task.value

        call.continuation.yield(.base(makeBaseSnapshot(metadata: metadata, groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5"])], defaultModel: "gpt-5", activeProvider: "openai")))
        call.continuation.yield(.live(makeLiveSnapshot(metadata: metadata, groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5-mini"])], provider: "openai")))
        call.continuation.yield(.finished(metadata))
        call.continuation.finish()

        await second.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }
        XCTAssertEqual(
            harness.provider.callCount(),
            1,
            "a waiter canceling its subscription must not cancel the coordinator-owned operation"
        )
        let secondEvents = second.collector.snapshot()
        XCTAssertTrue(secondEvents.contains { event in
            if case .live = event { return true }
            return false
        })
        XCTAssertTrue(secondEvents.contains { event in
            if case .finished = event { return true }
            return false
        })
        let state = await harness.coordinator.state
        XCTAssertEqual(state, .freshReady)
        await cancel(second)
    }

    func testSupersededCleanupCannotRemoveReplacement() async throws {
        let harness = makeHarness()
        let subscriber = await makeSubscriber(harness.coordinator)

        // Operation A is verified and in flight under epoch 0.
        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        let callA = harness.provider.call(0)
        let metadataA = verifiedMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            activeProfile: "default",
            gateEpoch: Self.epochZero,
            operationID: callA.operationID,
            operationGeneration: callA.operationGeneration
        )
        callA.continuation.yield(.contextVerified(metadataA, makeProfileContext(activeProfile: "default")))
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .contextVerified = event { return true }
                return false
            }
        }

        // A profile switch advances the gate epoch; operation B starts under it.
        try await advanceGateEpoch(gateKey: harness.gateKey)
        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(2)
        let callB = harness.provider.call(1)
        let metadataB = verifiedMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            activeProfile: "work",
            gateEpoch: 1,
            operationID: callB.operationID,
            operationGeneration: callB.operationGeneration
        )

        // A completes late: its base is fenced out, and its cleanup must not
        // remove B's in-flight record.
        callA.continuation.yield(.base(makeBaseSnapshot(metadata: metadataA, groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5"])], defaultModel: "gpt-5", activeProvider: "openai")))
        callA.continuation.yield(.finished(metadataA))
        callA.continuation.finish()

        // B is still in flight: its live child must still be multicast.
        callB.continuation.yield(.contextVerified(metadataB, makeProfileContext(activeProfile: "work")))
        callB.continuation.yield(.base(makeBaseSnapshot(metadata: metadataB, groups: [makeGroup(providerID: "anthropic", modelIDs: ["claude-4"])], defaultModel: "claude-4", activeProvider: "anthropic")))
        callB.continuation.yield(.live(makeLiveSnapshot(metadata: metadataB, groups: [makeGroup(providerID: "anthropic", modelIDs: ["claude-4-mini"])], provider: "anthropic")))
        callB.continuation.yield(.finished(metadataB))
        callB.continuation.finish()

        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case let .live(snapshot) = event, snapshot.metadata.operationID == callB.operationID { return true }
                return false
            }
        }
        let events = subscriber.collector.snapshot()
        XCTAssertFalse(
            containsCompletionEvent(from: callA.operationID, in: events),
            "no event from the superseded operation A may be multicast"
        )
        let state = await harness.coordinator.state
        XCTAssertEqual(state, .freshReady)
        await cancel(subscriber)
    }

    func testOldBaseCompletionCannotPublishAfterSwitchEpoch() async throws {
        let harness = makeHarness()
        let subscriber = await makeSubscriber(harness.coordinator)

        // Operation A is verified and visible under epoch 0.
        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        let callA = harness.provider.call(0)
        let metadataA = verifiedMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            activeProfile: "default",
            gateEpoch: Self.epochZero,
            operationID: callA.operationID,
            operationGeneration: callA.operationGeneration
        )
        callA.continuation.yield(.contextVerified(metadataA, makeProfileContext(activeProfile: "default")))
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .contextVerified = event { return true }
                return false
            }
        }

        // The switch advances the epoch; the old base/live completion is queued
        // and released only after the new operation is visible.
        try await advanceGateEpoch(gateKey: harness.gateKey)
        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(2)
        let callB = harness.provider.call(1)
        let metadataB = verifiedMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            activeProfile: "work",
            gateEpoch: 1,
            operationID: callB.operationID,
            operationGeneration: callB.operationGeneration
        )

        // Release the old response now.
        callA.continuation.yield(.base(makeBaseSnapshot(metadata: metadataA, groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5"])], defaultModel: "gpt-5", activeProvider: "openai")))
        callA.continuation.yield(.finished(metadataA))
        callA.continuation.finish()

        // The new context becomes visible: a context reset precedes its rows.
        callB.continuation.yield(.contextVerified(metadataB, makeProfileContext(activeProfile: "work")))
        callB.continuation.yield(.base(makeBaseSnapshot(metadata: metadataB, groups: [makeGroup(providerID: "anthropic", modelIDs: ["claude-4"])], defaultModel: "claude-4", activeProvider: "anthropic")))
        callB.continuation.yield(.finished(metadataB))
        callB.continuation.finish()

        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }
        let events = subscriber.collector.snapshot()
        XCTAssertFalse(
            containsCompletionEvent(from: callA.operationID, in: events),
            "the old base completion must never publish after the switch epoch"
        )
        let resetIndex = try XCTUnwrap(events.firstIndex { event in
            if case .contextReset = event { return true }
            return false
        })
        let newBaseIndex = try XCTUnwrap(events.firstIndex { event in
            if case let .base(snapshot) = event, snapshot.metadata.operationID == callB.operationID { return true }
            return false
        })
        XCTAssertLessThan(resetIndex, newBaseIndex, "a context reset precedes the new context's rows")
        let state = await harness.coordinator.state
        XCTAssertEqual(state, .freshReady)
        await cancel(subscriber)
    }

    func testCoordinatorRejectsEventWithStaleGateEpochBeforeYield() async throws {
        let harness = makeHarness()
        let subscriber = await makeSubscriber(harness.coordinator)

        // Operation A is in flight under epoch 0.
        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        let callA = harness.provider.call(0)
        let metadataA = verifiedMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            activeProfile: "default",
            gateEpoch: Self.epochZero,
            operationID: callA.operationID,
            operationGeneration: callA.operationGeneration
        )
        callA.continuation.yield(.contextVerified(metadataA, makeProfileContext(activeProfile: "default")))
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .contextVerified = event { return true }
                return false
            }
        }

        // The switch advances the epoch; operation B is current.
        try await advanceGateEpoch(gateKey: harness.gateKey)
        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(2)
        let callB = harness.provider.call(1)
        let metadataB = verifiedMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            activeProfile: "work",
            gateEpoch: 1,
            operationID: callB.operationID,
            operationGeneration: callB.operationGeneration
        )
        callB.continuation.yield(.contextVerified(metadataB, makeProfileContext(activeProfile: "work")))
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case let .contextVerified(metadata, _) = event, metadata.operationID == callB.operationID { return true }
                return false
            }
        }

        // The VM-facing authority check rejects the stale operation and accepts
        // the current one.
        let acceptsStale = await harness.coordinator.accepts(metadataA)
        XCTAssertFalse(acceptsStale, "an event from the pre-switch operation must be rejected")
        let acceptsCurrent = await harness.coordinator.accepts(metadataB)
        XCTAssertTrue(acceptsCurrent, "the current operation under the authoritative epoch is accepted")

        callA.continuation.finish()
        callB.continuation.finish()
        await cancel(subscriber)
    }

    // MARK: - Profile-context failure and retry

    func testProfileResolutionFailureUsesOnlyPreviouslyVerifiedCache() async throws {
        let clock = ScriptedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let harness = makeHarness(clock: { clock.now() })
        let subscriber = await makeSubscriber(harness.coordinator)

        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        completeOperation(
            call: harness.provider.call(0),
            harness: harness,
            activeProfile: "default",
            groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5"])]
        )
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }

        // A forced refresh fails profile verification: only the previously
        // verified snapshot may be published, read-only, as stale-failed.
        await harness.coordinator.retry()
        await harness.provider.waitForCallCount(2)
        let failedCall = harness.provider.call(1)
        let failedMetadata = provisionalMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            startingGateEpoch: Self.epochZero,
            operationID: failedCall.operationID,
            operationGeneration: failedCall.operationGeneration
        )
        failedCall.continuation.yield(.failed(failedMetadata, .context, .profileUnavailable))
        failedCall.continuation.finish()

        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case let .state(state) = event, state == .staleFailed { return true }
                return false
            }
        }
        let staleBase = try XCTUnwrap(lastBase(in: subscriber.collector.snapshot()))
        XCTAssertEqual(staleBase.groups.map(\.id), ["openai"], "the previously verified snapshot stays visible")
        XCTAssertEqual(
            staleBase.metadata.operationID,
            failedCall.operationID,
            "the read-only stale publication rebinds the current operation's metadata"
        )
        let state = await harness.coordinator.state
        XCTAssertEqual(state, .staleFailed)
        XCTAssertEqual(
            harness.provider.callCount(),
            2,
            "profile verification failure must not trigger an automatic refresh"
        )
        await cancel(subscriber)
    }

    func testColdFailureClearsLoadingAndRetryIsAccessible() async throws {
        let harness = makeHarness()
        let subscriber = await makeSubscriber(harness.coordinator)

        await harness.coordinator.openPicker()
        await harness.provider.waitForCallCount(1)
        let failedCall = harness.provider.call(0)
        let failedMetadata = provisionalMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            startingGateEpoch: Self.epochZero,
            operationID: failedCall.operationID,
            operationGeneration: failedCall.operationGeneration
        )
        failedCall.continuation.yield(.failed(failedMetadata, .context, .profileUnavailable))
        failedCall.continuation.finish()

        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case let .state(state) = event, state == .coldFailed(.profileUnavailable) { return true }
                return false
            }
        }
        let failedState = await harness.coordinator.state
        XCTAssertEqual(failedState, .coldFailed(.profileUnavailable), "coldFailed is a terminal, not loading")

        // Retry is accessible and starts a fresh operation.
        await harness.coordinator.retry()
        await harness.provider.waitForCallCount(2)
        XCTAssertEqual(harness.provider.callCount(), 2)
        completeOperation(
            call: harness.provider.call(1),
            harness: harness,
            activeProfile: "default",
            groups: [makeGroup(providerID: "openai", modelIDs: ["gpt-5"])]
        )
        await subscriber.collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }
        let state = await harness.coordinator.state
        XCTAssertEqual(state, .freshReady)
        await cancel(subscriber)
    }

    func testUnverifiedProfileFailureIssuesZeroModelGETsAndRetryIsAccessible() async throws {
        let fixture = CoordinatorWireFixture()
        fixture.installProfilesOnly(#"{"profiles":[],"active":null}"#)
        let client = fixture.makeClient()
        let gateKey = ProfileContextGateKey(
            origin: NormalizedServerOrigin(url: await client.baseURL),
            cookieContextID: client.cookieContextID
        )
        let provider: @Sendable (String?, UUID, UInt64) async -> AsyncStream<CatalogNetworkEvent> = { requestedProfile, operationID, operationGeneration in
            await client.modelCatalogStream(
                requestedProfile: requestedProfile,
                operationID: operationID,
                operationGeneration: operationGeneration
            )
        }
        let coordinator = ChatModelCatalogCoordinator(
            gateKey: gateKey,
            apiClientID: client.apiClientID,
            authGeneration: 0,
            provider: provider,
            configuration: ChatModelCatalogCoordinator.Configuration(
                now: { Date(timeIntervalSince1970: 1_700_000_000) },
                freshnessInterval: 300,
                completedContextLimit: 4,
                telemetrySink: nil
            )
        )
        let stream = await coordinator.subscribe()
        let collector = CatalogEventCollector()
        let subscriber = Task { for await event in stream { collector.append(event) } }

        await coordinator.openPicker()
        await collector.waitUntil { events in
            events.contains { event in
                if case let .state(state) = event, state == .coldFailed(.profileUnavailable) { return true }
                return false
            }
        }

        let modelRequests = fixture.requests().filter { request in
            request.url?.path == "/api/models" || request.url?.path == "/api/models/live"
        }
        XCTAssertEqual(modelRequests.count, 0, "an unverified profile context issues zero model GETs")
        XCTAssertEqual(
            fixture.requests().filter { $0.url?.path == "/api/profiles" }.count,
            1
        )
        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .coldFailed(.profileUnavailable))

        // After the server recovers, retry is accessible and completes normally.
        fixture.installStandardCatalogResponses()
        await coordinator.retry()
        await collector.waitUntil { events in
            events.contains { event in
                if case .finished = event { return true }
                return false
            }
        }
        XCTAssertEqual(
            fixture.requests().filter { $0.url?.path == "/api/models" || $0.url?.path == "/api/models/live" }.count,
            2,
            "the retried operation issues exactly one base/live pair"
        )
        XCTAssertEqual(fixture.requests().filter { $0.url?.path == "/api/profiles" }.count, 2)
        let state = await coordinator.state
        XCTAssertEqual(state, .freshReady)

        subscriber.cancel()
        _ = await subscriber.value
    }

    // MARK: - Project wiring and architecture boundaries

    func testSliceTwoPBXBoundaryIsExact() throws {
        guard let root = repositoryRoot(startingAt: #filePath) else {
            XCTFail("Could not locate the repository by walking upward from #filePath")
            return
        }
        let pbxURL = root
            .appendingPathComponent("HermesMobile.xcodeproj", isDirectory: true)
            .appendingPathComponent("project.pbxproj")
        let pbx = try String(contentsOf: pbxURL, encoding: .utf8)

        let objectIDs = captureAll(
            pattern: #"(?m)^\t\t([0-9A-F]{24})(?:\s*/\*.*?\*/\s*)?="#,
            in: pbx
        )
        XCTAssertEqual(objectIDs.count, Set(objectIDs).count, "PBX object IDs must be globally unique")

        assertPBXMembership(
            fileName: "ChatModelCatalogCoordinatorTests.swift",
            groupName: "HermesMobileTests",
            targetName: "HermesMobileTests",
            in: pbx
        )

        // The coordinator production file is intentionally absent at RED. The
        // structural oracle tolerates its absence here, but GREEN must member it
        // with the same exact flagged build entry before it can appear.
        let productionFile = root
            .appendingPathComponent("HermesMobile", isDirectory: true)
            .appendingPathComponent("Features", isDirectory: true)
            .appendingPathComponent("Chat", isDirectory: true)
            .appendingPathComponent("ChatModelCatalogCoordinator.swift")
        if FileManager.default.fileExists(atPath: productionFile.path)
            || pbx.contains("/* ChatModelCatalogCoordinator.swift") {
            assertPBXMembership(
                fileName: "ChatModelCatalogCoordinator.swift",
                groupName: "Chat",
                targetName: "HermesMobile",
                in: pbx
            )
        }
    }

    func testCoordinatorConsumesOnlyNeutralProjections() throws {
        guard let root = repositoryRoot(startingAt: #filePath) else {
            XCTFail("Could not locate the repository by walking upward from #filePath")
            return
        }
        let productionFile = root
            .appendingPathComponent("HermesMobile", isDirectory: true)
            .appendingPathComponent("Features", isDirectory: true)
            .appendingPathComponent("Chat", isDirectory: true)
            .appendingPathComponent("ChatModelCatalogCoordinator.swift")
        guard FileManager.default.fileExists(atPath: productionFile.path) else {
            // RED phase: the production file does not exist yet; the boundary is
            // enforced when it lands.
            return
        }
        let source = try String(contentsOf: productionFile, encoding: .utf8)
        XCTAssertFalse(source.contains("import SwiftUI"), "the coordinator must not import SwiftUI")
        XCTAssertFalse(source.contains("ModelsResponse"), "recursive wire DTOs stay APIClient-local")
        XCTAssertFalse(source.contains("ModelsLiveResponse"), "recursive wire DTOs stay APIClient-local")
        XCTAssertFalse(source.contains("JSONValue"), "the coordinator never touches raw JSON values")
        XCTAssertTrue(
            source.contains("CatalogNetworkEvent"),
            "the coordinator consumes only neutral CatalogNetworkEvent projections"
        )
    }

    // MARK: - Helpers

    private struct Harness {
        let coordinator: ChatModelCatalogCoordinator
        let gateKey: ProfileContextGateKey
        let apiClientID: UUID
        let provider: ScriptedCatalogProvider
    }

    private func makeHarness(
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) },
        freshnessInterval: TimeInterval = 300,
        completedContextLimit: Int = 4
    ) -> Harness {
        let provider = ScriptedCatalogProvider()
        let gateKey = makeIsolatedGateKey()
        let apiClientID = UUID()
        let coordinator = ChatModelCatalogCoordinator(
            gateKey: gateKey,
            apiClientID: apiClientID,
            authGeneration: 0,
            provider: provider.makeProvider(),
            configuration: ChatModelCatalogCoordinator.Configuration(
                now: clock,
                freshnessInterval: freshnessInterval,
                completedContextLimit: completedContextLimit,
                telemetrySink: nil
            )
        )
        return Harness(
            coordinator: coordinator,
            gateKey: gateKey,
            apiClientID: apiClientID,
            provider: provider
        )
    }

    private func makeIsolatedGateKey() -> ProfileContextGateKey {
        ProfileContextGateKey(
            origin: NormalizedServerOrigin(
                scheme: "https",
                host: "coordinator-\(UUID().uuidString.lowercased()).model-catalog.test",
                port: 443
            ),
            cookieContextID: CatalogCookieContextID.injected(UUID())
        )
    }

    private func makeSubscriber(
        _ coordinator: ChatModelCatalogCoordinator
    ) async -> (collector: CatalogEventCollector, task: Task<Void, Never>) {
        let stream = await coordinator.subscribe()
        let collector = CatalogEventCollector()
        let task = Task { for await event in stream { collector.append(event) } }
        return (collector, task)
    }

    private func cancel(_ subscriber: (collector: CatalogEventCollector, task: Task<Void, Never>)) async {
        subscriber.task.cancel()
        _ = await subscriber.task.value
    }

    private func provisionalMetadata(
        gateKey: ProfileContextGateKey,
        apiClientID: UUID,
        requestedProfile: String? = nil,
        startingGateEpoch: UInt64,
        operationID: UUID,
        operationGeneration: UInt64 = 1
    ) -> CatalogEventMetadata {
        CatalogEventMetadata(
            identity: .provisional(
                CatalogOperationKey(
                    gateKey: gateKey,
                    apiClientID: apiClientID,
                    authGeneration: 0,
                    requestedProfile: requestedProfile,
                    startingGateEpoch: startingGateEpoch
                )
            ),
            operationID: operationID,
            operationGeneration: operationGeneration
        )
    }

    private func verifiedMetadata(
        gateKey: ProfileContextGateKey,
        apiClientID: UUID,
        activeProfile: String,
        gateEpoch: UInt64,
        operationID: UUID,
        operationGeneration: UInt64 = 1
    ) -> CatalogEventMetadata {
        CatalogEventMetadata(
            identity: .verified(
                CatalogContextKey(
                    gateKey: gateKey,
                    apiClientID: apiClientID,
                    authGeneration: 0,
                    activeProfile: activeProfile,
                    gateEpoch: gateEpoch
                )
            ),
            operationID: operationID,
            operationGeneration: operationGeneration
        )
    }

    private func makeProfileContext(activeProfile: String) -> CatalogProfileContext {
        CatalogProfileContext(
            profiles: [
                ProfileSummary(
                    name: activeProfile,
                    path: nil,
                    isDefault: nil,
                    isActive: true,
                    gatewayRunning: nil,
                    model: nil,
                    provider: nil,
                    hasEnv: nil,
                    skillCount: nil
                )
            ],
            activeProfile: activeProfile,
            requestedProfile: nil,
            singleProfileMode: true,
            defaults: CatalogProfileDefaults(model: nil, workspace: nil),
            switchResult: .notRequested
        )
    }

    private func makeGroup(providerID: String, modelIDs: [String]) -> ModelCatalogGroup {
        ModelCatalogGroup(
            id: providerID,
            name: providerID,
            providerID: providerID,
            models: modelIDs.map { ModelCatalogOption(id: $0, displayName: $0, providerID: providerID) },
            extraModels: []
        )
    }

    private func makeBaseSnapshot(
        metadata: CatalogEventMetadata,
        groups: [ModelCatalogGroup],
        defaultModel: String?,
        activeProvider: String?
    ) -> CatalogBaseSnapshot {
        CatalogBaseSnapshot(
            metadata: metadata,
            groups: groups,
            defaultModel: defaultModel,
            activeProvider: activeProvider
        )
    }

    private func makeLiveSnapshot(
        metadata: CatalogEventMetadata,
        groups: [ModelCatalogGroup],
        provider: String?
    ) -> CatalogLiveSnapshot {
        CatalogLiveSnapshot(metadata: metadata, groups: groups, provider: provider)
    }

    private func completeOperation(
        call: ScriptedCatalogCall,
        harness: Harness,
        activeProfile: String,
        groups: [ModelCatalogGroup]
    ) {
        let metadata = verifiedMetadata(
            gateKey: harness.gateKey,
            apiClientID: harness.apiClientID,
            activeProfile: activeProfile,
            gateEpoch: Self.epochZero,
            operationID: call.operationID,
            operationGeneration: call.operationGeneration
        )
        call.continuation.yield(.contextVerified(metadata, makeProfileContext(activeProfile: activeProfile)))
        call.continuation.yield(.base(makeBaseSnapshot(metadata: metadata, groups: groups, defaultModel: groups.first?.models.first?.id, activeProvider: groups.first?.providerID)))
        call.continuation.yield(.finished(metadata))
        call.continuation.finish()
    }

    private func lastBase(in events: [CatalogEvent]) -> CatalogBaseSnapshot? {
        events.reversed().compactMap { event in
            if case let .base(snapshot) = event { return snapshot }
            return nil
        }.first
    }

    private func containsCompletionEvent(from operationID: UUID, in events: [CatalogEvent]) -> Bool {
        // Completion events (base/live/failure/terminal/reset) from a superseded
        // operation must never multicast. A pre-switch contextVerified is
        // legitimate and is excluded: it published before the epoch advanced.
        events.contains { event in
            switch event {
            case .base(let baseSnapshot):
                return baseSnapshot.metadata.operationID == operationID
            case .live(let liveSnapshot):
                return liveSnapshot.metadata.operationID == operationID
            case .liveFailed(let metadata, _), .failed(let metadata, _, _), .finished(let metadata), .cancelled(let metadata), .contextReset(let metadata):
                return metadata.operationID == operationID
            case .contextVerified, .state:
                return false
            }
        }
    }

    private func advanceGateEpoch(gateKey: ProfileContextGateKey) async throws {
        let gate = ProfileContextGateRegistry.shared.gate(for: gateKey)
        let writerID = UUID()
        let admission = try await gate.acquireWriter(operationID: writerID)
        await gate.advanceEpoch(operationID: writerID)
        await gate.releaseWriter(operationID: writerID, admission: admission)
    }

    private func repositoryRoot(startingAt filePath: String) -> URL? {
        var candidate = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        while candidate.path != "/" {
            let projectFile = candidate
                .appendingPathComponent("HermesMobile.xcodeproj", isDirectory: true)
                .appendingPathComponent("project.pbxproj")
            if fileManager.fileExists(atPath: projectFile.path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private func assertPBXMembership(
        fileName: String,
        groupName: String,
        targetName: String,
        in pbx: String
    ) {
        let escapedFileName = NSRegularExpression.escapedPattern(for: fileName)
        let buildPattern = #"(?m)^\t\t([0-9A-F]{24}) /\* \#(escapedFileName) in Sources \*/ = \{isa = PBXBuildFile; fileRef = ([0-9A-F]{24}) /\* \#(escapedFileName) \*/; settings = \{COMPILER_FLAGS = \"-strict-concurrency=complete -warnings-as-errors\"; \}; \};$"#
        guard let buildMatches = captureGroups(pattern: buildPattern, in: pbx), buildMatches.count == 2 else {
            XCTFail("Expected one exact flagged PBXBuildFile for \(fileName)")
            return
        }
        let buildID = buildMatches[0]
        let fileReferenceID = buildMatches[1]

        XCTAssertEqual(
            occurrenceCount(of: "/* \(fileName) in Sources */", in: pbx),
            2,
            "\(fileName) must have one PBXBuildFile and one Sources-phase comment"
        )
        XCTAssertEqual(
            occurrenceCount(of: "/* \(fileName) */", in: pbx),
            3,
            "\(fileName) must have one file reference, one group child, and one PBXBuildFile reference"
        )

        let escapedGroupName = NSRegularExpression.escapedPattern(for: groupName)
        let groupPattern = #"(?ms)^\t\t[0-9A-F]{24} /\* \#(escapedGroupName) \*/ = \{\n\t\t\tisa = PBXGroup;.*?^\t\t\};"#
        let groupBlocks = captureAllBlocks(pattern: groupPattern, in: pbx)
        XCTAssertEqual(groupBlocks.count, 1, "Expected exactly one \(groupName) PBXGroup")
        if let group = groupBlocks.first {
            XCTAssertEqual(occurrenceCount(of: fileReferenceID, in: group), 1)
        }

        let escapedTargetName = NSRegularExpression.escapedPattern(for: targetName)
        let targetPattern = #"(?ms)^\t\t[0-9A-F]{24} /\* \#(escapedTargetName) \*/ = \{\n\t\t\tisa = PBXNativeTarget;.*?(?=^\t\t[0-9A-F]{24} /\*|^/\* End PBXNativeTarget)"#
        guard let target = captureAllBlocks(pattern: targetPattern, in: pbx).first else {
            XCTFail("Missing native target \(targetName)")
            return
        }
        let phaseMatches = captureAll(
            pattern: #"buildPhases = \(\s*([0-9A-F]{24}) /\* Sources \*/"#,
            in: target
        )
        XCTAssertEqual(phaseMatches.count, 1, "\(targetName) must have one leading Sources phase")
        guard let phaseID = phaseMatches.first else { return }

        let phasePattern = #"(?ms)^\t\t\#(phaseID) /\* Sources \*/ = \{.*?(?=^\t\t[0-9A-F]{24} /\*|^/\* End PBXSourcesBuildPhase)"#
        guard let phase = captureAllBlocks(pattern: phasePattern, in: pbx).first else {
            XCTFail("Missing Sources phase for \(targetName)")
            return
        }
        XCTAssertEqual(occurrenceCount(of: buildID, in: phase), 1)

        let allSourcePhases = captureAllBlocks(
            pattern: #"(?ms)^\t\t[0-9A-F]{24} /\* Sources \*/ = \{.*?(?=^\t\t[0-9A-F]{24} /\*|^/\* End PBXSourcesBuildPhase)"#,
            in: pbx
        )
        XCTAssertEqual(
            allSourcePhases.reduce(0) { $0 + occurrenceCount(of: buildID, in: $1) },
            1,
            "\(fileName) build file must belong to exactly one Sources phase"
        )
    }

    private func occurrenceCount(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func captureAll(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let capture = match.range(at: 1)
            guard let swiftRange = Range(capture, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private func captureGroups(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            let capture = match.range(at: index)
            guard let swiftRange = Range(capture, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private func captureAllBlocks(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }
}

// MARK: - Scripted provider fixture

private struct ScriptedCatalogCall {
    let requestedProfile: String?
    let operationID: UUID
    let operationGeneration: UInt64
    let continuation: AsyncStream<CatalogNetworkEvent>.Continuation
}

/// Lock-protected provider that hands the coordinator one scripted event stream
/// per operation. The test observes each provider invocation through a checked
/// continuation and drives events through the recorded stream continuation.
/// No sleep, polling, or wall-clock oracle is involved.
private final class ScriptedCatalogProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [ScriptedCatalogCall] = []
    private var callWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func makeProvider() -> @Sendable (String?, UUID, UInt64) async -> AsyncStream<CatalogNetworkEvent> {
        { [self] requestedProfile, operationID, operationGeneration in
            AsyncStream { continuation in
                register(
                    requestedProfile: requestedProfile,
                    operationID: operationID,
                    operationGeneration: operationGeneration,
                    continuation: continuation
                )
            }
        }
    }

    private func register(
        requestedProfile: String?,
        operationID: UUID,
        operationGeneration: UInt64,
        continuation: AsyncStream<CatalogNetworkEvent>.Continuation
    ) {
        lock.lock()
        calls.append(
            ScriptedCatalogCall(
                requestedProfile: requestedProfile,
                operationID: operationID,
                operationGeneration: operationGeneration,
                continuation: continuation
            )
        )
        let count = calls.count
        let waiters = callWaiters.removeValue(forKey: count) ?? []
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForCallCount(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if calls.count >= count {
                lock.unlock()
                continuation.resume()
                return
            }
            callWaiters[count, default: []].append(continuation)
            lock.unlock()
        }
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.count
    }

    func call(_ index: Int) -> ScriptedCatalogCall {
        lock.lock()
        defer { lock.unlock() }
        return calls[index]
    }
}

// MARK: - Subscriber collector

/// Lock-protected multicast subscriber that records `CatalogEvent`s in order and
/// resolves checked-continuation waiters as soon as a predicate holds. Waiters
/// are one-shot and re-checked on every append, so no event can be missed.
private final class CatalogEventCollector: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let predicate: ([CatalogEvent]) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var events: [CatalogEvent] = []
    private var waiters: [Waiter] = []

    func append(_ event: CatalogEvent) {
        lock.lock()
        events.append(event)
        let resolved = waiters.filter { $0.predicate(events) }
        let resolvedIDs = Set(resolved.map { $0.id })
        waiters.removeAll { resolvedIDs.contains($0.id) }
        lock.unlock()
        for waiter in resolved {
            waiter.continuation.resume()
        }
    }

    func waitUntil(_ predicate: @escaping ([CatalogEvent]) -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if predicate(events) {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(Waiter(id: UUID(), predicate: predicate, continuation: continuation))
            lock.unlock()
        }
    }

    func snapshot() -> [CatalogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

// MARK: - Scripted clock

private final class ScriptedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) {
        current = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

// MARK: - Wire fixture for the zero-model-GET proof

private final class CoordinatorWireHandlerRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

    func install(_ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data), for host: String) {
        lock.lock()
        handlers[host] = handler
        lock.unlock()
    }

    func removeHandler(for host: String) {
        lock.lock()
        handlers.removeValue(forKey: host)
        lock.unlock()
    }

    func handler(for host: String) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        lock.lock()
        defer { lock.unlock() }
        if let handler = handlers[host] {
            return handler
        }
        return { _ in throw URLError(.resourceUnavailable) }
    }
}

private final class CoordinatorWireURLProtocol: URLProtocol {
    static let registry = CoordinatorWireHandlerRegistry()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".model-catalog.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let host = request.url?.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try Self.registry.handler(for: host)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedWireRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }

    func snapshot() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }
}

/// Deterministic URLProtocol fixture keyed by a unique per-fixture test host.
/// Every handler is lock-protected and `@Sendable`; request recording belongs to
/// the lock-owned recorder, mirroring the Slice 0/1 networking fixture pattern.
private final class CoordinatorWireFixture: @unchecked Sendable {
    private let host: String
    let baseURL: URL
    private let recorder = LockedWireRequestRecorder()

    init() {
        host = "coordinator-wire-\(UUID().uuidString.lowercased()).model-catalog.test"
        baseURL = URL(string: "https://\(host)")!
    }

    deinit {
        CoordinatorWireURLProtocol.registry.removeHandler(for: host)
    }

    func install(_ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        CoordinatorWireURLProtocol.registry.install(
            { [recorder] request in
                recorder.append(request)
                return try handler(request)
            },
            for: host
        )
    }

    func installProfilesOnly(_ json: String) {
        install { request in
            switch request.url?.path {
            case "/api/profiles":
                return try Self.jsonResponse(json, for: request)
            default:
                throw URLError(.resourceUnavailable)
            }
        }
    }

    func installStandardCatalogResponses() {
        install { request in
            switch request.url?.path {
            case "/api/profiles":
                return try Self.jsonResponse(Self.profilesDefaultJSON, for: request)
            case "/api/models":
                return try Self.jsonResponse(Self.modelsDefaultJSON, for: request)
            case "/api/models/live":
                return try Self.jsonResponse(Self.liveDefaultJSON, for: request)
            default:
                throw URLError(.resourceUnavailable)
            }
        }
    }

    func makeClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoordinatorWireURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return APIClient(baseURL: baseURL, session: session)
    }

    func requests() -> [URLRequest] {
        recorder.snapshot()
    }

    static let profilesDefaultJSON =
        #"{"profiles":[{"name":"default","isActive":true}],"active":"default","single_profile_mode":true}"#
    static let modelsDefaultJSON =
        #"{"groups":[{"provider_id":"openai","name":"OpenAI","models":[{"id":"gpt-5","label":"GPT-5"}]}],"default_model":"gpt-5","active_provider":"openai"}"#
    static let liveDefaultJSON =
        #"{"provider":"openai","models":[{"id":"gpt-5-mini","label":"GPT-5 Mini"}]}"#

    static func jsonResponse(
        _ json: String,
        for request: URLRequest,
        statusCode: Int = 200
    ) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else { throw URLError(.badURL) }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            throw URLError(.badServerResponse)
        }
        return (response, Data(json.utf8))
    }
}
