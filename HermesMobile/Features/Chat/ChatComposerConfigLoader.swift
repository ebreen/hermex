import Foundation

struct ChatComposerConfigState: Equatable, Sendable {
    var currentWorkspace: String?
    var currentModel: String?
    var currentModelProvider: String?
    var currentProfile: String?
    var selectedProfileName: String?
    var selectedReasoningEffort: String?
    /// Model-aware effort vocabulary (`supported_efforts`); `nil` on older
    /// servers → composer falls back to the full static list (issue #18).
    var supportedReasoningEfforts: [String]?
    /// `supports_reasoning_effort`; `false` hides the effort control, `nil`
    /// (older servers) keeps it visible.
    var supportsReasoningEffort: Bool?
    var modelCatalogGroups: [ModelCatalogGroup]
    var agentCommands: [AgentCommand]
    var workspaceRoots: [WorkspaceRoot]
    var workspaceSuggestions: [String]
    var profileOptions: [ProfileSummary]
    var isSingleProfileMode: Bool

    init(
        currentWorkspace: String? = nil,
        currentModel: String? = nil,
        currentModelProvider: String? = nil,
        currentProfile: String? = nil,
        selectedProfileName: String? = nil,
        selectedReasoningEffort: String? = nil,
        supportedReasoningEfforts: [String]? = nil,
        supportsReasoningEffort: Bool? = nil,
        modelCatalogGroups: [ModelCatalogGroup] = [],
        agentCommands: [AgentCommand] = [],
        workspaceRoots: [WorkspaceRoot] = [],
        workspaceSuggestions: [String] = [],
        profileOptions: [ProfileSummary] = [],
        isSingleProfileMode: Bool = false
    ) {
        self.currentWorkspace = currentWorkspace
        self.currentModel = currentModel
        self.currentModelProvider = currentModelProvider
        self.currentProfile = currentProfile
        self.selectedProfileName = selectedProfileName
        self.selectedReasoningEffort = selectedReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportsReasoningEffort = supportsReasoningEffort
        self.modelCatalogGroups = modelCatalogGroups
        self.agentCommands = agentCommands
        self.workspaceRoots = workspaceRoots
        self.workspaceSuggestions = workspaceSuggestions
        self.profileOptions = profileOptions
        self.isSingleProfileMode = isSingleProfileMode
    }
}

/// Fixed Sendable failure categories for composer configuration loading
/// (Slice 3, #16). The Sendable result never carries a raw `Error`.
enum ChatComposerConfigFailure: Equatable, Sendable {
    case profileUnavailable
    case profileSwitchRejected
    case catalogUnavailable
    case reasoningUnavailable
    case workspacesUnavailable
}

struct ChatComposerConfigLoadResult: Sendable {
    let state: ChatComposerConfigState
    let configurationError: Error?
    let configurationFailure: ChatComposerConfigFailure?
}

struct ChatComposerConfigLoader {
    private let client: APIClient
    /// The coordinator's ordered catalog stream (Slice 3): when present the
    /// loader consumes the neutral base projection instead of issuing direct
    /// profile/switch/models requests.
    private let catalogEvents: AsyncStream<CatalogEvent>?
    /// Narrow `@MainActor` callback invoked exactly once with the parsed/
    /// defaulted base projection, immediately after catalog parsing and
    /// before the reasoning request is awaited.
    private let onCatalogReady: (@MainActor @Sendable (CatalogBaseSnapshot) -> Void)?

    init(client: APIClient) {
        self.client = client
        self.catalogEvents = nil
        self.onCatalogReady = nil
    }

    init(
        client: APIClient,
        catalogEvents: AsyncStream<CatalogEvent>,
        onCatalogReady: @escaping @MainActor @Sendable (CatalogBaseSnapshot) -> Void
    ) {
        self.client = client
        self.catalogEvents = catalogEvents
        self.onCatalogReady = onCatalogReady
    }

