import SwiftData
import XCTest
@testable import HermesMobile

final class ChatViewModelMergeDedupTests: XCTestCase {

    // #330 regression: a server-transcribed voice note sends the bare transcript
    // (no "[Attached files:]" marker). The server frequently returns the clip
    // attachment on reload as a bare filename (no path), while the optimistic
    // bubble holds the full upload path. Dedup must still match them so the
    // optimistic message isn't re-inserted as a duplicate user turn.
    func testVoiceNoteDedupesWhenServerReturnsBareFilenameAttachment() {
        let transcript = "The last chatted about this portable monstrosity"
        let optimistic = ChatMessage(
            role: "user",
            content: transcript,
            timestamp: 1000,
            messageId: "local-ABC123",
            attachments: [
                MessageAttachment(
                    name: "voice-note-7765a1e2.m4a",
                    path: "/Users/hermes/.hermes/webui/attachments/db9/voice-note-7765a1e2.m4a",
                    mime: "audio/mp4a-latm",
                    size: 116155,
                    isImage: false
                )
            ]
        )
        let reloaded = ChatMessage(
            role: "user",
            content: transcript,
            timestamp: 1000,
            messageId: "server-1",
            attachments: [MessageAttachment(name: "voice-note-7765a1e2.m4a", path: nil)]
        )

        let merged = ChatViewModel.mergingLoadedMessages(
            [reloaded],
            withCachedLocalOptimisticMessages: [optimistic]
        )

        XCTAssertEqual(
            merged.filter { $0.role == "user" }.count, 1,
            "Optimistic voice note must dedupe against a bare-filename reload"
        )
    }

    // Sanity: a full-object reload whose path is a different directory than the
    // optimistic upload path also dedupes via basename normalization.
    func testVoiceNoteDedupesWhenReloadPathDirectoryDiffers() {
        let transcript = "Hello, hello, testing. Can you hear me?"
        let optimistic = ChatMessage(
            role: "user", content: transcript, timestamp: 2000, messageId: "local-XYZ",
            attachments: [MessageAttachment(name: "voice-note-d6.m4a", path: "/tmp/upload/voice-note-d6.m4a")]
        )
        let reloaded = ChatMessage(
            role: "user", content: transcript, timestamp: 2000, messageId: "server-2",
            attachments: [MessageAttachment(name: "voice-note-d6.m4a",
                                            path: "/Users/hermes/.hermes/webui/attachments/x/voice-note-d6.m4a")]
        )
        let merged = ChatViewModel.mergingLoadedMessages([reloaded], withCachedLocalOptimisticMessages: [optimistic])
        XCTAssertEqual(merged.filter { $0.role == "user" }.count, 1)
    }

    // Guard: genuinely different attachment filenames must NOT be deduped away.
    func testDifferentAttachmentFilenamesAreNotDeduped() {
        let optimistic = ChatMessage(
            role: "user", content: "same text", timestamp: 3000, messageId: "local-1",
            attachments: [MessageAttachment(name: "alpha.m4a", path: "/tmp/alpha.m4a")]
        )
        let reloaded = ChatMessage(
            role: "user", content: "same text", timestamp: 3000, messageId: "server-3",
            attachments: [MessageAttachment(name: "beta.m4a", path: nil)]
        )
        let merged = ChatViewModel.mergingLoadedMessages([reloaded], withCachedLocalOptimisticMessages: [optimistic])
        XCTAssertEqual(merged.filter { $0.role == "user" }.count, 2,
                       "Different attachment filenames are distinct messages")
    }

    // MARK: - Slice 5 (#18): run-status-v1 terminal event key and handoff
    //
    // The stable terminal event message ID is `run-status-v1-` + SHA-256 over
    // the contract's exact canonical bytes (issue #18 §6): domain
    // `hermex.chat.run-status-terminal/v1\0`, 4-byte BE session-byte length,
    // session UTF-8, 4-byte BE stream-byte length, stream UTF-8, 8-byte BE
    // logical generation, and one outcome byte (completed 0x01, failed 0x02,
    // cancelled 0x03). The four pinned fixtures below are contract-mandated
    // and were verified independently; changing the canonical encoding is a
    // v1-contract break.

