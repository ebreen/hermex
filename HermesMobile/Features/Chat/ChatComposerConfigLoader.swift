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
    let configurationFailure: ChatComposerConfigFailure?
}

struct ChatComposerConfigLoader {
    private let client: APIClient

    init(client: APIClient) {
        self.client = client; self.catalogEvents = nil; self.onCatalogReady = nil
    }

    func loadConfigurationFromClient(from initialState: ChatComposerConfigState) async -> ChatComposerConfigLoadResult {
        var state = initialState
        var configurationError: Error?
        var selectedProfile: ProfileSummary?
        let operationID = UUID()
        let operationGeneration: UInt64 = 1

        // The coordinator-backed initializer consumes the ordered
        // `modelCatalogStream`; this direct compatibility-free path uses the
        // same Networking-owned Sendable projections when no coordinator is
        // injected (legacy callers still retain their request ordering).
        let requestedProfile = Self.nonEmpty(state.currentProfile)
        var catalogResult: CatalogSnapshotResult?

        if let requestedProfile {
            let profileSnapshot = await client.profileContextSnapshot(
                operationID: operationID,
                operationGeneration: operationGeneration
            )
            guard await client.acceptsCatalogMetadata(profileSnapshot.metadata) else {
                configurationError = NSError(
                    domain: "ChatComposerConfigLoader",
                    code: ChatComposerConfigFailure.profileUnavailable.code,
                    userInfo: [NSLocalizedDescriptionKey: ChatComposerConfigFailure.profileUnavailable.localizedDescription]
                )
                return await finishDirectLoad(
                    state: state,
                    configurationError: configurationError,
                    client: client
                )
            }

            state.profileOptions = profileSnapshot.profiles
            state.isSingleProfileMode = profileSnapshot.singleProfileMode
            state.selectedProfileName = requestedProfile
            selectedProfile = Self.profileSummary(matching: requestedProfile, in: state.profileOptions)
            if state.currentModel == nil {
                state.currentModel = Self.nonEmpty(selectedProfile?.model)
            }

            if profileSnapshot.activeProfile != requestedProfile {
                do {
                    let switchResponse = try await client.switchProfile(name: requestedProfile)
                    state.profileOptions = switchResponse.profiles ?? state.profileOptions
                    state.selectedProfileName = Self.nonEmpty(switchResponse.active) ?? requestedProfile
                    state.currentProfile = state.selectedProfileName
                    if state.currentWorkspace == nil {
                        state.currentWorkspace = Self.nonEmpty(switchResponse.defaultWorkspace)
                    }
                    if state.currentModel == nil {
                        state.currentModel = Self.nonEmpty(switchResponse.defaultModel)
                    }
                } catch {
                    configurationError = error
                }
            }

            if configurationError == nil {
                catalogResult = await client.modelCatalogBaseOnlySnapshot(
                    operationID: operationID,
                    operationGeneration: operationGeneration,
                    activeProfile: state.selectedProfileName
                )
            }
        } else {
            catalogResult = await client.modelCatalogBaseSnapshot(
                requestedProfile: nil,
                operationID: operationID,
                operationGeneration: operationGeneration
            )
        }

        if let catalogResult {
            guard await client.acceptsCatalogSnapshot(catalogResult) else {
                configurationError = NSError(
                    domain: "ChatComposerConfigLoader",
                    code: ChatComposerConfigFailure.catalogUnavailable.code,
                    userInfo: [NSLocalizedDescriptionKey: ChatComposerConfigFailure.catalogUnavailable.localizedDescription]
                )
            }

            if configurationError == nil, let context = catalogResult.context {
                state.profileOptions = context.profiles
                state.isSingleProfileMode = context.singleProfileMode
                state.selectedProfileName = Self.nonEmpty(state.currentProfile)
                    ?? Self.nonEmpty(context.activeProfile)
                    ?? context.requestedProfile
                selectedProfile = Self.profileSummary(
                    matching: state.selectedProfileName,
                    in: state.profileOptions
                )
                if state.currentModel == nil {
                    state.currentModel = Self.nonEmpty(selectedProfile?.model)
                }
            }

            if configurationError == nil, let base = catalogResult.base {
                state.modelCatalogGroups = base.groups
                if state.currentModel == nil {
                    state.currentModel = base.defaultModel
                }
                if Self.nonEmpty(state.currentModelProvider) == nil {
                    state.currentModelProvider = Self.nonEmpty(selectedProfile?.provider)
                        ?? Self.uniqueProvider(for: state.currentModel, in: state.modelCatalogGroups)
                }
                if let failure = catalogResult.failure {
                    configurationError = Self.error(for: failure)
                }
            } else if configurationError == nil {
                configurationError = Self.error(for: catalogResult.failure ?? .transport)
            }
        }

        if configurationError == nil {
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
            }

            do {
                let workspaceResponse = try await client.workspaces()
                state.workspaceRoots = workspaceResponse.workspaces ?? []
                if state.currentWorkspace == nil {
                    state.currentWorkspace = workspaceResponse.last ?? state.workspaceRoots.compactMap(\.path).first
                }
                state.workspaceSuggestions = state.workspaceRoots.compactMap(\.path)
            } catch {
                if configurationError == nil { configurationError = error }
            }
        }

