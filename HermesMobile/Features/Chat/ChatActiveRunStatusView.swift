import SwiftUI

struct ChatActiveRunStatusView: View {
    let presentation: ChatActiveRunStatusPresentation
    let onClose: () -> Void
    let onCancel: () -> Void
    private let showsActions: Bool

    /// Compatibility initializer used by previews and existing callers that
    /// render the status as a passive pill.
    init(presentation: ChatActiveRunStatusPresentation) {
        self.presentation = presentation
        self.onClose = {}
        self.onCancel = {}
        self.showsActions = false
    }

    /// UI-action initializer. Close only dismisses the projection; cancellation
    /// is intentionally a separate action so it cannot be confused with close.
    init(
        presentation: ChatActiveRunStatusPresentation,
        onClose: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.onClose = onClose
        self.onCancel = onCancel
        self.showsActions = true
    }

    /// Identity-carrying cancellation initializer used by the real ChatView
    /// path. The stored action remains callable as `onCancel()` for the
    /// existing test seam while the supplied closure receives the exact
    /// connection identity captured by the row.
    init(
        presentation: ChatActiveRunStatusPresentation,
        connectionIdentity: ChatRunConnectionIdentity,
        onClose: @escaping () -> Void,
        onCancel: @escaping (ChatRunConnectionIdentity) -> Void
    ) {
        self.init(
            presentation: presentation,
            onClose: onClose,
            onCancel: { onCancel(connectionIdentity) }
        )
    }

    /// Label-compatible spelling for callers that describe the token as the
    /// row's identity.
    init(
        presentation: ChatActiveRunStatusPresentation,
        identity: ChatRunConnectionIdentity,
        onClose: @escaping () -> Void,
        onCancel: @escaping (ChatRunConnectionIdentity) -> Void
    ) {
        self.init(
            presentation: presentation,
            connectionIdentity: identity,
            onClose: onClose,
            onCancel: onCancel
        )
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                progressIndicator

                Text(presentation.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(0.88)

                Spacer(minLength: 0)

                if showsActions {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Dismiss run status"))

                    Button(action: onCancel) {
                        Image(systemName: "stop.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Cancel response"))
                }
            }

            if !presentation.goal.isEmpty {
                Text(presentation.goal)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .chatTimelineAccessorySurface(
            fallbackMaterial: .regularMaterial,
            cornerRadius: 16
        )
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if reduceMotion {
            Circle()
                .fill(.secondary)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        } else {
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
        }
    }
}

#Preview("Active Run Status") {
    VStack(spacing: 12) {
        ChatActiveRunStatusView(
            presentation: ChatActiveRunStatusPresentation(kind: .active)
        )

        ChatActiveRunStatusView(
            presentation: ChatActiveRunStatusPresentation(kind: .reconnecting)
        )
    }
    .padding()
    .background(Color(.systemBackground))
}