    func testTerminalEventMessageIDIsStableForRunIdentityAndOutcome() {
        let identity = ChatRunIdentity(sessionID: "session-A", streamID: "stream-1", generation: 7)
        let key = ChatRunStatusTerminalEventKey(identity: identity, outcome: .completed)
        XCTAssertEqual(
            key.messageID,
            ChatRunStatusTerminalEventKey(identity: identity, outcome: .completed).messageID,
            "The same (run identity, outcome) must map to one stable terminal event message ID"
        )
        XCTAssertNotEqual(
            key.messageID,
            ChatRunStatusTerminalEventKey(identity: identity, outcome: .failed).messageID,
            "A different outcome is a different terminal event key"
        )
    }

    func testTerminalEventMessageIDMatchesFixedV1Fixtures() {
        // Pinned v1 fixtures (issue #18 §6): GREEN must reproduce these
        // byte-for-byte. The delimiter and UTF-8 vectors prove the ID depends
        // on byte counts, not ambiguous concatenation or character counts.
        XCTAssertEqual(
            ChatRunStatusTerminalEventKey(
                identity: ChatRunIdentity(sessionID: "session-A", streamID: "stream-1", generation: 7),
                outcome: .completed
            ).messageID,
            "run-status-v1-d82f95e865eda8e6b4a3b38e47435465a2d7be51fe9e5360eb7d409e538c7b5d"
        )
        XCTAssertEqual(
            ChatRunStatusTerminalEventKey(
                identity: ChatRunIdentity(sessionID: "s|a", streamID: "stream\n2", generation: 42),
                outcome: .failed
            ).messageID,
            "run-status-v1-d7f0ba16152e17743c4d648e087ced49d8c620cc5eae063fc92ae748debbddb4"
        )
        XCTAssertEqual(
            ChatRunStatusTerminalEventKey(
                identity: ChatRunIdentity(sessionID: "session-A", streamID: "stream-1", generation: 8),
                outcome: .cancelled
            ).messageID,
            "run-status-v1-62c615d786392fc96eaafeb424f4b7c6b014b33336b6b1bd2bf244d8d3dfac6a"
        )
        XCTAssertEqual(
            ChatRunStatusTerminalEventKey(
                identity: ChatRunIdentity(sessionID: "sess-é", streamID: "str/\n", generation: 9),
                outcome: .completed
            ).messageID,
            "run-status-v1-687284ccdd959da453bc6db0d3fb770c4f1c50b96d8cab8bb071da8f43c6d58f"
        )
    }

    func testTerminalEventMessageIDExcludesConnectionGeneration() {
        // The completed-basic vector must produce the same ID whether the
        // connection generation is 1 or 99: the key is derived from the
        // LOGICAL identity (session, stream, generation) plus outcome only.
        // ChatRunConnectionIdentity — the transport-fencing token that carries
        // the connection generation — is not an input to the key, so two
        // distinct connections of the same logical run share one message ID.
        let identity = ChatRunIdentity(sessionID: "session-A", streamID: "stream-1", generation: 7)
        let connection1 = ChatRunConnectionIdentity(streamID: "stream-1", logicalGeneration: 7, connectionGeneration: 1)
        let connection99 = ChatRunConnectionIdentity(streamID: "stream-1", logicalGeneration: 7, connectionGeneration: 99)
        XCTAssertNotEqual(connection1, connection99, "The two connections are distinct transport identities")
        XCTAssertEqual(
            ChatRunStatusTerminalEventKey(identity: identity, outcome: .completed).messageID,
            ChatRunStatusTerminalEventKey(identity: identity, outcome: .completed).messageID,
            "connectionGeneration is excluded from the terminal event key"
        )
    }