    func loadConfiguration(from initialState: ChatComposerConfigState) async -> ChatComposerConfigLoadResult {
        if let catalogEvents, let onCatalogReady {
            return await loadConfigurationFromCatalog(
                from: initialState,
                catalogEvents: catalogEvents,
                onCatalogReady: onCatalogReady
            )
        }
        return await loadConfigurationFromClient(from: initialState)
    }

    /// Legacy path: direct Networking-compatibility lease reads. Preserves the
    /// established request ordering profiles → (switch) → models → reasoning →
    /// workspaces → commands, tagging each failure with the fixed category.
    private func loadConfigurationFromClient(
        from initialState: ChatComposerConfigState
    ) async -> ChatComposerConfigLoadResult {
        var state = initialState
        var configurationError: Error?
        var configurationFailure: ChatComposerConfigFailure?

        // The phase in flight when a throw lands; the catch below tags the
        // fixed category without changing the legacy control flow.
        var failingPhase: ChatComposerConfigFailure?
        do {
            // Raw profile read under the Networking compatibility lease (issue
            // #16 Slice 1). An epoch-advanced result (a concurrent profile
            // switch) is discarded before it can mutate state; the next
            // configuration load reconciles.
            var selectedProfile: ProfileSummary?
            failingPhase = .profileUnavailable
            let profilesEnvelope = try await client.compatibilityProfiles(operationID: UUID(), operationGeneration: 1)
            if await client.acceptsCompatibilityEpoch(gateEpoch: profilesEnvelope.gateEpoch, gateKey: profilesEnvelope.gateKey) {
                let profilesResponse = profilesEnvelope.value
                state.profileOptions = profilesResponse.profiles ?? []
                state.isSingleProfileMode = profilesResponse.singleProfileMode ?? false
                state.selectedProfileName = Self.nonEmpty(state.currentProfile)
                    ?? Self.nonEmpty(profilesResponse.active)
                    ?? profilesResponse.effectiveDefaultProfileName

                if let sessionProfile = Self.nonEmpty(state.currentProfile),
                   Self.nonEmpty(profilesResponse.active) != sessionProfile {
                    failingPhase = .profileSwitchRejected
                    let switchResponse = try await client.switchProfile(name: sessionProfile)
                    state.profileOptions = switchResponse.profiles ?? state.profileOptions
                    state.selectedProfileName = Self.nonEmpty(switchResponse.active) ?? sessionProfile
                    state.currentProfile = state.selectedProfileName

                    if state.currentWorkspace == nil {
                        state.currentWorkspace = Self.nonEmpty(switchResponse.defaultWorkspace)
                    }

                    if state.currentModel == nil {
                        state.currentModel = Self.nonEmpty(switchResponse.defaultModel)
                    }
                }

                selectedProfile = Self.profileSummary(
                    matching: state.selectedProfileName,
                    in: state.profileOptions
                )
                if state.currentModel == nil {
                    state.currentModel = Self.nonEmpty(selectedProfile?.model)
                }
            }

            // Base catalog under the same shared compatibility lease; an
            // epoch-advanced result is discarded before state mutation.
            failingPhase = .catalogUnavailable
            let modelsEnvelope = try await client.compatibilityModels(operationID: UUID(), operationGeneration: 1)
            if await client.acceptsCompatibilityEpoch(gateEpoch: modelsEnvelope.gateEpoch, gateKey: modelsEnvelope.gateKey) {
                let modelsResponse = modelsEnvelope.value
                state.modelCatalogGroups = modelsResponse.groups
                if state.currentModel == nil {
                    state.currentModel = modelsResponse.defaultModel
                }
                if Self.nonEmpty(state.currentModelProvider) == nil {
                    state.currentModelProvider = Self.nonEmpty(selectedProfile?.provider)
                        ?? Self.uniqueProvider(for: state.currentModel, in: state.modelCatalogGroups)
                }
            }

            // Scope the query to the session's resolved model/provider so the
            // gating fields are model-accurate (issue #18); the seeded effort is
            // the server's already-coerced value for that model.
            failingPhase = .reasoningUnavailable
            let reasoningResponse = try await client.reasoning(
                model: Self.nonEmpty(state.currentModel),
                provider: Self.nonEmpty(state.currentModelProvider)
            )
            state.selectedReasoningEffort = reasoningResponse.effectiveEffort
            state.supportedReasoningEfforts = reasoningResponse.normalizedSupportedEfforts
            state.supportsReasoningEffort = reasoningResponse.supportsReasoningEffort

            failingPhase = .workspacesUnavailable
            let workspaceResponse = try await client.workspaces()
            state.workspaceRoots = workspaceResponse.workspaces ?? []
            if state.currentWorkspace == nil {
                state.currentWorkspace = workspaceResponse.last ?? state.workspaceRoots.compactMap(\.path).first
            }
            state.workspaceSuggestions = state.workspaceRoots.compactMap(\.path)
        } catch {
            configurationError = error
            configurationFailure = failingPhase
        }

        do {
            state.agentCommands = (try await client.commands()).commands ?? []
        } catch {
            state.agentCommands = []
        }

        return ChatComposerConfigLoadResult(
            state: state,
            configurationError: configurationError,
            configurationFailure: configurationFailure
        )
    }

