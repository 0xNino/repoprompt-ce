import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import XCTest

final class DirectHeadlessCompositionTests: XCTestCase {
    func testProductionStandaloneCompositionResolvesAndDispatchesAllTwentySevenToolsWithoutAppTypes() async throws {
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-composition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let service = DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "composition-test",
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": root.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            currentDirectory: root
        )
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let snapshot = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        let context = DomainToolInvocationSecurityContext(
            principal: prepared.principal,
            connectionID: prepared.connectionID,
            connectionGeneration: prepared.connectionGeneration,
            invocationID: UUID(),
            runtimeID: prepared.runtime.identity.runtimeID,
            runtimeGeneration: prepared.runtime.identity.lifecycleGeneration,
            workspaceID: snapshot.identity.workspaceID,
            workspaceRevision: snapshot.workspace.revisions.workingRevision,
            authorizedCanonicalRoots: Set(snapshot.roots.map(\.path)),
            hasAuthoritativeRoutingContext: true,
            ephemeralGrantedToolNames: []
        )
        let fixturePath = root.appendingPathComponent("Package.swift").path
        let arguments: [String: [String: Value]] = [
            "app_settings": ["op": .string("list")],
            "bind_context": ["op": .string("status")],
            "manage_workspaces": ["action": .string("list")],
            "manage_selection": ["op": .string("get")],
            "file_actions": ["action": .string("create"), "path": .string(profile.appendingPathComponent("denied.txt").path)],
            "get_code_structure": ["paths": .array([.string(fixturePath)]), "signatures": .bool(false)],
            "get_file_tree": ["type": .string("roots")],
            "read_file": ["path": .string(fixturePath), "start_line": .int(1), "limit": .int(1)],
            "file_search": ["pattern": .string("swift-tools-version"), "path": .string(fixturePath), "regex": .bool(false)],
            "workspace_context": ["op": .string("snapshot")],
            "prompt": ["op": .string("get")],
            "apply_edits": ["path": .string(fixturePath), "search": .string("not-present"), "replace": .string("never")],
            "oracle_utils": ["op": .string("models")],
            "ask_oracle": ["message": .string("Reply exactly OK")],
            "oracle_send": ["chat_id": .string(UUID().uuidString), "message": .string("continue")],
            "oracle_chat_log": [:],
            "context_builder": ["instructions": .string("Inspect the workspace")],
            "ask_user": ["questions": .array([.object(["id": .string("q"), "question": .string("Continue?")])])],
            "git": ["op": .string("status")],
            "manage_worktree": ["op": .string("list")],
            "agent_explore": ["op": .string("poll"), "session_id": .string(UUID().uuidString)],
            "agent_run": ["op": .string("poll"), "session_id": .string(UUID().uuidString)],
            "agent_manage": ["op": .string("list_agents"), "roles_only": .bool(true)],
            "share_thoughts": ["text": .string("progress")],
            "set_status": ["session_name": .string("composition")],
            "wait_for_next_user_instruction": [:],
            "history": ["op": .string("list_sessions")]
        ]
        XCTAssertEqual(arguments.count, 27)
        XCTAssertEqual(Set(arguments.keys), Set(MCPDomainCanonicalToolDefinitions.definitions.map(\.name)))

        var dispatched: Set<String> = []
        for name in MCPDomainToolCatalog.orderedToolNames {
            let scope: MCPDomainToolRegistrationScope = ["app_settings", "bind_context", "manage_workspaces"].contains(name)
                ? .application
                : .standalone(id: prepared.scopeID)
            let resolution = try await prepared.runtime.domainHost.resolve(toolName: name, scope: scope)
            var invocationContext = context
            invocationContext = DomainToolInvocationSecurityContext(
                principal: context.principal,
                connectionID: context.connectionID,
                connectionGeneration: context.connectionGeneration,
                invocationID: UUID(),
                runtimeID: context.runtimeID,
                runtimeGeneration: context.runtimeGeneration,
                workspaceID: context.workspaceID,
                workspaceRevision: context.workspaceRevision,
                authorizedCanonicalRoots: context.authorizedCanonicalRoots,
                hasAuthoritativeRoutingContext: context.hasAuthoritativeRoutingContext,
                ephemeralGrantedToolNames: context.ephemeralGrantedToolNames
            )
            do {
                _ = try await prepared.runtime.domainHost.invoke(MCPDomainHostInvocation(
                    invocationID: invocationContext.invocationID,
                    connectionID: prepared.connectionID,
                    resolution: resolution,
                    arguments: XCTUnwrap(arguments[name]),
                    securityContext: invocationContext
                ))
            } catch {
                let text = String(describing: error)
                XCTAssertFalse(text.contains("Missing canonical definition"), "tool=\(name): \(text)")
                XCTAssertFalse(text.contains("No standalone"), "tool=\(name): \(text)")
                XCTAssertFalse(text.contains("live Agent session/worktree binding adapter"), "tool=\(name): \(text)")
            }
            dispatched.insert(name)
        }
        XCTAssertEqual(dispatched, Set(arguments.keys))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.appendingPathComponent("denied.txt").path))
    }
}
