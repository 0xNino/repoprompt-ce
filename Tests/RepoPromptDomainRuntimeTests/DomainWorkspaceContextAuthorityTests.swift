import Darwin
import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainWorkspaceContextAuthorityTests: XCTestCase {
    func testAwaitedReadRegistrationRoutesMissingWorkspaceWithoutPersistence() async throws {
        let fixture = try Fixture.make(includeWorkspace: false)
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let document = try fixture.document(prompt: "ephemeral")

        let registered = await runtime.workspaceStore.registerReadDocument(document)
        XCTAssertEqual(registered.document.contentDigest, document.contentDigest)
        XCTAssertEqual(registered.contexts.first?.metadata.identity.contextID, fixture.contextID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceFile.path))
        let catalog = await runtime.workspaceStore.snapshot()
        XCTAssertTrue(catalog.workspaces.isEmpty)

        let connectionID = UUID()
        let registrationOutcome = await runtime.routingCoordinator.registerConnection(
            connectionID: connectionID,
            operationID: UUID()
        )
        let registration = try XCTUnwrap(registrationOutcome.snapshot.connections.first?.registration)
        let bound = await runtime.routingCoordinator.bind(
            connection: registration,
            binding: .context(
                DomainContextIdentity(workspaceID: fixture.workspaceID, contextID: fixture.contextID),
                explicit: true
            ),
            operationID: UUID()
        )
        XCTAssertEqual(bound.disposition, .applied)
        let handle = try await runtime.routingCoordinator.resolveReadContext(connection: registration)
        XCTAssertEqual(handle.workspaceRevision, registered.revisions.workingRevision)
        XCTAssertEqual(handle.contextRevision, registered.contexts.first?.revisions.workingRevision)

        let rejectedReplace = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            origin: .standalone,
            command: .replaceWorkingDocument(document)
        ))
        XCTAssertEqual(rejectedReplace.disposition, .invalid)
        let stillRegistered = await runtime.contextStore.workspaceSnapshot(fixture.workspaceID)
        XCTAssertNotNil(stillRegistered)

        // A different newer canonical document supersedes the transient overlay.
        let canonicalDocument = try fixture.document(prompt: "canonical")
        let created = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(canonicalDocument)
        ))
        XCTAssertEqual(created.disposition, .applied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspaceFile.path))
        let registeredCanonicalSnapshot = await runtime.contextStore.workspaceSnapshot(fixture.workspaceID)
        let canonicalSnapshot = try XCTUnwrap(registeredCanonicalSnapshot)
        XCTAssertEqual(canonicalSnapshot.document.contentDigest, canonicalDocument.contentDigest)
        XCTAssertNotEqual(canonicalSnapshot.document.contentDigest, document.contentDigest)
    }

    func testSubscriptionBootstrapsBeforePublishingFirstProjection() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()

        let subscription = await runtime.workspaceStore.subscribe()

        XCTAssertTrue(subscription.snapshot.isBootstrapped)
        XCTAssertEqual(subscription.snapshot.workspaces.map(\.document.workspaceID), [fixture.workspaceID])
        XCTAssertEqual(subscription.snapshot.workspaces.first?.document.documentBytes, try Data(contentsOf: fixture.workspaceFile))
    }

    func testExplicitCreatePersistsAndDeletePrunesCatalogDespiteStaleLegacyIndex() async throws {
        let fixture = try Fixture.make(includeWorkspace: false)
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let document = try fixture.document(prompt: "created")
        let created = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(document)
        ))

        XCTAssertEqual(created.disposition, .applied)
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceFile), document.documentBytes)
        _ = await runtime.shutdown()

        let restarted = fixture.runtime(generation: 2)
        try await restarted.start()
        let restored = await restarted.workspaceStore.snapshot()
        XCTAssertEqual(restored.workspaces.map(\.document.workspaceID), [fixture.workspaceID])
        let deleted = await restarted.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: restored.catalogRevision,
            expectedWorkspaceRevision: restored.workspaces.first?.revisions.workingRevision,
            origin: .standalone,
            command: .deleteWorkspace(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(deleted.disposition, .applied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceFile.path))
        _ = await restarted.shutdown()
        try fixture.writeLegacyIndex()

        // The intentionally stale legacy index still names the workspace. Runtime catalog
        // deletion truth must prevent resurrection or false degraded state.
        let finalRuntime = fixture.runtime(generation: 3)
        try await finalRuntime.start()
        let finalSnapshot = await finalRuntime.workspaceStore.snapshot()
        XCTAssertTrue(finalSnapshot.workspaces.isEmpty)
        XCTAssertEqual(finalSnapshot.health, .writable)
    }

    func testPendingSaveJournalRecoversCommittedDocumentWithoutManufacturedConflict() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let changed = try fixture.document(prompt: "crash-safe")
        let working = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(changed)
        ))
        XCTAssertEqual(working.disposition, .applied)
        _ = await runtime.shutdown()

        let journalURL = try XCTUnwrap(try allFiles(below: fixture.storageRoot.appendingPathComponent("DomainRuntime"))
            .first { $0.path.contains("working-journals") && $0.lastPathComponent == "\(fixture.workspaceID.uuidString).json" })
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let journal = try decoder.decode(DomainWorkingJournal.self, from: Data(contentsOf: journalURL))
        let operationID = UUID()
        let pending = DomainWorkingJournal(
            workspaceID: journal.workspaceID,
            fileURL: journal.fileURL,
            revisions: journal.revisions,
            savedDigest: journal.savedDigest,
            workingDocument: changed.documentBytes,
            contextRevisions: journal.contextRevisions,
            contextDigests: journal.contextDigests,
            contextTombstones: journal.contextTombstones,
            operations: journal.operations,
            pendingSave: DomainPendingSave(operationID: operationID, documentDigest: changed.contentDigest),
            updatedAt: Date()
        )
        try encoder.encode(pending).write(to: journalURL, options: .atomic)
        try changed.documentBytes.write(to: fixture.workspaceFile, options: .atomic)

        let restarted = fixture.runtime(generation: 2)
        try await restarted.start()
        let recoveredSnapshot = await restarted.workspaceStore.snapshot()
        let recovered = try XCTUnwrap(recoveredSnapshot.workspaces.first)
        XCTAssertEqual(recovered.health, .writable)
        XCTAssertNil(recovered.revisions.dirtyRevision)
        XCTAssertEqual(recovered.revisions.savedRevision, recovered.revisions.workingRevision)
        XCTAssertEqual(recovered.document.documentBytes, changed.documentBytes)

        let editedAfterRecovery = try fixture.document(prompt: "edited after recovery")
        let edit = await restarted.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: recovered.revisions.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(editedAfterRecovery)
        ))
        XCTAssertEqual(edit.disposition, .applied)
        let save = await restarted.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: edit.after?.workingRevision,
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(save.disposition, .applied)
        XCTAssertNil(save.after?.dirtyRevision)
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceFile), editedAfterRecovery.documentBytes)
    }

    func testContendedLockIsCancellableAndDoesNotBlockAuthoritySnapshots() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let first = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(try fixture.document(prompt: "seed lock"))
        ))
        XCTAssertEqual(first.disposition, .applied)

        let lockURL = try XCTUnwrap(try allFiles(
            below: fixture.storageRoot.appendingPathComponent("DomainRuntime", isDirectory: true)
        ).first {
            $0.lastPathComponent == "workspace-\(fixture.workspaceID.uuidString).lock"
        })
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        let blockedDocument = try fixture.document(prompt: "blocked")
        let mutation = Task {
            await runtime.workspaceStore.execute(.init(
                operationID: UUID(),
                expectedWorkspaceRevision: 1,
                origin: .standalone,
                command: .replaceWorkingDocument(blockedDocument)
            ))
        }
        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let start = clock.now
        let snapshot = await runtime.workspaceStore.snapshot()
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(250))
        XCTAssertEqual(snapshot.workspaces.first?.revisions.workingRevision, 1)
        mutation.cancel()
        let cancelled = await mutation.value
        XCTAssertEqual(cancelled.disposition, .failed)
        XCTAssertEqual(cancelled.errorCode, .cancelled)
    }

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

        let unchangedOperationID = UUID()
        let unchangedEnvelope = DomainWorkspaceCommandEnvelope(
            operationID: unchangedOperationID,
            expectedWorkspaceRevision: 1,
            origin: .standalone,
            command: .replaceWorkingDocument(changed)
        )
        let unchanged = await first.workspaceStore.execute(unchangedEnvelope)
        XCTAssertEqual(unchanged.disposition, .unchanged)
        let restarted = fixture.runtime(runtimeID: UUID())
        try await restarted.start()
        let restartedDuplicate = await restarted.workspaceStore.execute(unchangedEnvelope)
        XCTAssertEqual(restartedDuplicate.disposition, .deduplicated)

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

        let firstCreatedID = UUID()
        let secondCreatedID = UUID()
        let firstCreatedURL = fixture.storageRoot
            .appendingPathComponent("Workspaces/Workspace-First-\(firstCreatedID.uuidString)/workspace.json")
        let secondCreatedURL = fixture.storageRoot
            .appendingPathComponent("Workspaces/Workspace-Second-\(secondCreatedID.uuidString)/workspace.json")
        let firstCreatedDocument = try fixture.document(
            workspaceID: firstCreatedID,
            contextID: UUID(),
            fileURL: firstCreatedURL,
            prompt: "catalog winner"
        )
        let secondCreatedDocument = try fixture.document(
            workspaceID: secondCreatedID,
            contextID: UUID(),
            fileURL: secondCreatedURL,
            prompt: "catalog stale writer"
        )
        let catalogWinner = await first.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(firstCreatedDocument)
        ))
        XCTAssertEqual(catalogWinner.disposition, .applied)
        let staleCatalogWriter = await second.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(secondCreatedDocument)
        ))
        XCTAssertEqual(staleCatalogWriter.disposition, .conflict)
        XCTAssertEqual(staleCatalogWriter.errorCode, .stateConflict)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondCreatedURL.path))
    }

    func testContextCASFailsClosedWhenOneCommandChangesMultipleContexts() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let secondContextID = UUID()
        let twoContexts = try fixture.document(prompts: [
            fixture.contextID: "first initial",
            secondContextID: "second initial",
        ])
        let seeded = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(twoContexts)
        ))
        XCTAssertEqual(seeded.disposition, .applied)
        let bothChanged = try fixture.document(prompts: [
            fixture.contextID: "first changed",
            secondContextID: "second changed",
        ])
        let rejected = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 1,
            expectedContextRevision: 1,
            origin: .standalone,
            command: .replaceWorkingDocument(bothChanged)
        ))
        XCTAssertEqual(rejected.disposition, .conflict)
        XCTAssertEqual(rejected.diagnostic, "context_revision_scope_mismatch")
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
        let readHandle = try await runtime.routingCoordinator.resolveReadContext(connection: registration)
        XCTAssertEqual(readHandle.context, context)
        XCTAssertEqual(readHandle.runtimeID, runtime.identity.runtimeID)
        XCTAssertEqual(readHandle.runtimeGeneration, runtime.identity.lifecycleGeneration)
        XCTAssertEqual(readHandle.connectionID, connectionID)
        XCTAssertEqual(readHandle.bindingKind, .explicit)

        _ = await runtime.routingCoordinator.openWindow(
            windowID: 99,
            activeWorkspaceID: nil,
            activeContextID: nil,
            presentationRevision: 1,
            operationID: UUID()
        )
        let refreshed = try await runtime.routingCoordinator.refreshReadContext(readHandle)
        XCTAssertEqual(refreshed.context, readHandle.context)
        XCTAssertEqual(refreshed.workspaceRevision, readHandle.workspaceRevision)
        XCTAssertEqual(refreshed.contextRevision, readHandle.contextRevision)
        XCTAssertNotEqual(refreshed.routingRevision, readHandle.routingRevision)

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
        let runRegistration: DomainConnectionRegistration
        if case let .accepted(binding) = accepted {
            runRegistration = binding.registration
        } else {
            XCTFail("Launch token was not accepted: \(accepted)")
            return
        }
        let runReleased = await runtime.routingCoordinator.unregisterConnection(
            runRegistration,
            operationID: UUID()
        )
        XCTAssertEqual(runReleased.disposition, .applied)
        XCTAssertFalse(runReleased.snapshot.connections.contains {
            $0.registration.connectionID == runRegistration.connectionID
        })
        let staleRunRelease = await runtime.routingCoordinator.unregisterConnection(
            runRegistration,
            operationID: UUID()
        )
        XCTAssertEqual(staleRunRelease.disposition, .unchanged)

        let firstWindow = await runtime.routingCoordinator.openWindow(
            windowID: 7,
            activeWorkspaceID: fixture.workspaceID,
            activeContextID: fixture.contextID,
            presentationRevision: 1,
            operationID: UUID()
        )
        let firstGeneration = try XCTUnwrap(firstWindow.snapshot.windows.first?.generation)
        _ = await runtime.routingCoordinator.unregisterWindow(
            windowID: 7,
            generation: firstGeneration,
            operationID: UUID()
        )
        let secondWindow = await runtime.routingCoordinator.openWindow(
            windowID: 7,
            activeWorkspaceID: fixture.workspaceID,
            activeContextID: fixture.contextID,
            presentationRevision: 1,
            operationID: UUID()
        )
        let secondGeneration = try XCTUnwrap(secondWindow.snapshot.windows.first?.generation)
        XCTAssertGreaterThan(secondGeneration, firstGeneration)
        let staleUnregister = await runtime.routingCoordinator.unregisterWindow(
            windowID: 7,
            generation: firstGeneration,
            operationID: UUID()
        )
        XCTAssertEqual(staleUnregister.disposition, .staleGeneration)
        XCTAssertEqual(staleUnregister.snapshot.windows.first?.generation, secondGeneration)
        _ = await runtime.routingCoordinator.unregisterWindow(
            windowID: 7,
            generation: secondGeneration,
            operationID: UUID()
        )
        let latePublication = await runtime.routingCoordinator.registerWindow(
            DomainWindowDescriptor(
                windowID: 7,
                generation: secondGeneration,
                activeWorkspaceID: fixture.workspaceID,
                activeContextID: fixture.contextID,
                isClosing: false,
                presentationRevision: 2
            ),
            operationID: UUID()
        )
        XCTAssertEqual(latePublication.disposition, .staleGeneration)
        XCTAssertFalse(latePublication.snapshot.windows.contains { $0.windowID == 7 })

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

    static func make(includeWorkspace: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("domain-context-authority-\(UUID().uuidString)", isDirectory: true)
        let storageRoot = root.appendingPathComponent("state", isDirectory: true)
        let workspaceRoot = storageRoot.appendingPathComponent("Workspaces", isDirectory: true)
        let workspaceID = UUID()
        let contextID = UUID()
        let directory = workspaceRoot.appendingPathComponent("Workspace-Fixture-\(workspaceID.uuidString)", isDirectory: true)
        let workspaceFile = directory.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let fixture = Fixture(
            root: root,
            storageRoot: storageRoot,
            workspaceID: workspaceID,
            contextID: contextID,
            workspaceFile: workspaceFile
        )
        if includeWorkspace {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try fixture.document(prompt: "saved").documentBytes.write(to: workspaceFile)
        }
        if includeWorkspace {
            try fixture.writeLegacyIndex()
        }
        return fixture
    }

    func writeLegacyIndex() throws {
        let index: [[String: Any]] = [[
            "id": workspaceID.uuidString,
            "name": "Fixture",
            "customStoragePath": NSNull(),
            "isSystemWorkspace": false,
            "isHiddenInMenus": false,
        ]]
        let workspaceRoot = storageRoot.appendingPathComponent("Workspaces", isDirectory: true)
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
            .write(to: workspaceRoot.appendingPathComponent("workspacesIndex.json"))
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
        try document(
            workspaceID: workspaceID,
            contextID: contextID,
            fileURL: workspaceFile,
            prompt: prompt
        )
    }

    func document(prompts: [UUID: String]) throws -> DomainWorkspaceDocument {
        let ordered = prompts.sorted { $0.key.uuidString < $1.key.uuidString }
        let object: [String: Any] = [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "Fixture",
            "repoPaths": ["/tmp/repo"],
            "isSystemWorkspace": false,
            "isHiddenInMenus": false,
            "activeComposeTabID": ordered.first?.key.uuidString ?? contextID.uuidString,
            "composeTabs": ordered.map { id, prompt in
                [
                    "id": id.uuidString,
                    "name": "Context",
                    "prompt": prompt,
                    "unknownFutureField": ["preserved": true],
                ] as [String: Any]
            },
            "unknownWorkspaceField": "preserved",
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try DomainWorkspaceDocument.decode(documentBytes: data, fileURL: workspaceFile)
    }

    func document(
        workspaceID: UUID,
        contextID: UUID,
        fileURL: URL,
        prompt: String
    ) throws -> DomainWorkspaceDocument {
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
        return try DomainWorkspaceDocument.decode(documentBytes: data, fileURL: fileURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
