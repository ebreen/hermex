import Foundation

/// Neutral, actor-crossing profile projection. The recursive wire DTO remains
/// inside APIClient; only this immutable snapshot is consumed by UI and App
/// Intent callers.
struct CatalogProfileReadSnapshot: Equatable, Sendable {
    let metadata: CatalogEventMetadata
    let profiles: [ProfileSummary]
    let activeProfile: String
    let singleProfileMode: Bool
}

extension APIClient {
    /// Reads and strictly verifies profile context without issuing model
    /// requests. The returned metadata is the authoritative apply token.
    func profileContextSnapshot(
        operationID: UUID,
        operationGeneration: UInt64,
        telemetrySink: (any CatalogTelemetrySink)? = nil
    ) async -> CatalogProfileReadSnapshot {
        _ = telemetrySink
        do {
            let envelope = try await compatibilityProfiles(
                operationID: operationID,
                operationGeneration: operationGeneration
            )
            let response = envelope.value
            let profiles = response.profiles ?? []
            switch CatalogProfileVerifier.verify(
                profiles: profiles,
                explicitActive: response.active,
                singleProfileMode: response.singleProfileMode ?? false,
                requestedProfile: nil
            ) {
            case let .verified(activeProfile, singleProfileMode):
                return CatalogProfileReadSnapshot(
                    metadata: catalogMetadata(
                        operationID: operationID,
                        operationGeneration: operationGeneration,
                        gateKey: envelope.gateKey,
                        gateEpoch: envelope.gateEpoch,
                        activeProfile: activeProfile
                    ),
                    profiles: profiles,
                    activeProfile: activeProfile,
                    singleProfileMode: singleProfileMode
                )
            case .unavailable, .mismatch:
                return emptyProfileContextSnapshot(
                    operationID: operationID,
                    operationGeneration: operationGeneration,
                    gateKey: envelope.gateKey,
                    gateEpoch: envelope.gateEpoch
                )
            }
        } catch {
            let gateKey = ProfileContextGateKey(
                origin: NormalizedServerOrigin(url: baseURL),
                cookieContextID: cookieContextID
            )
            let gate = ProfileContextGateRegistry.shared.gate(for: gateKey)
            return emptyProfileContextSnapshot(
                operationID: operationID,
                operationGeneration: operationGeneration,
                gateKey: gateKey,
                gateEpoch: await gate.gateEpoch
            )
        }
    }

    /// Authoritative acceptance for a neutral profile/catalog result. The
    /// check is intentionally performed against the shared gate, not a
    /// caller's last-applied profile or local epoch copy.
    func acceptsCatalogMetadata(_ metadata: CatalogEventMetadata) async -> Bool {
        let gateKey: ProfileContextGateKey
        let epoch: UInt64
        switch metadata.identity {
        case let .provisional(key):
            guard key.gateKey == catalogGateKey,
                  key.apiClientID == apiClientID,
                  key.authGeneration == 0 else { return false }
            gateKey = key.gateKey
            epoch = key.startingGateEpoch
        case let .verified(key):
            guard key.gateKey == catalogGateKey,
                  key.apiClientID == apiClientID,
                  key.authGeneration == 0 else { return false }
            gateKey = key.gateKey
            epoch = key.gateEpoch
        }
        let gate = ProfileContextGateRegistry.shared.gate(for: gateKey)
        return await gate.gateEpoch == epoch
    }

    func acceptsCatalogSnapshot(_ result: CatalogSnapshotResult) async -> Bool {
        await acceptsCatalogMetadata(result.metadata)
    }

