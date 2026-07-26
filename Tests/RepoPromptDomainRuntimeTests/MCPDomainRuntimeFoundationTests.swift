import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class MCPDomainToolCatalogTests: XCTestCase {
    func testCanonicalCatalogHasExplicitUniqueCapabilityAndAdmissionClassification() {
        XCTAssertEqual(MCPDomainToolCatalog.entries.count, 27)
        XCTAssertEqual(Set(MCPDomainToolCatalog.orderedToolNames).count, 27)
        XCTAssertEqual(MCPDomainToolCatalog.globalToolNames, [
            "app_settings",
            "bind_context",
            "manage_workspaces",
        ])
        XCTAssertEqual(MCPDomainToolCatalog.windowToolNames.count, 24)
        XCTAssertEqual(Set(MCPDomainToolCatalog.classifications.keys), Set(MCPDomainToolCatalog.orderedToolNames))
        XCTAssertTrue(MCPDomainToolCatalog.entries.allSatisfy {
            MCPDomainToolCatalog.capabilities(for: $0.name) == [$0.capability]
                && MCPDomainToolCatalog.admissionClass(for: $0.name) == $0.admissionClass
        })
        XCTAssertTrue(MCPToolCapability.allCases.allSatisfy {
            !MCPDomainToolCatalog.toolNames(for: [$0]).isEmpty
        })
        XCTAssertEqual(MCPDomainToolCatalog.capabilities(for: "read_file"), [.fileRead])
        XCTAssertEqual(MCPDomainToolCatalog.capabilities(for: "file_search"), [.fileSearch])
        XCTAssertEqual(MCPDomainToolCatalog.capabilities(for: "history"), [.historyRead])
        XCTAssertNil(MCPDomainToolCatalog.admissionClass(for: "unknown"))
        XCTAssertTrue(MCPDomainToolCatalog.capabilities(for: "unknown").isEmpty)
    }

    func testEveryClientProfileHasExplicitPolicyAndPreservesFrozenVisibility() {
        XCTAssertEqual(
            Set(MCPClientToolPolicyCatalog.classifications.keys),
            Set(MCPClientToolPolicyProfile.allCases)
        )
        let expected: [MCPClientToolPolicyProfile: [String]] = [
            .direct: ["app_settings", "bind_context", "manage_workspaces", "manage_selection", "file_actions", "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt", "apply_edits", "oracle_utils", "oracle_send", "git", "manage_worktree", "context_builder", "agent_run", "agent_manage", "history"],
            .discovery: ["manage_selection", "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt", "git", "ask_user", "history"],
            .agentModeGenericExplore: ["app_settings", "get_code_structure", "get_file_tree", "read_file", "file_search", "git", "ask_user", "share_thoughts", "set_status", "wait_for_next_user_instruction", "history"],
            .agentModeGenericEngineer: ["app_settings", "manage_selection", "file_actions", "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt", "apply_edits", "ask_oracle", "oracle_chat_log", "git", "manage_worktree", "context_builder", "ask_user", "agent_explore", "share_thoughts", "set_status", "wait_for_next_user_instruction", "history"],
            .agentModeGenericEngineerOrchestrator: ["app_settings", "manage_selection", "file_actions", "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt", "apply_edits", "ask_oracle", "oracle_chat_log", "git", "manage_worktree", "context_builder", "ask_user", "agent_explore", "agent_run", "agent_manage", "share_thoughts", "set_status", "wait_for_next_user_instruction", "history"],
            .agentModeClaudeEngineer: ["app_settings", "manage_selection", "file_actions", "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt", "apply_edits", "ask_oracle", "oracle_chat_log", "git", "manage_worktree", "context_builder", "ask_user", "agent_explore", "set_status", "history"],
            .agentModeCodexEngineer: ["app_settings", "manage_selection", "file_actions", "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt", "apply_edits", "ask_oracle", "oracle_chat_log", "git", "manage_worktree", "context_builder", "ask_user", "agent_explore", "set_status", "history"],
            .agentModeOpenCodeEngineer: ["app_settings", "manage_selection", "file_actions", "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt", "apply_edits", "ask_oracle", "oracle_chat_log", "git", "manage_worktree", "context_builder", "ask_user", "agent_explore", "set_status", "history"],
            .agentModeCursorEngineer: ["app_settings", "manage_selection", "file_actions", "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt", "apply_edits", "ask_oracle", "oracle_chat_log", "git", "manage_worktree", "context_builder", "ask_user", "agent_explore", "set_status", "history"],
        ]
        for profile in MCPClientToolPolicyProfile.allCases {
            XCTAssertEqual(
                MCPClientToolPolicyCatalog.resolvedToolNames(for: profile),
                expected[profile] ?? [],
                profile.rawValue
            )
            let expectedAnnotations: MCPClientToolAnnotationProfile = profile == .agentModeCodexEngineer
                ? .suppressReadOnlyHint
                : .canonical
            XCTAssertEqual(
                MCPClientToolPolicyCatalog.classification(for: profile).annotationProfile,
                expectedAnnotations,
                profile.rawValue
            )
        }
    }
}