        return await finishDirectLoad(
            state: state,
            configurationError: configurationError,
            client: client
        )
    }

    private func finishDirectLoad(
        state: ChatComposerConfigState,
        configurationError: Error?,
        client: APIClient
    ) async -> ChatComposerConfigLoadResult {
        var state = state
        do {
            state.agentCommands = (try await client.commands()).commands ?? []
        } catch {
            state.agentCommands = []
        }
        return ChatComposerConfigLoadResult(
            state: state,
            configurationFailure: Self.failureCategory(from: configurationError)
        )
    }

    private static func error(for failure: CatalogFailureCategory) -> Error {
        switch failure {
        case .profileUnavailable, .unknownContext:
            return NSError(domain: "ChatComposerConfigLoader", code: ChatComposerConfigFailure.profileUnavailable.code, userInfo: [NSLocalizedDescriptionKey: ChatComposerConfigFailure.profileUnavailable.localizedDescription])
        case .profileSwitchRejected:
            return NSError(domain: "ChatComposerConfigLoader", code: ChatComposerConfigFailure.profileSwitchRejected.code, userInfo: [NSLocalizedDescriptionKey: ChatComposerConfigFailure.profileSwitchRejected.localizedDescription])
        default:
            return NSError(domain: "ChatComposerConfigLoader", code: ChatComposerConfigFailure.catalogUnavailable.code, userInfo: [NSLocalizedDescriptionKey: ChatComposerConfigFailure.catalogUnavailable.localizedDescription])
        }
    }

    private static func failureCategory(from error: Error?) -> ChatComposerConfigFailure? {
        guard let error else { return nil }
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        if message.localizedCaseInsensitiveContains("profile") {
            if message.localizedCaseInsensitiveContains("switch") {
                return .profileSwitchRejected
            }
            return .profileUnavailable
        }
        if message.localizedCaseInsensitiveContains("reasoning") {
            return .reasoningUnavailable
        }
        if message.localizedCaseInsensitiveContains("workspace") || message.localizedCaseInsensitiveContains("command") {
            return .workspacesUnavailable
        }
        return .catalogUnavailable
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

    // MARK: Slice 3 catalog path (#16)

    private let catalogEvents: AsyncStream<CatalogEvent>?
    private let onCatalogReady: (@MainActor @Sendable (CatalogBaseSnapshot) -> Void)?

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

    private func loadConfigurationFromCatalog(
        from initialState: ChatComposerConfigState,
        catalogEvents: AsyncStream<CatalogEvent>,
        onCatalogReady: @escaping @MainActor @Sendable (CatalogBaseSnapshot) -> Void
    ) async -> ChatComposerConfigLoadResult {
        var state = initialState
        var configurationFailure: ChatComposerConfigFailure?

        // The coordinator's ordered stream is the single catalog authority.
        // The narrow callback carries only the Sendable base projection and is
        // invoked exactly once, immediately after parsing/defaulting and
        // before any reasoning request is awaited.
        var publishedSnapshot: CatalogBaseSnapshot?
        var sawContextVerified = false
        var sawBase = false
        for await event in catalogEvents {
            switch event {
            case let .contextVerified(_, context):
                sawContextVerified = true
                state.profileOptions = context.profiles
                state.selectedProfileName = Self.nonEmpty(state.currentProfile)
                    ?? Self.nonEmpty(context.activeProfile)
                    ?? context.requestedProfile
                state.isSingleProfileMode = context.singleProfileMode
                state.currentProfile = state.selectedProfileName
                if state.currentWorkspace == nil {
                    state.currentWorkspace = Self.nonEmpty(context.defaults.workspace)
                }
                if state.currentModel == nil {
                    state.currentModel = Self.nonEmpty(context.defaults.model)
                }
            case let .base(snapshot):
                sawBase = true
                state.modelCatalogGroups = snapshot.groups
                if state.currentModel == nil {
                    state.currentModel = snapshot.defaultModel
                }
                if Self.nonEmpty(state.currentModelProvider) == nil {
                    state.currentModelProvider = Self.nonEmpty(snapshot.activeProvider)
                        ?? Self.uniqueProvider(for: state.currentModel, in: state.modelCatalogGroups)
                }
                publishedSnapshot = snapshot
            case .live, .liveFailed, .failed, .finished, .cancelled, .contextReset, .state:
                break
            }
            if sawContextVerified, sawBase {
                break
            }
        }

        if let publishedSnapshot {
            await MainActor.run {
                onCatalogReady(publishedSnapshot)
            }
        } else {
            configurationFailure = .catalogUnavailable
        }

        // Preserve the established ordering: reasoning → workspaces →
        // commands (issue #18). The catalog phase is complete by now.
        do {
            let reasoningResponse = try await client.reasoning(
                model: Self.nonEmpty(state.currentModel),
                provider: Self.nonEmpty(state.currentModelProvider)
            )
            state.selectedReasoningEffort = reasoningResponse.effectiveEffort
            state.supportedReasoningEfforts = reasoningResponse.normalizedSupportedEfforts
            state.supportsReasoningEffort = reasoningResponse.supportsReasoningEffort
        } catch {
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
            if configurationFailure == nil {
                configurationFailure = .workspacesUnavailable
            }
        }

        do {
            let commandsResponse = try await client.commands()
            state.agentCommands = commandsResponse.commands ?? []
        } catch {
            if configurationFailure == nil {
                configurationFailure = .workspacesUnavailable
            }
        }

        return ChatComposerConfigLoadResult(
            state: state,
            configurationFailure: configurationFailure
        )
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

/// Fixed Sendable failure categories for composer configuration loading
/// (Slice 3, #16). The Sendable result never carries a raw `Error`.
enum ChatComposerConfigFailure: Equatable, Sendable {
    case profileUnavailable
    case profileSwitchRejected
    case catalogUnavailable
    case reasoningUnavailable
    case workspacesUnavailable

    var code: Int {
        switch self {
        case .profileUnavailable: return 1
        case .profileSwitchRejected: return 2
        case .catalogUnavailable: return 3
        case .reasoningUnavailable: return 4
        case .workspacesUnavailable: return 5
        }
    }

    var localizedDescription: String {
        switch self {
        case .profileUnavailable: return "Profile catalog is unavailable."
        case .profileSwitchRejected: return "Profile switch was rejected."
        case .catalogUnavailable: return "Model catalog is unavailable."
        case .reasoningUnavailable: return "Reasoning configuration is unavailable."
        case .workspacesUnavailable: return "Workspace configuration is unavailable."
        }
    }
}

extension ChatComposerConfigLoadResult {
    /// Compatibility projection for pre-Slice-3 consumers. The Sendable
    /// result never carries a raw `Error` (v14 §310-330).
    var configurationError: Error? {
        configurationFailure.map { failure in
            NSError(
                domain: "ChatComposerConfigLoader",
                code: failure.code,
                userInfo: [NSLocalizedDescriptionKey: failure.localizedDescription]
            )
        }
    }
}