    /// Neutral base catalog read used by the direct (non-Chat coordinator)
    /// composer path. It retains the single profile phase and never issues a
    /// live request; the Chat coordinator's ordered stream remains the full
    /// base/live surface.
    func modelCatalogBaseSnapshot(
        requestedProfile: String? = nil,
        operationID: UUID,
        operationGeneration: UInt64,
        telemetrySink: (any CatalogTelemetrySink)? = nil
    ) async -> CatalogSnapshotResult {
        _ = telemetrySink
        let profileEnvelope: CatalogCompatibilityEnvelope<ProfilesResponse>
        do {
            profileEnvelope = try await compatibilityProfiles(
                operationID: operationID,
                operationGeneration: operationGeneration
            )
        } catch {
            return await failedCatalogSnapshot(
                operationID: operationID,
                operationGeneration: operationGeneration,
                category: .profileUnavailable
            )
        }

        let response = profileEnvelope.value
        let profiles = response.profiles ?? []
        let verification = CatalogProfileVerifier.verify(
            profiles: profiles,
            explicitActive: response.active,
            singleProfileMode: response.singleProfileMode ?? false,
            requestedProfile: requestedProfile
        )
        guard case let .verified(activeProfile, singleProfileMode) = verification else {
            let category: CatalogFailureCategory = verification == .mismatch
                ? .profileMismatch
                : .profileUnavailable
            return await failedCatalogSnapshot(
                operationID: operationID,
                operationGeneration: operationGeneration,
                gateKey: profileEnvelope.gateKey,
                gateEpoch: profileEnvelope.gateEpoch,
                category: category
            )
        }

        let metadata = catalogMetadata(
            operationID: operationID,
            operationGeneration: operationGeneration,
            gateKey: profileEnvelope.gateKey,
            gateEpoch: profileEnvelope.gateEpoch,
            activeProfile: activeProfile
        )
        let context = CatalogProfileContext(
            profiles: profiles,
            activeProfile: activeProfile,
            requestedProfile: requestedProfile,
            singleProfileMode: singleProfileMode,
            defaults: CatalogProfileDefaults(model: nil, workspace: nil),
            switchResult: .notRequested
        )

        do {
            let baseEnvelope = try await compatibilityModels(
                operationID: operationID,
                operationGeneration: operationGeneration
            )
            let base = CatalogBaseSnapshot(
                metadata: metadata,
                groups: baseEnvelope.value.groups,
                defaultModel: baseEnvelope.value.defaultModel,
                activeProvider: baseEnvelope.value.activeProvider
            )
            return CatalogSnapshotResult(
                metadata: metadata,
                context: context,
                base: base,
                live: nil,
                failure: nil
            )
        } catch {
            return CatalogSnapshotResult(
                metadata: metadata,
                context: context,
                base: nil,
                live: nil,
                failure: .transport
            )
        }
    }

    /// Base-only neutral read for a caller that has just completed the gated
    /// profile switch itself. It preserves the old request graph while still
    /// returning a Sendable, epoch-fenced projection.
    func modelCatalogBaseOnlySnapshot(
        operationID: UUID,
        operationGeneration: UInt64,
        activeProfile: String? = nil,
        telemetrySink: (any CatalogTelemetrySink)? = nil
    ) async -> CatalogSnapshotResult {
        _ = telemetrySink
        let gateKey = catalogGateKey
        let gate = ProfileContextGateRegistry.shared.gate(for: gateKey)
        let epoch = await gate.gateEpoch
        let metadata = catalogMetadata(
            operationID: operationID,
            operationGeneration: operationGeneration,
            gateKey: gateKey,
            gateEpoch: epoch,
            activeProfile: activeProfile
        )
        do {
            let envelope = try await compatibilityModels(
                operationID: operationID,
                operationGeneration: operationGeneration
            )
            let base = CatalogBaseSnapshot(
                metadata: metadata,
                groups: envelope.value.groups,
                defaultModel: envelope.value.defaultModel,
                activeProvider: envelope.value.activeProvider
            )
            return CatalogSnapshotResult(
                metadata: metadata,
                context: nil,
                base: base,
                live: nil,
                failure: nil
            )
        } catch {
            return CatalogSnapshotResult(
                metadata: metadata,
                context: nil,
                base: nil,
                live: nil,
                failure: .transport
            )
        }
    }

    private var catalogGateKey: ProfileContextGateKey {
        ProfileContextGateKey(
            origin: NormalizedServerOrigin(url: baseURL),
            cookieContextID: cookieContextID
        )
    }

