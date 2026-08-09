import Foundation

// MARK: - Cookie and request-context identity

enum CatalogCookieContextID: Hashable, Sendable {
    case shared
    case injected(UUID)
}

struct NormalizedServerOrigin: Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init(scheme: String, host: String, port: Int) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port
    }

    init(url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        let port: Int
        if let explicitPort = url.port {
            port = explicitPort
        } else {
            switch scheme {
            case "http":
                port = 80
            case "https":
                port = 443
            default:
                port = 0
            }
        }

        self.init(
            scheme: scheme,
            host: url.host?.lowercased() ?? "",
            port: port
        )
    }
}

struct ProfileContextGateKey: Hashable, Sendable {
    let origin: NormalizedServerOrigin
    let cookieContextID: CatalogCookieContextID
}

struct CatalogOperationKey: Hashable, Sendable {
    let gateKey: ProfileContextGateKey
    let apiClientID: UUID
    let authGeneration: UInt64
    let requestedProfile: String?
    let startingGateEpoch: UInt64
}

struct CatalogContextKey: Hashable, Sendable {
    let gateKey: ProfileContextGateKey
    let apiClientID: UUID
    let authGeneration: UInt64
    let activeProfile: String
    let gateEpoch: UInt64
}

enum CatalogEventIdentity: Equatable, Sendable {
    case provisional(CatalogOperationKey)
    case verified(CatalogContextKey)
}

struct CatalogEventMetadata: Equatable, Sendable {
    let identity: CatalogEventIdentity
    let operationID: UUID
    let operationGeneration: UInt64
}

// MARK: - Profile projection

struct CatalogProfileDefaults: Equatable, Sendable {
    let model: String?
    let workspace: String?
}

enum CatalogProfileSwitchResult: Equatable, Sendable {
    case notRequested
    case alreadyActive
    case switched(defaults: CatalogProfileDefaults)
}

struct CatalogProfileContext: Equatable, Sendable {
    let profiles: [ProfileSummary]
    let activeProfile: String
    let requestedProfile: String?
    let singleProfileMode: Bool
    let defaults: CatalogProfileDefaults
    let switchResult: CatalogProfileSwitchResult
}

// MARK: - Sendable catalog projections

struct CatalogBaseSnapshot: Equatable, Sendable {
    let metadata: CatalogEventMetadata
    let groups: [ModelCatalogGroup]
    let defaultModel: String?
    let activeProvider: String?
}

struct CatalogLiveSnapshot: Equatable, Sendable {
    let metadata: CatalogEventMetadata
    let groups: [ModelCatalogGroup]
    let provider: String?
}

enum CatalogPhase: Equatable, Sendable {
    case context
    case models
    case live
}

enum CatalogCacheState: Equatable, Sendable {
    case cold
    case loading
    case freshReady
    case freshEmpty
    case staleRefreshing
    case staleFailed
    case coldFailed(CatalogFailureCategory)
}

enum CatalogFailureCategory: Error, Equatable, Sendable {
    case profileUnavailable
    case profileSwitchRejected
    case profileMismatch
    case unknownContext
    case transport
    case unauthorized
    case http
    case decoding
    case providerMismatch
    case cancelled
}

enum CatalogNetworkEvent: Equatable, Sendable {
    case contextVerified(CatalogEventMetadata, CatalogProfileContext)
    case base(CatalogBaseSnapshot)
    case live(CatalogLiveSnapshot)
    case liveFailed(CatalogEventMetadata, CatalogFailureCategory)
    case failed(CatalogEventMetadata, CatalogPhase, CatalogFailureCategory)
    case finished(CatalogEventMetadata)
    case cancelled(CatalogEventMetadata)
}

struct CatalogSnapshotResult: Equatable, Sendable {
    let metadata: CatalogEventMetadata
    let context: CatalogProfileContext?
    let base: CatalogBaseSnapshot?
    let live: CatalogLiveSnapshot?
    let failure: CatalogFailureCategory?
}

// MARK: - Fixed, local telemetry schema

protocol CatalogTelemetrySink: Sendable {
    func emit(_ event: CatalogTelemetryEvent)
}

