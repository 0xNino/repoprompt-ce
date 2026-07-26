import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainWorkspaceContextAuthorityTests: XCTestCase {
    func testBootstrapIsReadOnlyAndFirstWorkingMutationCreatesJournalAndRollbackWithoutRewritingSavedDocument() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.workspaceFile)
        let runtime = fixture.runtime(legacyDefaults: ["GlobalCustomStorageURL": Data("legacy".utf8)])

        try await runtime.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storageRoot.appendingPathComponent("DomainRuntime").path))
        let initial = await runtime.workspaceStore.snapshot()
        XCTAssertEqual(initial.workspaces.first?.revisions, .initial)

        let changed = try fixture.document(prompt: "working")
        let outcome = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(changed)
        ))

        XCTAssertEqual(outcome.disposition, .applied)
        XCTAssertEqual(outcome.after, .init(workingRevision: 1, savedRevision: 0, dirtyRevision: 1))
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceFile), original)
        let runtimeFiles = try allFiles(below: fixture.storageRoot.appendingPathComponent("DomainRuntime"))
        XCTAssertTrue(runtimeFiles.contains { $0.lastPathComponent == "\(fixture.workspaceID.uuidString).json" })
        XCTAssertTrue(runtimeFiles.contains { $0.lastPathComponent == "manifest.json" })
        XCTAssertTrue(runtimeFiles.contains { $0.lastPathComponent == "legacy-runtime-defaults.json" })
    }

    func testExplicitSaveAdvancesSavedRevisionAndRestartRecoversDirtyWorkingState() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let changed = try fixture.document(prompt: "recover me")
        let mutation = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(changed)
        ))
        XCTAssertEqual(mutation.disposition, .applied)
        _ = await runtime.shutdown()

        let restarted = fixture.runtime(generation: 2)
        try await restarted.start()
        let recovered = await restarted.workspaceStore.snapshot().workspaces.first
        XCTAssertEqual(recovered?.document.documentBytes, changed.documentBytes)
        XCTAssertEqual(recovered?.revisions.dirtyRevision, 1)

        let save = await restarted.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 1,
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(save.disposition, .applied)
        XCTAssertEqual(save.after, .init(workingRevision: 1, savedRevision: 1, dirtyRevision: nil))
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceFile), changed.documentBytes)
    }

    func testOperationDeduplicationCollisionAndWriterCASAreDeterministic() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let first = fixture.runtime(runtimeID: UUID())
        let second = fixture.runtime(runtimeID: UUID())
        try await first.start()
        try await second.start()
        let operationID = UUID()
        let changed = try fixture.document(prompt: "first writer")
        let envelope = DomainWorkspaceCommandEnvelope(
            operationID: operationID,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(changed)
        )

        let applied = await first.workspaceStore.execute(envelope)
        let duplicate = await first.workspaceStore.execute(envelope)
        XCTAssertEqual(applied.disposition, .applied)
        XCTAssertEqual(duplicate.disposition, .deduplicated)

        let collision = await first.workspaceStore.execute(.init(
            operationID: operationID,
            expectedWorkspaceRevision: 1,
            origin: .standalone,
            command: .replaceWorkingDocument(try fixture.document(prompt: "collision"))
        ))
        XCTAssertEqual(collision.errorCode, .operationIDCollision)

        let staleWriter = await second.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(try fixture.document(prompt: "stale"))
        ))
        XCTAssertEqual(staleWriter.disposition, .conflict)
        XCTAssertEqual(staleWriter.errorCode, .stateConflict)
        XCTAssertEqual(staleWriter.workspace?.document.documentBytes, changed.documentBytes)
    }

    func testExternalReloadIsAppliedWhenCleanAndConflictsWhenDirty() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()

        let external = try fixture.document(prompt: "external clean")
        try external.documentBytes.write(to: fixture.workspaceFile, options: .atomic)
        await runtime.workspaceStore.reloadExternalChanges()
        var snapshot = await runtime.workspaceStore.snapshot().workspaces.first
        XCTAssertEqual(snapshot?.document.documentBytes, external.documentBytes)
        XCTAssertEqual(snapshot?.revisions.dirtyRevision, nil)

        let working = try fixture.document(prompt: "local dirty")
        let result = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: snapshot?.revisions.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(working)
        ))
        XCTAssertEqual(result.disposition, .applied)
        await runtime.workspaceStore.reloadExternalChanges()
        snapshot = await runtime.workspaceStore.snapshot().workspaces.first
        XCTAssertEqual(snapshot?.health, .writable)
        XCTAssertEqual(snapshot?.document.documentBytes, working.documentBytes)

        let conflictingExternal = try fixture.document(prompt: "external conflict")
        try conflictingExternal.documentBytes.write(to: fixture.workspaceFile, options: .atomic)
        await runtime.workspaceStore.reloadExternalChanges()
        snapshot = await runtime.workspaceStore.snapshot().workspaces.first
        if case .externalConflict = snapshot?.health {
            // Expected.
        } else {
            XCTFail("Dirty workspace did not enter external-conflict state")
        }
        XCTAssertEqual(snapshot?.document.documentBytes, working.documentBytes)

        let rebase = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: snapshot?.revisions.workingRevision,
            origin: .standalone,
            command: .resolveExternalConflict(workspaceID: fixture.workspaceID, acceptExternal: false)
        ))
        XCTAssertEqual(rebase.disposition, .applied)
        XCTAssertEqual(rebase.workspace?.health, .writable)
        XCTAssertNotNil(rebase.after?.dirtyRevision)
        _ = await runtime.shutdown()

        let restarted = fixture.runtime(generation: 2)
        try await restarted.start()
        let recovered = await restarted.workspaceStore.snapshot().workspaces.first
        XCTAssertEqual(recovered?.document.documentBytes, working.documentBytes)
        XCTAssertEqual(recovered?.health, .writable)
        XCTAssertNotNil(recovered?.revisions.dirtyRevision)
        let save = await restarted.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: recovered?.revisions.workingRevision,
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(save.disposition, .applied)
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceFile), working.documentBytes)
    }

    func testFutureJournalDegradesToReadOnlyWithoutDiscardingSavedDocument() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        _ = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(try fixture.document(prompt: "journal"))
        ))
        _ = await runtime.shutdown()
        let journal = try XCTUnwrap(try allFiles(below: fixture.storageRoot.appendingPathComponent("DomainRuntime"))
            .first {
                $0.path.contains("working-journals")
                    && $0.lastPathComponent == "\(fixture.workspaceID.uuidString).json"
            })
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        object["version"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: journal, options: .atomic)

        let restarted = fixture.runtime(generation: 2)
        try await restarted.start()
        let runtimeSnapshot = await restarted.snapshot()
        let workspace = await restarted.workspaceStore.snapshot().workspaces.first
        XCTAssertEqual(runtimeSnapshot.lifecycle, .degraded)
        XCTAssertEqual(workspace?.document.documentBytes, try Data(contentsOf: fixture.workspaceFile))
        XCTAssertFalse(workspace?.health.acceptsMutations ?? true)
    }

    func testRoutingGenerationsAndRunLaunchTokensAreAuthoritativeAndSingleUse() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime(generation: 9)
        try await runtime.start()
        let connectionID = UUID()
        let registered = await runtime.routingCoordinator.registerConnection(
            connectionID: connectionID,
            operationID: UUID()
        )
        let registration = try XCTUnwrap(registered.snapshot.connections.first?.registration)
        let context = DomainContextIdentity(workspaceID: fixture.workspaceID, contextID: fixture.contextID)
        let bound = await runtime.routingCoordinator.bind(
            connection: registration,
            binding: .context(context, explicit: true),
            operationID: UUID()
        )
        XCTAssertEqual(bound.disposition, .applied)
        _ = await runtime.routingCoordinator.registerConnection(connectionID: connectionID, operationID: UUID())
        let stale = await runtime.routingCoordinator.bind(
            connection: registration,
            binding: .unbound,
            operationID: UUID()
        )
        XCTAssertEqual(stale.disposition, .staleGeneration)

        let token = try await runtime.routingCoordinator.issueLaunchToken(.init(
            runID: UUID(),
            context: context,
            expectedContextRevision: 0,
            windowID: nil,
            clientPrincipal: "test",
            providerIdentifier: "fixture",
            runPurpose: "test"
        ))
        let rejectedIdentity = await runtime.routingCoordinator.redeemLaunchToken(
            material: token.material,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: 9,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: "other",
            providerIdentifier: "fixture"
        )
        XCTAssertEqual(rejectedIdentity, .identityMismatch)
        let accepted = await runtime.routingCoordinator.redeemLaunchToken(
            material: token.material,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: 9,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: "test",
            providerIdentifier: "fixture"
        )
        if case .accepted = accepted {
            // Expected.
        } else {
            XCTFail("Launch token was not accepted: \(accepted)")
        }
        let replay = await runtime.routingCoordinator.redeemLaunchToken(
            material: token.material,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: 9,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: "test",
            providerIdentifier: "fixture"
        )
        XCTAssertEqual(replay, .alreadyConsumed)
    }

    private func allFiles(below root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { !$0.hasDirectoryPath }
    }
}