    private func catalogMetadata(
        operationID: UUID,
        operationGeneration: UInt64,
        gateKey: ProfileContextGateKey,
        gateEpoch: UInt64,
        activeProfile: String?
    ) -> CatalogEventMetadata {
        let identity: CatalogEventIdentity
        if let activeProfile, !activeProfile.isEmpty {
            identity = .verified(
                CatalogContextKey(
                    gateKey: gateKey,
                    apiClientID: apiClientID,
                    authGeneration: 0,
                    activeProfile: activeProfile,
                    gateEpoch: gateEpoch
                )
            )
        } else {
            identity = .provisional(
                CatalogOperationKey(
                    gateKey: gateKey,
                    apiClientID: apiClientID,
                    authGeneration: 0,
                    requestedProfile: nil,
                    startingGateEpoch: gateEpoch
                )
            )
        }
        return CatalogEventMetadata(
            identity: identity,
            operationID: operationID,
            operationGeneration: operationGeneration
        )
    }

    private func emptyProfileContextSnapshot(
        operationID: UUID,
        operationGeneration: UInt64,
        gateKey: ProfileContextGateKey,
        gateEpoch: UInt64
    ) -> CatalogProfileReadSnapshot {
        CatalogProfileReadSnapshot(
            metadata: catalogMetadata(
                operationID: operationID,
                operationGeneration: operationGeneration,
                gateKey: gateKey,
                gateEpoch: gateEpoch,
                activeProfile: nil
            ),
            profiles: [],
            activeProfile: "",
            singleProfileMode: false
        )
    }

    private func failedCatalogSnapshot(
        operationID: UUID,
        operationGeneration: UInt64,
        gateKey: ProfileContextGateKey? = nil,
        gateEpoch: UInt64? = nil,
        category: CatalogFailureCategory
    ) async -> CatalogSnapshotResult {
        let key = gateKey ?? catalogGateKey
        let epoch: UInt64
        if let gateEpoch {
            epoch = gateEpoch
        } else {
            epoch = await ProfileContextGateRegistry.shared.gate(for: key).gateEpoch
        }
        let metadata = catalogMetadata(
            operationID: operationID,
            operationGeneration: operationGeneration,
            gateKey: key,
            gateEpoch: epoch,
            activeProfile: nil
        )
        return CatalogSnapshotResult(
            metadata: metadata,
            context: nil,
            base: nil,
            live: nil,
            failure: category
        )
    }

    func commands() async throws -> CommandsResponse {
        try await send(endpoint: .commands, method: "GET")
    }

    func saveDefaultModel(model: String) async throws -> DefaultModelResponse {
        try await send(
            endpoint: .defaultModel,
            method: "POST",
            body: DefaultModelRequest(model: model)
        )
    }

    /// Reasoning status for a specific model/provider (`GET /api/reasoning`).
    /// Passing the session's current model + provider makes `supported_efforts`
    /// model-accurate (mirrors the upstream WebUI composer chip, issue #18);
    /// with no params the server resolves the config default model instead.
    func reasoning(model: String? = nil, provider: String? = nil) async throws -> ReasoningStatusResponse {
        try await send(endpoint: .reasoning(model: model, provider: provider), method: "GET")
    }

    func saveReasoningEffort(_ effort: String) async throws -> ReasoningStatusResponse {
        try await send(
            endpoint: .reasoning(),
            method: "POST",
            body: ReasoningEffortRequest(effort: effort)
        )
    }

    func saveReasoningDisplay(_ display: String) async throws -> ReasoningStatusResponse {
        try await send(
            endpoint: .reasoning(),
            method: "POST",
            body: ReasoningDisplayRequest(display: display)
        )
    }

    func personalities() async throws -> PersonalitiesResponse {
        try await send(endpoint: .personalities, method: "GET")
    }

    func setPersonality(sessionID: String, name: String) async throws -> PersonalitySetResponse {
        try await send(
            endpoint: .setPersonality,
            method: "POST",
            body: PersonalitySetRequest(sessionId: sessionID, name: name)
        )
    }

    func profiles() async throws -> ProfilesResponse {
        try await send(endpoint: .profiles, method: "GET")
    }

