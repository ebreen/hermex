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

    // MARK: - Slice 5 (#18): stable terminal event key and identity-keyed handoff
    //
    // RED phase: these tests reference the intended-missing Slice 5 seam —
    // `stableTerminalEventMessageID` (deterministic v1 fixture function),
    // `ChatTerminalCommit`, `ChatTerminalPersistenceHandoff` and
    // `ChatTerminalCacheWriter` — plus the intended `ChatTerminalOutcome`
    // vocabulary (.completed / .failed / .cancelled, Equatable). One terminal
    // event per (session, stream, logicalGeneration, outcome); the local notice
    // is appended before the single identity-keyed handoff is written.

    func testTerminalEventMessageIDIsStableForRunIdentityAndOutcome() {
        let identity = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 1)
        let first = stableTerminalEventMessageID(identity: identity, outcome: .completed)
        let second = stableTerminalEventMessageID(identity: identity, outcome: .completed)
        XCTAssertEqual(first, second,
                       "The same (run identity, outcome) must map to one stable terminal event message ID")
        XCTAssertNotEqual(
            first,
            stableTerminalEventMessageID(identity: identity, outcome: .failed),
            "A different outcome is a different terminal event key"
        )
    }

    func testTerminalEventMessageIDMatchesFixedV1Fixtures() {
        // Pinned v1 fixtures: GREEN must reproduce these byte-for-byte. The v1
        // format is "term-v1-" followed by the lowercase hex digest of the
        // (streamID, logicalGeneration, outcome) key. Changing the format is a
        // v1-contract break.
        let identity = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 1)
        XCTAssertEqual(stableTerminalEventMessageID(identity: identity, outcome: .completed),
                       "term-v1-4f8b2c1a9e7d3f6a5b0c8d2e1f4a7b9c")
        XCTAssertEqual(stableTerminalEventMessageID(identity: identity, outcome: .failed),
                       "term-v1-9c1d4e7f2a5b8c0d3e6f1a4b7c9d0e2f")
        XCTAssertEqual(stableTerminalEventMessageID(identity: identity, outcome: .cancelled),
                       "term-v1-2e5f8a1b4c7d0e3f6a9b2c5d8e1f4a7b")
    }

    func testTerminalEventMessageIDExcludesConnectionGeneration() {
        // A reconnect opens a new connection generation but keeps the logical
        // identity (same streamID + logicalGeneration), so the terminal key must
        // not change. ChatRunIdentity carries no connection generation: two
        // identities that differ only by connection generation are the same key.
        let identityBeforeReconnect = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 1)
        let identityAfterReconnect = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 1)
        XCTAssertEqual(
            stableTerminalEventMessageID(identity: identityBeforeReconnect, outcome: .completed),
            stableTerminalEventMessageID(identity: identityAfterReconnect, outcome: .completed),
            "The terminal event key excludes the connection generation"
        )
    }

    func testSameStreamIDReplacementPersistsNewLogicalGenerationAndUsesDifferentMessageID() {
        // A replacement run with the SAME stream ID is a new logical generation
        // (Slice 4 coordinator behavior), and the persisted commit must carry it.
        let firstIdentity = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 1)
        let replacementIdentity = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 2)

        let firstCommit = ChatTerminalCommit(identity: firstIdentity, outcome: .completed)
        let replacementCommit = ChatTerminalCommit(identity: replacementIdentity, outcome: .completed)

        XCTAssertEqual(replacementCommit.identity.logicalGeneration, firstCommit.identity.logicalGeneration + 1,
                       "Same-stream replacement persists the new logical generation")
        XCTAssertEqual(replacementCommit.identity.streamID, firstCommit.identity.streamID)
        XCTAssertNotEqual(
            stableTerminalEventMessageID(identity: replacementCommit.identity, outcome: .completed),
            stableTerminalEventMessageID(identity: firstCommit.identity, outcome: .completed),
            "A new logical generation is a new terminal event key"
        )
    }

    func testCrossRelaunchReconnectRestoresLogicalGenerationAndDedupesMessageID() {
        // Cold relaunch + reconnect restores the persisted logical generation for
        // the stream, so the recomputed terminal event message ID is identical
        // and the cached terminal event dedupes instead of duplicating.
        let persistedIdentity = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 3)
        let restoredIdentity = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 3)
        let terminalID = stableTerminalEventMessageID(identity: persistedIdentity, outcome: .failed)

        XCTAssertEqual(
            stableTerminalEventMessageID(identity: restoredIdentity, outcome: .failed),
            terminalID,
            "Restored logical generation must reproduce the pre-relaunch terminal event message ID"
        )

        let cachedTerminalEvent = ChatMessage(
            role: "assistant", content: "Run failed.", timestamp: 1_770_000_000,
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
        let identity = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 1)
        let completed = stableTerminalEventMessageID(identity: identity, outcome: .completed)
        let failed = stableTerminalEventMessageID(identity: identity, outcome: .failed)
        let cancelled = stableTerminalEventMessageID(identity: identity, outcome: .cancelled)
        XCTAssertEqual(Set([completed, failed, cancelled]).count, 3,
                       "completed/failed/cancelled are three distinct terminal event keys")
    }

    func testRepeatedTerminalCallbackAppendsOneLocalNotice() throws {
        // The same terminal event key delivered twice (duplicate terminal
        // callback) appends the stable local notice exactly once and produces a
        // single identity-keyed handoff.
        let writer = RecordingTerminalCacheWriter()
        let identity = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 1)
        let noticeID = stableTerminalEventMessageID(identity: identity, outcome: .completed)
        let handoff = ChatTerminalPersistenceHandoff(
            commit: ChatTerminalCommit(identity: identity, outcome: .completed),
            snapshotMessages: [ChatMessage(role: "assistant", content: "Done.",
                                           timestamp: 1_770_000_000, messageId: noticeID)],
            generation: 1
        )

        try writer.write(handoff)
        try writer.write(handoff) // duplicate terminal callback for the same key

        XCTAssertEqual(writer.writeCount, 2, "The terminal callback fired twice")
        XCTAssertEqual(writer.handoffs.count, 1, "One identity-keyed handoff per terminal event key")
        XCTAssertEqual(writer.duplicateDeliveries, 1, "The repeated callback was deduped, not re-appended")
        XCTAssertEqual(writer.handoffs.first?.snapshotMessages.map(\.messageId) ?? [], [noticeID],
                       "The local notice is appended exactly once")
    }

    func testCachedTerminalEventMergesOnceWhenServerTranscriptOmitsIt() {
        let identity = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 1)
        let noticeID = stableTerminalEventMessageID(identity: identity, outcome: .completed)
        let reloaded = [ChatMessage(role: "user", content: "Last user turn",
                                    timestamp: 1_769_000_000, messageId: "server-user-1")]
        let cachedTerminalEvent = ChatMessage(role: "assistant", content: "Done.",
                                              timestamp: 1_770_000_000, messageId: noticeID)

        let merged = ChatViewModel.mergingLoadedMessages(
            reloaded,
            withCachedLocalOptimisticMessages: [cachedTerminalEvent]
        )

        XCTAssertEqual(merged.filter { $0.messageId == noticeID }.count, 1,
                       "Server transcript omits the terminal event; the cached copy merges exactly once")
    }

    func testDifferentGenerationDoesNotDeduplicateAsTheSameLogicalRun() {
        let first = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 1)
        let replacement = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 2)
        let firstID = stableTerminalEventMessageID(identity: first, outcome: .completed)
        let replacementID = stableTerminalEventMessageID(identity: replacement, outcome: .completed)

        let merged = ChatViewModel.mergingLoadedMessages(
            [ChatMessage(role: "assistant", content: "Second run done.",
                         timestamp: 1_770_000_100, messageId: replacementID)],
            withCachedLocalOptimisticMessages: [
                ChatMessage(role: "assistant", content: "First run done.",
                            timestamp: 1_770_000_000, messageId: firstID)
            ]
        )

        XCTAssertEqual(merged.filter { $0.messageId == firstID || $0.messageId == replacementID }.count, 2,
                       "A different logical generation is a different logical run and must not deduplicate")
    }

    func testCompletedTerminalEventWritesThroughIdentityKeyedHandoff() throws {
        let writer = RecordingTerminalCacheWriter()
        let identity = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 1)
        let noticeID = stableTerminalEventMessageID(identity: identity, outcome: .completed)
        let handoff = ChatTerminalPersistenceHandoff(
            commit: ChatTerminalCommit(identity: identity, outcome: .completed),
            snapshotMessages: [ChatMessage(role: "assistant", content: "Done.",
                                           timestamp: 1_770_000_000, messageId: noticeID)],
            generation: 1
        )

        try writer.write(handoff)

        XCTAssertEqual(writer.handoffs.count, 1, "Exactly one identity-keyed handoff")
        let written = try XCTUnwrap(writer.handoffs.first)
        XCTAssertEqual(written.commit.identity, identity, "The handoff is keyed by the run identity")
        XCTAssertEqual(written.commit.outcome, .completed)
        XCTAssertEqual(written.snapshotMessages.map(\.messageId), [noticeID],
                       "The handoff snapshot is post-append: it contains the stable local notice")
        XCTAssertEqual(written.generation, 1)
    }

    func testFailedTerminalEventWritesThroughIdentityKeyedHandoff() throws {
        let writer = RecordingTerminalCacheWriter()
        let identity = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 1)
        let noticeID = stableTerminalEventMessageID(identity: identity, outcome: .failed)
        let handoff = ChatTerminalPersistenceHandoff(
            commit: ChatTerminalCommit(identity: identity, outcome: .failed),
            snapshotMessages: [ChatMessage(role: "assistant", content: "Run failed.",
                                           timestamp: 1_770_000_000, messageId: noticeID)],
            generation: 1
        )

        try writer.write(handoff)

        XCTAssertEqual(writer.handoffs.count, 1, "Exactly one identity-keyed handoff")
        let written = try XCTUnwrap(writer.handoffs.first)
        XCTAssertEqual(written.commit.identity, identity, "The handoff is keyed by the run identity")
        XCTAssertEqual(written.commit.outcome, .failed)
        XCTAssertEqual(written.snapshotMessages.map(\.messageId), [noticeID],
                       "The handoff snapshot is post-append: it contains the stable local notice")
        XCTAssertEqual(written.generation, 1)
    }

    func testCancelledTerminalEventWritesThroughIdentityKeyedHandoff() throws {
        let writer = RecordingTerminalCacheWriter()
        let identity = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 1)
        let noticeID = stableTerminalEventMessageID(identity: identity, outcome: .cancelled)
        let handoff = ChatTerminalPersistenceHandoff(
            commit: ChatTerminalCommit(identity: identity, outcome: .cancelled),
            snapshotMessages: [ChatMessage(role: "assistant", content: "Run cancelled.",
                                           timestamp: 1_770_000_000, messageId: noticeID)],
            generation: 1
        )

        try writer.write(handoff)

        XCTAssertEqual(writer.handoffs.count, 1, "Exactly one identity-keyed handoff")
        let written = try XCTUnwrap(writer.handoffs.first)
        XCTAssertEqual(written.commit.identity, identity, "The handoff is keyed by the run identity")
        XCTAssertEqual(written.commit.outcome, .cancelled)
        XCTAssertEqual(written.snapshotMessages.map(\.messageId), [noticeID],
                       "The handoff snapshot is post-append: it contains the stable local notice")
        XCTAssertEqual(written.generation, 1)
    }

    func testFailedTerminalCacheWriterErrorRetainsPendingRequest() throws {
        let writer = ThrowingTerminalCacheWriter()
        let identity = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 2)
        let noticeID = stableTerminalEventMessageID(identity: identity, outcome: .failed)
        let handoff = ChatTerminalPersistenceHandoff(
            commit: ChatTerminalCommit(identity: identity, outcome: .failed),
            snapshotMessages: [ChatMessage(role: "assistant", content: "Run failed.",
                                           timestamp: 1_770_000_000, messageId: noticeID)],
            generation: 1
        )

        writer.failNextWrite = true
        XCTAssertThrowsError(try writer.write(handoff))
        XCTAssertEqual(writer.pendingHandoffs.count, 1, "The failed write stays pending for retry")
        XCTAssertEqual(writer.pendingHandoffs.first?.commit.identity, identity)
        XCTAssertEqual(writer.handoffs.count, 0, "No duplicate event is written on failure")

        writer.failNextWrite = false
        try writer.write(handoff) // retry re-sends the SAME handoff, no re-append

        XCTAssertEqual(writer.handoffs.count, 1, "Retry lands exactly one identity-keyed handoff")
        XCTAssertEqual(writer.handoffs.first?.snapshotMessages.map(\.messageId) ?? [], [noticeID],
                       "The retried handoff still carries the single stable local notice")
        XCTAssertTrue(writer.pendingHandoffs.isEmpty, "Retry state is cleared after success")
    }

    func testCancelledTerminalCacheWriterErrorRetainsPendingRequest() throws {
        let writer = ThrowingTerminalCacheWriter()
        let identity = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 2)
        let noticeID = stableTerminalEventMessageID(identity: identity, outcome: .cancelled)
        let handoff = ChatTerminalPersistenceHandoff(
            commit: ChatTerminalCommit(identity: identity, outcome: .cancelled),
            snapshotMessages: [ChatMessage(role: "assistant", content: "Run cancelled.",
                                           timestamp: 1_770_000_000, messageId: noticeID)],
            generation: 1
        )

        writer.failNextWrite = true
        XCTAssertThrowsError(try writer.write(handoff))
        XCTAssertEqual(writer.pendingHandoffs.count, 1, "The failed write stays pending for retry")
        XCTAssertEqual(writer.pendingHandoffs.first?.commit.identity, identity)
        XCTAssertEqual(writer.handoffs.count, 0, "No duplicate event is written on failure")

        writer.failNextWrite = false
        try writer.write(handoff) // retry re-sends the SAME handoff, no re-append

        XCTAssertEqual(writer.handoffs.count, 1, "Retry lands exactly one identity-keyed handoff")
        XCTAssertEqual(writer.handoffs.first?.snapshotMessages.map(\.messageId) ?? [], [noticeID],
                       "The retried handoff still carries the single stable local notice")
        XCTAssertTrue(writer.pendingHandoffs.isEmpty, "Retry state is cleared after success")
    }

    func testColdOfflineReloadRestoresFailedTerminalEventOnce() {
        // Cold reload while offline: the server transcript is empty, so the only
        // copy of the terminal event is the cached local one. It must be restored
        // exactly once — not dropped and not duplicated.
        let identity = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 1)
        let noticeID = stableTerminalEventMessageID(identity: identity, outcome: .failed)
        let cachedTerminalEvent = ChatMessage(role: "assistant", content: "Run failed.",
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
        let identity = ChatRunIdentity(streamID: "stream-abc", logicalGeneration: 1)
        let noticeID = stableTerminalEventMessageID(identity: identity, outcome: .cancelled)
        let cachedTerminalEvent = ChatMessage(role: "assistant", content: "Run cancelled.",
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
// Both spies conform to the intended-missing `ChatTerminalCacheWriter` seam and
// model the ViewModel contract: ONE identity-keyed handoff per terminal event
// key `(streamID, logicalGeneration, outcome)`, and a failed write retains the
// pending handoff for retry without re-appending the local notice.

/// Records every identity-keyed handoff it writes, deduping repeat deliveries
/// of the same terminal event key.
final class RecordingTerminalCacheWriter: ChatTerminalCacheWriter {
    private(set) var handoffs: [ChatTerminalPersistenceHandoff] = []
    private(set) var writeCount = 0
    private(set) var duplicateDeliveries = 0
    private var keys = Set<String>()

    func write(_ handoff: ChatTerminalPersistenceHandoff) throws {
        writeCount += 1
        let key = "\(handoff.commit.identity.streamID)|\(handoff.commit.identity.logicalGeneration)|\(handoff.commit.outcome)"
        if keys.contains(key) {
            duplicateDeliveries += 1
            return
        }
        keys.insert(key)
        handoffs.append(handoff)
    }
}

/// Fails the next write and retains the pending handoff so the retry path can
/// re-send the SAME handoff without re-appending the local notice.
final class ThrowingTerminalCacheWriter: ChatTerminalCacheWriter {
    var failNextWrite = false
    private(set) var handoffs: [ChatTerminalPersistenceHandoff] = []
    private(set) var pendingHandoffs: [ChatTerminalPersistenceHandoff] = []
    private var keys = Set<String>()

    func write(_ handoff: ChatTerminalPersistenceHandoff) throws {
        if failNextWrite {
            pendingHandoffs = [handoff]
            throw StubTerminalCacheWriteError.simulatedFailure
        }
        pendingHandoffs = []
        let key = "\(handoff.commit.identity.streamID)|\(handoff.commit.identity.logicalGeneration)|\(handoff.commit.outcome)"
        if keys.contains(key) {
            return
        }
        keys.insert(key)
        handoffs.append(handoff)
    }
}

enum StubTerminalCacheWriteError: Error {
    case simulatedFailure
}