private struct Fixture {
    let root: URL
    let storageRoot: URL
    let workspaceID: UUID
    let contextID: UUID
    let workspaceFile: URL

    static func make() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("domain-context-authority-\(UUID().uuidString)", isDirectory: true)
        let storageRoot = root.appendingPathComponent("state", isDirectory: true)
        let workspaceRoot = storageRoot.appendingPathComponent("Workspaces", isDirectory: true)
        let workspaceID = UUID()
        let contextID = UUID()
        let directory = workspaceRoot.appendingPathComponent("Workspace-Fixture-\(workspaceID.uuidString)", isDirectory: true)
        let workspaceFile = directory.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = Fixture(
            root: root,
            storageRoot: storageRoot,
            workspaceID: workspaceID,
            contextID: contextID,
            workspaceFile: workspaceFile
        )
        try fixture.document(prompt: "saved").documentBytes.write(to: workspaceFile)
        let index: [[String: Any]] = [[
            "id": workspaceID.uuidString,
            "name": "Fixture",
            "customStoragePath": NSNull(),
            "isSystemWorkspace": false,
            "isHiddenInMenus": false,
        ]]
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
            .write(to: workspaceRoot.appendingPathComponent("workspacesIndex.json"))
        return fixture
    }

    func runtime(
        runtimeID: UUID = UUID(),
        generation: UInt64 = 1,
        legacyDefaults: [String: Data] = [:]
    ) -> MCPDomainRuntime {
        MCPDomainRuntime(
            configuration: .init(
                mode: .standalone,
                profileIdentifier: "fixture-profile",
                storageDirectory: storageRoot,
                eventDirectory: root.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true),
                legacyRuntimeDefaults: legacyDefaults,
                externalReloadInterval: nil
            ),
            runtimeID: runtimeID,
            lifecycleGeneration: generation
        )
    }

    func document(prompt: String) throws -> DomainWorkspaceDocument {
        let object: [String: Any] = [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "Fixture",
            "repoPaths": ["/tmp/repo"],
            "isSystemWorkspace": false,
            "isHiddenInMenus": false,
            "activeComposeTabID": contextID.uuidString,
            "composeTabs": [[
                "id": contextID.uuidString,
                "name": "Context",
                "prompt": prompt,
                "unknownFutureField": ["preserved": true],
            ]],
            "unknownWorkspaceField": "preserved",
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try DomainWorkspaceDocument.decode(documentBytes: data, fileURL: workspaceFile)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