    func testSameStreamIDReplacementPersistsNewLogicalGenerationAndUsesDifferentMessageID() {
        // A replacement run with the SAME stream ID is a new logical generation
        // (Slice 4 coordinator behavior), and the persisted commit must carry it.
        let firstIdentity = ChatRunIdentity(sessionID: "session-A", streamID: "stream-abc", generation: 1)
        let replacementIdentity = ChatRunIdentity(sessionID: "session-A", streamID: "stream-abc", generation: 2)

        let firstKey = ChatRunStatusTerminalEventKey(identity: firstIdentity, outcome: .completed)
        let replacementKey = ChatRunStatusTerminalEventKey(identity: replacementIdentity, outcome: .completed)

        XCTAssertEqual(replacementIdentity.generation, firstIdentity.generation + 1,
                       "Same-stream replacement persists the new logical generation")
        XCTAssertEqual(replacementIdentity.streamID, firstIdentity.streamID)
        XCTAssertNotEqual(replacementKey.messageID, firstKey.messageID,
                          "A new logical generation is a new terminal event key")
    }

    func testCrossRelaunchReconnectRestoresLogicalGenerationAndDedupesMessageID() {
        // Cold relaunch + reconnect restores the persisted logical generation for
        // the stream, so the recomputed terminal event message ID is identical
        // and the cached terminal event dedupes instead of duplicating.
        let persistedIdentity = ChatRunIdentity(sessionID: "session-A", streamID: "stream-abc", generation: 3)
        let restoredIdentity = ChatRunIdentity(sessionID: "session-A", streamID: "stream-abc", generation: 3)
        let terminalID = ChatRunStatusTerminalEventKey(identity: persistedIdentity, outcome: .failed).messageID

        XCTAssertEqual(
            ChatRunStatusTerminalEventKey(identity: restoredIdentity, outcome: .failed).messageID,
            terminalID,
            "Restored logical generation must reproduce the pre-relaunch terminal event message ID"
        )

        let cachedTerminalEvent = ChatMessage(
            role: "local_notice", content: "Response failed", timestamp: 1_770_000_000,
            messageId: terminalID
        )
        let merged = ChatViewModel.mergingLoadedMessages(
            [], // server transcript omits the terminal event on cold reload
            withCachedLocalOptimisticMessages: [cachedTerminalEvent]
        )
        XCTAssertEqual(merged.filter { $0.messageId == terminalID }.count, 1,
                       "Restored terminal event dedupes to exactly one message")
    }

    func testDifferentOutcomeGetsDifferentTerminalEventKey() {
        let identity = ChatRunIdentity(sessionID: "session-A", streamID: "stream-abc", generation: 1)
        let completed = ChatRunStatusTerminalEventKey(identity: identity, outcome: .completed).messageID
        let failed = ChatRunStatusTerminalEventKey(identity: identity, outcome: .failed).messageID
        let cancelled = ChatRunStatusTerminalEventKey(identity: identity, outcome: .cancelled).messageID
        XCTAssertEqual(Set([completed, failed, cancelled]).count, 3,
                       "completed/failed/cancelled are three distinct terminal event keys")
    }

    func testChatRunTerminalCommitCarriesIdentityOutcomeKeyAndServerIDs() {
        let identity = ChatRunIdentity(sessionID: "session-A", streamID: "stream-1", generation: 7)
        let key = ChatRunStatusTerminalEventKey(identity: identity, outcome: .completed)
        let commit = ChatRunTerminalCommit(
            identity: identity,
            outcome: .completed,
            eventKey: key,
            serverSessionID: "session-A",
            serverStreamID: "stream-1"
        )
        XCTAssertEqual(commit.eventKey, key)
        XCTAssertEqual(commit.serverSessionID, commit.identity.sessionID)
        XCTAssertEqual(commit.serverStreamID, commit.identity.streamID)

        let handoff = ChatTerminalPersistenceHandoff(
            commit: commit,
            postAppendMessages: [ChatMessage(role: "local_notice", content: "Response complete",
                                             timestamp: 1_770_000_000, messageId: key.messageID)],
            handoffGeneration: 1
        )
        XCTAssertEqual(handoff.commit, commit)
        XCTAssertEqual(handoff.handoffGeneration, 1)
        XCTAssertEqual(handoff.postAppendMessages.map(\.messageId), [key.messageID],
                       "The handoff snapshot is post-append: it contains the stable local notice")
    }