    /// Slice 3 catalog path: consumes the coordinator's ordered stream. The
    /// coordinator is the single authority for the profile phase and the
    /// catalog, so this path issues zero direct profile/switch/models
    /// requests. The parsed/defaulted base projection is published through the
    /// narrow `onCatalogReady` callback exactly once, immediately after catalog
    /// parsing/defaulting and before the reasoning request is awaited;
    /// reasoning → workspaces → commands ordering is unchanged.
    private func loadConfigurationFromCatalog(
        from initialState: ChatComposerConfigState,
        catalogEvents: AsyncStream<CatalogEvent>,
        onCatalogReady: @escaping @MainActor @Sendable (CatalogBaseSnapshot) -> Void
    ) async -> ChatComposerConfigLoadResult {
        var state = initialState
        var configurationError: Error?
        var configurationFailure: ChatComposerConfigFailure?
        var didPublishCatalogReady = false

        var profileContext: CatalogProfileContext?
        var baseSnapshot: CatalogBaseSnapshot?
        for await event in catalogEvents {
            switch event {
            case let .contextVerified(_, context):
                profileContext = context
            case let .base(snapshot):
                baseSnapshot = snapshot
            case let .failed(_, phase, category):
                configurationFailure = Self.failureCategory(for: phase, category: category)
            case .liveFailed, .finished, .cancelled, .state, .live, .contextReset:
                break
            }

            if let context = profileContext, let base = baseSnapshot {
                // Copy the verified profile projection into the composer state.
                state.profileOptions = context.profiles
                state.isSingleProfileMode = context.singleProfileMode
                state.selectedProfileName = Self.nonEmpty(state.currentProfile)
                    ?? Self.nonEmpty(context.activeProfile)
                if case let .switched(defaults) = context.switchResult {
                    if state.currentWorkspace == nil {
                        state.currentWorkspace = Self.nonEmpty(defaults.workspace)
                    }
                    if state.currentModel == nil {
                        state.currentModel = Self.nonEmpty(defaults.model)
                    }
                }

                // Copy the neutral base projection and apply catalog defaults.
                state.modelCatalogGroups = base.groups
                if state.currentModel == nil {
                    state.currentModel = Self.nonEmpty(base.defaultModel)
                }
                if Self.nonEmpty(state.currentModelProvider) == nil {
                    state.currentModelProvider = Self.nonEmpty(base.activeProvider)
                        ?? Self.uniqueProvider(for: state.currentModel, in: state.modelCatalogGroups)
                }

                // Publish exactly once, immediately after catalog parsing/
                // defaulting and before the reasoning request is awaited.
                if !didPublishCatalogReady {
                    await onCatalogReady(base)
                    didPublishCatalogReady = true
                }
                break
            }

            if configurationFailure != nil {
                break
            }
        }

        // reasoning → workspaces → commands: unchanged ordering and error
        // behavior after catalog publication.
        if configurationFailure == nil {
            do {
                let reasoningResponse = try await client.reasoning(
                    model: Self.nonEmpty(state.currentModel),
                    provider: Self.nonEmpty(state.currentModelProvider)
                )
                state.selectedReasoningEffort = reasoningResponse.effectiveEffort
                state.supportedReasoningEfforts = reasoningResponse.normalizedSupportedEfforts
                state.supportsReasoningEffort = reasoningResponse.supportsReasoningEffort
            } catch {
                configurationError = error
                configurationFailure = .reasoningUnavailable
            }

            do {
                let workspaceResponse = try await client.workspaces()
                state.workspaceRoots = workspaceResponse.workspaces ?? []
                if state.currentWorkspace == nil {
                    state.currentWorkspace = workspaceResponse.last ?? state.workspaceRoots.compactMap(\.path).first
                }
                state.workspaceSuggestions = state.workspaceRoots.compactMap(\.path)
            } catch {
                configurationError = error
                configurationFailure = .workspacesUnavailable
            }
        }

        do {
            state.agentCommands = (try await client.commands()).commands ?? []
        } catch {
            state.agentCommands = []
        }

        return ChatComposerConfigLoadResult(
            state: state,
            configurationError: configurationError,
            configurationFailure: configurationFailure
        )
    }