struct CatalogLeaseAdmissionMetadata: Equatable, Sendable {
    let admissionID: UUID
    let gateEpoch: UInt64
}

enum CatalogTelemetrySurface: String, Equatable, Sendable {
    case context
    case models
    case live
    case picker
}

enum CatalogTelemetryPhase: String, Equatable, Sendable {
    case gateWaitStarted
    case gateAcquired
    case childRequestStarted
    case wireStarted
    case decodeStarted
    case ended
    case pickerActionStarted
    case sheetVisible
    case usefulRow
    case empty
    case failed
    case cancelled
}

enum CatalogTelemetryOutcome: Equatable, Sendable {
    case success
    case failure(CatalogFailureCategory)
    case cancelled
}

struct CatalogTelemetryEvent: Equatable, Sendable {
    let surface: CatalogTelemetrySurface
    let phase: CatalogTelemetryPhase
    let outcome: CatalogTelemetryOutcome?
    let cacheState: CatalogCacheState?
    let durationMilliseconds: Int?
    let ageMilliseconds: Int?
    let groupCount: Int?
    let rowCount: Int?
    let openToken: UUID?
    let requestToken: UUID?
    let operationID: UUID
    let admission: CatalogLeaseAdmissionMetadata?
}

// MARK: - Slice 0 neutral APIClient surface

extension APIClient {
    func modelCatalogStream(
        requestedProfile: String?,
        operationID: UUID,
        operationGeneration: UInt64,
        telemetrySink: (any CatalogTelemetrySink)? = nil
    ) -> AsyncStream<CatalogNetworkEvent> {
        let metadata = catalogProvisionalMetadata(
            requestedProfile: requestedProfile,
            operationID: operationID,
            operationGeneration: operationGeneration
        )

        let effectiveTelemetrySink = telemetrySink ?? catalogTelemetrySink
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                await self.runModelCatalogStream(
                    metadata: metadata,
                    continuation: continuation,
                    telemetrySink: effectiveTelemetrySink
                )
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func modelCatalogSnapshot(
        requestedProfile: String?,
        operationID: UUID,
        operationGeneration: UInt64,
        telemetrySink: (any CatalogTelemetrySink)? = nil
    ) async -> CatalogSnapshotResult {
        let provisionalMetadata = catalogProvisionalMetadata(
            requestedProfile: requestedProfile,
            operationID: operationID,
            operationGeneration: operationGeneration
        )
        let stream = modelCatalogStream(
            requestedProfile: requestedProfile,
            operationID: operationID,
            operationGeneration: operationGeneration,
            telemetrySink: telemetrySink
        )

        var metadata = provisionalMetadata
        var context: CatalogProfileContext?
        var base: CatalogBaseSnapshot?
        var live: CatalogLiveSnapshot?
        var failure: CatalogFailureCategory?

        for await event in stream {
            switch event {
            case let .contextVerified(eventMetadata, value):
                metadata = eventMetadata
                context = value
            case let .base(value):
                metadata = value.metadata
                base = value
            case let .live(value):
                metadata = value.metadata
                live = value
            case let .liveFailed(eventMetadata, category):
                metadata = eventMetadata
                failure = category
            case let .failed(eventMetadata, _, category):
                metadata = eventMetadata
                failure = category
                return CatalogSnapshotResult(
                    metadata: metadata,
                    context: context,
                    base: base,
                    live: live,
                    failure: failure
                )
            case let .finished(eventMetadata):
                metadata = eventMetadata
                return CatalogSnapshotResult(
                    metadata: metadata,
                    context: context,
                    base: base,
                    live: live,
                    failure: failure
                )
            case let .cancelled(eventMetadata):
                metadata = eventMetadata
                failure = .cancelled
                return CatalogSnapshotResult(
                    metadata: metadata,
                    context: context,
                    base: base,
                    live: live,
                    failure: failure
                )
            }
        }

        return CatalogSnapshotResult(
            metadata: metadata,
            context: context,
            base: base,
            live: live,
            failure: failure
        )
    }
}

private extension APIClient {
    func catalogProvisionalMetadata(
        requestedProfile: String?,
        operationID: UUID,
        operationGeneration: UInt64
    ) -> CatalogEventMetadata {
        let normalizedProfile = requestedProfile
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let gateKey = ProfileContextGateKey(
            origin: NormalizedServerOrigin(url: baseURL),
            cookieContextID: cookieContextID
        )
        let operationKey = CatalogOperationKey(
            gateKey: gateKey,
            apiClientID: apiClientID,
            authGeneration: 0,
            requestedProfile: normalizedProfile,
            startingGateEpoch: 0
        )
        return CatalogEventMetadata(
            identity: .provisional(operationKey),
            operationID: operationID,
            operationGeneration: operationGeneration
        )
    }