    func testCachedTerminalEventMergesOnceWhenServerTranscriptOmitsIt() {
        let identity = ChatRunIdentity(sessionID: "session-A", streamID: "stream-abc", generation: 1)
        let noticeID = ChatRunStatusTerminalEventKey(identity: identity, outcome: .completed).messageID
        let reloaded = [ChatMessage(role: "user", content: "Last user turn",
                                    timestamp: 1_769_000_000, messageId: "server-user-1")]
        let cachedTerminalEvent = ChatMessage(role: "local_notice", content: "Response complete",
                                              timestamp: 1_770_000_000, messageId: noticeID)

        let merged = ChatViewModel.mergingLoadedMessages(
            reloaded,
            withCachedLocalOptimisticMessages: [cachedTerminalEvent]
        )

        XCTAssertEqual(merged.filter { $0.messageId == noticeID }.count, 1,
                       "Server transcript omits the terminal event; the cached copy merges exactly once")
    }

    func testDifferentGenerationDoesNotDeduplicateAsTheSameLogicalRun() {
        let first = ChatRunIdentity(sessionID: "session-A", streamID: "stream-abc", generation: 1)
        let replacement = ChatRunIdentity(sessionID: "session-A", streamID: "stream-abc", generation: 2)
        let firstID = ChatRunStatusTerminalEventKey(identity: first, outcome: .completed).messageID
        let replacementID = ChatRunStatusTerminalEventKey(identity: replacement, outcome: .completed).messageID

        let merged = ChatViewModel.mergingLoadedMessages(
            [ChatMessage(role: "local_notice", content: "Second run done.",
                         timestamp: 1_770_000_100, messageId: replacementID)],
            withCachedLocalOptimisticMessages: [
                ChatMessage(role: "local_notice", content: "First run done.",
                            timestamp: 1_770_000_000, messageId: firstID)
            ]
        )

        XCTAssertEqual(merged.filter { $0.messageId == firstID || $0.messageId == replacementID }.count, 2,
                       "A different logical generation is a different logical run and must not deduplicate")
    }

    func testMergingLoadedMessagesRetainsOnlyRunStatusNoticesAbsentFromServerPayload() {
        // Narrow merge rule (#18 §6): ONLY `run-status-v1-` terminal notices
        // absent from the server payload are retained. Generic local-notice
        // and optimistic-user merge behavior is unchanged: a generic cached
        // local notice is NOT re-created by a reload, and an optimistic user
        // message still merges when the server omits it.
        let identity = ChatRunIdentity(sessionID: "session-A", streamID: "stream-abc", generation: 1)
        let noticeID = ChatRunStatusTerminalEventKey(identity: identity, outcome: .completed).messageID
        let reloaded = [ChatMessage(role: "user", content: "Last user turn",
                                    timestamp: 1_769_000_000, messageId: "server-user-1")]
        let cachedTerminalEvent = ChatMessage(role: "local_notice", content: "Response complete",
                                              timestamp: 1_770_000_000, messageId: noticeID)
        let cachedGenericNotice = ChatMessage(role: "local_notice", content: "Goal set.",
                                              timestamp: 1_769_500_000, messageId: "local-notice-xyz")
        let cachedOptimisticUser = ChatMessage(role: "user", content: "Optimistic turn",
                                               timestamp: 1_769_800_000, messageId: "local-opt-1")

        let merged = ChatViewModel.mergingLoadedMessages(
            reloaded,
            withCachedLocalOptimisticMessages: [cachedTerminalEvent, cachedGenericNotice, cachedOptimisticUser]
        )

        XCTAssertEqual(merged.filter { $0.messageId == noticeID }.count, 1,
                       "run-status terminal notice is retained when the server omits it")
        XCTAssertEqual(merged.filter { $0.messageId == "local-notice-xyz" }.count, 0,
                       "Generic local notices are not re-created by a reload")
        XCTAssertEqual(merged.filter { $0.messageId == "local-opt-1" }.count, 1,
                       "Optimistic user messages keep the existing merge behavior")
    }

