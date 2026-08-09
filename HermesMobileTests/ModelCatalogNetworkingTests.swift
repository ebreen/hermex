import Foundation
import XCTest
@testable import HermesMobile

final class ModelCatalogNetworkingTests: XCTestCase {
    func testActorBoundaryEmitsOnlySendableCatalogProjections() async throws {
        requireSendable(AsyncStream<CatalogNetworkEvent>.self)
        requireSendable(CatalogNetworkEvent.self)
        requireSendable(CatalogBaseSnapshot.self)
        requireSendable(CatalogLiveSnapshot.self)
        requireSendable(CatalogSnapshotResult.self)
        requireSendable(CatalogEventMetadata.self)
        requireSendable(CatalogProfileContext.self)
        requireSendable(CatalogCookieContextID.self)
        requireSendable(NormalizedServerOrigin.self)
        requireSendable(ProfileContextGateKey.self)
        requireSendable(CatalogOperationKey.self)
        requireSendable(CatalogContextKey.self)
        requireSendable(CatalogEventIdentity.self)

        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installStandardCatalogResponses()
        let client = fixture.makeClient()
        let operationID = UUID()
        let stream = await client.modelCatalogStream(
            requestedProfile: nil,
            operationID: operationID,
            operationGeneration: 1
        )
        let events = await collectEvents(from: stream)
        let snapshot = await client.modelCatalogSnapshot(
            requestedProfile: nil,
            operationID: UUID(),
            operationGeneration: 2
        )

        var base: CatalogBaseSnapshot?
        var live: CatalogLiveSnapshot?
        for event in events {
            requireSendable(type(of: event))
            switch event {
            case let .contextVerified(metadata, context):
                requireSendable(type(of: metadata))
                requireSendable(type(of: context))
            case let .base(value):
                requireSendable(type(of: value))
                requireSendable(type(of: value.metadata))
                base = value
            case let .live(value):
                requireSendable(type(of: value))
                requireSendable(type(of: value.metadata))
                live = value
            case let .liveFailed(metadata, category):
                requireSendable(type(of: metadata))
                requireSendable(type(of: category))
            case let .failed(metadata, phase, category):
                requireSendable(type(of: metadata))
                requireSendable(type(of: phase))
                requireSendable(type(of: category))
            case let .finished(metadata), let .cancelled(metadata):
                requireSendable(type(of: metadata))
            }
        }

        let baseValue = try XCTUnwrap(base)
        let liveValue = try XCTUnwrap(live)
        XCTAssertEqual(baseValue.metadata.operationID, operationID)
        XCTAssertEqual(baseValue.defaultModel, "gpt-5")
        XCTAssertEqual(baseValue.activeProvider, "openai")
        XCTAssertEqual(baseValue.groups.first?.providerID, "openai")
        XCTAssertEqual(baseValue.groups.first?.models.first?.id, "gpt-5")
        XCTAssertEqual(liveValue.provider, "openai")
        XCTAssertEqual(liveValue.groups.first?.models.first?.id, "gpt-5-mini")
        XCTAssertEqual(snapshot.base?.groups.first?.models.first?.id, "gpt-5")
        XCTAssertEqual(snapshot.live?.groups.first?.models.first?.id, "gpt-5-mini")
        XCTAssertNil(snapshot.failure)
    }

    func testActorBoundaryDoesNotExposeRecursiveDTO() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installStandardCatalogResponses()
        let client = fixture.makeClient()

        let stream = await client.modelCatalogStream(
            requestedProfile: nil,
            operationID: UUID(),
            operationGeneration: 1
        )
        let events = await collectEvents(from: stream)
        let snapshot = await client.modelCatalogSnapshot(
            requestedProfile: nil,
            operationID: UUID(),
            operationGeneration: 2
        )