    func runModelCatalogStream(
        metadata: CatalogEventMetadata,
        continuation: AsyncStream<CatalogNetworkEvent>.Continuation,
        telemetrySink: (any CatalogTelemetrySink)?
    ) async {
        _ = telemetrySink
        var didFinish = false

        func finish(with event: CatalogNetworkEvent) {
            guard !didFinish else { return }
            didFinish = true
            continuation.yield(event)
            continuation.finish()
        }

        if Task.isCancelled {
            finish(with: .cancelled(metadata))
            return
        }

        // Slice 0 deliberately uses provisional metadata and does not resolve or
        // switch profiles. Slice 1 owns the strict profile phase and gate lease.
        let baseResult = await fetchCatalogData(endpoint: .models)
        var baseSnapshot: CatalogBaseSnapshot?
        var baseFailure: CatalogFailureCategory?

        switch baseResult {
        case let .success(data):
            do {
                baseSnapshot = try decodeCatalogBaseSnapshot(
                    data: data,
                    metadata: metadata
                )
            } catch {
                baseFailure = catalogFailure(for: error)
            }
        case let .failure(category):
            baseFailure = category
        }

        if let baseFailure {
            if baseFailure == .cancelled || Task.isCancelled {
                finish(with: .cancelled(metadata))
            } else {
                finish(with: .failed(metadata, .models, baseFailure))
            }
            return
        }

        guard let baseSnapshot else {
            finish(with: .failed(metadata, .models, .decoding))
            return
        }
        continuation.yield(.base(baseSnapshot))

        let liveResult = await fetchCatalogData(endpoint: .modelsLive)

        switch liveResult {
        case let .success(data):
            do {
                let liveSnapshot = try decodeCatalogLiveSnapshot(
                    data: data,
                    baseGroups: baseSnapshot.groups,
                    metadata: metadata
                )
                continuation.yield(.live(liveSnapshot))
                finish(with: .finished(metadata))
            } catch {
                let category = catalogFailure(for: error)
                if category == .cancelled || Task.isCancelled {
                    finish(with: .cancelled(metadata))
                } else {
                    continuation.yield(.liveFailed(metadata, category))
                    finish(with: .finished(metadata))
                }
            }
        case let .failure(category):
            if category == .cancelled || Task.isCancelled {
                finish(with: .cancelled(metadata))
            } else {
                continuation.yield(.liveFailed(metadata, category))
                finish(with: .finished(metadata))
            }
        }
    }

    func fetchCatalogData(endpoint: Endpoint) async -> Result<Data, CatalogFailureCategory> {
        do {
            return .success(try await sendData(endpoint: endpoint, method: "GET"))
        } catch {
            return .failure(catalogFailure(for: error))
        }
    }

    func catalogFailure(for error: Error) -> CatalogFailureCategory {
        if Task.isCancelled || isCatalogCancellation(error) {
            return .cancelled
        }

        guard let apiError = error as? APIError else {
            return .transport
        }

        switch apiError {
        case .unauthorized:
            return .unauthorized
        case .http:
            return .http
        case .decoding:
            return .decoding
        case .network:
            return .transport
        case .invalidServerURL:
            return .transport
        }
    }

    func isCatalogCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        if case let APIError.network(underlying) = error {
            return isCatalogCancellation(underlying)
        }
        return false
    }
}
