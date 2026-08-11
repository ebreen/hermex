import XCTest
@testable import HermesMobile

/// Slice 0 setup smoke: proves the test member is target-wired and discoverable.
/// Compile-only by contract — it must reference NO production symbols added by #18
/// ("no production status implementation yet"). It may not require a host UI.
final class ChatRunStatusLayoutTests: XCTestCase {
    func testChatRunStatusLayoutTestMemberIsTargetWired() throws {
        XCTAssertTrue(true, "target wiring smoke: member discovered, compiled, and ran")
    }

    // MARK: - Slice 3 (#18): cancellation feedback gate (injected haptic performer)

    // The ChatView cancel action feeds the ViewModel's Bool result through the
    // cancellation feedback helper/action, which consumes the accepted ticket
    // exactly once and fires the haptic only for that accepted result. The
    // stale path (result == false, no ticket) must be silent: zero haptic
    // callbacks, nothing consumed, no message ID published.
    @MainActor
    func testStaleCancellationResultProducesNoHapticFeedback() throws {
        let performer = SpyHapticPerformer()

        let messageID = ChatCancellationFeedback.apply(
            result: false,
            ticket: nil,
            isHapticsEnabled: true,
            performer: { performer.perform($0) }
        )

        XCTAssertNil(messageID)
        XCTAssertTrue(performer.feedback.isEmpty)
    }

    // Accepted-current-identity path: result true with the exact ticket →
    // one valid/consumed terminal feedback ticket, one haptic callback, one
    // deduplicated stable message ID. Replaying the same accepted result
    // cannot consume again or fire a second haptic.
    @MainActor
    func testAcceptedCancellationConsumesTicketOnceAndFiresSingleHaptic() throws {
        let performer = SpyHapticPerformer()
        let ticket = ChatCancellationTicket(
            identity: ChatRunConnectionIdentity(
                streamID: "stream-123",
                logicalGeneration: 7,
                connectionGeneration: 1
            ),
            messageID: "cancelled-msg-7"
        )

        let messageID = ChatCancellationFeedback.apply(
            result: true,
            ticket: ticket,
            isHapticsEnabled: true,
            performer: { performer.perform($0) }
        )

        XCTAssertEqual(messageID, "cancelled-msg-7")
        XCTAssertTrue(ticket.isConsumed)
        XCTAssertEqual(performer.feedback, [.mediumImpact])

        let replayedMessageID = ChatCancellationFeedback.apply(
            result: true,
            ticket: ticket,
            isHapticsEnabled: true,
            performer: { performer.perform($0) }
        )
        XCTAssertNil(replayedMessageID)
        XCTAssertEqual(performer.feedback, [.mediumImpact])
    }
}

/// Records every haptic the injected performer is asked to emit.
@MainActor
private final class SpyHapticPerformer {
    private(set) var feedback: [ChatHapticFeedback] = []

    func perform(_ feedback: ChatHapticFeedback) {
        self.feedback.append(feedback)
    }
}