        XCTAssertTrue(events.contains { event in
            if case .base(_) = event { return true }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .live(_) = event { return true }
            return false
        })
        XCTAssertNotNil(snapshot.base)
        XCTAssertNotNil(snapshot.live)
        requireSendable(CatalogNetworkEvent.self)
        requireSendable(CatalogSnapshotResult.self)
    }

    func testModelsAndLiveRequestsRemainParameterlessGETs() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installStandardCatalogResponses()
        let client = fixture.makeClient()

        let stream = await client.modelCatalogStream(
            requestedProfile: nil,
            operationID: UUID(),
            operationGeneration: 1
        )
        _ = await collectEvents(from: stream)

        let modelRequests = fixture.requests().filter { request in
            request.url?.path == "/api/models" || request.url?.path == "/api/models/live"
        }
        XCTAssertEqual(modelRequests.count, 2)
        for request in modelRequests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.httpBodyStream)
        }
        XCTAssertEqual(
            Set(modelRequests.compactMap { $0.url?.path }),
            Set(["/api/models", "/api/models/live"])
        )
    }

    func testOmittedSessionUsesSharedCookieContext() {
        let baseURL = URL(string: "https://EXAMPLE.test:443/catalog")!
        let client = APIClient(baseURL: baseURL)
        let secondClient = APIClient(baseURL: URL(string: "https://example.test")!)

        XCTAssertEqual(client.cookieContextID, CatalogCookieContextID.shared)
        XCTAssertEqual(secondClient.cookieContextID, CatalogCookieContextID.shared)
    }

    func testDefaultSessionForcesSharedCookieContextWhenIsolatedTokenIsPassed() {
        let isolatedToken = CatalogCookieContextID.injected(UUID())
        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            cookieContextID: isolatedToken
        )

        XCTAssertEqual(client.cookieContextID, CatalogCookieContextID.shared)
        XCTAssertNotEqual(client.cookieContextID, isolatedToken)
    }

    func testInjectedSessionGetsFreshIsolatedCookieContext() {
        let fixture = IsolatedCatalogURLProtocolFixture()
        let first = fixture.makeClient()
        let second = fixture.makeClient()

        XCTAssertNotEqual(first.cookieContextID, CatalogCookieContextID.shared)
        XCTAssertNotEqual(second.cookieContextID, CatalogCookieContextID.shared)
        XCTAssertNotEqual(first.cookieContextID, second.cookieContextID)
        assertInjected(first.cookieContextID)
        assertInjected(second.cookieContextID)
    }

    func testExplicitStableTokenSharesInjectedCookieContext() {
        let fixture = IsolatedCatalogURLProtocolFixture()
        let stableToken = CatalogCookieContextID.injected(UUID())
        let first = fixture.makeClient(cookieContextID: stableToken)
        let second = fixture.makeClient(cookieContextID: stableToken)
        let independentlyInjected = fixture.makeClient()

        XCTAssertEqual(first.cookieContextID, stableToken)
        XCTAssertEqual(second.cookieContextID, stableToken)
        XCTAssertEqual(first.cookieContextID, second.cookieContextID)
        XCTAssertNotEqual(independentlyInjected.cookieContextID, stableToken)

        let sharedOrigin = NormalizedServerOrigin(
            scheme: "https",
            host: "example.test",
            port: 443
        )
        let alternatePort = NormalizedServerOrigin(
            scheme: "https",
            host: "example.test",
            port: 8443
        )
        let sharedKey = ProfileContextGateKey(
            origin: sharedOrigin,
            cookieContextID: stableToken
        )
        let alternatePortKey = ProfileContextGateKey(
            origin: alternatePort,
            cookieContextID: stableToken
        )
        XCTAssertNotEqual(sharedKey, alternatePortKey)
        requireSendable(type(of: sharedKey))
    }

    func testStrictConcurrencyPBXBoundaryIsExact() throws {
        guard let root = repositoryRoot(startingAt: #filePath) else {
            XCTFail("Could not locate the repository by walking upward from #filePath")
            return
        }
        let pbxURL = root
            .appendingPathComponent("HermesMobile.xcodeproj", isDirectory: true)
            .appendingPathComponent("project.pbxproj")
        let pbx = try String(contentsOf: pbxURL, encoding: .utf8)

        let objectIDs = captureAll(
            pattern: #"(?m)^\t\t([0-9A-F]{24})(?:\s*/\*.*?\*/)?\s*="#,
            in: pbx
        )
        XCTAssertEqual(objectIDs.count, Set(objectIDs).count, "PBX object IDs must be globally unique")

        assertPBXMembership(
            fileName: "ModelCatalogNetworkingTests.swift",
            groupName: "HermesMobileTests",
            targetName: "HermesMobileTests",
            in: pbx
        )

        let productionFile = root
            .appendingPathComponent("HermesMobile", isDirectory: true)
            .appendingPathComponent("Networking", isDirectory: true)
            .appendingPathComponent("ModelCatalogNetworking.swift")
        if FileManager.default.fileExists(atPath: productionFile.path)
            || pbx.contains("/* ModelCatalogNetworking.swift") {
            assertPBXMembership(
                fileName: "ModelCatalogNetworking.swift",
                groupName: "Networking",
                targetName: "HermesMobile",
                in: pbx
            )
        }
    }

    func testSliceZeroLegacyDTOCallerInventoryDoesNotGrow() throws {
        guard let root = repositoryRoot(startingAt: #filePath) else {
            XCTFail("Could not locate the repository by walking upward from #filePath")
            return
        }

        let inventory = legacyCatalogInventory(root: root)
        XCTAssertEqual(inventory.count, 9, "Slice 0 freezes nine legacy catalog matches")
        let callers = inventory.filter { !$0.path.hasSuffix("APIClient+ServerPanels.swift") }
        XCTAssertEqual(callers.count, 7, "Slice 0 permits seven legacy production callers")

        let expectedLocations: Set<String> = [
            "HermesMobile/Features/Chat/ChatComposerConfigLoader.swift:104",
            "HermesMobile/Features/Chat/ChatViewModel.swift:761",
            "HermesMobile/Features/Chat/ChatViewModel.swift:768",
            "HermesMobile/Features/Settings/DefaultModelPickerView.swift:199",
            "HermesMobile/Features/Settings/DefaultModelPickerView.swift:215",
            "HermesMobile/Features/Settings/DefaultProfilePickerView.swift:458",
            "HermesMobile/Features/Settings/SettingsView.swift:1059",
            "HermesMobile/Networking/APIClient+ServerPanels.swift:4",
            "HermesMobile/Networking/APIClient+ServerPanels.swift:11"
        ]
        let actualLocations = Set(inventory.map { "\($0.path):\($0.line)" })
        XCTAssertEqual(actualLocations, expectedLocations)

        let networkingFile = root
            .appendingPathComponent("HermesMobile", isDirectory: true)
            .appendingPathComponent("Networking", isDirectory: true)
            .appendingPathComponent("ModelCatalogNetworking.swift")
        if FileManager.default.fileExists(atPath: networkingFile.path) {
            let networking = try String(contentsOf: networkingFile, encoding: .utf8)
            for forbidden in ["ModelsResponse", "ModelsLiveResponse", "JSONValue"] {
                XCTAssertFalse(
                    networking.contains(forbidden),
                    "Neutral networking must not expose recursive wire type \(forbidden)"
                )
            }
            XCTAssertFalse(networking.contains("Features/Chat"))
            XCTAssertNil(
                firstMatch(pattern: #"(?m)^\s*import\s+(Chat\b)"#, in: networking),
                "Neutral networking must not import Chat"
            )
        }
    }

    private func requireSendable<T: Sendable>(_ type: T.Type) {}

    private func assertInjected(_ value: CatalogCookieContextID) {
        if case .injected(_) = value {
            return
        }
        XCTFail("Injected URLSession clients must receive an isolated opaque context token")
    }

    private func collectEvents(
        from stream: AsyncStream<CatalogNetworkEvent>
    ) async -> [CatalogNetworkEvent] {
        var events: [CatalogNetworkEvent] = []
        for await event in stream {
            events.append(event)
            switch event {
            case .finished(_), .failed(_, _, _), .cancelled(_):
                return events
            case .contextVerified(_, _), .base(_), .live(_), .liveFailed(_, _):
                continue
            }
        }
        return events
    }

    private func repositoryRoot(startingAt filePath: String) -> URL? {
        var candidate = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        while candidate.path != "/" {
            let projectFile = candidate
                .appendingPathComponent("HermesMobile.xcodeproj", isDirectory: true)
                .appendingPathComponent("project.pbxproj")
            if fileManager.fileExists(atPath: projectFile.path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private func assertPBXMembership(
        fileName: String,
        groupName: String,
        targetName: String,
        in pbx: String
    ) {
        let escapedFileName = NSRegularExpression.escapedPattern(for: fileName)
        let buildPattern = #"(?m)^\t\t([0-9A-F]{24}) /\* \#(escapedFileName) in Sources \*/ = \{isa = PBXBuildFile; fileRef = ([0-9A-F]{24}) /\* \#(escapedFileName) \*/; settings = \{COMPILER_FLAGS = \"-strict-concurrency=complete -warnings-as-errors\"; \}; \};$"#
        guard let buildMatches = captureGroups(pattern: buildPattern, in: pbx), buildMatches.count == 2 else {
            XCTFail("Expected one exact flagged PBXBuildFile for \(fileName)")
            return
        }
        let buildID = buildMatches[0]
        let fileReferenceID = buildMatches[1]

        XCTAssertEqual(
            occurrenceCount(of: "/* \(fileName) in Sources */", in: pbx),
            2,
            "\(fileName) must have one PBXBuildFile and one Sources-phase comment"
        )
        XCTAssertEqual(
            occurrenceCount(of: "/* \(fileName) */", in: pbx),
            3,
            "\(fileName) must have one file reference, one group child, and one PBXBuildFile reference"
        )

        let escapedGroupName = NSRegularExpression.escapedPattern(for: groupName)
        let groupPattern = #"(?ms)^\t\t[0-9A-F]{24} /\* \#(escapedGroupName) \*/ = \{.*?^\t\t\};"#
        let groupBlocks = captureAllBlocks(pattern: groupPattern, in: pbx)
        XCTAssertEqual(groupBlocks.count, 1, "Expected exactly one \(groupName) PBXGroup")
        if let group = groupBlocks.first {
            XCTAssertEqual(occurrenceCount(of: fileReferenceID, in: group), 1)
        }

        let escapedTargetName = NSRegularExpression.escapedPattern(for: targetName)
        let targetPattern = #"(?ms)^\t\t[0-9A-F]{24} /\* \#(escapedTargetName) \*/ = \{\n\t\t\tisa = PBXNativeTarget;.*?(?=^\t\t[0-9A-F]{24} /\*|^/\* End PBXNativeTarget)"#
        guard let target = captureAllBlocks(pattern: targetPattern, in: pbx).first else {
            XCTFail("Missing native target \(targetName)")
            return
        }
        let phaseMatches = captureAll(
            pattern: #"buildPhases = \(\s*([0-9A-F]{24}) /\* Sources \*/"#,
            in: target
        )
        XCTAssertEqual(phaseMatches.count, 1, "\(targetName) must have one leading Sources phase")
        guard let phaseID = phaseMatches.first else { return }

        let phasePattern = #"(?ms)^\t\t\#(phaseID) /\* Sources \*/ = \{.*?(?=^\t\t[0-9A-F]{24} /\*|^/\* End PBXSourcesBuildPhase)"#
        guard let phase = captureAllBlocks(pattern: phasePattern, in: pbx).first else {
            XCTFail("Missing Sources phase for \(targetName)")
            return
        }
        XCTAssertEqual(occurrenceCount(of: buildID, in: phase), 1)

        let allSourcePhases = captureAllBlocks(
            pattern: #"(?ms)^\t\t[0-9A-F]{24} /\* Sources \*/ = \{.*?(?=^\t\t[0-9A-F]{24} /\*|^/\* End PBXSourcesBuildPhase)"#,
            in: pbx
        )
        XCTAssertEqual(
            allSourcePhases.reduce(0) { $0 + occurrenceCount(of: buildID, in: $1) },
            1,
            "\(fileName) build file must belong to exactly one Sources phase"
        )
    }

    private func occurrenceCount(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func firstMatch(pattern: String, in text: String) -> String? {
        captureAll(pattern: pattern, in: text).first
    }

    private func captureAll(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let capture = match.range(at: 1)
            guard let swiftRange = Range(capture, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private func captureGroups(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            let capture = match.range(at: index)
            guard let swiftRange = Range(capture, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private func captureAllBlocks(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private struct LegacyCatalogMatch: Equatable {
        let path: String
        let line: Int
    }

    private func legacyCatalogInventory(root: URL) -> [LegacyCatalogMatch] {
        let pattern = try! NSRegularExpression(pattern: #"\.(models|modelsLive)\(\)|func (models|modelsLive)\(\)"#)
        let appRoot = root.appendingPathComponent("HermesMobile", isDirectory: true)
        let fileManager = FileManager.default
        let relativePaths = (fileManager.subpaths(atPath: appRoot.path) ?? [])
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        var inventory: [LegacyCatalogMatch] = []
        for relativePath in relativePaths {
            let fileURL = appRoot.appendingPathComponent(relativePath)
            guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if pattern.firstMatch(in: line, range: range) != nil {
                    inventory.append(
                        LegacyCatalogMatch(
                            path: "HermesMobile/\(relativePath)",
                            line: index + 1
                        )
                    )
                }
            }
        }
        return inventory
    }
}

private final class LockedRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }

    func snapshot() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }
}

private final class IsolatedHandlerRegistry: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]

    func install(_ handler: @escaping Handler, for host: String) {
        lock.lock()
        handlers[host] = handler
        lock.unlock()
    }

    func removeHandler(for host: String) {
        lock.lock()
        handlers.removeValue(forKey: host)
        lock.unlock()
    }

    func handler(for host: String) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[host]
    }
}

private final class IsolatedCatalogURLProtocol: URLProtocol {
    static let registry = IsolatedHandlerRegistry()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".model-catalog.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let host = request.url?.host,
            let handler = Self.registry.handler(for: host)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class IsolatedCatalogURLProtocolFixture: @unchecked Sendable {
    private let host: String
    let baseURL: URL
    private let recorder = LockedRequestRecorder()

    init() {
        host = "catalog-\(UUID().uuidString.lowercased()).model-catalog.test"
        baseURL = URL(string: "https://\(host)")!
    }

    deinit {
        IsolatedCatalogURLProtocol.registry.removeHandler(for: host)
    }

    func install(_ handler: @escaping IsolatedHandlerRegistry.Handler) {
        IsolatedCatalogURLProtocol.registry.install(
            { [recorder] request in
                recorder.append(request)
                return try handler(request)
            },
            for: host
        )
    }

    func installStandardCatalogResponses() {
        install { request in
            switch request.url?.path {
            case "/api/profiles":
                return try Self.jsonResponse(
                    #"{"profiles":[{"name":"default","isActive":true}],"active":"default","single_profile_mode":true}"#,
                    for: request
                )
            case "/api/models":
                return try Self.jsonResponse(
                    #"{"groups":[{"provider_id":"openai","name":"OpenAI","models":[{"id":"gpt-5","label":"GPT-5","nested":{"ignored":[1,true,null]}}],"extra_models":[{"id":"gpt-4o","label":"GPT-4o"}]}],"default_model":"gpt-5","active_provider":"openai"}"#,
                    for: request
                )
            case "/api/models/live":
                return try Self.jsonResponse(
                    #"{"provider":"openai","models":[{"id":"gpt-5-mini","label":"GPT-5 Mini","nested":{"ignored":true}}],"count":1}"#,
                    for: request
                )
            default:
                throw URLError(.resourceUnavailable)
            }
        }
    }

    func makeClient(cookieContextID: CatalogCookieContextID? = nil) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IsolatedCatalogURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return APIClient(
            baseURL: baseURL,
            session: session,
            cookieContextID: cookieContextID
        )
    }

    func requests() -> [URLRequest] {
        recorder.snapshot()
    }

    private static func jsonResponse(
        _ json: String,
        for request: URLRequest
    ) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else { throw URLError(.badURL) }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            throw URLError(.badServerResponse)
        }
        return (response, Data(json.utf8))
    }
}