final class MCPDomainToolRegistryTests: XCTestCase {
    func testRegistrationIsAtomicAndRejectsUnknownScopeDuplicateAndFingerprintDrift() async throws {
        let registry = MCPDomainToolRegistry(registryID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let readFile = Self.binding(name: MCPWindowToolName.readFile)
        let initial = await registry.snapshot()

        await assertRegistryError(.emptyRegistration) {
            try await registry.register(
                registrationID: .init(rawValue: 1),
                scope: .window(id: 1),
                bindings: []
            )
        }
        await assertRegistryError(.invalidWindowID(0)) {
            try await registry.register(
                registrationID: .init(rawValue: 1),
                scope: .window(id: 0),
                bindings: [readFile]
            )
        }
        await assertRegistryError(.duplicateToolName(MCPWindowToolName.readFile)) {
            try await registry.register(
                registrationID: .init(rawValue: 1),
                scope: .window(id: 1),
                bindings: [readFile, readFile]
            )
        }
        await assertRegistryError(.unknownToolName("unknown")) {
            try await registry.register(
                registrationID: .init(rawValue: 1),
                scope: .window(id: 1),
                bindings: [Self.binding(name: "unknown")]
            )
        }
        await assertRegistryError(.scopeMismatch(toolName: MCPWindowToolName.readFile, expected: .window, actual: .application)) {
            try await registry.register(
                registrationID: .init(rawValue: 1),
                scope: .application,
                bindings: [readFile]
            )
        }
        let afterRejectedRegistrations = await registry.snapshot()
        XCTAssertEqual(afterRejectedRegistrations.revision, initial.revision)

        let firstHandle = try await registry.register(
            registrationID: .init(rawValue: 1),
            scope: .window(id: 1),
            bindings: [readFile]
        )
        await assertRegistryError(.bindingAlreadyRegistered(toolName: MCPWindowToolName.readFile, scope: .window(id: 1))) {
            try await registry.register(
                registrationID: .init(rawValue: 2),
                scope: .window(id: 1),
                bindings: [readFile]
            )
        }
        let beforeConflict = await registry.snapshot()
        await assertRegistryError(.conflictingDefinition(toolName: MCPWindowToolName.readFile)) {
            try await registry.register(
                registrationID: .init(rawValue: 3),
                scope: .window(id: 2),
                bindings: [Self.binding(name: MCPWindowToolName.readFile, description: "changed")]
            )
        }
        let afterConflict = await registry.snapshot()
        XCTAssertEqual(afterConflict.revision, beforeConflict.revision)
        let firstRemoval = await registry.unregister(firstHandle)
        XCTAssertEqual(firstRemoval, .removed)
        await assertRegistryError(.conflictingDefinition(toolName: MCPWindowToolName.readFile)) {
            try await registry.register(
                registrationID: .init(rawValue: 3),
                scope: .window(id: 2),
                bindings: [Self.binding(name: MCPWindowToolName.readFile, description: "changed")]
            )
        }
    }

    func testSnapshotsDeduplicateCanonicalDefinitionsAndResolutionStaysScopeSpecific() async throws {
        let registry = MCPDomainToolRegistry()
        let first = try await registry.register(
            registrationID: .init(rawValue: 1),
            scope: .window(id: 1),
            bindings: [Self.binding(name: MCPWindowToolName.readFile, result: "one")]
        )
        let second = try await registry.register(
            registrationID: .init(rawValue: 2),
            scope: .window(id: 2),
            bindings: [Self.binding(name: MCPWindowToolName.readFile, result: "two")]
        )
        let global = try await registry.register(
            registrationID: .init(rawValue: 3),
            scope: .application,
            bindings: [Self.binding(name: MCPGlobalToolName.appSettings, result: "global")]
        )
        let snapshot = await registry.snapshot()
        XCTAssertEqual(snapshot.toolNames, [MCPGlobalToolName.appSettings, MCPWindowToolName.readFile])
        XCTAssertEqual(snapshot.activeScopesByToolName[MCPWindowToolName.readFile], [.window(id: 1), .window(id: 2)])
        XCTAssertFalse(snapshot.catalogFingerprint.isEmpty)

        let firstResolution = await registry.resolve(toolName: MCPWindowToolName.readFile, scope: .window(id: 1))
        let secondResolution = await registry.resolve(toolName: MCPWindowToolName.readFile, scope: .window(id: 2))
        let firstTool = try XCTUnwrap(firstResolution)
        let secondTool = try XCTUnwrap(secondResolution)
        let firstResult = try await firstTool.binding([:])
        let secondResult = try await secondTool.binding([:])
        XCTAssertEqual(firstResult.stringValue, "one")
        XCTAssertEqual(secondResult.stringValue, "two")
        let applicationResolution = await registry.resolve(toolName: MCPWindowToolName.readFile, scope: .application)
        XCTAssertNil(applicationResolution)

        let firstRemoval = await registry.unregister(first)
        let repeatedRemoval = await registry.unregister(first)
        let retainedResolution = await registry.resolve(toolName: MCPWindowToolName.readFile, scope: .window(id: 2))
        let secondIsActive = await registry.isActive(second)
        let globalIsActive = await registry.isActive(global)
        XCTAssertEqual(firstRemoval, .removed)
        XCTAssertEqual(repeatedRemoval, .unchanged)
        XCTAssertNotNil(retainedResolution)
        XCTAssertTrue(secondIsActive)
        XCTAssertTrue(globalIsActive)
    }

    func testReplacingARegistrationInvalidatesThePriorGenerationHandle() async throws {
        let registry = MCPDomainToolRegistry()
        let registrationID = MCPDomainToolRegistrationID(rawValue: 1)
        let first = try await registry.register(
            registrationID: registrationID,
            scope: .window(id: 1),
            bindings: [Self.binding(name: MCPWindowToolName.readFile, result: "first")]
        )
        let second = try await registry.register(
            registrationID: registrationID,
            scope: .window(id: 1),
            bindings: [Self.binding(name: MCPWindowToolName.readFile, result: "second")]
        )

        let firstIsActive = await registry.isActive(first)
        let secondIsActive = await registry.isActive(second)
        let staleRemoval = await registry.unregister(first)
        let currentResolution = await registry.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: .window(id: 1)
        )
        XCTAssertFalse(firstIsActive)
        XCTAssertTrue(secondIsActive)
        XCTAssertEqual(staleRemoval, .unchanged)
        let resolved = try XCTUnwrap(currentResolution)
        let result = try await resolved.binding([:])
        XCTAssertEqual(result.stringValue, "second")
    }