    /// Switches the active server profile under the exclusive profile-context
    /// writer lease (issue #16 Slice 1).
    ///
    /// The writer first cancels coordinator-owned catalog readers (streams and
    /// compatibility adapters register a synchronous cancellation hook with
    /// the gate) so their held leases drain, then acquires the exclusive
    /// writer lease — which waits for every held reader, including held
    /// compatibility reads and held live children, to unwind — and only then
    /// dispatches the POST. The response is validated with the strict profile
    /// verifier; the gate epoch advances only after a validated success.
    /// Failed or canceled POSTs release the writer and wake queued readers,
    /// and a canceled writer never POSTs.
    func switchProfile(name: String) async throws -> ProfileSwitchResponse {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let gateKey = ProfileContextGateKey(
            origin: NormalizedServerOrigin(url: baseURL),
            cookieContextID: cookieContextID
        )
        let gate = ProfileContextGateRegistry.shared.gate(for: gateKey)
        let operationID = UUID()

        // Cancel coordinator-owned readers so their leases drain before the
        // POST. Re-snapshot after every round: a reader admitted between the
        // snapshot and its cancels must be cancelled by the next round, so a
        // held compatibility read can never slip through uncancelled. The
        // loop is bounded so pathological reader churn cannot spin forever;
        // readers that slip in after the last round are still unwound by the
        // exclusive lease below, which waits for every held reader.
        var drainRounds = 0
        var heldReaders = await gate.snapshot().heldReaders
        while !heldReaders.isEmpty && drainRounds < 8 {
            for readerID in heldReaders {
                await gate.cancel(operationID: readerID)
            }
            heldReaders = await gate.snapshot().heldReaders
            drainRounds += 1
        }

        // The exclusive writer lease. A canceled writer throws here and never
        // reaches the POST.
        let admission: CatalogLeaseAdmission
        do {
            admission = try await gate.acquireWriter(operationID: operationID)
        } catch {
            throw ProfileContextSwitchFailure.cancelled
        }

        do {
            guard !Task.isCancelled else {
                throw CancellationError()
            }
            let response: ProfileSwitchResponse = try await send(
                endpoint: .switchProfile,
                method: "POST",
                body: ProfileSwitchRequest(name: normalizedName)
            )
            let verification = CatalogProfileVerifier.verify(
                profiles: response.profiles ?? [],
                explicitActive: response.active,
                singleProfileMode: false,
                requestedProfile: normalizedName
            )
            guard case let .verified(activeProfile, _) = verification,
                  activeProfile == normalizedName else {
                throw ProfileContextSwitchFailure.rejected
            }
            // The validated switch is the only event that advances the gate
            // epoch; failed or canceled POSTs leave it untouched.
            await gate.advanceEpoch(operationID: operationID)
            await gate.releaseWriter(operationID: operationID, admission: admission)
            return response
        } catch {
            await gate.releaseWriter(operationID: operationID, admission: admission)
            throw Self.switchFailure(for: error)
        }
    }

    /// Creates a new profile (`POST /api/profile/create`), mirroring the webui's
    /// create form payload: `clone_config` is always sent, everything else only
    /// when provided (`clone_from` is intentionally omitted — the server clones
    /// from the active profile). Rejected with 403 in single-profile mode.
    func createProfile(
        name: String,
        cloneConfig: Bool = false,
        defaultModel: String? = nil,
        modelProvider: String? = nil,
        baseUrl: String? = nil,
        apiKey: String? = nil
    ) async throws -> ProfileCreateResponse {
        try await send(
            endpoint: .createProfile,
            method: "POST",
            body: ProfileCreateRequest(
                name: name,
                cloneConfig: cloneConfig,
                defaultModel: defaultModel,
                modelProvider: modelProvider,
                baseUrl: baseUrl,
                apiKey: apiKey
            )
        )
    }

    func providers() async throws -> ProvidersResponse {
        try await send(endpoint: .providers, method: "GET")
    }

    func settings() async throws -> SettingsResponse {
        try await send(endpoint: .settings, method: "GET")
    }