    private static func failureCategory(
        for phase: CatalogPhase,
        category: CatalogFailureCategory
    ) -> ChatComposerConfigFailure {
        switch category {
        case .profileSwitchRejected:
            return .profileSwitchRejected
        case .profileUnavailable, .profileMismatch, .unknownContext:
            return .profileUnavailable
        case .transport, .unauthorized, .http, .decoding, .providerMismatch, .cancelled:
            return phase == .context ? .profileUnavailable : .catalogUnavailable
        }
    }

    private static func profileSummary(
        matching profileName: String?,
        in profileOptions: [ProfileSummary]
    ) -> ProfileSummary? {
        guard let profileName = nonEmpty(profileName) else { return nil }
        return profileOptions.first { $0.normalizedName == profileName }
    }

    private static func uniqueProvider(
        for modelID: String?,
        in groups: [ModelCatalogGroup]
    ) -> String? {
        guard let modelID = nonEmpty(modelID) else { return nil }
        let providers = Set(
            groups
                .flatMap(\.slashAutocompleteModels)
                .filter { $0.id == modelID }
                .compactMap { nonEmpty($0.providerID) }
        )
        return providers.count == 1 ? providers.first : nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Reload-comparison fingerprint that excludes catalog groups and
/// catalog-derived model/provider defaults (Slice 3): early catalog
/// publication must not trigger the full composer reload loop.
struct NonCatalogComposerFingerprint: Equatable, Sendable {
    let currentWorkspace: String?
    let currentProfile: String?
    let selectedProfileName: String?
    let selectedReasoningEffort: String?
    let supportedReasoningEfforts: [String]?
    let supportsReasoningEffort: Bool?
    let agentCommands: [AgentCommand]
    let workspaceRoots: [WorkspaceRoot]
    let workspaceSuggestions: [String]
    let profileOptions: [ProfileSummary]
    let isSingleProfileMode: Bool
}

extension ChatComposerConfigState {
    var nonCatalogReloadFingerprint: NonCatalogComposerFingerprint {
        NonCatalogComposerFingerprint(
            currentWorkspace: currentWorkspace,
            currentProfile: currentProfile,
            selectedProfileName: selectedProfileName,
            selectedReasoningEffort: selectedReasoningEffort,
            supportedReasoningEfforts: supportedReasoningEfforts,
            supportsReasoningEffort: supportsReasoningEffort,
            agentCommands: agentCommands,
            workspaceRoots: workspaceRoots,
            workspaceSuggestions: workspaceSuggestions,
            profileOptions: profileOptions,
            isSingleProfileMode: isSingleProfileMode
        )
    }
}
