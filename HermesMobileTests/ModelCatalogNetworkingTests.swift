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
        let events = await Self.collectEvents(from: stream)
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
        let events = await Self.collectEvents(from: stream)
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
        _ = await Self.collectEvents(from: stream)

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

    // MARK: - Slice 1 gate protocol (RED)
    //
    // These tests encode the ticketed reader/writer gate contract from issue
    // #16 Slice 1. The gate machinery (ProfileContextGateRegistry, per-key gate
    // actor, CatalogGateLeaseState, CatalogLeaseAdmission, gate epoch, strict
    // profile verifier, and the compatibility adapters) does not exist yet, so
    // the RED failure is missing-symbol diagnostics only. Every async barrier
    // is a checked continuation; no sleep, polling, expectation-timing,
    // semaphore, or wall-clock oracle is used.

    func testSharedLeaseCoversProfileVerificationBaseAndLiveUntilBothChildrenUnwind() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installStandardCatalogResponses()
        fixture.holdResponses(["/api/models/live"])
        let client = fixture.makeClient()
        let recorder = LockedTelemetryRecorder()
        let sink = RecordingTelemetrySink(recorder: recorder)
        let operationID = UUID()
        let gate = gateFor(fixture: fixture, client: client)

        let stream = await client.modelCatalogStream(
            requestedProfile: nil,
            operationID: operationID,
            operationGeneration: 1,
            telemetrySink: sink
        )
        let collectTask = Task { await Self.collectEvents(from: stream) }

        // The live child is parked on the wire, so the single physical
        // operation-level reader lease must still be held: it covers profile
        // verification plus both children until both have unwound.
        await fixture.waitForParkedLoad(path: "/api/models/live")
        let midFlight = await gate.snapshot()
        XCTAssertEqual(midFlight.heldReaders, [operationID])
        XCTAssertNil(midFlight.heldWriter)
        XCTAssertEqual(midFlight.pendingWriterCount, 0)
        let midFlightTelemetry = recorder.snapshot()
        XCTAssertEqual(gatePhases(in: midFlightTelemetry).gateWaitStarted, 1)
        XCTAssertEqual(gatePhases(in: midFlightTelemetry).gateAcquired, 1)

        fixture.completeParkedLoad(
            path: "/api/models/live",
            json: IsolatedCatalogURLProtocolFixture.liveDefaultJSON
        )
        let events = await collectTask.value
        XCTAssertEqual(terminalCount(of: events), 1)
        XCTAssertTrue(events.contains { event in
            if case .finished = event { return true }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .failed = event { return true }
            return false
        })

        let finalState = await gate.snapshot()
        XCTAssertTrue(finalState.heldReaders.isEmpty, "the shared lease releases only after both children unwind")
        XCTAssertNil(finalState.heldWriter)

        let telemetry = recorder.snapshot()
        XCTAssertEqual(gatePhases(in: telemetry).gateWaitStarted, 1)
        XCTAssertEqual(gatePhases(in: telemetry).gateAcquired, 1)
        let admissions = Set(telemetry.compactMap { $0.admission?.admissionID })
        XCTAssertEqual(admissions.count, 1, "one physical operation-level reader admission")
        let children = telemetry.filter { $0.surface == .models || $0.surface == .live }
        XCTAssertEqual(children.filter { $0.phase == .childRequestStarted }.count, 2)
        XCTAssertEqual(children.filter { $0.phase == .ended }.count, 2)
        XCTAssertFalse(
            children.contains { $0.phase == .gateWaitStarted || $0.phase == .gateAcquired },
            "children never acquire the gate; no nested admission pair"
        )
        XCTAssertTrue(children.allSatisfy { $0.admission?.admissionID == admissions.first })
    }

    func testOneOperationLeaseHasOnePhysicalAdmission() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installStandardCatalogResponses()
        let client = fixture.makeClient()
        let recorder = LockedTelemetryRecorder()
        let sink = RecordingTelemetrySink(recorder: recorder)

        let stream = await client.modelCatalogStream(
            requestedProfile: nil,
            operationID: UUID(),
            operationGeneration: 1,
            telemetrySink: sink
        )
        let events = await Self.collectEvents(from: stream)
        XCTAssertEqual(terminalCount(of: events), 1)
        XCTAssertTrue(events.contains { event in
            if case .finished = event { return true }
            return false
        })

        let telemetry = recorder.snapshot()
        let gateEvents = telemetry.filter { $0.phase == .gateWaitStarted || $0.phase == .gateAcquired }
        XCTAssertEqual(gateEvents.count, 2, "exactly one gateWaitStarted/gateAcquired pair per operation")
        XCTAssertEqual(gateEvents.filter { $0.phase == .gateWaitStarted }.count, 1)
        XCTAssertEqual(gateEvents.filter { $0.phase == .gateAcquired }.count, 1)
        let admissionIDs = Set(gateEvents.compactMap { $0.admission?.admissionID })
        let epochs = Set(gateEvents.compactMap { $0.admission?.gateEpoch })
        XCTAssertEqual(admissionIDs.count, 1, "the pair shares one admission ID")
        XCTAssertEqual(epochs.count, 1, "the pair shares one gate epoch")

        let children = telemetry.filter { $0.surface == .models || $0.surface == .live }
        XCTAssertEqual(children.filter { $0.phase == .childRequestStarted }.count, 2)
        XCTAssertEqual(children.filter { $0.phase == .wireStarted }.count, 2)
        XCTAssertEqual(children.filter { $0.phase == .decodeStarted }.count, 2)
        XCTAssertEqual(children.filter { $0.phase == .ended }.count, 2)
        XCTAssertEqual(children.filter { $0.phase == .ended && $0.outcome == .success }.count, 2)
        XCTAssertFalse(
            children.contains { $0.phase == .gateWaitStarted || $0.phase == .gateAcquired },
            "children emit no gate phases; there is no nested admission"
        )
        XCTAssertTrue(children.allSatisfy { $0.admission?.admissionID == admissionIDs.first })
    }

    func testWriterWaitsForHeldReaderLiveChild() async throws {
        let gate = makeIsolatedGate()
        let readerOperation = UUID()
        let writerOperation = UUID()

        let reader = makeReaderTask(gate: gate, operationID: readerOperation)
        _ = await reader.admitted.first(where: { _ in true })
        guard case .heldReader? = await gate.leaseState(of: readerOperation) else {
            XCTFail("the reader must hold the shared lease while its live child is in flight")
            return
        }

        let writer = makeWriterTask(gate: gate, operationID: writerOperation)
        await gate.waitForLeaseState(writerOperation, .waitingWriter)
        let waiting: CatalogGateSnapshot = await gate.snapshot()
        XCTAssertEqual(waiting.heldReaders, [readerOperation])
        XCTAssertEqual(waiting.waitingWriters, [writerOperation])
        XCTAssertNil(waiting.heldWriter)
        XCTAssertEqual(waiting.pendingWriterCount, 1)

        // The held reader's live child is still in flight: the exclusive writer
        // stays queued. Release the live child, then the writer proceeds.
        reader.release.yield(())
        _ = await writer.admitted.first(where: { _ in true })

        let after = await gate.snapshot()
        XCTAssertTrue(after.heldReaders.isEmpty)
        XCTAssertNil(after.heldWriter)
        XCTAssertTrue(after.waitingWriters.isEmpty)
        XCTAssertEqual(after.pendingWriterCount, 0)
        _ = await reader.task.value
        writer.release.yield(())
        _ = await writer.task.value
    }

    func testCanceledWaitingReaderUnregistersAndDoesNotBlockWriter() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installSwitchOnly(IsolatedCatalogURLProtocolFixture.switchWorkJSON)
        let client = fixture.makeClient()
        let gate = gateFor(fixture: fixture, client: client)
        let heldOperation = UUID()
        let waitingOperation = UUID()

        let heldReader = makeReaderTask(gate: gate, operationID: heldOperation)
        _ = await heldReader.admitted.first(where: { _ in true })

        let waitingReader = makeReaderTask(gate: gate, operationID: waitingOperation)
        await gate.waitForLeaseState(waitingOperation, .waitingReader)
        waitingReader.task.cancel()
        let canceled = await waitingReader.canceled.first(where: { _ in true })
        XCTAssertNotNil(canceled)

        let afterCancel = await gate.snapshot()
        XCTAssertFalse(afterCancel.waitingReaders.contains(waitingOperation), "canceled waiting reader unregisters")
        XCTAssertFalse(afterCancel.heldReaders.contains(waitingOperation))
        XCTAssertEqual(afterCancel.heldReaders, [heldOperation])
        let releasedState = await gate.leaseState(of: waitingOperation)
        XCTAssertNil(releasedState)

        // The canceled waiter must not block the exclusive writer.
        let switchTask = Task { try await client.switchProfile(name: "work") }
        heldReader.release.yield(())
        _ = try await switchTask.value
        XCTAssertEqual(fixture.requests().filter { $0.url?.path == "/api/profile/switch" }.count, 1)
        _ = await heldReader.task.value
        _ = await waitingReader.task.value
    }

    func testWriterPreferenceBlocksReadersArrivingAfterWriter() async throws {
        let gate = makeIsolatedGate()
        let readerOperation = UUID()
        let writerOperation = UUID()
        let lateReaderOperation = UUID()

        let heldReader = makeReaderTask(gate: gate, operationID: readerOperation)
        _ = await heldReader.admitted.first(where: { _ in true })

        let writer = makeWriterTask(gate: gate, operationID: writerOperation)
        await gate.waitForLeaseState(writerOperation, .waitingWriter)

        let lateReader = makeReaderTask(gate: gate, operationID: lateReaderOperation, holdsAfterAdmission: false)
        await gate.waitForLeaseState(lateReaderOperation, .waitingReader)

        let queued = await gate.snapshot()
        XCTAssertEqual(queued.heldReaders, [readerOperation])
        XCTAssertEqual(queued.waitingWriters, [writerOperation])
        XCTAssertEqual(queued.waitingReaders, [lateReaderOperation])
        XCTAssertEqual(queued.pendingWriterCount, 1)

        heldReader.release.yield(())
        _ = await writer.admitted.first(where: { _ in true })
        let writerHeld = await gate.snapshot()
        XCTAssertEqual(writerHeld.heldWriter, writerOperation)
        XCTAssertEqual(
            writerHeld.waitingReaders,
            [lateReaderOperation],
            "a reader arriving after the writer cannot bypass it"
        )

        writer.release.yield(())
        let lateAdmission = await lateReader.admitted.first(where: { _ in true })
        XCTAssertNotNil(lateAdmission)
        _ = await heldReader.task.value
        _ = await writer.task.value
        _ = await lateReader.task.value
    }

    func testCanceledWaitingWriterRemovesReservationAndDoesNotPost() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installSwitchOnly(IsolatedCatalogURLProtocolFixture.switchWorkJSON)
        let client = fixture.makeClient()
        let gate = gateFor(fixture: fixture, client: client)
        let heldOperation = UUID()
        let writerOperation = UUID()

        let heldReader = makeReaderTask(gate: gate, operationID: heldOperation)
        _ = await heldReader.admitted.first(where: { _ in true })

        // Phase 1: a waiting writer's cancellation removes its reservation.
        let waitingWriter = makeWriterTask(gate: gate, operationID: writerOperation)
        await gate.waitForLeaseState(writerOperation, .waitingWriter)
        let reserved = await gate.snapshot()
        XCTAssertEqual(reserved.pendingWriterCount, 1)
        waitingWriter.task.cancel()
        let canceled = await waitingWriter.canceled.first(where: { _ in true })
        XCTAssertNotNil(canceled)
        let afterCancel = await gate.snapshot()
        XCTAssertEqual(afterCancel.pendingWriterCount, 0, "canceled waiting writer removes its reservation")
        XCTAssertFalse(afterCancel.waitingWriters.contains(writerOperation))
        _ = await waitingWriter.task.value

        // Phase 2: a canceled waiting switch writer never POSTs.
        let switchTask = Task { try await client.switchProfile(name: "work") }
        switchTask.cancel()
        do {
            _ = try await switchTask.value
            XCTFail("canceled switch must throw")
        } catch {
        }
        heldReader.release.yield(())
        let postSwitchReader = makeReaderTask(gate: gate, operationID: UUID(), holdsAfterAdmission: false)
        let postSwitchAdmission = await postSwitchReader.admitted.first(where: { _ in true })
        XCTAssertNotNil(postSwitchAdmission)
        XCTAssertEqual(
            fixture.requests().filter { $0.url?.path == "/api/profile/switch" }.count,
            0,
            "a canceled waiting writer never POSTs"
        )
        _ = await heldReader.task.value
        _ = await postSwitchReader.task.value
    }

    func testCanceledHeldWriterReleasesExclusiveOwnership() async throws {
        let gate = makeIsolatedGate()
        let writerOperation = UUID()
        let readerOperation = UUID()

        let writer = makeWriterTask(gate: gate, operationID: writerOperation)
        _ = await writer.admitted.first(where: { _ in true })
        let held = await gate.snapshot()
        XCTAssertEqual(held.heldWriter, writerOperation)

        let queuedReader = makeReaderTask(gate: gate, operationID: readerOperation, holdsAfterAdmission: false)
        await gate.waitForLeaseState(readerOperation, .waitingReader)

        writer.task.cancel()
        writer.release.yield(())
        let queuedAdmission = await queuedReader.admitted.first(where: { _ in true })
        XCTAssertNotNil(queuedAdmission)

        let after = await gate.snapshot()
        XCTAssertNil(after.heldWriter, "canceled held writer releases exclusive ownership")
        XCTAssertTrue(after.heldReaders.isEmpty)
        XCTAssertTrue(after.waitingWriters.isEmpty)
        XCTAssertEqual(after.pendingWriterCount, 0)
        _ = await writer.task.value
        _ = await queuedReader.task.value
    }

    func testFailedPostReleasesWriterAndWakesReaders() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installSwitchOnly(#"{"error":"switch rejected"}"#, statusCode: 500)
        let client = fixture.makeClient()
        let gate = gateFor(fixture: fixture, client: client)
        let heldOperation = UUID()
        let queuedOperation = UUID()

        let heldReader = makeReaderTask(gate: gate, operationID: heldOperation)
        _ = await heldReader.admitted.first(where: { _ in true })

        let switchTask = Task { try await client.switchProfile(name: "work") }
        let queuedReader = makeReaderTask(gate: gate, operationID: queuedOperation, holdsAfterAdmission: false)
        await gate.waitForLeaseState(queuedOperation, .waitingReader)

        heldReader.release.yield(())
        do {
            _ = try await switchTask.value
            XCTFail("a failed switch POST must throw")
        } catch is ProfileContextSwitchFailure {
        } catch {
            XCTFail("switch failures use the fixed ProfileContextSwitchFailure category")
        }
        let queuedAdmission = await queuedReader.admitted.first(where: { _ in true })
        XCTAssertNotNil(queuedAdmission)

        let state = await gate.snapshot()
        XCTAssertTrue(state.heldReaders.isEmpty)
        XCTAssertNil(state.heldWriter, "failed POST releases the exclusive writer")
        XCTAssertTrue(state.waitingWriters.isEmpty)
        XCTAssertEqual(state.pendingWriterCount, 0)
        XCTAssertEqual(state.epoch, 0, "a failed POST must not advance the gate epoch")
        XCTAssertEqual(fixture.requests().filter { $0.url?.path == "/api/profile/switch" }.count, 1)
        _ = await heldReader.task.value
        _ = await queuedReader.task.value
    }

    func testCanceledPostReleasesWriterAndWakesReaders() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installSwitchOnly(IsolatedCatalogURLProtocolFixture.switchWorkJSON)
        fixture.holdResponses(["/api/profile/switch"])
        let client = fixture.makeClient()
        let gate = gateFor(fixture: fixture, client: client)
        let heldOperation = UUID()
        let queuedOperation = UUID()

        let heldReader = makeReaderTask(gate: gate, operationID: heldOperation)
        _ = await heldReader.admitted.first(where: { _ in true })

        let switchTask = Task { try await client.switchProfile(name: "work") }
        heldReader.release.yield(())
        await fixture.waitForParkedLoad(path: "/api/profile/switch")

        // The writer now holds exclusive ownership with its POST on the wire; a
        // reader queued behind it is woken only when the canceled POST unwinds.
        let queuedReader = makeReaderTask(gate: gate, operationID: queuedOperation, holdsAfterAdmission: false)
        await gate.waitForLeaseState(queuedOperation, .waitingReader)
        let blocked = await gate.snapshot()
        XCTAssertNotNil(blocked.heldWriter)
        XCTAssertTrue(blocked.waitingReaders.contains(queuedOperation))

        switchTask.cancel()
        do {
            _ = try await switchTask.value
            XCTFail("canceled switch must throw")
        } catch {
        }
        let queuedAdmission = await queuedReader.admitted.first(where: { _ in true })
        XCTAssertNotNil(queuedAdmission)

        let state = await gate.snapshot()
        XCTAssertNil(state.heldWriter, "canceled POST releases the exclusive writer")
        XCTAssertTrue(state.heldReaders.isEmpty)
        XCTAssertTrue(state.waitingReaders.isEmpty)
        XCTAssertEqual(state.pendingWriterCount, 0)
        XCTAssertEqual(state.epoch, 0, "a canceled POST must not advance the gate epoch")
        XCTAssertEqual(
            fixture.requests().filter { $0.url?.path == "/api/profile/switch" }.count,
            1,
            "the POST was dispatched exactly once"
        )
        fixture.completeParkedLoad(
            path: "/api/profile/switch",
            json: IsolatedCatalogURLProtocolFixture.switchWorkJSON
        )
        _ = await heldReader.task.value
        _ = await queuedReader.task.value
    }

    func testQueuedReadersAndWritersMakeProgressWithoutStarvation() async throws {
        let gate = makeIsolatedGate()
        let firstReader = UUID()
        let secondReader = UUID()
        let writer = UUID()
        let lateReader = UUID()

        let heldReader = makeReaderTask(gate: gate, operationID: firstReader)
        _ = await heldReader.admitted.first(where: { _ in true })

        let queuedReader = makeReaderTask(gate: gate, operationID: secondReader, holdsAfterAdmission: false)
        await gate.waitForLeaseState(secondReader, .waitingReader)
        let waitingWriter = makeWriterTask(gate: gate, operationID: writer)
        await gate.waitForLeaseState(writer, .waitingWriter)
        let arrivingReader = makeReaderTask(gate: gate, operationID: lateReader, holdsAfterAdmission: false)
        await gate.waitForLeaseState(lateReader, .waitingReader)

        let queued = await gate.snapshot()
        XCTAssertEqual(queued.heldReaders, [firstReader])
        XCTAssertEqual(queued.waitingReaders, [secondReader, lateReader])
        XCTAssertEqual(queued.waitingWriters, [writer])
        XCTAssertEqual(queued.pendingWriterCount, 1)

        // The reader cohort ahead of the writer drains first...
        heldReader.release.yield(())
        let queuedAdmission = await queuedReader.admitted.first(where: { _ in true })
        XCTAssertNotNil(queuedAdmission)
        // ...then writer preference admits the queued writer...
        let writerAdmission = await waitingWriter.admitted.first(where: { _ in true })
        XCTAssertNotNil(writerAdmission)
        waitingWriter.release.yield(())
        // ...and only then the reader that arrived after the writer.
        let arrivingAdmission = await arrivingReader.admitted.first(where: { _ in true })
        XCTAssertNotNil(arrivingAdmission)

        let finalState = await gate.snapshot()
        XCTAssertTrue(finalState.heldReaders.isEmpty)
        XCTAssertTrue(finalState.waitingReaders.isEmpty)
        XCTAssertTrue(finalState.waitingWriters.isEmpty)
        XCTAssertNil(finalState.heldWriter)
        XCTAssertEqual(finalState.pendingWriterCount, 0)
        _ = await heldReader.task.value
        _ = await queuedReader.task.value
        _ = await waitingWriter.task.value
        _ = await arrivingReader.task.value
    }

    func test2xxProfileErrorDoesNotAdvanceEpochOrIssueModelsGET() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installProfilesOnly(#"{"error":"profiles unavailable"}"#)
        let client = fixture.makeClient()
        let gate = gateFor(fixture: fixture, client: client)

        let stream = await client.modelCatalogStream(
            requestedProfile: nil,
            operationID: UUID(),
            operationGeneration: 1
        )
        let events = await Self.collectEvents(from: stream)
        guard case let .failed(_, phase, category)? = events.last else {
            XCTFail("a 2xx profile error must produce a failed terminal")
            return
        }
        XCTAssertEqual(phase, .context)
        XCTAssertEqual(category, .profileUnavailable)
        let epoch = await gate.gateEpoch
        XCTAssertEqual(epoch, 0, "invalid profiles must not advance the epoch")
        let paths = fixture.requests().compactMap { $0.url?.path }
        XCTAssertFalse(paths.contains("/api/models"), "zero models GETs on an invalid profile response")
        XCTAssertFalse(paths.contains("/api/models/live"))
        XCTAssertEqual(paths.filter { $0 == "/api/profiles" }.count, 1)
    }

    func testActiveProfileMismatchDoesNotAdvanceEpochOrIssueModelsGET() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installProfilesOnly(
            #"{"profiles":[{"name":"work","isActive":true}],"active":"work","single_profile_mode":false}"#
        )
        let client = fixture.makeClient()
        let gate = gateFor(fixture: fixture, client: client)

        let stream = await client.modelCatalogStream(
            requestedProfile: "default",
            operationID: UUID(),
            operationGeneration: 1
        )
        let events = await Self.collectEvents(from: stream)
        guard case let .failed(_, phase, category)? = events.last else {
            XCTFail("a requested-profile mismatch must produce a failed terminal")
            return
        }
        XCTAssertEqual(phase, .context)
        XCTAssertEqual(category, .profileMismatch)
        let epoch = await gate.gateEpoch
        XCTAssertEqual(epoch, 0, "a mismatched profile must not advance the epoch")
        let paths = fixture.requests().compactMap { $0.url?.path }
        XCTAssertFalse(paths.contains("/api/models"))
        XCTAssertFalse(paths.contains("/api/models/live"))
        XCTAssertEqual(paths.filter { $0 == "/api/profiles" }.count, 1)
    }

    func testAmbiguousProfilesResponseIssuesZeroModelsGETs() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installProfilesOnly(
            #"{"profiles":[{"name":"a","isActive":true},{"name":"b","isActive":true}],"single_profile_mode":false}"#
        )
        let client = fixture.makeClient()

        let stream = await client.modelCatalogStream(
            requestedProfile: nil,
            operationID: UUID(),
            operationGeneration: 1
        )
        let events = await Self.collectEvents(from: stream)
        guard case let .failed(_, phase, category)? = events.last else {
            XCTFail("an ambiguous profile response must produce a failed terminal")
            return
        }
        XCTAssertEqual(phase, .context)
        XCTAssertEqual(category, .profileUnavailable)
        let epoch = await gateFor(fixture: fixture, client: client).gateEpoch
        XCTAssertEqual(epoch, 0)
        let paths = fixture.requests().compactMap { $0.url?.path }
        XCTAssertFalse(paths.contains("/api/models"))
        XCTAssertFalse(paths.contains("/api/models/live"))
    }

    func testSafeSingleProfileProofAuthorizesExactlyOneContext() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        // Safe single-profile proof: no explicit active, no isActive flags,
        // exactly one normalized profile, single_profile_mode true.
        fixture.installCatalog(
            profilesJSON: #"{"profiles":[{"name":"default"}],"single_profile_mode":true}"#
        )
        let client = fixture.makeClient()

        let stream = await client.modelCatalogStream(
            requestedProfile: nil,
            operationID: UUID(),
            operationGeneration: 1
        )
        let events = await Self.collectEvents(from: stream)
        let contextEvents = events.filter { event in
            if case .contextVerified = event { return true }
            return false
        }
        XCTAssertEqual(contextEvents.count, 1, "the safe single-profile proof authorizes exactly one context")
        guard let firstContextEvent = contextEvents.first else {
            XCTFail("expected exactly one contextVerified event")
            return
        }
        guard case let .contextVerified(_, context) = firstContextEvent else {
            XCTFail("unexpected event \(firstContextEvent)")
            return
        }
        XCTAssertEqual(context.activeProfile, "default")
        XCTAssertTrue(context.singleProfileMode)
        XCTAssertNil(context.requestedProfile)
        XCTAssertTrue(events.contains { event in
            if case .finished = event { return true }
            return false
        })
        let paths = fixture.requests().compactMap { $0.url?.path }
        XCTAssertEqual(paths.filter { $0 == "/api/models" }.count, 1)
        XCTAssertEqual(paths.filter { $0 == "/api/models/live" }.count, 1)
    }

    func testProfileSwitchCancelsAndDrainsCoordinatorOwnedCatalogReaderBeforePOST() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installCatalogWithSwitch(switchJSON: IsolatedCatalogURLProtocolFixture.switchWorkJSON)
        fixture.holdResponses(["/api/models/live"])
        let client = fixture.makeClient()
        let gate = gateFor(fixture: fixture, client: client)
        let recorder = LockedTelemetryRecorder()
        let sink = RecordingTelemetrySink(recorder: recorder)
        let readerOperation = UUID()

        let stream = await client.modelCatalogStream(
            requestedProfile: nil,
            operationID: readerOperation,
            operationGeneration: 1,
            telemetrySink: sink
        )
        let readerTask = Task { await Self.collectEvents(from: stream) }
        await fixture.waitForParkedLoad(path: "/api/models/live")

        // The coordinator-owned reader holds the shared lease with its live
        // child in flight. The exclusive switch must cancel and drain it before
        // its POST; the POST count stays zero until the reader has unwound.
        let switchTask = Task { try await client.switchProfile(name: "work") }

        // The reader can only complete through the writer's cancellation, so
        // awaiting its events observes the drain before any POST is possible.
        let readerEvents = await readerTask.value
        XCTAssertEqual(terminalCount(of: readerEvents), 1)
        guard case .cancelled? = readerEvents.last else {
            XCTFail("the drained reader must end with exactly one cancelled terminal")
            return
        }
        XCTAssertFalse(readerEvents.contains { event in
            if case .failed = event { return true }
            return false
        })

        _ = try await switchTask.value
        let afterDrain = await gate.snapshot()
        XCTAssertTrue(afterDrain.heldReaders.isEmpty, "the reader lease is released before the switch POST")
        XCTAssertNil(afterDrain.heldWriter)
        XCTAssertTrue(afterDrain.waitingWriters.isEmpty)
        XCTAssertEqual(afterDrain.pendingWriterCount, 0)
        XCTAssertEqual(
            fixture.requests().filter { $0.url?.path == "/api/profile/switch" }.count,
            1,
            "exactly one switch POST, dispatched only after the drain"
        )
        XCTAssertEqual(afterDrain.epoch, 1, "a validated switch advances the gate epoch")

        // Subsequent reader progress after the switch.
        fixture.clearHolds()
        let secondStream = await client.modelCatalogStream(
            requestedProfile: nil,
            operationID: UUID(),
            operationGeneration: 2
        )
        let secondEvents = await Self.collectEvents(from: secondStream)
        XCTAssertTrue(secondEvents.contains { event in
            if case .finished = event { return true }
            return false
        })

        let readerTelemetry = recorder.snapshot().filter { $0.operationID == readerOperation }
        XCTAssertEqual(gatePhases(in: readerTelemetry).gateWaitStarted, 1)
        XCTAssertEqual(gatePhases(in: readerTelemetry).gateAcquired, 1)
    }

    func testTaskCancellationEmitsExactlyOneCancelledTerminal() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installStandardCatalogResponses()
        fixture.holdResponses(["/api/profiles"])
        let client = fixture.makeClient()
        let gate = gateFor(fixture: fixture, client: client)
        let operationID = UUID()

        let stream = await client.modelCatalogStream(
            requestedProfile: nil,
            operationID: operationID,
            operationGeneration: 1
        )
        let collectTask = Task { await Self.collectEvents(from: stream) }
        await fixture.waitForParkedLoad(path: "/api/profiles")

        // Cancel through the operation's gate registration; the repeated cancel
        // is a no-op for the finishOnce guard.
        await gate.cancel(operationID: operationID)
        await gate.cancel(operationID: operationID)

        let events = await collectTask.value
        XCTAssertEqual(terminalCount(of: events), 1, "exactly one terminal, never a second")
        guard case .cancelled? = events.last else {
            XCTFail("task cancellation must produce exactly one cancelled terminal")
            return
        }
        XCTAssertFalse(events.contains { event in
            if case .failed = event { return true }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .finished = event { return true }
            return false
        })
    }

    func testURLErrorCancelledEmitsCancelledNotTransport() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.install { request in
            switch request.url?.path {
            case "/api/profiles":
                return try IsolatedCatalogURLProtocolFixture.jsonResponse(
                    IsolatedCatalogURLProtocolFixture.profilesDefaultJSON,
                    for: request
                )
            case "/api/models":
                throw URLError(.cancelled)
            case "/api/models/live":
                throw URLError(.resourceUnavailable)
            default:
                throw URLError(.resourceUnavailable)
            }
        }
        let client = fixture.makeClient()

        let stream = await client.modelCatalogStream(
            requestedProfile: nil,
            operationID: UUID(),
            operationGeneration: 1
        )
        let events = await Self.collectEvents(from: stream)
        XCTAssertEqual(terminalCount(of: events), 1)
        guard case .cancelled? = events.last else {
            XCTFail("URLError.cancelled must map to the cancelled terminal, never transport failure")
            return
        }
        XCTAssertFalse(events.contains { event in
            if case .failed(_, _, .transport) = event { return true }
            return false
        })
    }

    func testCanceledChildBeforeWireEndsOnceWithoutNestedAdmission() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installStandardCatalogResponses()
        fixture.holdResponses(["/api/profiles"])
        let client = fixture.makeClient()
        let gate = gateFor(fixture: fixture, client: client)
        let recorder = LockedTelemetryRecorder()
        let sink = RecordingTelemetrySink(recorder: recorder)
        let operationID = UUID()

        let stream = await client.modelCatalogStream(
            requestedProfile: nil,
            operationID: operationID,
            operationGeneration: 1,
            telemetrySink: sink
        )
        let collectTask = Task { await Self.collectEvents(from: stream) }

        // The operation is admitted (one physical pair) and canceled before any
        // child reaches the wire: no child wire/decode events, no second pair.
        await fixture.waitForParkedLoad(path: "/api/profiles")
        await gate.cancel(operationID: operationID)
        fixture.completeParkedLoad(
            path: "/api/profiles",
            json: IsolatedCatalogURLProtocolFixture.profilesDefaultJSON
        )

        let events = await collectTask.value
        XCTAssertEqual(terminalCount(of: events), 1)
        guard case .cancelled? = events.last else {
            XCTFail("cancellation before wire must produce exactly one cancelled terminal")
            return
        }

        let telemetry = recorder.snapshot().filter { $0.operationID == operationID }
        XCTAssertEqual(gatePhases(in: telemetry).gateWaitStarted, 1)
        XCTAssertEqual(gatePhases(in: telemetry).gateAcquired, 1, "one admission, and never a second pair")
        let children = telemetry.filter { $0.surface == .models || $0.surface == .live }
        XCTAssertFalse(
            children.contains { $0.phase == .wireStarted || $0.phase == .decodeStarted },
            "no child reaches the wire before cancellation"
        )
        XCTAssertFalse(
            children.contains { $0.phase == .gateWaitStarted || $0.phase == .gateAcquired },
            "no nested child admission"
        )
        XCTAssertEqual(
            children.filter { $0.phase == .ended }.count,
            children.filter { $0.phase == .childRequestStarted }.count,
            "every started child ends exactly once"
        )
    }

    func testCanceledChildAfterWireEndsOnceWithoutNestedAdmission() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installStandardCatalogResponses()
        fixture.holdResponses(["/api/models", "/api/models/live"])
        let client = fixture.makeClient()
        let gate = gateFor(fixture: fixture, client: client)
        let recorder = LockedTelemetryRecorder()
        let sink = RecordingTelemetrySink(recorder: recorder)
        let operationID = UUID()

        let stream = await client.modelCatalogStream(
            requestedProfile: nil,
            operationID: operationID,
            operationGeneration: 1,
            telemetrySink: sink
        )
        let collectTask = Task { await Self.collectEvents(from: stream) }

        // Both children are on the wire (both loads parked) when the operation
        // is canceled: each started child ends exactly once, with no second
        // gateWaitStarted/gateAcquired pair and no nested child admission.
        await fixture.waitForParkedLoad(path: "/api/models")
        await fixture.waitForParkedLoad(path: "/api/models/live")
        await gate.cancel(operationID: operationID)
        fixture.completeParkedLoad(path: "/api/models", json: IsolatedCatalogURLProtocolFixture.modelsDefaultJSON)
        fixture.completeParkedLoad(path: "/api/models/live", json: IsolatedCatalogURLProtocolFixture.liveDefaultJSON)

        let events = await collectTask.value
        XCTAssertEqual(terminalCount(of: events), 1)
        guard case .cancelled? = events.last else {
            XCTFail("cancellation after wire must produce exactly one cancelled terminal")
            return
        }

        let telemetry = recorder.snapshot().filter { $0.operationID == operationID }
        XCTAssertEqual(gatePhases(in: telemetry).gateWaitStarted, 1)
        XCTAssertEqual(gatePhases(in: telemetry).gateAcquired, 1)
        let children = telemetry.filter { $0.surface == .models || $0.surface == .live }
        XCTAssertEqual(children.filter { $0.phase == .childRequestStarted }.count, 2)
        XCTAssertEqual(children.filter { $0.phase == .wireStarted }.count, 2, "both children reached the wire")
        XCTAssertEqual(children.filter { $0.phase == .ended }.count, 2, "each started child ends exactly once")
        XCTAssertEqual(children.filter { $0.phase == .ended && $0.outcome == .cancelled }.count, 2)
        XCTAssertFalse(children.contains { $0.phase == .decodeStarted }, "canceled at wire: no decode phase")
        XCTAssertFalse(
            children.contains { $0.phase == .gateWaitStarted || $0.phase == .gateAcquired },
            "no nested child admission"
        )
    }

    func testHeldCompatibilityModelsReadBlocksSwitch() async throws {
        try await assertHeldCompatibilityReadBlocksSwitch(path: "/api/models")
    }

    func testHeldCompatibilityModelsLiveReadBlocksSwitch() async throws {
        try await assertHeldCompatibilityReadBlocksSwitch(path: "/api/models/live")
    }

    func testHeldCompatibilityProfilesReadBlocksSwitch() async throws {
        try await assertHeldCompatibilityReadBlocksSwitch(path: "/api/profiles")
    }

    private func assertHeldCompatibilityReadBlocksSwitch(path: String) async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installCatalogWithSwitch(switchJSON: IsolatedCatalogURLProtocolFixture.switchWorkJSON)
        fixture.holdResponses([path])
        let client = fixture.makeClient()
        let gate = gateFor(fixture: fixture, client: client)
        let readOperation = UUID()

        let readTask: Task<Bool, Never>
        switch path {
        case "/api/models":
            readTask = Task {
                do {
                    _ = try await client.compatibilityModels(operationID: readOperation, operationGeneration: 1)
                    return true
                } catch {
                    return false
                }
            }
        case "/api/models/live":
            readTask = Task {
                do {
                    _ = try await client.compatibilityModelsLive(operationID: readOperation, operationGeneration: 1)
                    return true
                } catch {
                    return false
                }
            }
        case "/api/profiles":
            readTask = Task {
                do {
                    _ = try await client.compatibilityProfiles(operationID: readOperation, operationGeneration: 1)
                    return true
                } catch {
                    return false
                }
            }
        default:
            XCTFail("unexpected held compatibility path \(path)")
            return
        }
        await fixture.waitForParkedLoad(path: path)
        let held = await gate.snapshot()
        XCTAssertEqual(held.heldReaders, [readOperation], "the compatibility read holds the shared lease")
        XCTAssertNil(held.heldWriter)
        XCTAssertEqual(held.pendingWriterCount, 0)
        XCTAssertEqual(
            fixture.requests().filter { $0.url?.path == "/api/profile/switch" }.count,
            0,
            "switch POST count stays zero while the compatibility read is held"
        )

        let switchTask = Task { try await client.switchProfile(name: "work") }
        _ = try await switchTask.value
        let completedSuccessfully = await readTask.value
        XCTAssertFalse(completedSuccessfully, "the held compatibility read is canceled/drained by the switch")

        let state = await gate.snapshot()
        XCTAssertTrue(state.heldReaders.isEmpty)
        XCTAssertNil(state.heldWriter)
        XCTAssertEqual(state.pendingWriterCount, 0)
        XCTAssertEqual(state.epoch, 1, "a validated switch advances the gate epoch")
        XCTAssertEqual(fixture.requests().filter { $0.url?.path == "/api/profile/switch" }.count, 1)
        fixture.completeParkedLoad(path: path, json: IsolatedCatalogURLProtocolFixture.modelsDefaultJSON)
    }

    func testCanceledCompatibilityReadReleasesLease() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installCatalogWithSwitch(switchJSON: IsolatedCatalogURLProtocolFixture.switchWorkJSON)
        fixture.holdResponses(["/api/models"])
        let client = fixture.makeClient()
        let gate = gateFor(fixture: fixture, client: client)
        let readOperation = UUID()

        let readTask = Task { () -> Bool in
            do {
                _ = try await client.compatibilityModels(operationID: readOperation, operationGeneration: 1)
                return true
            } catch {
                return false
            }
        }
        await fixture.waitForParkedLoad(path: "/api/models")
        await gate.cancel(operationID: readOperation)
        let completedSuccessfully = await readTask.value
        XCTAssertFalse(completedSuccessfully, "the canceled compatibility read unwinds with cancellation")

        let state = await gate.snapshot()
        XCTAssertTrue(state.heldReaders.isEmpty, "a canceled compatibility read releases the shared lease")
        XCTAssertNil(state.heldWriter)

        // A subsequent exclusive writer can proceed immediately.
        let switchTask = Task { try await client.switchProfile(name: "work") }
        _ = try await switchTask.value
        XCTAssertEqual(fixture.requests().filter { $0.url?.path == "/api/profile/switch" }.count, 1)
        fixture.completeParkedLoad(path: "/api/models", json: IsolatedCatalogURLProtocolFixture.modelsDefaultJSON)
    }

    func testCompatibilityReadEpochFenceRejectsPostSwitchApply() async throws {
        let fixture = IsolatedCatalogURLProtocolFixture()
        fixture.installCatalogWithSwitch(switchJSON: IsolatedCatalogURLProtocolFixture.switchWorkJSON)
        let client = fixture.makeClient()
        let gate = gateFor(fixture: fixture, client: client)

        let envelope: CatalogCompatibilityEnvelope<ProfilesResponse> = try await client.compatibilityProfiles(
            operationID: UUID(),
            operationGeneration: 1
        )
        let currentEpoch = await gate.gateEpoch
        XCTAssertEqual(envelope.gateEpoch, currentEpoch)
        let acceptsCurrentEpoch = await client.acceptsCompatibilityEpoch(
            gateEpoch: envelope.gateEpoch,
            gateKey: envelope.gateKey
        )
        XCTAssertTrue(acceptsCurrentEpoch)

        _ = try await client.switchProfile(name: "work")
        let epochAfterSwitch = await gate.gateEpoch
        XCTAssertEqual(epochAfterSwitch, envelope.gateEpoch + 1)
        let acceptsStaleEpoch = await client.acceptsCompatibilityEpoch(
            gateEpoch: envelope.gateEpoch,
            gateKey: envelope.gateKey
        )
        XCTAssertFalse(acceptsStaleEpoch, "an advanced epoch rejects the pre-switch compatibility envelope before apply")
    }

    // MARK: - Slice 1 gate helpers

    private func gateFor(
        fixture: IsolatedCatalogURLProtocolFixture,
        client: APIClient
    ) -> ProfileContextGate {
        ProfileContextGateRegistry.shared.gate(
            for: ProfileContextGateKey(
                origin: NormalizedServerOrigin(url: fixture.baseURL),
                cookieContextID: client.cookieContextID
            )
        )
    }

    private func makeIsolatedGate() -> ProfileContextGate {
        ProfileContextGateRegistry.shared.gate(
            for: ProfileContextGateKey(
                origin: NormalizedServerOrigin(
                    scheme: "https",
                    host: "gate-\(UUID().uuidString.lowercased()).model-catalog.test",
                    port: 443
                ),
                cookieContextID: CatalogCookieContextID.injected(UUID())
            )
        )
    }

    private func terminalCount(of events: [CatalogNetworkEvent]) -> Int {
        events.filter { event in
            switch event {
            case .finished, .failed, .cancelled:
                return true
            case .contextVerified, .base, .live, .liveFailed:
                return false
            }
        }.count
    }

    private struct GatePhaseCounts: Equatable {
        let gateWaitStarted: Int
        let gateAcquired: Int
    }

    private func gatePhases(in telemetry: [CatalogTelemetryEvent]) -> GatePhaseCounts {
        GatePhaseCounts(
            gateWaitStarted: telemetry.filter { $0.phase == .gateWaitStarted }.count,
            gateAcquired: telemetry.filter { $0.phase == .gateAcquired }.count
        )
    }

    /// Spawns a reader task against the gate. The task signals admission on
    /// `admitted`, cancellation on `canceled`, and (when holding) stays inside
    /// the shared body until the test yields `release`.
    private func makeReaderTask(
        gate: ProfileContextGate,
        operationID: UUID,
        holdsAfterAdmission: Bool = true
    ) -> (
        admitted: AsyncStream<CatalogLeaseAdmission>,
        canceled: AsyncStream<Void>,
        release: AsyncStream<Void>.Continuation,
        task: Task<Void, Never>
    ) {
        let (admissionStream, admissionContinuation) = AsyncStream<CatalogLeaseAdmission>.makeStream()
        let (canceledStream, canceledContinuation) = AsyncStream<Void>.makeStream()
        let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            do {
                let admission = try await gate.acquireReader(operationID: operationID)
                admissionContinuation.yield(admission)
                if holdsAfterAdmission {
                    for await _ in releaseStream { break }
                }
                await gate.releaseReader(operationID: operationID, admission: admission)
            } catch {
                canceledContinuation.yield(())
            }
        }
        return (admissionStream, canceledStream, releaseContinuation, task)
    }

    /// Spawns a writer task against the gate with the same signaling contract.
    private func makeWriterTask(
        gate: ProfileContextGate,
        operationID: UUID,
        holdsAfterAdmission: Bool = true
    ) -> (
        admitted: AsyncStream<CatalogLeaseAdmission>,
        canceled: AsyncStream<Void>,
        release: AsyncStream<Void>.Continuation,
        task: Task<Void, Never>
    ) {
        let (admissionStream, admissionContinuation) = AsyncStream<CatalogLeaseAdmission>.makeStream()
        let (canceledStream, canceledContinuation) = AsyncStream<Void>.makeStream()
        let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            do {
                let admission = try await gate.acquireWriter(operationID: operationID)
                admissionContinuation.yield(admission)
                if holdsAfterAdmission {
                    for await _ in releaseStream { break }
                }
                await gate.releaseWriter(operationID: operationID, admission: admission)
            } catch {
                canceledContinuation.yield(())
            }
        }
        return (admissionStream, canceledStream, releaseContinuation, task)
    }

    private func requireSendable<T: Sendable>(_ type: T.Type) {}

    private func assertInjected(_ value: CatalogCookieContextID) {
        if case .injected(_) = value {
            return
        }
        XCTFail("Injected URLSession clients must receive an isolated opaque context token")
    }

    // Static so Task-wrapped collectors never capture the non-Sendable test
    // instance under -strict-concurrency=complete.
    private static func collectEvents(
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
        let groupPattern = #"(?ms)^\t\t[0-9A-F]{24} /\* \#(escapedGroupName) \*/ = \{\n\t\t\tisa = PBXGroup;.*?^\t\t\};"#
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
    private var controllers: [String: HeldResponseController] = [:]

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

    func install(_ controller: HeldResponseController, for host: String) {
        lock.lock()
        controllers[host] = controller
        lock.unlock()
    }

    func removeController(for host: String) {
        lock.lock()
        controllers.removeValue(forKey: host)
        lock.unlock()
    }

    func controller(for host: String) -> HeldResponseController? {
        lock.lock()
        defer { lock.unlock() }
        return controllers[host]
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
        guard let host = request.url?.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        if let path = request.url?.path,
           let controller = Self.registry.controller(for: host),
           controller.shouldHold(path: path) {
            controller.park(self, path: path)
            return
        }

        guard let handler = Self.registry.handler(for: host) else {
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

    override func stopLoading() {
        if let host = request.url?.host, let path = request.url?.path {
            Self.registry.controller(for: host)?.discardParkedLoad(path: path)
        }
    }
}

private final class IsolatedCatalogURLProtocolFixture: @unchecked Sendable {
    private let host: String
    let baseURL: URL
    private let recorder = LockedRequestRecorder()
    private let heldResponses = HeldResponseController()

    init() {
        host = "catalog-\(UUID().uuidString.lowercased()).model-catalog.test"
        baseURL = URL(string: "https://\(host)")!
        IsolatedCatalogURLProtocol.registry.install(heldResponses, for: host)
    }

    deinit {
        IsolatedCatalogURLProtocol.registry.removeHandler(for: host)
        IsolatedCatalogURLProtocol.registry.removeController(for: host)
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
        recorder.snapshot() + heldResponses.recordedRequests()
    }

    // MARK: - Held-response transport barriers
    //
    // A held response parks the matching load in the URLProtocol instead of
    // answering it. The test observes the park through a checked continuation
    // and later completes (or implicitly discards, on cancellation) the load —
    // no sleep, polling, expectation-timing, or semaphore oracle is involved.

    func holdResponses(_ paths: [String]) {
        heldResponses.hold(paths)
    }

    func clearHolds() {
        heldResponses.clearHolds()
    }

    func waitForParkedLoad(path: String) async {
        await heldResponses.waitForParkedLoad(path: path)
    }

    func completeParkedLoad(path: String, statusCode: Int = 200, json: String) {
        heldResponses.completeParkedLoad(path: path, statusCode: statusCode, json: json)
    }

    // MARK: - Profile/catalog response fixtures

    static let profilesDefaultJSON =
        #"{"profiles":[{"name":"default","isActive":true}],"active":"default","single_profile_mode":true}"#
    static let modelsDefaultJSON =
        #"{"groups":[{"provider_id":"openai","name":"OpenAI","models":[{"id":"gpt-5","label":"GPT-5"}]}],"default_model":"gpt-5","active_provider":"openai"}"#
    static let liveDefaultJSON =
        #"{"provider":"openai","models":[{"id":"gpt-5-mini","label":"GPT-5 Mini"}]}"#
    static let switchWorkJSON =
        #"{"profiles":[{"name":"work","isActive":true}],"active":"work"}"#

    func installProfilesOnly(_ json: String) {
        install { request in
            switch request.url?.path {
            case "/api/profiles":
                return try Self.jsonResponse(json, for: request)
            default:
                throw URLError(.resourceUnavailable)
            }
        }
    }

    func installSwitchOnly(_ json: String, statusCode: Int = 200) {
        install { request in
            switch request.url?.path {
            case "/api/profile/switch":
                return try Self.jsonResponse(json, for: request, statusCode: statusCode)
            default:
                throw URLError(.resourceUnavailable)
            }
        }
    }

    func installCatalog(profilesJSON: String, switchJSON: String? = nil) {
        install { request in
            switch request.url?.path {
            case "/api/profiles":
                return try Self.jsonResponse(profilesJSON, for: request)
            case "/api/models":
                return try Self.jsonResponse(Self.modelsDefaultJSON, for: request)
            case "/api/models/live":
                return try Self.jsonResponse(Self.liveDefaultJSON, for: request)
            case "/api/profile/switch":
                guard let switchJSON else { throw URLError(.resourceUnavailable) }
                return try Self.jsonResponse(switchJSON, for: request)
            default:
                throw URLError(.resourceUnavailable)
            }
        }
    }

    func installCatalogWithSwitch(switchJSON: String) {
        installCatalog(profilesJSON: Self.profilesDefaultJSON, switchJSON: switchJSON)
    }

    static func jsonResponse(
        _ json: String,
        for request: URLRequest,
        statusCode: Int = 200
    ) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else { throw URLError(.badURL) }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            throw URLError(.badServerResponse)
        }
        return (response, Data(json.utf8))
    }
}