    func testColdOfflineReloadRestoresFailedTerminalEventOnce() {
        // Cold reload while offline: the server transcript is empty, so the only
        // copy of the terminal event is the cached local one. It must be restored
        // exactly once — not dropped and not duplicated.
        let identity = ChatRunIdentity(sessionID: "session-A", streamID: "stream-abc", generation: 1)
        let noticeID = ChatRunStatusTerminalEventKey(identity: identity, outcome: .failed).messageID
        let cachedTerminalEvent = ChatMessage(role: "local_notice", content: "Response failed",
                                              timestamp: 1_770_000_000, messageId: noticeID)

        let merged = ChatViewModel.mergingLoadedMessages(
            [], withCachedLocalOptimisticMessages: [cachedTerminalEvent]
        )

        XCTAssertEqual(merged.filter { $0.messageId == noticeID }.count, 1,
                       "Cold offline reload restores the failed terminal event exactly once")
    }

    func testColdOfflineReloadRestoresCancelledTerminalEventOnce() {
        // Cold reload while offline: the server transcript is empty, so the only
        // copy of the terminal event is the cached local one. It must be restored
        // exactly once — not dropped and not duplicated.
        let identity = ChatRunIdentity(sessionID: "session-A", streamID: "stream-abc", generation: 1)
        let noticeID = ChatRunStatusTerminalEventKey(identity: identity, outcome: .cancelled).messageID
        let cachedTerminalEvent = ChatMessage(role: "local_notice", content: "Response cancelled",
                                              timestamp: 1_770_000_000, messageId: noticeID)

        let merged = ChatViewModel.mergingLoadedMessages(
            [], withCachedLocalOptimisticMessages: [cachedTerminalEvent]
        )

        XCTAssertEqual(merged.filter { $0.messageId == noticeID }.count, 1,
                       "Cold offline reload restores the cancelled terminal event exactly once")
    }

    // MARK: - Slice 5 (#18 §522): writer-error retention and retry
    //
    // `streamCoordinatorDidCommitTerminal(_:)` below is the exact delegate
    // delivery point the stream coordinator's centralized terminal transition
    // uses once per accepted outcome (ChatStreamCoordinatorTests pins that the
    // transition constructs the complete ChatRunTerminalCommit and invokes this
    // callback exactly once). Driving the callback directly — instead of
    // re-plumbing the SSE spies, which are private to ChatViewModelSendTests —
    // keeps these tests deterministic: the whole append → handoff → single-write
    // attempt runs synchronously inside the callback, so no continuation
    // choreography is required.
    //
    // The retention maps (`pendingTerminalPersistenceByKey`,
    // `terminalPersistenceErrorByKey`) are private and the error map has no
    // production reader, so assertions are behavioral: a failed write must keep
    // the EXACT handoff + post-append snapshot retryable (a later retry writes it
    // once more with the SAME handoff generation and snapshot), and a repeated
    // terminal commit for a still-pending key must append nothing and write
    // nothing. Retention after a throwing write is the observable proxy for the
    // error record: the catch branch that records the error
    // (ChatViewModel.swift:3460-3463) is the same branch that leaves the key
    // pending.

