import UIKit

enum ChatHapticFeedback: Equatable {
    case lightImpact
    case mediumImpact
    case selection
    case success
    case warning
}

@MainActor
enum ChatHaptics {
    typealias Performer = @MainActor (ChatHapticFeedback) -> Void

    static func messageSent(isEnabled: Bool, performer: Performer = perform) {
        emit(.lightImpact, isEnabled: isEnabled, performer: performer)
    }

    static func assistantResponseCompleted(isEnabled: Bool, performer: Performer = perform) {
        emit(.success, isEnabled: isEnabled, performer: performer)
    }

    static func streamCancelled(isEnabled: Bool, performer: Performer = perform) {
        emit(.mediumImpact, isEnabled: isEnabled, performer: performer)
    }

    static func approvalSubmitted(_ choice: ApprovalChoice, isEnabled: Bool, performer: Performer = perform) {
        switch choice {
        case .once, .session, .always:
            emit(.lightImpact, isEnabled: isEnabled, performer: performer)
        case .deny:
            emit(.warning, isEnabled: isEnabled, performer: performer)
        }
    }

    static func approvalBypassEnabled(isEnabled: Bool, performer: Performer = perform) {
        emit(.warning, isEnabled: isEnabled, performer: performer)
    }

    static func clarificationSubmitted(isEnabled: Bool, performer: Performer = perform) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    static func configurationSelected(isEnabled: Bool, performer: Performer = perform) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    static func destructiveConfirmationAccepted(isEnabled: Bool, performer: Performer = perform) {
        emit(.warning, isEnabled: isEnabled, performer: performer)
    }

    private static func emit(_ feedback: ChatHapticFeedback, isEnabled: Bool, performer: Performer) {
        guard isEnabled else { return }
        performer(feedback)
    }

    static func perform(_ feedback: ChatHapticFeedback) {
        switch feedback {
        case .lightImpact:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .mediumImpact:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}

/// Cancellation feedback helper (#18 Slice 3): consumes the accepted
/// cancellation ticket exactly once and fires the cancellation haptic only
/// for that accepted result, returning the ticket's stable message ID. The
/// stale path (result false, or nil/already-consumed ticket) is silent:
/// zero haptic callbacks, nothing consumed, no message ID published.
@MainActor
enum ChatCancellationFeedback {
    static func apply(
        result: Bool,
        ticket: ChatCancellationTicket?,
        isHapticsEnabled: Bool,
        performer: ChatHaptics.Performer = ChatHaptics.perform
    ) -> String? {
        guard result, let ticket, ticket.consume() else { return nil }
        ChatHaptics.streamCancelled(isEnabled: isHapticsEnabled, performer: performer)
        return ticket.messageID
    }
}