/// Lock-protected transport controller that parks matching loads instead of
/// answering them. Parked loads are recorded, observed through a checked
/// continuation, completed on demand, and discarded when the URLSession
/// cancels the load (stopLoading). Every member is lock-owned, so the fixture
/// is safe under parallel XCTest workers.
private final class HeldResponseController: @unchecked Sendable {
    private struct ParkedLoad {
        let protocolInstance: IsolatedCatalogURLProtocol
    }

    private let lock = NSLock()
    private let recorder = LockedRequestRecorder()
    private var heldPaths: Set<String> = []
    private var parkedLoads: [String: ParkedLoad] = [:]
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func hold(_ paths: [String]) {
        lock.lock()
        heldPaths.formUnion(paths)
        lock.unlock()
    }

    func clearHolds() {
        lock.lock()
        heldPaths.removeAll()
        lock.unlock()
    }

    func shouldHold(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return heldPaths.contains(path)
    }

    func park(_ protocolInstance: IsolatedCatalogURLProtocol, path: String) {
        lock.lock()
        recorder.append(protocolInstance.request)
        parkedLoads[path] = ParkedLoad(protocolInstance: protocolInstance)
        let waiter = waiters.removeValue(forKey: path)
        lock.unlock()
        waiter?.resume()
    }

    func waitForParkedLoad(path: String) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if parkedLoads[path] != nil {
                lock.unlock()
                continuation.resume()
            } else {
                waiters[path] = continuation
                lock.unlock()
            }
        }
    }

    func completeParkedLoad(path: String, statusCode: Int, json: String) {
        lock.lock()
        guard let load = parkedLoads.removeValue(forKey: path) else {
            lock.unlock()
            return
        }
        lock.unlock()
        guard let url = load.protocolInstance.request.url else { return }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            return
        }
        let protocolInstance = load.protocolInstance
        protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
        protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data(json.utf8))
        protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
    }

    func discardParkedLoad(path: String) {
        lock.lock()
        parkedLoads.removeValue(forKey: path)
        lock.unlock()
    }

    func recordedRequests() -> [URLRequest] {
        recorder.snapshot()
    }
}

private final class LockedTelemetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CatalogTelemetryEvent] = []

    func append(_ event: CatalogTelemetryEvent) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }

    func snapshot() -> [CatalogTelemetryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class RecordingTelemetrySink: CatalogTelemetrySink, @unchecked Sendable {
    private let recorder: LockedTelemetryRecorder

    init(recorder: LockedTelemetryRecorder) {
        self.recorder = recorder
    }

    func emit(_ event: CatalogTelemetryEvent) {
        recorder.append(event)
    }
}