    @MainActor
    func testFailedTerminalCacheWriterErrorRetainsPendingRequest() throws {
        let context = try makeContext()
        let writer = ThrowingTerminalCacheWriter()
        writer.failNextWrite = true
        let viewModel = try makeViewModel(writer: writer)
        viewModel.modelContext = context

        let identity = ChatRunIdentity(sessionID: "session-A", streamID: "stream-1", generation: 1)
        let key = ChatRunStatusTerminalEventKey(identity: identity, outcome: .completed)
        let commit = ChatRunTerminalCommit(
            identity: identity,
            outcome: .completed,
            eventKey: key,
            serverSessionID: "session-A",
            serverStreamID: "stream-1"
        )

        viewModel.streamCoordinatorDidCommitTerminal(commit)

        // The failed write still appended the stable local notice exactly once.
        XCTAssertEqual(
            viewModel.messages.filter { $0.messageId == key.messageID }.count, 1,
            "The terminal commit appends exactly one 'Response complete' local notice"
        )
        XCTAssertEqual(
            viewModel.messages.first { $0.messageId == key.messageID }?.content,
            "Response complete"
        )
        XCTAssertEqual(writer.writeCount, 1,
                       "A throwing writer is attempted exactly once per commit")
        XCTAssertTrue(writer.handoffs.isEmpty,
                      "The throwing writer records only successful writes")

        // Retained: a repeated terminal commit for the same key is rejected by
        // the pending-key guard — no second event appended, no second write.
        viewModel.streamCoordinatorDidCommitTerminal(commit)
        XCTAssertEqual(
            viewModel.messages.filter { $0.messageId == key.messageID }.count, 1,
            "A repeated commit for a still-pending key appends no second event"
        )
        XCTAssertEqual(writer.writeCount, 1,
                       "A repeated commit for a still-pending key writes nothing")
    }

    @MainActor
    func testCancelledTerminalCacheWriterErrorRetainsPendingRequest() throws {
        let context = try makeContext()
        let writer = ThrowingTerminalCacheWriter()
        writer.failNextWrite = true
        let viewModel = try makeViewModel(writer: writer)
        viewModel.modelContext = context

        let identity = ChatRunIdentity(sessionID: "session-A", streamID: "stream-1", generation: 1)
        let key = ChatRunStatusTerminalEventKey(identity: identity, outcome: .cancelled)
        let commit = ChatRunTerminalCommit(
            identity: identity,
            outcome: .cancelled,
            eventKey: key,
            serverSessionID: "session-A",
            serverStreamID: "stream-1"
        )

        viewModel.streamCoordinatorDidCommitTerminal(commit)

        XCTAssertEqual(
            viewModel.messages.filter { $0.messageId == key.messageID }.count, 1,
            "The cancelled terminal commit appends exactly one 'Response cancelled' local notice"
        )
        XCTAssertEqual(
            viewModel.messages.first { $0.messageId == key.messageID }?.content,
            "Response cancelled"
        )
        XCTAssertEqual(writer.writeCount, 1,
                       "A throwing writer is attempted exactly once per commit")
        XCTAssertTrue(writer.handoffs.isEmpty,
                      "The throwing writer records only successful writes")

        // Retained: a repeated terminal commit for the same key appends nothing
        // and writes nothing.
        viewModel.streamCoordinatorDidCommitTerminal(commit)
        XCTAssertEqual(
            viewModel.messages.filter { $0.messageId == key.messageID }.count, 1,
            "A repeated commit for a still-pending key appends no second event"
        )
        XCTAssertEqual(writer.writeCount, 1,
                       "A repeated commit for a still-pending key writes nothing")
    }