    /// Writes the single server-synced session-visibility key (#19):
    /// `POST /api/settings {"show_cli_sessions": <bool>}`. Upstream
    /// `save_settings(body)` merges exactly the keys sent — nothing else is
    /// touched — and responds with the full saved settings dict, so the
    /// response reuses `SettingsResponse`. A general settings editor stays
    /// out of scope.
    func updateSettings(showCliSessions: Bool) async throws -> SettingsResponse {
        try await send(
            endpoint: .settings,
            method: "POST",
            body: ShowCliSessionsUpdateRequest(showCliSessions: showCliSessions)
        )
    }

    /// Writes only the server-synced Claude Code session visibility key.
    func updateSettings(showClaudeCodeSessions: Bool) async throws -> SettingsResponse {
        try await send(
            endpoint: .settings,
            method: "POST",
            body: ShowClaudeCodeSessionsUpdateRequest(
                showClaudeCodeSessions: showClaudeCodeSessions
            )
        )
    }

    func updatesCheck() async throws -> UpdatesCheckResponse {
        try await send(endpoint: .updatesCheck, method: "GET")
    }

    /// Forces a *live* update check: `POST /api/updates/check` with `{ "force": true }`.
    /// Upstream runs a real `git fetch` for this path (`check_for_updates(force=True)`),
    /// whereas the plain GET only returns the cached status. Same response shape, so
    /// `UpdatesCheckResponse` is reused. Used by the manual "Check for updates" button (#308).
    func updatesCheckForced() async throws -> UpdatesCheckResponse {
        try await send(
            endpoint: .updatesCheck,
            method: "POST",
            body: UpdatesCheckForceRequest(force: true)
        )
    }

    /// Applies a pending repo update. The server pulls `--ff-only` and then
    /// restarts itself, so the caller must tolerate a brief connection outage
    /// and re-poll afterwards. Defaults to the `webui` target (issue #180 scope;
    /// no `agent` target, `/force`, or `/summary`).
    func applyUpdate(target: String = "webui") async throws -> UpdatesApplyResponse {
        try await send(
            endpoint: .updatesApply,
            method: "POST",
            body: UpdatesApplyRequest(target: target)
        )
    }

    func insights(days: Int) async throws -> InsightsResponse {
        try await send(endpoint: .insights(days: days), method: "GET")
    }

    /// Maps a switch POST failure onto the fixed switch failure category.
    /// Cancellation (task or transport) is detected before any APIError
    /// mapping so a canceled POST never surfaces as a transport failure.
    private static func switchFailure(for error: Error) -> ProfileContextSwitchFailure {
        if let failure = error as? ProfileContextSwitchFailure {
            return failure
        }
        if Task.isCancelled || isSwitchCancellation(error) {
            return .cancelled
        }
        guard let apiError = error as? APIError else {
            return .transport
        }
        switch apiError {
        case .unauthorized:
            return .unauthorized
        case .http:
            return .rejected
        case .decoding:
            return .decoding
        case .network:
            return .transport
        case .invalidServerURL:
            return .transport
        }
    }

    private static func isSwitchCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        if case let APIError.network(underlying) = error {
            return isSwitchCancellation(underlying)
        }
        return false
    }
}

private struct DefaultModelRequest: Encodable {
    let model: String
}

private struct ReasoningEffortRequest: Encodable {
    let effort: String
}

private struct ReasoningDisplayRequest: Encodable {
    let display: String
}

private struct PersonalitySetRequest: Encodable {
    let sessionId: String
    let name: String
}

private struct ProfileSwitchRequest: Encodable {
    let name: String
}

private struct ProfileCreateRequest: Encodable {
    let name: String
    let cloneConfig: Bool
    let defaultModel: String?
    let modelProvider: String?
    let baseUrl: String?
    let apiKey: String?
}

private struct UpdatesApplyRequest: Encodable {
    let target: String
}

private struct UpdatesCheckForceRequest: Encodable {
    let force: Bool
}

private struct ShowCliSessionsUpdateRequest: Encodable {
    // Encoded as `show_cli_sessions` via the client's convertToSnakeCase strategy.
    let showCliSessions: Bool
}

private struct ShowClaudeCodeSessionsUpdateRequest: Encodable {
    // Encoded as `show_claude_code_sessions` by convertToSnakeCase.
    let showClaudeCodeSessions: Bool
}
