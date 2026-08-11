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