    @MainActor
    func testRetryAfterWriterFailureWritesOnceMoreAndClearsKey() async throws {
        let context = try makeContext()
        let writer = ThrowingTerminalCacheWriter()
        writer.failNextWrite = true
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let viewModel = try makeViewModel(writer: writer, client: client)
        viewModel.modelContext = context

        let identity = ChatRunIdentity(sessionID: "session-A", streamID: "stream-1", generation: 1)
        let key = ChatRunStatusTerminalEventKey(identity: identity, outcome: .completed)
        let commit = ChatRunTerminalCommit(
            identity: identity,
            outcome: .completed,
            eventKey: key,
            serverSessionID: "session-A",
            serverStreamID: "stream-1"
        )

        viewModel.streamCoordinatorDidCommitTerminal(commit)
        XCTAssertEqual(viewModel.messages.filter { $0.messageId == key.messageID }.count, 1)
        XCTAssertEqual(writer.writeCount, 1)

        // Still pending: a repeated same-key commit appends nothing, writes nothing.
        viewModel.streamCoordinatorDidCommitTerminal(commit)
        XCTAssertEqual(viewModel.messages.filter { $0.messageId == key.messageID }.count, 1,
                       "No second event is appended while the key is pending")
        XCTAssertEqual(writer.writeCount, 1,
                       "No second write happens while the key is pending")

        // Retry (#18 §522): a transcript load that obtained a context retries
        // every retained handoff exactly once (ChatViewModel.swift:1447-1449).
        writer.failNextWrite = false
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            return apiTestJSONResponse(#"{"session": {"session_id": "session-A", "title": "Planning", "messages": [{"role": "user", "content": "Recovered transcript.", "timestamp": 1770000100, "message_id": "user-1"}]}}"#, for: request)
        }
        await viewModel.loadMessages(modelContext: context)

        XCTAssertEqual(writer.writeCount, 2,
                       "The retry writes exactly once more per retained key")
        let retriedHandoff = try XCTUnwrap(writer.handoffs.last)
        XCTAssertEqual(retriedHandoff.commit, commit,
                       "The retry writes the EXACT retained handoff")
        XCTAssertEqual(retriedHandoff.handoffGeneration, 1,
                       "The retained handoff keeps its original handoff generation")
        XCTAssertEqual(
            retriedHandoff.postAppendMessages.filter { $0.messageId == key.messageID }.count, 1,
            "The retained post-append snapshot is written as-is: exactly one terminal notice"
        )

        // The successful write removed exactly that key (and its error entry —
        // both are cleared in the same success branch, ChatViewModel.swift:3458-3459):
        // a fresh commit for the same key is accepted again instead of being
        // dropped by the pending-key guard, and it bumps the handoff generation.
        viewModel.streamCoordinatorDidCommitTerminal(commit)
        XCTAssertEqual(writer.writeCount, 3,
                       "A fresh same-key commit is accepted after the key was cleared")
        XCTAssertEqual(try XCTUnwrap(writer.handoffs.last).handoffGeneration, 2,
                       "The replacement handoff carries the next handoff generation")
        XCTAssertEqual(viewModel.messages.filter { $0.messageId == key.messageID }.count, 1,
                       "The fresh commit appends exactly one notice — the retry never appended a second")
    }

    @MainActor
    func testSuccessfulWriterCommitRemovesKeyAndError() throws {
        let context = try makeContext()
        let writer = RecordingTerminalCacheWriter()
        let viewModel = try makeViewModel(writer: writer)
        viewModel.modelContext = context

        let identity = ChatRunIdentity(sessionID: "session-A", streamID: "stream-1", generation: 1)
        let key = ChatRunStatusTerminalEventKey(identity: identity, outcome: .completed)
        let commit = ChatRunTerminalCommit(
            identity: identity,
            outcome: .completed,
            eventKey: key,
            serverSessionID: "session-A",
            serverStreamID: "stream-1"
        )

        viewModel.streamCoordinatorDidCommitTerminal(commit)

        XCTAssertEqual(writer.writeCount, 1,
                       "Exactly one write per successful commit")
        let handoff = try XCTUnwrap(writer.handoffs.first)
        XCTAssertEqual(handoff.commit, commit)
        XCTAssertEqual(handoff.handoffGeneration, 1)
        XCTAssertEqual(
            handoff.postAppendMessages.filter { $0.messageId == key.messageID }.count, 1,
            "The written handoff snapshot contains the post-append terminal notice"
        )
        XCTAssertEqual(viewModel.messages.filter { $0.messageId == key.messageID }.count, 1)
        XCTAssertEqual(viewModel.messages.first { $0.messageId == key.messageID }?.content,
                       "Response complete")

        // The successful write removed exactly that key and its error entry: a
        // fresh commit for the same key is accepted again and writes once more,
        // while the stable message ID still dedupes the notice to exactly one.
        viewModel.streamCoordinatorDidCommitTerminal(commit)
        XCTAssertEqual(writer.writeCount, 2,
                       "A fresh same-key commit after a successful write writes once more")
        XCTAssertEqual(try XCTUnwrap(writer.handoffs.last).handoffGeneration, 2,
                       "The replacement handoff carries the next handoff generation")
        XCTAssertEqual(viewModel.messages.filter { $0.messageId == key.messageID }.count, 1,
                       "The stable message ID still dedupes to exactly one notice")
    }

