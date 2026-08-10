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

struct ChatComposerConfigLoadResult: Sendable {
    let state: ChatComposerConfigState
    let configurationError: Error?
}

struct ChatComposerConfigLoader {
    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func loadConfiguration(from initialState: ChatComposerConfigState) async -> ChatComposerConfigLoadResult {
        var state = initialState
        var configurationError: Error?

        do {
            // Raw profile read under the Networking compatibility lease (issue
            // #16 Slice 1). An epoch-advanced result (a concurrent profile
            // switch) is discarded before it can mutate state; the next
            // configuration load reconciles.
            var selectedProfile: ProfileSummary?
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
            let reasoningResponse = try await client.reasoning(
                model: Self.nonEmpty(state.currentModel),
                provider: Self.nonEmpty(state.currentModelProvider)
            )
            state.selectedReasoningEffort = reasoningResponse.effectiveEffort
            state.supportedReasoningEfforts = reasoningResponse.normalizedSupportedEfforts
            state.supportsReasoningEffort = reasoningResponse.supportsReasoningEffort

            let workspaceResponse = try await client.workspaces()
            state.workspaceRoots = workspaceResponse.workspaces ?? []
            if state.currentWorkspace == nil {
                state.currentWorkspace = workspaceResponse.last ?? state.workspaceRoots.compactMap(\.path).first
            }
            state.workspaceSuggestions = state.workspaceRoots.compactMap(\.path)
        } catch {
            configurationError = error
        }

        do {
            state.agentCommands = (try await client.commands()).commands ?? []
        } catch {
            state.agentCommands = []
        }

        return ChatComposerConfigLoadResult(
            state: state,
            configurationError: configurationError
        )
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
