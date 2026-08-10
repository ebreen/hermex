import XCTest
@testable import HermesMobile

final class ChatComposerConfigLoaderTests: APIClientTestCase {
    func testLoadUsesSessionProfileDefaultAndRefreshesCommands() async throws {
        let openRouterModel = "deepseek/deepseek-chat-v3-0324:free"
        var requestPaths: [String] = []
        let client = makeClient { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "default",
                  "profiles": [
                    {"name": "default", "model": "gpt-5.4", "provider": "openai", "is_default": true},
                    {"name": "work", "model": "\(openRouterModel)", "provider": "openrouter"}
                  ]
                }
                """, for: request)
            case "/api/profile/switch":
                let body = try apiTestJSONBody(from: request)
                XCTAssertEqual(body["name"] as? String, "work")
                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "default_model": "\(openRouterModel)",
                  "default_workspace": "/tmp/workspace",
                  "profiles": [
                    {"name": "default", "model": "gpt-5.4", "provider": "openai", "is_default": true},
                    {"name": "work", "model": "\(openRouterModel)", "provider": "openrouter", "is_active": true}
                  ]
                }
                """, for: request)
            case "/api/models":
                return apiTestJSONResponse("""
                {
                  "default_model": "\(openRouterModel)",
                  "groups": [
                    {
                      "name": "OpenRouter",
                      "provider_id": "openrouter",
                      "models": [
                        {"id": "\(openRouterModel)", "name": "DeepSeek Chat v3 Free"}
                      ]
                    }
                  ]
                }
                """, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces": [{"path": "/tmp/workspace"}], "last": "/tmp/workspace"}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands": [{"name": "status", "description": "Show status"}]}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await ChatComposerConfigLoader(client: client).loadConfiguration(
            from: ChatComposerConfigState(currentProfile: "work")
        )