    func testResolvedInvocationMayFinishAfterUnregisterButNewResolutionFails() async throws {
        let registry = MCPDomainToolRegistry()
        let handle = try await registry.register(
            registrationID: .init(rawValue: 1),
            scope: .window(id: 1),
            bindings: [Self.binding(name: MCPWindowToolName.readFile, result: "retained")]
        )
        let initialResolution = await registry.resolve(toolName: MCPWindowToolName.readFile, scope: .window(id: 1))
        let resolved = try XCTUnwrap(initialResolution)
        let removal = await registry.unregister(handle)
        let resolutionAfterRemoval = await registry.resolve(toolName: MCPWindowToolName.readFile, scope: .window(id: 1))
        let retainedResult = try await resolved.binding([:])
        XCTAssertEqual(removal, .removed)
        XCTAssertNil(resolutionAfterRemoval)
        XCTAssertEqual(retainedResult.stringValue, "retained")
    }

    func testConcurrentWindowRegistrationsPublishOneCanonicalDefinition() async throws {
        let registry = MCPDomainToolRegistry()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 1 ... 12 {
                group.addTask {
                    _ = try await registry.register(
                        registrationID: .init(rawValue: UInt(id)),
                        scope: .window(id: id),
                        bindings: [Self.binding(name: MCPWindowToolName.readFile)]
                    )
                }
            }
            try await group.waitForAll()
        }
        let snapshot = await registry.snapshot()
        XCTAssertEqual(snapshot.toolNames, [MCPWindowToolName.readFile])
        XCTAssertEqual(snapshot.activeScopesByToolName[MCPWindowToolName.readFile]?.count, 12)
        XCTAssertEqual(snapshot.revision, 12)
    }

    private static func binding(
        name: String,
        description: String = "fixture",
        result: String = "ok"
    ) -> MCPDomainToolBinding {
        MCPDomainToolBinding(
            definition: MCPDomainToolDefinition(
                name: name,
                description: description,
                inputSchema: .object([
                    "properties": .object([:]),
                    "type": .string("object"),
                ]),
                annotations: .init(
                    readOnlyHint: true,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ),
            operation: { _ in .string(result) }
        )
    }

    private func assertRegistryError(
        _ expected: MCPDomainToolRegistryError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected registry error: \(expected)")
        } catch let error as MCPDomainToolRegistryError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

final class MCPDomainToolFingerprintTests: XCTestCase {
    func testFingerprintCanonicalizesSchemaKeysAndTracksEveryMetadataField() throws {
        let first = definition(schema: .object([
            "properties": .object(["b": .string("two"), "a": .string("one")]),
            "type": .string("object"),
        ]))
        let reordered = definition(schema: .object([
            "type": .string("object"),
            "properties": .object(["a": .string("one"), "b": .string("two")]),
        ]))
        XCTAssertEqual(
            try MCPDomainToolFingerprint(definition: first),
            try MCPDomainToolFingerprint(definition: reordered)
        )

        let fingerprint = try MCPDomainToolFingerprint(definition: first)
        XCTAssertTrue(fingerprint.goldenSignature(index: 4).hasPrefix("4|read_file|enabled=true|ann="))
        XCTAssertNotEqual(
            fingerprint,
            try MCPDomainToolFingerprint(definition: definition(schema: first.inputSchema, description: "changed"))
        )
        XCTAssertNotEqual(
            fingerprint,
            try MCPDomainToolFingerprint(definition: MCPDomainToolDefinition(
                name: first.name,
                description: first.description,
                inputSchema: first.inputSchema,
                annotations: .init(readOnlyHint: false),
                isEnabledByDefault: first.isEnabledByDefault
            ))
        )
    }

    private func definition(
        schema: Value,
        description: String = "fixture"
    ) -> MCPDomainToolDefinition {
        MCPDomainToolDefinition(
            name: MCPWindowToolName.readFile,
            description: description,
            inputSchema: schema,
            annotations: .init(readOnlyHint: true),
            isEnabledByDefault: true
        )
    }
}

final class RepoPromptDomainRuntimeLifecycleTests: XCTestCase {
    func testInertRuntimeStartIsIdempotentAndStoppedInstanceCannotRestart() async throws {
        let directory = URL(fileURLWithPath: "/tmp/runtime-owner-test", isDirectory: true)
        let runtime = MCPDomainRuntime(
            configuration: .init(
                mode: .app,
                profileIdentifier: "owner-test",
                storageDirectory: directory,
                eventDirectory: directory,
                temporaryDirectory: directory
            ),
            runtimeID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            lifecycleGeneration: 7,
            processID: 42,
            createdAt: Date(timeIntervalSince1970: 123),
            registryID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        )

        let created = await runtime.snapshot()
        XCTAssertEqual(created.lifecycle, .created)
        XCTAssertEqual(created.publicationSequence, 0)
        try await runtime.start()
        try await runtime.start()
        let ready = await runtime.snapshot()
        XCTAssertEqual(ready.lifecycle, .ready)
        XCTAssertEqual(ready.publicationSequence, 2)
        XCTAssertEqual(ready.identity.lifecycleGeneration, 7)
        XCTAssertEqual(ready.identity.processID, 42)
        XCTAssertEqual(ready.catalogRevision, 0)

        let result = await runtime.shutdown()
        XCTAssertEqual(result.previousLifecycle, .ready)
        XCTAssertEqual(result.finalLifecycle, .stopped)
        let stopped = await runtime.snapshot()
        XCTAssertEqual(stopped.publicationSequence, 4)
        do {
            try await runtime.start()
            XCTFail("Stopped runtime restarted")
        } catch let error as DomainRuntimeLifecycleError {
            XCTAssertEqual(error, .stoppedRuntimeCannotRestart)
        }
    }
}