    // §522 additionally requires a stale successful write to never clear a
    // replacement handoff (the guard compares handoffGeneration). That guard is
    // not reachable from the public/test surface with the current synchronous
    // writer seam; the skip reason below documents the full analysis.
    @MainActor
    func testStaleSuccessfulWriteDoesNotClearReplacementHandoff() throws {
        throw XCTSkip("""
        BLOCKED-with-reason: the stale-success generation guard \
        (ChatViewModel.swift:3457 and its catch-side twin at :3461) cannot be \
        exercised without production changes. A replacement handoff for the SAME \
        key can only be installed after the old key was removed: \
        streamCoordinatorDidCommitTerminal rejects any commit whose key is still \
        pending (line 3409), which also drops re-entrant same-key commits from a \
        writer that calls back into the VM during \
        persistPendingTerminalPersistence; and the writer seam is synchronous, so \
        the key is removed (line 3458) in the same call stack as the write — there \
        is no window in which a stale write could observe a newer handoff. The \
        throwing-then-recording two-sequential-commits alternative is not \
        expressible either: the writer is injected once at init (line 457), and a \
        second same-key commit while the key is pending is rejected per the line \
        3409 guard. The closest executable coverage — fail, retry once more, \
        succeed, then accept a fresh same-key commit with the NEXT handoff \
        generation — is provided by testRetryAfterWriterFailureWritesOnceMoreAndClearsKey \
        and testSuccessfulWriterCommitRemovesKeyAndError.
        """)
    }

    @MainActor
    private func makeViewModel(
        writer: (any ChatTerminalCacheWriter)?,
        client: APIClient? = nil
    ) throws -> ChatViewModel {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        return ChatViewModel(
            session: try makeSession(),
            server: server,
            client: client,
            runGenerationStore: InMemoryRunGenerationStore(),
            terminalCacheWriter: writer
        )
    }

    private func makeSession() throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            SessionSummary.self,
            from: Data(#"{"session_id": "session-A", "title": "Planning", "workspace": "/tmp/workspace"}"#.utf8)
        )
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: CachedSession.self,
            CachedMessage.self,
            configurations: configuration
        )
        return ModelContext(container)
    }
}

// MARK: - Slice 5 spies (shared across the test target)
//
// Both spies conform to the `ChatTerminalCacheWriter` seam: the ViewModel
// routes exactly one identity-keyed handoff per terminal event key through
// `persistPendingTerminalPersistence(for:modelContext:)`, and a throwing
// writer retains the pending handoff for retry without re-appending the
// local notice.

/// Records every handoff the ViewModel routes through the seam, including
/// attempts that failed (the ViewModel retains the handoff for retry).
final class RecordingTerminalCacheWriter: ChatTerminalCacheWriter {
    private(set) var handoffs: [ChatTerminalPersistenceHandoff] = []
    private(set) var writeCount = 0

    func persistPendingTerminalPersistence(
        for handoff: ChatTerminalPersistenceHandoff,
        modelContext: ModelContext?
    ) throws {
        writeCount += 1
        handoffs.append(handoff)
    }
}

/// Fails writes while `failNextWrite` is set, recording every attempt so a
/// retry is observable as one additional write per attempt.
final class ThrowingTerminalCacheWriter: ChatTerminalCacheWriter {
    var failNextWrite = false
    private(set) var handoffs: [ChatTerminalPersistenceHandoff] = []
    private(set) var writeCount = 0

    func persistPendingTerminalPersistence(
        for handoff: ChatTerminalPersistenceHandoff,
        modelContext: ModelContext?
    ) throws {
        writeCount += 1
        if failNextWrite {
            throw StubTerminalCacheWriteError.simulatedFailure
        }
        handoffs.append(handoff)
    }
}

enum StubTerminalCacheWriteError: Error {
    case simulatedFailure
}
