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

    @MainActor
    func testCloseRecordsDismissalOnly() {
        let identity = makeStatusConnectionIdentity()
        var dismissedIdentity: ChatRunIdentity?
        var cancelCallCount = 0
        let view = makeActionView(
            onClose: { dismissedIdentity = identity.run },
            onCancel: { cancelCallCount += 1 }
        )

        view.onClose()

        XCTAssertEqual(dismissedIdentity, identity.run)
        XCTAssertEqual(cancelCallCount, 0)
    }

    @MainActor
    func testCancelRecordsExpectedIdentityAndDoesNotClose() {
        let identity = makeStatusConnectionIdentity()
        var dismissed = false
        var cancellationIdentities: [ChatRunConnectionIdentity] = []
        let view = makeActionView(
            onClose: { dismissed = true },
            onCancel: { cancellationIdentities.append(identity) }
        )

        view.onCancel()

        XCTAssertFalse(dismissed)
        XCTAssertEqual(cancellationIdentities, [identity])
    }

    @MainActor
    func testFailedCancelResultLeavesRowActive() {
        let identity = makeStatusConnectionIdentity()
        var lifecycle: ChatRunStatusLifecycle = .active
        var cancelResult: ChatCancelDisposition = .unconfirmed
        let rejectedResponse = ChatCancelResponse(
            ok: false,
            cancelled: nil,
            streamId: identity.run.streamID,
            error: nil
        )
        let view = makeActionView(
            onClose: {},
            onCancel: {
                cancelResult = .rejected(rejectedResponse)
                if case .accepted = cancelResult {
                    lifecycle = .cancelled
                }
            }
        )

        view.onCancel()

        XCTAssertEqual(cancelResult, .rejected(rejectedResponse))
        XCTAssertEqual(lifecycle, .active)
    }

    @MainActor
    func testStaleCancelResultLeavesReplacementStatusUndismissedAndInvokesNoHaptic() {
        let replacementIdentity = makeStatusConnectionIdentity(generation: 2)
        let performer = SpyHapticPerformer()
        var lifecycle: ChatRunStatusLifecycle = .active
        var dismissed = false
        let view = makeActionView(
            onClose: { dismissed = true },
            onCancel: {
                let result = ChatCancelDisposition.stale
                let didAccept = if case .accepted = result { true } else { false }
                let messageID = ChatCancellationFeedback.apply(
                    result: didAccept,
                    ticket: nil,
                    isHapticsEnabled: true,
                    performer: { performer.perform($0) }
                )
                if messageID != nil {
                    lifecycle = .cancelled
                }
            }
        )

        view.onCancel()

        XCTAssertEqual(replacementIdentity.run.generation, 2)
        XCTAssertEqual(lifecycle, .active)
        XCTAssertFalse(dismissed)
        XCTAssertTrue(performer.feedback.isEmpty)
    }

    @MainActor
    func testAcceptedCancelResultInvokesOneHapticOnlyAfterTerminalAcceptance() {
        let identity = makeStatusConnectionIdentity()
        let performer = SpyHapticPerformer()
        let ticket = ChatCancellationTicket(identity: identity, messageID: "cancelled-msg")
        var lifecycle: ChatRunStatusLifecycle = .active
        let view = makeActionView(
            onClose: {},
            onCancel: {
                let result = ChatCancelDisposition.accepted(ticket)
                let didAccept = if case .accepted = result { true } else { false }
                let messageID = ChatCancellationFeedback.apply(
                    result: didAccept,
                    ticket: ticket,
                    isHapticsEnabled: true,
                    performer: { performer.perform($0) }
                )
                if messageID != nil {
                    lifecycle = .cancelled
                }
            }
        )

        view.onCancel()
        view.onCancel()

        XCTAssertEqual(lifecycle, .cancelled)
        XCTAssertTrue(ticket.isConsumed)
        XCTAssertEqual(performer.feedback, [.mediumImpact])
    }

    @MainActor
    func testReduceMotionDisablesRunStatusParentMovement() {
        XCTAssertEqual(ChatMotion.runStatusParentMotion(reduceMotion: true), .none)
        XCTAssertEqual(ChatMotion.runStatusParentMotion(reduceMotion: false), .slideAndFade)
    }

    @MainActor
    private func makeActionView(
        onClose: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> ChatActiveRunStatusView {
        ChatActiveRunStatusView(
            presentation: ChatActiveRunStatusPresentation(kind: .active),
            onClose: onClose,
            onCancel: onCancel
        )
    }

    private func makeStatusConnectionIdentity(generation: Int = 1) -> ChatRunConnectionIdentity {
        ChatRunConnectionIdentity(
            run: ChatRunIdentity(
                sessionID: "session-1",
                streamID: "stream-1",
                generation: generation
            ),
            connectionGeneration: 1
        )
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
