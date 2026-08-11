import SwiftData
import XCTest
@testable import HermesMobile

final class ChatStreamCoordinatorTests: APIClientTestCase {
    @MainActor
    func testStartBuildsReplayURLAndStartsLiveActivity() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123", replayAfterSeq: 4, recoveryState: .reconnecting)

        let url = try XCTUnwrap(streamClient.startedURLs.first)
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.path, "/api/chat/stream")
        XCTAssertEqual(queryItems.first(where: { $0.name == "stream_id" })?.value, "stream-123")
        XCTAssertEqual(queryItems.first(where: { $0.name == "replay" })?.value, "1")
        XCTAssertEqual(queryItems.first(where: { $0.name == "after_seq" })?.value, "4")
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(coordinator.recoveryState, .reconnecting)
        XCTAssertTrue(coordinator.isReplayConnection)
        XCTAssertEqual(delegate.startMonitoringCount, 1)
        XCTAssertEqual(liveActivityManager.starts, [
            CoordinatorSpyLiveActivityManager.Start(
                sessionID: "session-abc",
                sessionTitle: "Planning",
                streamID: "stream-123"
            )
        ])
    }

    @MainActor
    func testSuspendSavesLastEventStopsStreamAndMarksLiveActivityStale() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.token("Partial answer."), lastEventID: "session-abc:7")
        coordinator.suspendActiveStreamConnection()

        XCTAssertEqual(coordinator.lastEventID, "session-abc:7")
        XCTAssertTrue(coordinator.isConnectionSuspended)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(delegate.saveSnapshotCount, 1)
        XCTAssertEqual(delegate.stopMonitoringClearPromptValues, [true])
        XCTAssertEqual(liveActivityManager.markStaleCount, 1)
    }

    @MainActor
    func testForegroundReconnectActiveStreamReloadsAndRestartsWithoutReplay() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")
        coordinator.suspendActiveStreamConnection()

        await coordinator.reconnectIfNeeded()

        XCTAssertEqual(delegate.loadMessagesCount, 1)
        XCTAssertFalse(coordinator.isConnectionSuspended)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        let resumedURL = try XCTUnwrap(streamClient.startedURLs.last)
        let queryItems = URLComponents(url: resumedURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(queryItems.first(where: { $0.name == "replay" }))
    }

    @MainActor
    func testForegroundReconnectActiveStreamDoesNotRestartAfterReplacementDuringLoad() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-123"}"#, for: request)
        }
        delegate.onLoadMessages = {
            coordinator.start(streamID: "stream-new")
        }

        coordinator.start(streamID: "stream-123")
        coordinator.suspendActiveStreamConnection()

        await coordinator.reconnectIfNeeded()

        XCTAssertEqual(coordinator.activeStreamID, "stream-new")
        XCTAssertFalse(coordinator.isConnectionSuspended)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertEqual(delegate.loadMessagesCount, 1)
    }

    @MainActor
    func testForegroundReconnectInactiveReplayUsesRestoredEventID() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(
                #"{"active": false, "stream_id": "stream-123", "replay_available": true}"#,
                for: request
            )
        }

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.token("Partial answer."), lastEventID: "session-abc:9")
        coordinator.suspendActiveStreamConnection()

        await coordinator.reconnectIfNeeded()

        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let queryItems = URLComponents(url: replayURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(queryItems.first(where: { $0.name == "replay" })?.value, "1")
        XCTAssertEqual(queryItems.first(where: { $0.name == "after_seq" })?.value, "9")
        XCTAssertFalse(coordinator.isConnectionSuspended)
    }

    @MainActor
    func testForegroundReconnectInactiveCompletedTranscriptFinishesStream() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = true
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")
        coordinator.suspendActiveStreamConnection()

        await coordinator.reconnectIfNeeded()

        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertEqual(delegate.loadMessagesCount, 1)
        XCTAssertEqual(delegate.completedNeedsTranscriptRefreshValues, [false])
        XCTAssertEqual(liveActivityManager.ends.last?.status, .complete)
    }

    @MainActor
    func testForegroundReconnectInactiveWithoutAssistantFinalizesFailedAndEndsLiveActivity() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        // The reloaded transcript surfaced no assistant reply after the user message.
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = false
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")
        coordinator.suspendActiveStreamConnection()

        await coordinator.reconnectIfNeeded()

        // #246: this path previously re-armed and returned, leaving the Live
        // Activity stuck on "running". It must now finalize as failed and end it.
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertFalse(coordinator.isConnectionSuspended)
        XCTAssertEqual(delegate.loadMessagesCount, 1)
        XCTAssertEqual(liveActivityManager.ends.last?.status, .failed)
    }

    @MainActor
    func testRefreshTranscriptIfCompletedWithoutAssistantKeepsWaitingWithoutEndingLiveActivity() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = false
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")

        await coordinator.refreshTranscriptIfCompleted(streamID: "stream-123")

        // The live SSE is still connected here, so the foreground safety net must
        // keep waiting for the real completion rather than finalizing (#246). This
        // is the deliberate counterpart to the reconnect-after-suspend fix.
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(delegate.loadMessagesCount, 1)
        XCTAssertTrue(liveActivityManager.ends.isEmpty)
    }

    @MainActor
    func testRefreshTranscriptIfCompletedBailsWhenStreamReplacedDuringLoad() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = true
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }
        // A newer run starts while the transcript reload is suspended.
        delegate.onLoadMessages = {
            coordinator.start(streamID: "stream-new")
        }

        coordinator.start(streamID: "stream-123")

        await coordinator.refreshTranscriptIfCompleted(streamID: "stream-123")

        // PR #266: the post-load guard must bail so the newer stream is neither
        // finalized nor clobbered by the now-stale refresh.
        XCTAssertEqual(coordinator.activeStreamID, "stream-new")
        XCTAssertTrue(liveActivityManager.ends.isEmpty)
    }

    @MainActor
    func testRefreshTranscriptIfCompletedSkipsFinalizeWhenRunCompletesDuringLoad() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = true
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }
        // The live SSE delivers completion while the transcript reload is suspended.
        delegate.onLoadMessages = {
            streamClient.emit(.done(DoneStreamEvent()))
        }

        coordinator.start(streamID: "stream-123")

        await coordinator.refreshTranscriptIfCompleted(streamID: "stream-123")

        // PR #266 #2: only the live-SSE completion finalizes; the now-stale refresh
        // must not finalize again (no double end / double finishStream). The run
        // generation captured before the load changed, so the refresh bails.
        XCTAssertEqual(liveActivityManager.ends.map(\.status), [.complete])
        XCTAssertNil(coordinator.activeStreamID)
    }

    @MainActor
    func testForegroundReconnectInactiveCompletedStreamDoesNotFinishReplacementAfterLoad() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = true
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }
        delegate.onLoadMessages = {
            coordinator.start(streamID: "stream-new")
        }

        coordinator.start(streamID: "stream-123")
        coordinator.suspendActiveStreamConnection()

        await coordinator.reconnectIfNeeded()

        XCTAssertEqual(coordinator.activeStreamID, "stream-new")
        XCTAssertFalse(coordinator.isConnectionSuspended)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertTrue(delegate.completedNeedsTranscriptRefreshValues.isEmpty)
        XCTAssertTrue(liveActivityManager.ends.isEmpty)
    }

    @MainActor
    func testStaleDetectionWaitsForTransportQuietThresholdThenPollsStatus() async throws {
        var statusRequests = 0
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            timing: ChatStreamCoordinatorTiming(
                checkingInterval: 5,
                reconnectInterval: 18,
                runningToolReconnectInterval: 25,
                statusPollCooldown: 4,
                transportFreshInterval: 12
            )
        ) { request in
            statusRequests += 1
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-123"}"#, for: request)
        }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: start)

        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(4.9))
        XCTAssertEqual(statusRequests, 0)
        XCTAssertEqual(coordinator.recoveryState, .idle)

        // #227: semantically quiet past checkingInterval, but the transport was
        // active 5.1s ago — still within transportFreshInterval, so no chip and
        // no status poll yet.
        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(5.1))
        XCTAssertEqual(statusRequests, 0)
        XCTAssertEqual(coordinator.recoveryState, .idle)

        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(12.1))
        XCTAssertEqual(statusRequests, 1)
        XCTAssertEqual(coordinator.recoveryState, .checking)
    }

    @MainActor
    func testHeartbeatKeepsSemanticallyQuietStreamOnOriginalConnection() async throws {
        var statusRequests = 0
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(streamClient: streamClient) { request in
            statusRequests += 1
            return apiTestJSONResponse(
                #"{"active": true, "stream_id": "stream-123", "replay_available": true}"#,
                for: request
            )
        }

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: Date().addingTimeInterval(-60))
        streamClient.emit(.heartbeat)

        await coordinator.recoverStaleStreamIfNeeded(now: Date().addingTimeInterval(1))

        // #227: the heartbeat 1s ago proves the transport is alive, so the
        // semantically quiet stream stays idle with zero status polls — no
        // "Checking stream" chip and no reconnect.
        XCTAssertEqual(statusRequests, 0)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(streamClient.stopCount, 0)
        XCTAssertEqual(coordinator.recoveryState, .idle)
    }

    @MainActor
    func testHeartbeatDemotesCheckingStateToIdle() async throws {
        var statusRequests = 0
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(streamClient: streamClient) { request in
            statusRequests += 1
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: Date().addingTimeInterval(-13))

        await coordinator.recoverStaleStreamIfNeeded(now: Date())
        XCTAssertEqual(statusRequests, 1)
        XCTAssertEqual(coordinator.recoveryState, .checking)

        streamClient.emit(.heartbeat)

        XCTAssertEqual(coordinator.recoveryState, .idle)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(streamClient.stopCount, 0)
    }

    // The MockURLProtocol handler runs on URLSession's protocol thread while the
    // coordinator's status-poll await has suspended the main actor, so a
    // main-queue sync hop delivers the heartbeat deterministically *mid-flight*
    // — before the poll's continuation resumes (PR #238 review).
    @MainActor
    func testHeartbeatDuringStatusPollKeepsIdleStateWithoutReassertingChecking() async throws {
        var statusRequests = 0
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(streamClient: streamClient) { request in
            statusRequests += 1
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { streamClient.emit(.heartbeat) }
            }
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: Date().addingTimeInterval(-13))

        await coordinator.recoverStaleStreamIfNeeded(now: Date())

        XCTAssertEqual(statusRequests, 1)
        XCTAssertEqual(coordinator.recoveryState, .idle)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(streamClient.stopCount, 0)
    }

    @MainActor
    func testHeartbeatDuringForceReconnectStatusPollSkipsReconnect() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(streamClient: streamClient) { request in
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { streamClient.emit(.heartbeat) }
            }
            return apiTestJSONResponse(
                #"{"active": true, "stream_id": "stream-123", "replay_available": true}"#,
                for: request
            )
        }

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: Date().addingTimeInterval(-19))

        await coordinator.recoverStaleStreamIfNeeded(now: Date())

        XCTAssertEqual(coordinator.recoveryState, .idle)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(streamClient.stopCount, 0)
    }

    @MainActor
    func testHeartbeatDoesNotDemoteReconnectingState() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(streamClient: streamClient) { request in
            apiTestJSONResponse(
                #"{"active": true, "stream_id": "stream-123", "replay_available": true}"#,
                for: request
            )
        }

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: Date().addingTimeInterval(-20))

        await coordinator.recoverStaleStreamIfNeeded(now: Date())
        XCTAssertEqual(coordinator.recoveryState, .reconnecting)

        streamClient.emit(.heartbeat)

        XCTAssertEqual(coordinator.recoveryState, .reconnecting)
    }

    @MainActor
    func testMissingTransportActivityReconnectsStaleActiveStream() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(streamClient: streamClient) { request in
            apiTestJSONResponse(
                #"{"active": true, "stream_id": "stream-123", "replay_available": true}"#,
                for: request
            )
        }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: start)

        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(18.1))

        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(coordinator.recoveryState, .reconnecting)
    }

    @MainActor
    func testSilentInitialConnectionReconnectsWhenStale() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(streamClient: streamClient) { request in
            apiTestJSONResponse(
                #"{"active": true, "stream_id": "stream-123", "replay_available": true}"#,
                for: request
            )
        }

        coordinator.start(streamID: "stream-123")
        XCTAssertNil(coordinator.lastProgressDate)
        let connectionStartedAt = try XCTUnwrap(coordinator.lastTransportActivityDate)

        await coordinator.recoverStaleStreamIfNeeded(
            now: connectionStartedAt.addingTimeInterval(18.1)
        )

        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(coordinator.recoveryState, .reconnecting)
    }

    @MainActor
    func testStaleRecoveryDoesNotFinishReplacementStreamAfterTranscriptLoad() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = true
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate,
            timing: ChatStreamCoordinatorTiming(
                checkingInterval: 5,
                reconnectInterval: 18,
                runningToolReconnectInterval: 25,
                statusPollCooldown: 4,
                transportFreshInterval: 12
            )
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }
        delegate.onLoadMessages = {
            coordinator.start(streamID: "stream-new")
        }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: start)

        // 12.1s: past transportFreshInterval, so the stale-recovery status poll
        // actually fires (#227).
        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(12.1))

        XCTAssertEqual(coordinator.activeStreamID, "stream-new")
        XCTAssertFalse(coordinator.isConnectionSuspended)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertTrue(delegate.completedNeedsTranscriptRefreshValues.isEmpty)
        XCTAssertTrue(liveActivityManager.ends.isEmpty)
    }

    @MainActor
    func testStaleRecoverySkipsFinalizeWhenRunCompletesDuringLoad() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = true
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate,
            timing: ChatStreamCoordinatorTiming(
                checkingInterval: 5,
                reconnectInterval: 18,
                runningToolReconnectInterval: 25,
                statusPollCooldown: 4,
                transportFreshInterval: 12
            )
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }
        // The live SSE delivers completion while the stale-recovery transcript
        // reload is suspended.
        delegate.onLoadMessages = {
            streamClient.emit(.done(DoneStreamEvent()))
        }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: start)

        // 12.1s: past transportFreshInterval, so the stale-recovery status poll
        // actually fires (#227).
        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(12.1))

        // PR #266 review #3: the run generation captured before the load changed
        // when `.done` finalized the run, so the now-stale stale-recovery path
        // bails via the shared canFinalizeRunAfterLoad guard instead of finalizing
        // a second time (no double end / double finishStream).
        XCTAssertEqual(liveActivityManager.ends.map(\.status), [.complete])
        XCTAssertNil(coordinator.activeStreamID)
    }

    @MainActor
    func testStaleRecoveryFinalizesInactiveStreamAndEndsLiveActivity() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        // The reloaded transcript surfaced the assistant reply for the completed run.
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = true
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate,
            timing: ChatStreamCoordinatorTiming(
                checkingInterval: 5,
                reconnectInterval: 18,
                runningToolReconnectInterval: 25,
                statusPollCooldown: 4,
                transportFreshInterval: 12
            )
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: start)

        // 12.1s: past transportFreshInterval, so the stale-recovery status poll
        // actually fires (#227).
        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(12.1))

        // Happy path: server reports the stale run inactive and no concurrent run or
        // completion intervened, so canFinalizeRunAfterLoad lets the stale-recovery
        // path complete from the refreshed transcript and end the Live Activity.
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertFalse(coordinator.isConnectionSuspended)
        XCTAssertEqual(liveActivityManager.ends.map(\.status), [.complete])
    }

    @MainActor
    func testTransportErrorSuspendsAndReconnectsWithReplay() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(
                #"{"active": false, "stream_id": "stream-123", "replay_available": true}"#,
                for: request
            )
        }

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.token("Partial answer."), lastEventID: "session-abc:4")
        streamClient.emit(.transportError("lost connection"), lastEventID: "session-abc:4")

        try await waitUntil { streamClient.startedURLs.count == 2 }

        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let queryItems = URLComponents(url: replayURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(queryItems.first(where: { $0.name == "after_seq" })?.value, "4")
        XCTAssertEqual(delegate.saveSnapshotCount, 1)
        XCTAssertEqual(liveActivityManager.markStaleCount, 1)
    }

    @MainActor
    func testCompletionErrorAndCancelFinalizeLiveActivity() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/cancel")
            return apiTestJSONResponse(#"{"ok": true}"#, for: request)
        }

        coordinator.start(streamID: "stream-complete")
        streamClient.emit(.done(DoneStreamEvent()))
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertEqual(delegate.completedNeedsTranscriptRefreshValues, [true])
        XCTAssertEqual(liveActivityManager.ends.last?.status, .complete)

        coordinator.start(streamID: "stream-error")
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 12.25,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(coordinator.liveTokensPerSecond, 12.25)
        streamClient.emit(.error("server failed"))
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertNil(coordinator.liveTokensPerSecond)
        XCTAssertEqual(delegate.errorMessages, ["server failed"])
        XCTAssertEqual(liveActivityManager.ends.last?.status, .failed)

        coordinator.start(streamID: "stream-cancel")
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 24.5,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(coordinator.liveTokensPerSecond, 24.5)
        let disposition = await coordinator.cancelActiveStream()
        guard case .accepted = disposition else {
            XCTFail("expected accepted cancel disposition, got \(disposition)")
            return
        }
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertNil(coordinator.liveTokensPerSecond)
        XCTAssertEqual(liveActivityManager.ends.last?.status, .cancelled)
    }

    @MainActor
    func testLiveResponseSpeedAcceptsOnlyCurrentSessionExactReadingsAndClearsOnLifecycleChanges() {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate)

        coordinator.start(streamID: "stream-one")
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 12.25,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(coordinator.liveTokensPerSecond, 12.25)

        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 99,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "another-session"
        )))
        XCTAssertEqual(coordinator.liveTokensPerSecond, 12.25)

        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 12.25,
            isTokensPerSecondAvailable: true,
            isEstimated: true,
            sessionId: "session-abc"
        )))
        XCTAssertNil(coordinator.liveTokensPerSecond)

        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 24.5,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        _ = coordinator.prepareForSessionLoad()
        XCTAssertNil(coordinator.liveTokensPerSecond)

        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 24.5,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        coordinator.start(streamID: "stream-two")
        XCTAssertNil(coordinator.liveTokensPerSecond)

        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 36.75,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        streamClient.emit(.done(DoneStreamEvent(usage: ContextWindowSnapshot(
            contextLength: nil,
            thresholdTokens: nil,
            lastPromptTokens: nil,
            inputTokens: nil,
            outputTokens: nil,
            estimatedCost: nil,
            tokensPerSecond: 40.5
        ))))

        XCTAssertNil(coordinator.liveTokensPerSecond)
        XCTAssertEqual(delegate.donePayloads.last?.usage?.tokensPerSecond, 40.5)
    }

    @MainActor
    func testLiveResponseSpeedClearsImmediatelyWhenTransportFails() {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate)

        coordinator.start(streamID: "stream-one")
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 12.25,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(coordinator.liveTokensPerSecond, 12.25)

        streamClient.emit(.transportError("Connection lost"))

        XCTAssertNil(coordinator.liveTokensPerSecond)
        XCTAssertTrue(coordinator.isConnectionSuspended)
    }

    @MainActor
    func testDecodedAppErrorEventTerminatesStreamAndSurfacesMessage() {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-apperror")
        streamClient.emit(SSEEventDecoder.decode(
            eventType: "apperror",
            data: #"{"message": "Auto-compression failed", "type": "compression_error"}"#
        ))

        // apperror rides the terminal `.error` path: message surfaced, run failed,
        // socket stopped, stream fully finished (issue #25).
        XCTAssertEqual(delegate.errorMessages, ["Auto-compression failed"])
        XCTAssertEqual(liveActivityManager.ends.last?.status, .failed)
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(delegate.finishCount, 1)
    }

    // MARK: - Slice 1 (#18): run identity model and connection callback fencing

    // A replacement run for the SAME stream ID is a new logical generation: the
    // run identity changes even though the stream ID does not. The first
    // connection is callback index 0; the replacement is a second connection.
    @MainActor
    func testSameStreamIDReplacementCreatesNewLogicalGeneration() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate)

        coordinator.start(streamID: "stream-123")
        let firstIdentity = try XCTUnwrap(coordinator.runIdentity)
        XCTAssertEqual(firstIdentity.streamID, "stream-123")
        XCTAssertEqual(firstIdentity.logicalGeneration, 1)

        // Replacement run with the SAME stream ID: new logical generation, not a
        // continuation of the first run.
        coordinator.start(streamID: "stream-123")
        let replacementIdentity = try XCTUnwrap(coordinator.runIdentity)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertEqual(replacementIdentity.streamID, "stream-123")
        XCTAssertEqual(replacementIdentity.logicalGeneration, firstIdentity.logicalGeneration + 1)
        XCTAssertNotEqual(replacementIdentity, firstIdentity)
    }

    // A token delivered through the OLD connection's retained callback (index 0)
    // must not mutate the replacement run: no delegate/transcript append, and
    // the replacement's identity and active stream survive untouched.
    @MainActor
    func testOldConnectionTokenCannotMutateReplacementRun() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate)

        // Connection 0: first run for the stream.
        coordinator.start(streamID: "stream-123")
        // Connection 1: replacement run with the SAME stream ID.
        coordinator.start(streamID: "stream-123")
        let replacementIdentity = try XCTUnwrap(coordinator.runIdentity)
        XCTAssertEqual(streamClient.startedURLs.count, 2)

        streamClient.emit(.token("stale token"), fromConnection: 0)

        XCTAssertTrue(delegate.tokens.isEmpty)
        XCTAssertEqual(coordinator.runIdentity, replacementIdentity)
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(delegate.finishCount, 0)
    }

    // A late terminal `.done` from the OLD connection must not finalize the
    // replacement: no delegate done, no completed-response callback, no Live
    // Activity end, no finish, and the replacement run stays active.
    @MainActor
    func testLateOldConnectionDoneCannotFinalizeReplacementRun() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        coordinator.start(streamID: "stream-123")
        let replacementIdentity = try XCTUnwrap(coordinator.runIdentity)
        XCTAssertEqual(streamClient.startedURLs.count, 2)

        streamClient.emit(.done(DoneStreamEvent()), fromConnection: 0)

        XCTAssertTrue(delegate.donePayloads.isEmpty)
        XCTAssertTrue(delegate.completedNeedsTranscriptRefreshValues.isEmpty)
        XCTAssertTrue(liveActivityManager.ends.isEmpty)
        XCTAssertEqual(delegate.finishCount, 0)
        XCTAssertEqual(coordinator.runIdentity, replacementIdentity)
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
    }

    // A callback retained from a DIFFERENT session's connection (different
    // stream ID) is fenced before any delegate mutation: the token never reaches
    // the transcript and the current run is untouched.
    @MainActor
    func testCallbackFromWrongSessionIsIgnoredBeforeDelegateMutation() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        // Connection 0: a run in one session context.
        coordinator.start(streamID: "stream-123")
        // Connection 1: a different session's run (different stream ID).
        coordinator.start(streamID: "stream-other")
        let currentIdentity = try XCTUnwrap(coordinator.runIdentity)
        XCTAssertEqual(currentIdentity.streamID, "stream-other")
        XCTAssertEqual(streamClient.startedURLs.count, 2)

        streamClient.emit(.token("cross-session token"), fromConnection: 0)

        XCTAssertTrue(delegate.tokens.isEmpty)
        XCTAssertEqual(coordinator.runIdentity, currentIdentity)
        XCTAssertEqual(coordinator.activeStreamID, "stream-other")
        XCTAssertTrue(liveActivityManager.ends.isEmpty)
        XCTAssertEqual(delegate.finishCount, 0)
    }

    // MARK: - Slice 2 (#18): central terminal transition and outcome precedence

    // First-valid-authoritative-terminal-wins: `.done` then `.streamEnd`
    // commits `completed` exactly once — one terminal record (identity +
    // outcome), one terminal event, one finish, one Live Activity end, one
    // snapshot removal, one cleanup pass. The completing connection's own
    // terminal event arrives late, after finalization, through its retained
    // callback (connection 0).
    @MainActor
    func testDoneThenStreamEndProducesOneCompletedTerminalAndOneInlineEvent() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        let identity = try XCTUnwrap(coordinator.runIdentity)

        streamClient.emit(.done(DoneStreamEvent()))
        streamClient.emit(.streamEnd, fromConnection: 0)

        XCTAssertEqual(
            delegate.terminalTransitions,
            [RecordedTerminalTransition(identity: identity, outcome: .completed)]
        )
        XCTAssertEqual(delegate.terminalEventCount, 1)
        XCTAssertEqual(delegate.finishCount, 1)
        XCTAssertEqual(delegate.completedNeedsTranscriptRefreshValues, [true])
        XCTAssertEqual(delegate.removedSnapshotStreamIDs.count, 1)
        XCTAssertEqual(delegate.stopMonitoringClearPromptValues.count, 1)
        XCTAssertEqual(liveActivityManager.ends.map { $0.status }, [.complete])
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertNil(coordinator.activeStreamID)
    }

    // `.streamEnd` then a late `.done` commits `completed`: the late done is
    // not a candidate, appends no transcript payload, and finishes nothing.
    @MainActor
    func testStreamEndThenDoneProducesOneCompletedTerminalAndOneInlineEvent() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        let identity = try XCTUnwrap(coordinator.runIdentity)

        streamClient.emit(.streamEnd)
        streamClient.emit(.done(DoneStreamEvent()), fromConnection: 0)

        XCTAssertEqual(
            delegate.terminalTransitions,
            [RecordedTerminalTransition(identity: identity, outcome: .completed)]
        )
        XCTAssertEqual(delegate.terminalEventCount, 1)
        XCTAssertEqual(delegate.finishCount, 1)
        XCTAssertTrue(delegate.donePayloads.isEmpty)
        XCTAssertEqual(delegate.removedSnapshotStreamIDs.count, 1)
        XCTAssertEqual(delegate.stopMonitoringClearPromptValues.count, 1)
        XCTAssertEqual(liveActivityManager.ends.map { $0.status }, [.complete])
        XCTAssertNil(coordinator.activeStreamID)
    }

    // `.cancelled` then `.error` commits `cancelled`: the late error is not a
    // candidate and neither surfaces a message nor finishes twice.
    @MainActor
    func testCancelledThenErrorKeepsCancelledOutcome() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        let identity = try XCTUnwrap(coordinator.runIdentity)

        streamClient.emit(.cancelled)
        streamClient.emit(.error("late failure"), fromConnection: 0)

        XCTAssertEqual(
            delegate.terminalTransitions,
            [RecordedTerminalTransition(identity: identity, outcome: .cancelled)]
        )
        XCTAssertEqual(delegate.terminalEventCount, 1)
        XCTAssertEqual(delegate.finishCount, 1)
        XCTAssertTrue(delegate.errorMessages.isEmpty)
        XCTAssertEqual(liveActivityManager.ends.map { $0.status }, [.cancelled])
        XCTAssertNil(coordinator.activeStreamID)
    }

    // `.error` then a late `.done` commits `failed`: the late done cannot
    // resurrect the failed row, append a transcript payload, or finish twice.
    @MainActor
    func testErrorThenLateDoneKeepsFailedOutcome() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        let identity = try XCTUnwrap(coordinator.runIdentity)

        streamClient.emit(.error("server failed"))
        streamClient.emit(.done(DoneStreamEvent()), fromConnection: 0)

        XCTAssertEqual(
            delegate.terminalTransitions,
            [RecordedTerminalTransition(identity: identity, outcome: .failed)]
        )
        XCTAssertEqual(delegate.terminalEventCount, 1)
        XCTAssertEqual(delegate.finishCount, 1)
        XCTAssertEqual(delegate.errorMessages, ["server failed"])
        XCTAssertTrue(delegate.donePayloads.isEmpty)
        XCTAssertEqual(liveActivityManager.ends.map { $0.status }, [.failed])
        XCTAssertNil(coordinator.activeStreamID)
    }

    // A replayed terminal event is a no-op after the first valid candidate:
    // one terminal record, one terminal event, one finish, one Live Activity
    // end, one snapshot removal, one stream stop, one cleanup pass.
    @MainActor
    func testDuplicateTerminalEventsDoNotFinishTwice() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        let identity = try XCTUnwrap(coordinator.runIdentity)

        streamClient.emit(.cancelled)
        streamClient.emit(.cancelled, fromConnection: 0)

        XCTAssertEqual(
            delegate.terminalTransitions,
            [RecordedTerminalTransition(identity: identity, outcome: .cancelled)]
        )
        XCTAssertEqual(delegate.terminalEventCount, 1)
        XCTAssertEqual(delegate.finishCount, 1)
        XCTAssertEqual(liveActivityManager.ends.map { $0.status }, [.cancelled])
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(delegate.removedSnapshotStreamIDs.count, 1)
        XCTAssertEqual(delegate.stopMonitoringClearPromptValues.count, 1)
        XCTAssertNil(coordinator.activeStreamID)
    }

    // Once a terminal outcome is committed, a later callback from the same
    // connection cannot resurrect active status: no token mutation, no active
    // stream, no restarted connection, no second finish.
    @MainActor
    func testTerminalOutcomeCannotResurrectActiveStatus() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        let identity = try XCTUnwrap(coordinator.runIdentity)

        streamClient.emit(.cancelled)
        streamClient.emit(.token("zombie token"), fromConnection: 0)

        XCTAssertEqual(
            delegate.terminalTransitions,
            [RecordedTerminalTransition(identity: identity, outcome: .cancelled)]
        )
        XCTAssertEqual(delegate.terminalEventCount, 1)
        XCTAssertTrue(delegate.tokens.isEmpty)
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertNil(coordinator.runIdentity)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(delegate.finishCount, 1)
    }

    // A transport error is NOT a terminal candidate: the run suspends with
    // the same logical generation and produces no terminal outcome, no
    // terminal event, no finish, no error message, and no Live Activity end.
    // The assertions run synchronously on the MainActor, before the deferred
    // reconnect task can execute.
    @MainActor
    func testTransportErrorDoesNotProduceTerminalOutcome() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        let identity = try XCTUnwrap(coordinator.runIdentity)

        streamClient.emit(.transportError("lost connection"))

        XCTAssertTrue(delegate.terminalTransitions.isEmpty)
        XCTAssertEqual(delegate.terminalEventCount, 0)
        XCTAssertEqual(delegate.finishCount, 0)
        XCTAssertTrue(delegate.errorMessages.isEmpty)
        XCTAssertTrue(liveActivityManager.ends.isEmpty)
        XCTAssertTrue(coordinator.isConnectionSuspended)
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(coordinator.runIdentity, identity)
        XCTAssertEqual(streamClient.stopCount, 1)
    }

    // MARK: - Slice 3 (#18): cancellation and async generation gates

    // A server-refused cancel response (explicit ok:false with a non-empty
    // error) never transitions the current run: `.rejected`, still active,
    // zero terminal/delegate/live-activity/cleanup mutation.
    @MainActor
    func testFailedCancelResponseLeavesRunActive() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/cancel")
            return apiTestJSONResponse(#"{"ok": false, "error": "busy"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")
        let connectionIdentity = try XCTUnwrap(coordinator.runConnectionIdentity)

        let disposition = await coordinator.cancelActiveStream()
        guard case .rejected = disposition else {
            XCTFail("expected rejected disposition, got \(disposition)")
            return
        }

        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(coordinator.runConnectionIdentity, connectionIdentity)
        assertNoCancellationMutation(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate,
            expectedStartedURLCount: 1
        )
    }

    // A thrown cancel request from the CURRENT identity is `.thrown` (kept
    // separate from a server rejection) and never transitions the run.
    @MainActor
    func testThrownCancelRequestLeavesRunActive() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/cancel")
            throw URLError(.timedOut)
        }

        coordinator.start(streamID: "stream-123")
        let connectionIdentity = try XCTUnwrap(coordinator.runConnectionIdentity)

        let disposition = await coordinator.cancelActiveStream()
        guard case .thrown = disposition else {
            XCTFail("expected thrown disposition, got \(disposition)")
            return
        }

        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(coordinator.runConnectionIdentity, connectionIdentity)
        assertNoCancellationMutation(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate,
            expectedStartedURLCount: 1
        )
    }

    // A delayed SUCCESSFUL cancel from a superseded run (same stream ID, new
    // logical generation) is `.stale`: the raw ok:true is never returned as a
    // current success, and nothing — terminal, Live Activity, cleanup,
    // replacement state — is touched. The replacement is asserted active
    // BEFORE the gate release.
    @MainActor
    func testDelayedSuccessfulCancelSameIDNewGenerationReturnsStaleDisposition() async throws {
        let gate = CancelResponseGate()
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeGatedCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/cancel")
            await gate.enter()
            if let error = gate.thrownError {
                throw error
            }
            return apiTestJSONResponse(gate.responseJSON, for: request)
        }

        coordinator.start(streamID: "stream-123")
        let oldIdentity = try XCTUnwrap(coordinator.runConnectionIdentity)
        let cancelTask = Task { @MainActor in
            await coordinator.cancelActiveStream()
        }
        await gate.waitForEntry()

        // Replacement run with the SAME stream ID: only the logical
        // generation changes.
        coordinator.start(streamID: "stream-123")
        let replacementIdentity = try XCTUnwrap(coordinator.runConnectionIdentity)
        XCTAssertEqual(replacementIdentity.streamID, oldIdentity.streamID)
        XCTAssertEqual(replacementIdentity.logicalGeneration, oldIdentity.logicalGeneration + 1)
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(coordinator.runConnectionIdentity, replacementIdentity)

        gate.responseJSON = #"{"ok": true, "stream_id": "stream-123"}"#
        gate.release()
        let disposition = await cancelTask.value
        guard case .stale = disposition else {
            XCTFail("expected stale disposition, got \(disposition)")
            return
        }

        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(coordinator.runConnectionIdentity, replacementIdentity)
        assertNoCancellationMutation(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate,
            expectedStartedURLCount: 2
        )
    }

    // Reconnect/replay keeps the logical identity and changes ONLY the
    // connection generation; a delayed successful cancel from the old
    // connection is still `.stale`.
    @MainActor
    func testDelayedSuccessfulCancelAfterConnectionGenerationReplacementReturnsStaleDisposition() async throws {
        let gate = CancelResponseGate()
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeGatedCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/cancel")
            await gate.enter()
            if let error = gate.thrownError {
                throw error
            }
            return apiTestJSONResponse(gate.responseJSON, for: request)
        }

        coordinator.start(streamID: "stream-123")
        let oldIdentity = try XCTUnwrap(coordinator.runConnectionIdentity)
        let cancelTask = Task { @MainActor in
            await coordinator.cancelActiveStream()
        }
        await gate.waitForEntry()

        // Reconnect/replay for the SAME logical run: the connection
        // generation changes while the logical generation stays.
        coordinator.start(streamID: "stream-123", replayAfterSeq: 4, recoveryState: .reconnecting)
        let replacementIdentity = try XCTUnwrap(coordinator.runConnectionIdentity)
        XCTAssertEqual(replacementIdentity.streamID, oldIdentity.streamID)
        XCTAssertEqual(replacementIdentity.logicalGeneration, oldIdentity.logicalGeneration)
        XCTAssertEqual(replacementIdentity.connectionGeneration, oldIdentity.connectionGeneration + 1)
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(coordinator.runConnectionIdentity, replacementIdentity)

        gate.responseJSON = #"{"ok": true, "stream_id": "stream-123"}"#
        gate.release()
        let disposition = await cancelTask.value
        guard case .stale = disposition else {
            XCTFail("expected stale disposition, got \(disposition)")
            return
        }

        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(coordinator.runConnectionIdentity, replacementIdentity)
        assertNoCancellationMutation(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate,
            expectedStartedURLCount: 2
        )
    }

    // A delayed REJECTED cancel (ok:false + error) from a superseded run is
    // still `.stale` — the rejection must not surface as a current error.
    @MainActor
    func testDelayedRejectedCancelAfterReplacementReturnsStaleDispositionWithoutError() async throws {
        let gate = CancelResponseGate()
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeGatedCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/cancel")
            await gate.enter()
            if let error = gate.thrownError {
                throw error
            }
            return apiTestJSONResponse(gate.responseJSON, for: request)
        }

        coordinator.start(streamID: "stream-123")
        let oldIdentity = try XCTUnwrap(coordinator.runConnectionIdentity)
        let cancelTask = Task { @MainActor in
            await coordinator.cancelActiveStream()
        }
        await gate.waitForEntry()

        coordinator.start(streamID: "stream-123")
        let replacementIdentity = try XCTUnwrap(coordinator.runConnectionIdentity)
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(coordinator.runConnectionIdentity, replacementIdentity)

        gate.responseJSON = #"{"ok": false, "error": "busy"}"#
        gate.release()
        let disposition = await cancelTask.value
        guard case .stale = disposition else {
            XCTFail("expected stale disposition, got \(disposition)")
            return
        }

        // The stale rejection surfaces no error at all.
        XCTAssertTrue(delegate.errorMessages.isEmpty)
        XCTAssertTrue(delegate.recoveryErrors.isEmpty)
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(coordinator.runConnectionIdentity, replacementIdentity)
        assertNoCancellationMutation(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate,
            expectedStartedURLCount: 2
        )
    }

    // A delayed THROWN cancel from a superseded run is `.stale` too: the
    // throw is swallowed, never published as a current error.
    @MainActor
    func testDelayedThrownCancelAfterReplacementReturnsStaleDispositionWithoutError() async throws {
        let gate = CancelResponseGate()
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeGatedCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/cancel")
            await gate.enter()
            if let error = gate.thrownError {
                throw error
            }
            return apiTestJSONResponse(gate.responseJSON, for: request)
        }

        coordinator.start(streamID: "stream-123")
        let oldIdentity = try XCTUnwrap(coordinator.runConnectionIdentity)
        let cancelTask = Task { @MainActor in
            await coordinator.cancelActiveStream()
        }
        await gate.waitForEntry()

        coordinator.start(streamID: "stream-123")
        let replacementIdentity = try XCTUnwrap(coordinator.runConnectionIdentity)
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(coordinator.runConnectionIdentity, replacementIdentity)

        gate.thrownError = URLError(.timedOut)
        gate.release()
        let disposition = await cancelTask.value
        guard case .stale = disposition else {
            XCTFail("expected stale disposition, got \(disposition)")
            return
        }

        XCTAssertTrue(delegate.errorMessages.isEmpty)
        XCTAssertTrue(delegate.recoveryErrors.isEmpty)
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(coordinator.runConnectionIdentity, replacementIdentity)
        assertNoCancellationMutation(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate,
            expectedStartedURLCount: 2
        )
    }

    // Two overlapping cancellations: A's request is gated, B replaces the run
    // and cancels the CURRENT identity (accepted). A's stale cleanup must not
    // clear B's committed terminal state or re-run any cleanup.
    @MainActor
    func testOverlappingCancellationAStaleCleanupDoesNotClearCurrentBState() async throws {
        let gate = CancelResponseGate()
        var cancelEntryCount = 0
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeGatedCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/cancel")
            cancelEntryCount += 1
            if cancelEntryCount == 1 {
                await gate.enter()
            }
            return apiTestJSONResponse(#"{"ok": true, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")
        let cancelTaskA = Task { @MainActor in
            await coordinator.cancelActiveStream()
        }
        await gate.waitForEntry()

        // Replacement run B with the SAME stream ID: A's cancel is now stale.
        coordinator.start(streamID: "stream-123")
        let connectionIdentityB = try XCTUnwrap(coordinator.runConnectionIdentity)
        let runIdentityB = try XCTUnwrap(coordinator.runIdentity)
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")

        // B's cancellation is CURRENT: accepted, transitions B exactly once.
        let dispositionB = await coordinator.cancelActiveStream()
        guard case .accepted = dispositionB else {
            XCTFail("expected accepted disposition for B, got \(dispositionB)")
            return
        }
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertEqual(
            delegate.terminalTransitions,
            [RecordedTerminalTransition(identity: runIdentityB, outcome: .cancelled)]
        )
        XCTAssertEqual(delegate.terminalEventCount, 1)
        XCTAssertEqual(liveActivityManager.ends.map(\.status), [.cancelled])
        XCTAssertEqual(delegate.finishCount, 1)

        // Release A's stale success: it must not clear B's committed state or
        // re-run any cleanup.
        gate.release()
        let dispositionA = await cancelTaskA.value
        guard case .stale = dispositionA else {
            XCTFail("expected stale disposition for A, got \(dispositionA)")
            return
        }
        XCTAssertEqual(delegate.terminalTransitions.count, 1)
        XCTAssertEqual(delegate.terminalEventCount, 1)
        XCTAssertEqual(delegate.finishCount, 1)
        XCTAssertEqual(liveActivityManager.ends.count, 1)
        XCTAssertEqual(delegate.removedSnapshotStreamIDs.count, 1)
        XCTAssertEqual(delegate.stopMonitoringClearPromptValues.count, 1)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertTrue(delegate.errorMessages.isEmpty)
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertNotEqual(coordinator.runConnectionIdentity, connectionIdentityB)
    }

    // Current-identity accepted cancel: `.accepted(ticket)`, one centralized
    // terminal transition, one terminal event, one valid ticket consume, and
    // no duplicate when the terminal callback is replayed.
    @MainActor
    func testSuccessfulCancelCurrentIdentityReturnsAcceptedDisposition() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/cancel")
            return apiTestJSONResponse(#"{"ok": true, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")
        let identity = try XCTUnwrap(coordinator.runIdentity)
        let connectionIdentity = try XCTUnwrap(coordinator.runConnectionIdentity)

        let disposition = await coordinator.cancelActiveStream()
        guard case .accepted(let ticket) = disposition else {
            XCTFail("expected accepted disposition, got \(disposition)")
            return
        }

        // The ticket is bound to the exact connection identity that accepted.
        XCTAssertEqual(ticket.identity, connectionIdentity)
        XCTAssertFalse(ticket.messageID.isEmpty)

        XCTAssertEqual(
            delegate.terminalTransitions,
            [RecordedTerminalTransition(identity: identity, outcome: .cancelled)]
        )
        XCTAssertEqual(delegate.terminalEventCount, 1)
        XCTAssertEqual(delegate.finishCount, 1)
        XCTAssertEqual(liveActivityManager.ends.map(\.status), [.cancelled])
        XCTAssertNil(coordinator.activeStreamID)

        // One valid ticket consume; a second consume is refused.
        XCTAssertTrue(ticket.consume())
        XCTAssertFalse(ticket.consume())
        XCTAssertTrue(ticket.isConsumed)

        // Replaying the completing connection's own terminal callback cannot
        // commit a second transition or finish twice.
        streamClient.emit(.cancelled, fromConnection: 0)
        XCTAssertEqual(delegate.terminalTransitions.count, 1)
        XCTAssertEqual(delegate.terminalEventCount, 1)
        XCTAssertEqual(delegate.finishCount, 1)
        XCTAssertEqual(liveActivityManager.ends.count, 1)
        XCTAssertEqual(streamClient.stopCount, 1)
    }

    // Envelope precedence matrix: stream identity mismatch ⇒ stale; trimmed
    // non-empty error ⇒ rejected; explicit ok:false ⇒ rejected; ok:true ⇒
    // accepted; nil/nil ⇒ unconfirmed. Contradictory booleans resolve by the
    // same precedence.
    @MainActor
    func testChatCancelResponseEnvelopeMatrixUsesStreamIdentityErrorAndBooleanPrecedence() async throws {
        let envelopes: [(json: String, expected: ExpectedCancelDisposition)] = [
            (#"{"ok": true}"#, .accepted),
            (#"{"ok": true, "stream_id": "stream-123"}"#, .accepted),
            (#"{"ok": false}"#, .rejected),
            (#"{"ok": false, "error": "busy"}"#, .rejected),
            (#"{"ok": true, "error": "boom"}"#, .rejected),
            (#"{"ok": true, "error": "  "}"#, .accepted),
            (#"{}"#, .unconfirmed),
            (#"{"error": ""}"#, .unconfirmed),
            (#"{"ok": true, "stream_id": "stream-other"}"#, .stale),
            (#"{"ok": false, "stream_id": "stream-other", "error": "busy"}"#, .stale),
        ]

        for envelope in envelopes {
            let streamClient = CoordinatorSpySSEStreamingClient()
            let liveActivityManager = CoordinatorSpyLiveActivityManager()
            let delegate = CoordinatorDelegateSpy()
            let coordinator = makeCoordinator(
                streamClient: streamClient,
                liveActivityManager: liveActivityManager,
                delegate: delegate
            ) { request in
                XCTAssertEqual(request.url?.path, "/api/chat/cancel")
                return apiTestJSONResponse(envelope.json, for: request)
            }

            coordinator.start(streamID: "stream-123")
            let disposition = await coordinator.cancelActiveStream()
            assertDisposition(disposition, matches: envelope.expected)

            switch envelope.expected {
            case .accepted:
                XCTAssertNil(coordinator.activeStreamID)
                XCTAssertEqual(delegate.terminalTransitions.map(\.outcome), [.cancelled])
                XCTAssertEqual(delegate.terminalEventCount, 1)
                XCTAssertEqual(liveActivityManager.ends.map(\.status), [.cancelled])
            case .stale, .rejected, .unconfirmed:
                XCTAssertEqual(coordinator.activeStreamID, "stream-123")
                XCTAssertTrue(delegate.terminalTransitions.isEmpty)
                XCTAssertEqual(delegate.terminalEventCount, 0)
                XCTAssertTrue(liveActivityManager.ends.isEmpty)
                XCTAssertEqual(delegate.finishCount, 0)
            }
        }
    }

    // The surfaced rejection error is trimmed; whitespace-only or nil/nil
    // envelopes stay `.unconfirmed` and never transition the run.
    @MainActor
    func testChatCancelResponseTrimsNonEmptyErrorAndPreservesNilNilUnconfirmed() async throws {
        var envelopeIndex = 0
        let envelopes = [
            #"{"ok": false, "error": "  busy  "}"#,
            #"{"error": "   "}"#,
            #"{}"#,
        ]
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/cancel")
            let json = envelopes[envelopeIndex]
            envelopeIndex += 1
            return apiTestJSONResponse(json, for: request)
        }

        coordinator.start(streamID: "stream-123")
        let identity = try XCTUnwrap(coordinator.runIdentity)

        let rejected = await coordinator.cancelActiveStream()
        guard case .rejected(let response) = rejected else {
            XCTFail("expected rejected disposition, got \(rejected)")
            return
        }
        XCTAssertEqual(response.error, "busy")

        let whitespaceOnly = await coordinator.cancelActiveStream()
        assertDisposition(whitespaceOnly, matches: .unconfirmed)

        let nilNil = await coordinator.cancelActiveStream()
        assertDisposition(nilNil, matches: .unconfirmed)

        // Nil/nil unconfirmed never transitions: the run stays active.
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(coordinator.runIdentity, identity)
        XCTAssertTrue(delegate.terminalTransitions.isEmpty)
        XCTAssertEqual(delegate.terminalEventCount, 0)
        XCTAssertTrue(liveActivityManager.ends.isEmpty)
        XCTAssertEqual(delegate.finishCount, 0)
        XCTAssertEqual(streamClient.stopCount, 0)
    }

    // Accepted current-identity cancel transitions once; the completing
    // connection's replayed `.cancelled` and a late `.error` both dedupe.
    @MainActor
    func testAcceptedCancelTransitionsOnceAndDedupesCancelledEvent() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/cancel")
            return apiTestJSONResponse(#"{"ok": true, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")
        let identity = try XCTUnwrap(coordinator.runIdentity)

        let disposition = await coordinator.cancelActiveStream()
        guard case .accepted = disposition else {
            XCTFail("expected accepted disposition, got \(disposition)")
            return
        }

        XCTAssertEqual(
            delegate.terminalTransitions,
            [RecordedTerminalTransition(identity: identity, outcome: .cancelled)]
        )
        XCTAssertEqual(delegate.terminalEventCount, 1)
        XCTAssertEqual(delegate.finishCount, 1)
        XCTAssertEqual(liveActivityManager.ends.map(\.status), [.cancelled])
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(delegate.removedSnapshotStreamIDs.count, 1)
        XCTAssertEqual(delegate.stopMonitoringClearPromptValues.count, 1)

        // The completing connection's own terminal callbacks replay after
        // finalization: `.cancelled` then a late `.error` must both dedupe.
        streamClient.emit(.cancelled, fromConnection: 0)
        streamClient.emit(.error("late failure"), fromConnection: 0)

        XCTAssertEqual(delegate.terminalTransitions.count, 1)
        XCTAssertEqual(delegate.terminalEventCount, 1)
        XCTAssertEqual(delegate.finishCount, 1)
        XCTAssertEqual(liveActivityManager.ends.count, 1)
        XCTAssertTrue(delegate.errorMessages.isEmpty)
        XCTAssertNil(coordinator.activeStreamID)
    }

    // The post-recovery-load gate bails when the run was replaced during the
    // transcript load: the replay replacement (connection-generation change)
    // is neither finalized nor clobbered by the stale recovery path.
    @MainActor
    func testRecoveryLoadGateBailsAfterGenerationReplacement() async throws {
        let gate = CancelResponseGate()
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = true
        let coordinator = makeGatedCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate,
            timing: ChatStreamCoordinatorTiming(
                checkingInterval: 5,
                reconnectInterval: 18,
                runningToolReconnectInterval: 25,
                statusPollCooldown: 4,
                transportFreshInterval: 12
            )
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            await gate.enter()
            if let error = gate.thrownError {
                throw error
            }
            return apiTestJSONResponse(gate.responseJSON, for: request)
        }

        coordinator.start(streamID: "stream-123")
        let oldIdentity = try XCTUnwrap(coordinator.runConnectionIdentity)
        // A replay replacement happens DURING the transcript load, so the
        // connection generation changes while the logical run stays the same.
        delegate.onLoadMessages = {
            coordinator.start(streamID: "stream-123", replayAfterSeq: 4, recoveryState: .reconnecting)
        }
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        coordinator.markProgress(now: start)

        let recoveryTask = Task { @MainActor in
            await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(12.1))
        }
        await gate.waitForEntry()
        gate.responseJSON = #"{"active": false, "stream_id": "stream-123"}"#
        gate.release()
        await recoveryTask.value

        // The post-load gate bailed: the replacement stays active and nothing
        // was finalized or ended.
        let replacementIdentity = try XCTUnwrap(coordinator.runConnectionIdentity)
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(coordinator.runConnectionIdentity, replacementIdentity)
        XCTAssertNotEqual(replacementIdentity, oldIdentity)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertTrue(liveActivityManager.ends.isEmpty)
        XCTAssertTrue(delegate.terminalTransitions.isEmpty)
        XCTAssertEqual(delegate.terminalEventCount, 0)
        XCTAssertEqual(delegate.finishCount, 0)
        XCTAssertTrue(delegate.completedNeedsTranscriptRefreshValues.isEmpty)
    }

    // A delayed status response for a superseded run cannot restart the
    // replacement: no third connection, no stop, no terminal mutation.
    @MainActor
    func testDelayedStatusResponseCannotRestartReplacementRun() async throws {
        let gate = CancelResponseGate()
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeGatedCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate,
            timing: ChatStreamCoordinatorTiming(
                checkingInterval: 5,
                reconnectInterval: 18,
                runningToolReconnectInterval: 25,
                statusPollCooldown: 4,
                transportFreshInterval: 12
            )
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            await gate.enter()
            if let error = gate.thrownError {
                throw error
            }
            return apiTestJSONResponse(gate.responseJSON, for: request)
        }

        coordinator.start(streamID: "stream-123")
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        coordinator.markProgress(now: start)

        let recoveryTask = Task { @MainActor in
            await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(12.1))
        }
        await gate.waitForEntry()

        // Replacement run (same stream ID, new logical generation) while the
        // status poll is suspended.
        coordinator.start(streamID: "stream-123")
        let replacementIdentity = try XCTUnwrap(coordinator.runConnectionIdentity)
        XCTAssertEqual(streamClient.startedURLs.count, 2)

        gate.responseJSON = #"{"active": true, "stream_id": "stream-123", "replay_available": true}"#
        gate.release()
        await recoveryTask.value

        // The delayed response must not restart or reconnect the replacement.
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertEqual(streamClient.stopCount, 0)
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(coordinator.runConnectionIdentity, replacementIdentity)
        XCTAssertNotEqual(coordinator.recoveryState, .reconnecting)
        XCTAssertTrue(liveActivityManager.ends.isEmpty)
        XCTAssertTrue(delegate.terminalTransitions.isEmpty)
        XCTAssertEqual(delegate.terminalEventCount, 0)
        XCTAssertEqual(delegate.finishCount, 0)
    }

    private func assertDisposition(
        _ disposition: ChatCancelDisposition,
        matches expected: ExpectedCancelDisposition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matches: Bool
        switch (disposition, expected) {
        case (.accepted, .accepted), (.stale, .stale), (.rejected, .rejected), (.unconfirmed, .unconfirmed):
            matches = true
        default:
            matches = false
        }
        XCTAssertTrue(matches, "expected \(expected) disposition, got \(disposition)", file: file, line: line)
    }

    @MainActor
    private func assertNoCancellationMutation(
        streamClient: CoordinatorSpySSEStreamingClient,
        liveActivityManager: CoordinatorSpyLiveActivityManager,
        delegate: CoordinatorDelegateSpy,
        expectedStartedURLCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(streamClient.startedURLs.count, expectedStartedURLCount, file: file, line: line)
        XCTAssertEqual(streamClient.stopCount, 0, file: file, line: line)
        XCTAssertTrue(delegate.terminalTransitions.isEmpty, file: file, line: line)
        XCTAssertEqual(delegate.terminalEventCount, 0, file: file, line: line)
        XCTAssertEqual(delegate.finishCount, 0, file: file, line: line)
        XCTAssertTrue(liveActivityManager.ends.isEmpty, file: file, line: line)
        XCTAssertTrue(delegate.errorMessages.isEmpty, file: file, line: line)
        XCTAssertTrue(delegate.recoveryErrors.isEmpty, file: file, line: line)
        XCTAssertTrue(delegate.removedSnapshotStreamIDs.isEmpty, file: file, line: line)
        XCTAssertTrue(delegate.stopMonitoringClearPromptValues.isEmpty, file: file, line: line)
    }

    override func tearDown() {
        GatedURLProtocol.asyncHandler = nil
        super.tearDown()
    }

    @MainActor
    private func makeGatedCoordinator(
        streamClient: CoordinatorSpySSEStreamingClient? = nil,
        liveActivityManager: CoordinatorSpyLiveActivityManager? = nil,
        delegate: CoordinatorDelegateSpy? = nil,
        timing: ChatStreamCoordinatorTiming = .standard,
        handler: @escaping @MainActor (URLRequest) async throws -> (HTTPURLResponse, Data)
    ) -> ChatStreamCoordinator {
        GatedURLProtocol.asyncHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(baseURL: URL(string: "https://example.test")!, session: session)

        let streamClient = streamClient ?? CoordinatorSpySSEStreamingClient()
        let liveActivityManager = liveActivityManager ?? CoordinatorSpyLiveActivityManager()
        let delegate = delegate ?? CoordinatorDelegateSpy()
        let coordinator = ChatStreamCoordinator(
            client: client,
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            showsLiveActivityResponseExcerpts: false,
            timing: timing
        )
        coordinator.attach(delegate: delegate)
        return coordinator
    }

    @MainActor
    private func makeCoordinator(
        streamClient: CoordinatorSpySSEStreamingClient? = nil,
        liveActivityManager: CoordinatorSpyLiveActivityManager? = nil,
        delegate: CoordinatorDelegateSpy? = nil,
        timing: ChatStreamCoordinatorTiming = .standard,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            apiTestJSONResponse(#"{"active": true}"#, for: request)
        }
    ) -> ChatStreamCoordinator {
        let streamClient = streamClient ?? CoordinatorSpySSEStreamingClient()
        let liveActivityManager = liveActivityManager ?? CoordinatorSpyLiveActivityManager()
        let delegate = delegate ?? CoordinatorDelegateSpy()
        let coordinator = ChatStreamCoordinator(
            client: makeClient(handler: handler),
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            showsLiveActivityResponseExcerpts: false,
            timing: timing
        )
        coordinator.attach(delegate: delegate)
        return coordinator
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

/// One committed terminal transition recorded by the centralized terminal
/// path (#18 Slice 2): the finalized run's identity and the first-valid
/// outcome. `ChatRunTerminalOutcome` is the intended centralized terminal
/// outcome type; GREEN adds it beside the run identity types and routes every
/// terminal candidate through `transitionToTerminal`.
private struct RecordedTerminalTransition: Equatable {
    let identity: ChatRunIdentity
    let outcome: ChatRunTerminalOutcome
}

private final class CoordinatorDelegateSpy: ChatStreamCoordinatorDelegate {
    var streamCoordinatorSessionID: String? = "session-abc"
    var streamCoordinatorDisplayTitle = "Planning"
    var streamCoordinatorHasRunningLiveToolCall = false
    var streamCoordinatorHasPendingPrompt = false
    var latestServerLoadHadAssistantResponseAfterLatestUser = false
    var streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser: Bool {
        latestServerLoadHadAssistantResponseAfterLatestUser
    }
    var streamCoordinatorStreamingAssistantMessageID: String?

    private(set) var loadMessagesCount = 0
    private(set) var startMonitoringCount = 0
    private(set) var stopMonitoringClearPromptValues: [Bool] = []
    private(set) var saveSnapshotCount = 0
    private(set) var restoredSnapshotStreamIDs: [String] = []
    private(set) var removedSnapshotStreamIDs: [String?] = []
    private(set) var flushedNoticeCount = 0
    private(set) var drainQueueCount = 0
    private(set) var refreshTitleCount = 0
    private(set) var completedNeedsTranscriptRefreshValues: [Bool] = []
    private(set) var finishCount = 0
    private(set) var errorMessages: [String] = []
    private(set) var recoveryErrors: [String] = []
    private(set) var startConnectionReplayValues: [Bool] = []
    private(set) var resetRecoveryCount = 0
    private(set) var tokens: [String] = []
    private(set) var donePayloads: [DoneStreamEvent] = []
    private(set) var pendingSteerLeftovers: [String] = []
    var latestAssistantMessageID: String? = "assistant-latest"
    var restoredSnapshotEventID: String?
    var appendTokenResult = true
    var doneHasCompletedTranscript = false
    // MARK: Slice 2 (#18): centralized terminal transition recording
    private(set) var terminalTransitions: [RecordedTerminalTransition] = []
    private(set) var terminalEventCount = 0
    var onLoadMessages: (() async -> Void)?

    func streamCoordinatorLoadMessages(modelContext: ModelContext?) async {
        loadMessagesCount += 1
        await onLoadMessages?()
    }

    func streamCoordinatorLatestAssistantMessageID() -> String? {
        latestAssistantMessageID
    }

    func streamCoordinatorStartAuxiliaryMonitoring() {
        startMonitoringCount += 1
    }

    func streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: Bool) {
        stopMonitoringClearPromptValues.append(clearPrompt)
    }

    func streamCoordinatorSaveSnapshotIfNeeded() {
        saveSnapshotCount += 1
    }

    func streamCoordinatorRestoreSnapshotIfAvailable(streamID: String) -> String? {
        restoredSnapshotStreamIDs.append(streamID)
        return restoredSnapshotEventID
    }

    func streamCoordinatorRemoveSnapshot(streamID: String?) {
        removedSnapshotStreamIDs.append(streamID)
    }

    func streamCoordinatorFlushPinnedLocalNoticesToTranscript() {
        flushedNoticeCount += 1
    }

    func streamCoordinatorDrainQueuedSlashMessageIfIdle() {
        drainQueueCount += 1
    }

    func streamCoordinatorRefreshCompletedResponseTitleIfNeeded() {
        refreshTitleCount += 1
    }

    func streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: Bool) {
        completedNeedsTranscriptRefreshValues.append(needsTranscriptRefresh)
    }

    func streamCoordinatorDidFinishStream() {
        finishCount += 1
    }

    func streamCoordinatorDidReceiveErrorMessage(_ message: String) {
        errorMessages.append(message)
    }

    func streamCoordinatorDidReceiveRecoveryError(_ error: Error) {
        recoveryErrors.append(error.localizedDescription)
    }

    func streamCoordinatorDidStartConnection(isReplay: Bool) {
        startConnectionReplayValues.append(isReplay)
    }

    func streamCoordinatorDidResetRecoveryState() {
        resetRecoveryCount += 1
    }

    func streamCoordinatorAppendToken(_ text: String) -> Bool {
        tokens.append(text)
        return appendTokenResult
    }

    func streamCoordinatorAppendInterimAssistant(_ payload: InterimAssistantStreamEvent) -> Bool {
        payload.text?.isEmpty == false
    }

    func streamCoordinatorAppendReasoning(_ text: String) -> Bool {
        !text.isEmpty
    }

    func streamCoordinatorAppendToolCall(_ payload: ToolStreamEvent) -> Bool {
        true
    }

    func streamCoordinatorCompleteToolCall(_ payload: ToolStreamEvent) -> Bool {
        true
    }

    func streamCoordinatorUpdateTitle(_ payload: TitleStreamEvent) -> Bool {
        payload.title?.isEmpty == false
    }

    func streamCoordinatorApplyDone(_ payload: DoneStreamEvent) -> Bool {
        donePayloads.append(payload)
        return doneHasCompletedTranscript
    }

    /// Centralized terminal-event delegate callback (#18 Slice 2): invoked
    /// exactly once per committed terminal transition with the winning
    /// outcome and the finalized run's identity. GREEN adds this requirement
    /// to `ChatStreamCoordinatorDelegate` and invokes it from the idempotent
    /// centralized terminal transition.
    func streamCoordinatorDidCommitTerminalOutcome(
        _ outcome: ChatRunTerminalOutcome,
        identity: ChatRunIdentity
    ) {
        terminalTransitions.append(RecordedTerminalTransition(identity: identity, outcome: outcome))
        terminalEventCount += 1
    }

    func streamCoordinatorApplyApprovalUpdate(_ update: ApprovalPendingResponse) {}

    func streamCoordinatorApplyClarificationUpdate(_ update: ClarificationPendingResponse) {}

    func streamCoordinatorEnqueuePendingSteerLeftover(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        pendingSteerLeftovers.append(trimmed)
        return true
    }
}

private final class CoordinatorSpySSEStreamingClient: SSEStreamingClient {
    private(set) var startedURLs: [URL] = []
    private(set) var stopCount = 0
    private(set) var lastEventID: String?
    // Slice 1 (#18): every connection retains its own callback, keyed by
    // connection index (0 = first `start`). The fencing tests deliver events
    // through an OLD connection's retained callback to prove the coordinator
    // fences it before mutating the replacement run.
    private var callbacksByConnectionIndex: [Int: @MainActor (SSEEvent) -> Void] = [:]

    /// Index of the most recently started connection, or -1 before any start.
    private(set) var latestConnectionIndex = -1

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
        startedURLs.append(url)
        lastEventID = nil
        latestConnectionIndex += 1
        callbacksByConnectionIndex[latestConnectionIndex] = onEvent
    }

    func stop() {
        stopCount += 1
    }

    /// Compatibility accessor: delivers to the CURRENT (most recent) connection's
    /// retained callback — the behavior all pre-Slice-1 tests rely on.
    func emit(_ event: SSEEvent, lastEventID: String? = nil) {
        self.lastEventID = lastEventID
        callbacksByConnectionIndex[latestConnectionIndex]?(event)
    }

    /// Delivers through the callback retained for a specific connection index
    /// (0 = first connection). Used by the Slice 1 fencing tests to simulate a
    /// late event arriving from an old connection.
    func emit(_ event: SSEEvent, fromConnection connectionIndex: Int, lastEventID: String? = nil) {
        self.lastEventID = lastEventID
        callbacksByConnectionIndex[connectionIndex]?(event)
    }
}

@MainActor
private final class CoordinatorSpyLiveActivityManager: AgentLiveActivityManaging {
    struct Start: Equatable {
        let sessionID: String
        let sessionTitle: String
        let streamID: String?
    }

    struct End: Equatable {
        let status: AgentRunActivityStatus
        let activity: String
        let errorSummary: String?
    }

    private(set) var starts: [Start] = []
    private(set) var updates: [AgentLiveActivityEvent] = []
    private(set) var markStaleCount = 0
    private(set) var ends: [End] = []

    func start(sessionID: String, sessionTitle: String, streamID: String?) {
        starts.append(Start(sessionID: sessionID, sessionTitle: sessionTitle, streamID: streamID))
    }

    func update(_ event: AgentLiveActivityEvent) {
        updates.append(event)
    }

    func markStale() {
        markStaleCount += 1
    }

    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {
        ends.append(End(status: status, activity: activity, errorSummary: errorSummary))
    }
}

private enum ExpectedCancelDisposition {
    case accepted
    case stale
    case rejected
    case unconfirmed
}

// MARK: - Slice 3 (#18): continuation-gated HTTP mock

/// Checked-continuation gate for one HTTP request (#18 Slice 3). The mock
/// handler awaits `enter()` after recording entry; the test observes entry
/// with `waitForEntry()` and resumes the request with `release()`. The
/// released outcome (ok response, rejection, or thrown error) is configured
/// on the gate BEFORE `release()`, so every delayed-result variant is
/// deterministic. No sleeps, polling, or semaphores establish ordering.
@MainActor
final class CancelResponseGate {
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var enteredCount = 0

    /// JSON body returned after release (default: an accepted cancel).
    var responseJSON = #"{"ok": true}"#

    /// When set, the handler throws this error after release instead of
    /// returning `responseJSON`.
    var thrownError: Error?

    func enter() async {
        enteredCount += 1
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitForEntry() async {
        guard enteredCount == 0 else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

/// URLProtocol test double whose handler is async and continuation-gated:
/// `startLoading` runs the handler on the main actor so it can `await` a
/// `CancelResponseGate`; the response is produced only after the test calls
/// `gate.release()`. Deterministic replacement for the old semaphore-blocked
/// sync handler (#18 Slice 3).
final class GatedURLProtocol: URLProtocol {
    static var asyncHandler: (@MainActor (URLRequest) async throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let asyncHandler = Self.asyncHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let client = self.client
        let request = self.request
        Task { @MainActor in
            do {
                let (response, data) = try await asyncHandler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}