        XCTAssertNil(result.configurationError)
        XCTAssertEqual(result.state.selectedProfileName, "work")
        XCTAssertEqual(result.state.currentProfile, "work")
        XCTAssertEqual(result.state.currentModel, openRouterModel)
        XCTAssertEqual(result.state.currentModelProvider, "openrouter")
        XCTAssertEqual(result.state.currentWorkspace, "/tmp/workspace")
        XCTAssertEqual(result.state.selectedReasoningEffort, "medium")
        // Older server: no supported_efforts / supports_reasoning_effort fields.
        XCTAssertNil(result.state.supportedReasoningEfforts)
        XCTAssertNil(result.state.supportsReasoningEffort)
        XCTAssertEqual(result.state.workspaceSuggestions, ["/tmp/workspace"])
        XCTAssertEqual(result.state.agentCommands.map(\.name), ["status"])
        XCTAssertEqual(requestPaths, [
            "/api/profiles",
            "/api/profile/switch",
            "/api/models",
            "/api/reasoning",
            "/api/workspaces",
            "/api/commands"
        ])
    }

    func testLoadKeepsSessionModelOverrideWhenProfileHasDifferentDefault() async throws {
        let sessionModel = "@openai:gpt-5.5"
        let profileDefault = "deepseek/deepseek-chat-v3-0324:free"
        var reasoningQueryItems: [String: String?] = [:]
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "profiles": [
                    {"name": "work", "model": "\(profileDefault)", "provider": "openrouter", "is_active": true}
                  ]
                }
                """, for: request)
            case "/api/models":
                return apiTestJSONResponse("""
                {
                  "default_model": "\(profileDefault)",
                  "groups": [
                    {
                      "name": "OpenRouter",
                      "provider_id": "openrouter",
                      "models": [{"id": "\(profileDefault)", "name": "DeepSeek Chat v3 Free"}]
                    },
                    {
                      "name": "OpenAI",
                      "provider_id": "openai",
                      "models": [{"id": "\(sessionModel)", "name": "GPT 5.5"}]
                    }
                  ]
                }
                """, for: request)
            case "/api/reasoning":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                reasoningQueryItems = Dictionary(
                    uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) }
                )
                return apiTestJSONResponse("""
                {
                  "reasoning_effort": "high",
                  "supported_efforts": ["low", "medium", "high"],
                  "supports_reasoning_effort": true
                }
                """, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces": [{"path": "/tmp/workspace"}]}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands": []}"#, for: request)
            case "/api/default-model":
                XCTFail("Composer configuration loading must not save profile defaults.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await ChatComposerConfigLoader(client: client).loadConfiguration(
            from: ChatComposerConfigState(
                currentWorkspace: "/tmp/workspace",
                currentModel: sessionModel,
                currentModelProvider: "openai",
                currentProfile: "work"
            )
        )

        XCTAssertNil(result.configurationError)
        XCTAssertEqual(result.state.currentModel, sessionModel)
        XCTAssertEqual(result.state.currentModelProvider, "openai")
        XCTAssertEqual(result.state.selectedProfileName, "work")
        XCTAssertEqual(result.state.selectedReasoningEffort, "high")
        // The reasoning query is scoped to the session's model/provider so the
        // gating fields are model-accurate (issue #18).
        XCTAssertEqual(reasoningQueryItems["model"], sessionModel)
        XCTAssertEqual(reasoningQueryItems["provider"], "openai")
        XCTAssertEqual(result.state.supportedReasoningEfforts, ["low", "medium", "high"])
        XCTAssertEqual(result.state.supportsReasoningEffort, true)
    }

    func testLoadReturnsPartialStateAndStillRefreshesCommandsWhenConfigurationFails() async throws {
        var requestPaths: [String] = []
        let client = makeClient { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "default",
                  "profiles": [
                    {"name": "default", "model": "gpt-5.4", "provider": "openai", "is_default": true}
                  ]
                }
                """, for: request)
            case "/api/models":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"models unavailable"}"#.utf8))
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands": [{"name": "status"}]}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await ChatComposerConfigLoader(client: client).loadConfiguration(
            from: ChatComposerConfigState()
        )

        XCTAssertNotNil(result.configurationError)
        XCTAssertEqual(result.state.selectedProfileName, "default")
        XCTAssertEqual(result.state.profileOptions.map(\.name), ["default"])
        XCTAssertEqual(result.state.currentModel, "gpt-5.4")
        XCTAssertNil(result.state.currentModelProvider)
        XCTAssertEqual(result.state.agentCommands.map(\.name), ["status"])
        XCTAssertEqual(requestPaths, ["/api/profiles", "/api/models", "/api/commands"])
    }

    func testLoadStoresSingleProfileModeFromProfilesResponse() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "default",
                  "profiles": [
                    {"name": "default", "model": "gpt-5.4", "provider": "openai", "is_default": true, "is_active": true}
                  ],
                  "single_profile_mode": true
                }
                """, for: request)
            case "/api/models":
                return apiTestJSONResponse(#"{"default_model": "gpt-5.4", "groups": []}"#, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces": [], "last": null}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands": []}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await ChatComposerConfigLoader(client: client).loadConfiguration(
            from: ChatComposerConfigState()
        )

        XCTAssertNil(result.configurationError)
        XCTAssertTrue(result.state.isSingleProfileMode)
    }

    @MainActor
    func testCatalogPublicationPrecedesReasoningWhileUnrelatedOrderRemains() async throws {
        let openRouterModel = "deepseek/deepseek-chat-v3-0324:free"
        var requestPaths: [String] = []
        // The reasoning response is held until the catalog-ready callback has
        // fired: the loader must publish the parsed/defaulted catalog before
        // it awaits reasoning (Slice 3).
        let releaseReasoning = DispatchSemaphore(value: 0)
        var reasoningResponseDelivered = false
        var catalogReadyCount = 0
        var catalogReadySnapshot: CatalogBaseSnapshot?
        var readyContinuation: CheckedContinuation<Void, Never>?

        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                requestPaths.append("/api/profiles")
                return apiTestJSONResponse("""
                {
                  "active": "default",
                  "profiles": [
                    {"name": "default", "is_active": true}
                  ],
                  "single_profile_mode": true
                }
                """, for: request)
            case "/api/models":
                requestPaths.append("/api/models")
                return apiTestJSONResponse("""
                {
                  "default_model": "\(openRouterModel)",
                  "active_provider": "openrouter",
                  "groups": [
                    {
                      "name": "OpenRouter",
                      "provider_id": "openrouter",
                      "models": [
                        {"id": "\(openRouterModel)", "name": "DeepSeek Chat v3 Free"}
                      ]
                    }
                  ]
                }
                """, for: request)
            case "/api/models/live":
                requestPaths.append("/api/models/live")
                return apiTestJSONResponse("""
                {
                  "provider": "openrouter",
                  "models": [
                    {"id": "\(openRouterModel)", "name": "DeepSeek Chat v3 Free"}
                  ]
                }
                """, for: request)
            case "/api/reasoning":
                XCTAssertEqual(releaseReasoning.wait(timeout: .now() + 5), .success)
                requestPaths.append("/api/reasoning")
                reasoningResponseDelivered = true
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            case "/api/workspaces":
                requestPaths.append("/api/workspaces")
                return apiTestJSONResponse(#"{"workspaces": [{"path": "/tmp/workspace"}]}"#, for: request)
            case "/api/commands":
                requestPaths.append("/api/commands")
                return apiTestJSONResponse(#"{"commands": [{"name": "status", "description": "Show status"}]}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        // The Slice 2 coordinator is the single catalog authority: its ordered
        // stream carries the neutral base/live projections. The loader consumes
        // that stream and must make no direct profile/switch request.
        let gateKey = ProfileContextGateKey(
            origin: NormalizedServerOrigin(
                scheme: "https",
                host: "loader-catalog-\(UUID().uuidString.lowercased()).test",
                port: 443
            ),
            cookieContextID: CatalogCookieContextID.injected(UUID())
        )
        let coordinator = ChatModelCatalogCoordinator(
            gateKey: gateKey,
            apiClientID: UUID(),
            authGeneration: 0,
            provider: { requestedProfile, operationID, operationGeneration in
                await client.modelCatalogStream(
                    requestedProfile: requestedProfile,
                    operationID: operationID,
                    operationGeneration: operationGeneration
                )
            },
            configuration: ChatModelCatalogCoordinator.Configuration(
                now: { Date(timeIntervalSince1970: 1_700_000_000) },
                freshnessInterval: 300,
                completedContextLimit: 4,
                telemetrySink: nil
            )
        )

        // Intended Slice 3 seam: a narrow @MainActor @Sendable onCatalogReady
        // callback carrying only the Sendable base projection.
        let loader = ChatComposerConfigLoader(
            client: client,
            catalogEvents: await coordinator.subscribe(),
            onCatalogReady: { @MainActor snapshot in
                catalogReadyCount += 1
                catalogReadySnapshot = snapshot
                readyContinuation?.resume()
                readyContinuation = nil
            }
        )

        let loadTask = Task {
            await loader.loadConfiguration(from: ChatComposerConfigState())
        }
        await coordinator.openPicker()

        // Catalog-ready must be visible while the reasoning response is still
        // held: publication precedes the reasoning await.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if catalogReadyCount > 0 {
                continuation.resume()
            } else {
                readyContinuation = continuation
            }
        }
        XCTAssertEqual(catalogReadyCount, 1, "onCatalogReady must fire exactly once")
        XCTAssertEqual(catalogReadySnapshot?.defaultModel, openRouterModel)
        XCTAssertFalse(
            reasoningResponseDelivered,
            "catalog must be published before the reasoning response is released"
        )

        releaseReasoning.signal()
        let result = await loadTask.value

        XCTAssertNil(result.configurationFailure)
        XCTAssertEqual(result.state.profileOptions.map(\.name), ["default"])
        XCTAssertEqual(result.state.selectedProfileName, "default")
        XCTAssertTrue(result.state.isSingleProfileMode)
        XCTAssertEqual(result.state.currentModel, openRouterModel)
        XCTAssertEqual(result.state.currentModelProvider, "openrouter")
        XCTAssertEqual(result.state.modelCatalogGroups.map(\.providerID), ["openrouter"])
        XCTAssertEqual(result.state.selectedReasoningEffort, "medium")
        XCTAssertEqual(result.state.workspaceSuggestions, ["/tmp/workspace"])
        XCTAssertEqual(result.state.agentCommands.map(\.name), ["status"])

        // Exactly one profiles/switch/base phase and no duplicate full load:
        // the loader itself performs zero direct profile/switch calls.
        XCTAssertEqual(requestPaths.filter { $0 == "/api/profiles" }.count, 1)
        XCTAssertEqual(requestPaths.filter { $0 == "/api/profile/switch" }.count, 0)
        XCTAssertEqual(requestPaths.first, "/api/profiles")
        XCTAssertEqual(Set(requestPaths).count, requestPaths.count, "no duplicate request path in one load")
        let catalogPaths: Set<String> = ["/api/models", "/api/models/live"]
        let catalogIndexes = requestPaths.indices.filter { catalogPaths.contains(requestPaths[$0]) }
        XCTAssertEqual(catalogIndexes.count, 2, "both neutral base and live projections arrive")
        let reasoningIndex = try XCTUnwrap(requestPaths.firstIndex(of: "/api/reasoning"))
        XCTAssertLessThan(
            catalogIndexes.max() ?? 0,
            reasoningIndex,
            "both base/live projections precede reasoning"
        )
        XCTAssertEqual(
            Array(requestPaths[reasoningIndex...]),
            ["/api/reasoning", "/api/workspaces", "/api/commands"],
            "reasoning → workspaces → commands order is preserved"
        )
    }
}

/// Pure gating logic for the composer reasoning-effort menu (issue #18):
/// building the option list from `supported_efforts` and deciding whether
/// the control is shown at all.
final class ReasoningEffortGatingTests: XCTestCase {
    func testOptionsFallBackToStaticListWithoutServerVocabulary() {
        XCTAssertEqual(
            ReasoningEffortOption.options(forSupportedEfforts: nil).map(\.id),
            ["none", "minimal", "low", "medium", "high", "xhigh"]
        )
        // Defensive: an empty list also falls back (the control is hidden
        // before this is rendered because supports_reasoning_effort is false).
        XCTAssertEqual(
            ReasoningEffortOption.options(forSupportedEfforts: []).map(\.id),
            ["none", "minimal", "low", "medium", "high", "xhigh"]
        )
    }

    func testOptionsFilterToServerVocabularyPreservingServerOrder() {
        let options = ReasoningEffortOption.options(forSupportedEfforts: ["high", "low"])
        XCTAssertEqual(options.map(\.id), ["high", "low"])
        XCTAssertEqual(options.map(\.title), ["High", "Low"])
    }

    func testOptionsNormalizeAndKeepUnknownServerEfforts() {
        let options = ReasoningEffortOption.options(forSupportedEfforts: [" Low ", "low", "", "turbo"])
        XCTAssertEqual(options.map(\.id), ["low", "turbo"])
        XCTAssertEqual(options.map(\.title), ["Low", "Turbo"])
    }

    func testShowsEffortControlFollowsServerFlag() {
        XCTAssertFalse(ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: false,
            supportedEfforts: ["low"]
        ))
        XCTAssertTrue(ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: true,
            supportedEfforts: []
        ))
    }

    func testShowsEffortControlInfersFromEffortsWhenFlagMissing() {
        XCTAssertFalse(ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: nil,
            supportedEfforts: []
        ))
        XCTAssertTrue(ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: nil,
            supportedEfforts: ["low"]
        ))
        // Older servers send neither field: keep today's behavior (visible).
        XCTAssertTrue(ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: nil,
            supportedEfforts: nil
        ))
    }
}
