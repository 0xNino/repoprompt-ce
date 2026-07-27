@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceSavePreparationTests: XCTestCase {
        private var originalMCPAutoStart = false
        private var savePreparationGates: [WorkspaceSavePreparationGate] = []
        private var saveTasks: [Task<Void, Never>] = []
        private var managersWithSavePreparationHooks: [WorkspaceManagerViewModel] = []
        private var retainedWorkspaceManagers: [WorkspaceManagerViewModel] = []
        private var temporaryDirectories: [URL] = []

        override func setUp() async throws {
            try await super.setUp()
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
        }

        override func tearDown() async throws {
            for managersWithSavePreparationHook in managersWithSavePreparationHooks {
                managersWithSavePreparationHook.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
            }
            savePreparationGates.forEach { $0.cancel() }
            saveTasks.forEach { $0.cancel() }
            for saveTask in saveTasks {
                await saveTask.value
            }
            managersWithSavePreparationHooks.removeAll()
            savePreparationGates.removeAll()
            saveTasks.removeAll()
            for manager in retainedWorkspaceManagers {
                manager.prepareForWindowClose()
            }
            retainedWorkspaceManagers.removeAll()
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
            for directory in temporaryDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
            temporaryDirectories.removeAll()
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            try await super.tearDown()
        }

        func testSaveKeepsCapturedWorkspaceIdentityAndURLAcrossReorderAfterPreparation() async throws {
            let storageRoot = try temporaryDirectory(named: "IdentityURL")
            let composition = makeComposition(windowID: -981)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspaceA = makeWorkspace(name: "A", storage: storageRoot.appendingPathComponent("A"))
            let workspaceB = makeWorkspace(name: "B", storage: storageRoot.appendingPathComponent("B"))
            manager.workspaces.append(contentsOf: [workspaceA, workspaceB])
            let switchResult = await manager.switchWorkspace(to: workspaceA, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            await manager.waitUntilPostSwitchGitDataLoadComplete()
            manager.markWorkspaceDirty()

            let gate = WorkspaceSavePreparationGate()
            savePreparationGates.append(gate)
            managersWithSavePreparationHooks.append(manager)
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, fileURL, _ in
                await gate.arriveAndWait(workspaceID: workspaceID, fileURL: fileURL)
            }
            let saveTask = Task { @MainActor in
                await manager.pollAndSaveStateAsync()
            }
            saveTasks.append(saveTask)
            let arrival = try await gate.waitUntilArrivedAndBlocked()
            XCTAssertEqual(arrival.workspaceID, workspaceA.id)
            XCTAssertEqual(arrival.fileURL, manager.workspaceFileURL(for: workspaceA))
            try manager.workspaces.swapAt(
                XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceA.id }),
                XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceB.id })
            )
            gate.release()
            await saveTask.value
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)

            let savedA = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: arrival.fileURL)
            XCTAssertEqual(savedA.id, workspaceA.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: manager.workspaceFileURL(for: workspaceB).path))
        }

        func testSaveBailsWithoutEnqueueOrAcknowledgementWhenWorkspaceRemovedAfterPreparation() async throws {
            let storageRoot = try temporaryDirectory(named: "Removal")
            let composition = makeComposition(windowID: -982)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspace = makeWorkspace(name: "Removed", storage: storageRoot.appendingPathComponent("Removed"))
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            await manager.waitUntilPostSwitchGitDataLoadComplete()
            manager.markWorkspaceDirty()
            let expectedURL = manager.workspaceFileURL(for: workspace)

            let gate = WorkspaceSavePreparationGate()
            savePreparationGates.append(gate)
            managersWithSavePreparationHooks.append(manager)
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, fileURL, _ in
                await gate.arriveAndWait(workspaceID: workspaceID, fileURL: fileURL)
            }
            let saveTask = Task { @MainActor in
                await manager.pollAndSaveStateAsync()
            }
            saveTasks.append(saveTask)
            _ = try await gate.waitUntilArrivedAndBlocked()
            manager.workspaces.removeAll { $0.id == workspace.id }
            gate.release()
            await saveTask.value
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)

            XCTAssertFalse(FileManager.default.fileExists(atPath: expectedURL.path))
            XCTAssertNil(manager.debugLastSavedVersionForWorkspace(workspace.id))
        }

        func testSaveRetriesSameIdentityOnceWhenStateChangesAfterPreparation() async throws {
            let storageRoot = try temporaryDirectory(named: "Retry")
            let composition = makeComposition(windowID: -983)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspace = makeWorkspace(name: "Retry", storage: storageRoot.appendingPathComponent("Retry"))
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            await manager.waitUntilPostSwitchGitDataLoadComplete()
            manager.markWorkspaceDirty()
            manager.resetWorkspaceSaveDiagnosticsForTesting()
            let preparedVersion = AsyncTestCondition<Int?>(nil)

            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, _, remainingRetryCount in
                if remainingRetryCount == 1 {
                    await MainActor.run {
                        guard let index = manager.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
                        manager.workspaces[index].currentPromptText = "newer state"
                        manager.markWorkspaceDirty()
                    }
                } else {
                    let version = await MainActor.run {
                        manager.debugStateVersionForWorkspace(workspaceID)
                    }
                    preparedVersion.update { $0 = version }
                }
            }
            await manager.pollAndSaveStateAsync()
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)

            let diagnostics = manager.workspaceSaveDiagnosticsForTesting(workspaceID: workspace.id)
            XCTAssertEqual(diagnostics.attemptCount, 2)
            let saved = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: manager.workspaceFileURL(for: workspace)
            )
            XCTAssertEqual(saved.currentPromptText, "newer state")
            let expectedSavedVersion = preparedVersion.snapshot()
            XCTAssertEqual(
                manager.debugLastSavedVersionForWorkspace(workspace.id),
                expectedSavedVersion
            )
        }

        func testPreparationFailureDoesNotAdvanceLastSavedVersion() async throws {
            let storageRoot = try temporaryDirectory(named: "Failure")
            let blockingFile = storageRoot.appendingPathComponent("not-a-directory")
            try Data("block".utf8).write(to: blockingFile)
            let composition = makeComposition(windowID: -984)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspace = makeWorkspace(name: "Failure", storage: blockingFile)
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            await manager.waitUntilPostSwitchGitDataLoadComplete()
            manager.markWorkspaceDirty()

            await manager.pollAndSaveStateAsync()

            XCTAssertGreaterThan(manager.debugStateVersionForWorkspace(workspace.id), 0)
            XCTAssertNil(manager.debugLastSavedVersionForWorkspace(workspace.id))
        }

        func testQuiescentCapturePublishesWorkspaceOnceWithoutReloadingComposeTabs() async throws {
            let storageRoot = try temporaryDirectory(named: "Publication")
            let composition = makeComposition(windowID: -985)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspace = makeWorkspace(name: "Publication", storage: storageRoot.appendingPathComponent("Publication"))
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            await manager.waitUntilPostSwitchGitDataLoadComplete()
            manager.markWorkspaceDirty()
            manager.resetWorkspaceSaveDiagnosticsForTesting()

            await manager.pollAndSaveStateAsync()

            let diagnostics = manager.workspaceSaveDiagnosticsForTesting(workspaceID: workspace.id)
            XCTAssertEqual(diagnostics.capturePublicationCount, 1)
            XCTAssertEqual(diagnostics.composeTabReloadCount, 0)
        }

        func testDomainProjectionUsesCanonicalComposeTabNormalization() throws {
            let workspace = makeWorkspace(
                name: "Canonical",
                storage: FileManager.default.temporaryDirectory
            )
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any]
            )
            object["composeTabs"] = []
            object["activeComposeTabID"] = UUID().uuidString
            let bytes = try JSONSerialization.data(withJSONObject: object)

            let decoded = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: bytes,
                fileURL: URL(fileURLWithPath: "/tmp/canonical-workspace.json")
            )

            XCTAssertEqual(decoded.composeTabs.count, 1)
            XCTAssertEqual(decoded.activeComposeTabID, decoded.composeTabs.first?.id)
            XCTAssertTrue(decoded.normalizationRequiresSave)
        }

        func testDomainAuthoritySaveRetainsRetryBaselineAndIgnoresStaleLegacyList() async throws {
            let root = try temporaryDirectory(named: "DomainSaveInvariants")
            defer { try? FileManager.default.removeItem(at: root) }
            let defaults = UserDefaults.standard
            let priorStoragePath = defaults.string(forKey: "GlobalCustomStorageURL")
            defaults.set(
                root.appendingPathComponent("Workspaces", isDirectory: true).path,
                forKey: "GlobalCustomStorageURL"
            )
            defer {
                if let priorStoragePath {
                    defaults.set(priorStoragePath, forKey: "GlobalCustomStorageURL")
                } else {
                    defaults.removeObject(forKey: "GlobalCustomStorageURL")
                }
            }

            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "app-save-invariants-\(UUID().uuidString)",
                storageDirectory: root,
                eventDirectory: root.appendingPathComponent("events"),
                temporaryDirectory: root.appendingPathComponent("tmp"),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }
            let composition = WindowStateCompositionFactory.make(
                windowID: -991,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                domainRuntime: runtime,
                workspaceFileContextStore: WorkspaceFileContextStore()
            )
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let authoritative = try await waitForDomainWorkspace(runtime)
            let workspaceID = authoritative.document.workspaceID
            manager.resetWorkspaceSaveDiagnosticsForTesting()
            managersWithSavePreparationHooks.append(manager)
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { id, _, remainingRetryCount in
                guard id == workspaceID, remainingRetryCount == 1 else { return }
                await MainActor.run {
                    guard let index = manager.workspaces.firstIndex(where: { $0.id == id }) else { return }
                    manager.workspaces[index].currentPromptText = "newer runtime state"
                    manager.markWorkspaceDirty()
                }
            }
            guard let index = manager.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                return XCTFail("Bootstrapped runtime workspace was not projected")
            }
            manager.workspaces[index].repoPaths = ["/tmp/runtime-baseline"]
            manager.workspaces[index].currentPromptText = "captured runtime state"
            manager.markWorkspaceDirty()

            await manager.pollAndSaveStateAsync()
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)

            let diagnostics = manager.workspaceSaveDiagnosticsForTesting(workspaceID: workspaceID)
            XCTAssertEqual(diagnostics.attemptCount, 2)
            XCTAssertEqual(
                manager.debugLastSavedVersionForWorkspace(workspaceID),
                manager.debugStateVersionForWorkspace(workspaceID)
            )
            XCTAssertEqual(manager.debugRepoPathBaselineForWorkspace(workspaceID), ["/tmp/runtime-baseline"])
            let savedSnapshot = await runtime.workspaceStore.snapshot()
            let savedDocument = try XCTUnwrap(savedSnapshot.workspaces.first {
                $0.document.workspaceID == workspaceID
            })
            XCTAssertNil(savedDocument.revisions.dirtyRevision)
            let decoded = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: savedDocument.document.documentBytes,
                fileURL: savedDocument.document.fileURL
            )
            XCTAssertEqual(decoded.currentPromptText, "newer runtime state")

            let staleID = UUID()
            let staleIndex: [[String: Any]] = [[
                "id": staleID.uuidString,
                "name": "Stale legacy only",
                "customStoragePath": NSNull(),
                "isSystemWorkspace": false,
                "isHiddenInMenus": false
            ]]
            try JSONSerialization.data(withJSONObject: staleIndex).write(
                to: root.appendingPathComponent("Workspaces/workspacesIndex.json"),
                options: .atomic
            )
            manager.reloadWorkspacesFromDisk()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(manager.workspaces.contains { $0.id == workspaceID })
            XCTAssertFalse(manager.workspaces.contains { $0.id == staleID })

            var localDirty = decoded
            localDirty.currentPromptText = "local unresolved state"
            manager.debugPublishWorkingDocumentToDomainAuthority(localDirty)
            try await Task.sleep(for: .milliseconds(300))
            var external = decoded
            external.currentPromptText = "external accepted state"
            try JSONEncoder().encode(external).write(
                to: savedDocument.document.fileURL,
                options: .atomic
            )
            await manager.refreshDomainWorkspaceAuthority()
            let issue = try XCTUnwrap(manager.domainWorkspaceAuthorityIssue)
            XCTAssertEqual(issue.workspaceID, workspaceID)
            XCTAssertTrue(issue.canResolveExternalConflict)
            let conflictResolved = await manager.resolveDomainWorkspaceConflict(
                workspaceID: workspaceID,
                acceptExternal: true
            )
            XCTAssertTrue(conflictResolved)
            XCTAssertNil(manager.domainWorkspaceAuthorityIssue)
            let resolvedSnapshot = await runtime.workspaceStore.snapshot()
            let resolved = try XCTUnwrap(resolvedSnapshot.workspaces.first {
                $0.document.workspaceID == workspaceID
            })
            XCTAssertEqual(resolved.health, .writable)
            XCTAssertNil(resolved.revisions.dirtyRevision)
            let accepted = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: resolved.document.documentBytes,
                fileURL: resolved.document.fileURL
            )
            XCTAssertEqual(accepted.currentPromptText, "external accepted state")

            let authoritativeURL = resolved.document.fileURL
            manager.renameWorkspace(accepted, newName: "Runtime Renamed")
            try await Task.sleep(for: .milliseconds(400))
            let renamedSnapshot = await runtime.workspaceStore.snapshot()
            let renamed = try XCTUnwrap(renamedSnapshot.workspaces.first {
                $0.document.workspaceID == workspaceID
            })
            XCTAssertEqual(renamed.document.fileURL, authoritativeURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: authoritativeURL.path))
            let renamedModel = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: renamed.document.documentBytes,
                fileURL: renamed.document.fileURL
            )
            XCTAssertEqual(renamedModel.name, "Runtime Renamed")
        }

        func testCompositionUsesExplicitDomainRuntimeOwnershipOnlyWhenInjected() async throws {
            let legacy = makeComposition(windowID: -989)
            XCTAssertNil(legacy.domainWorkspacePresentationBridge)

            let root = try temporaryDirectory(named: "DomainOwnership")
            defer { try? FileManager.default.removeItem(at: root) }
            let defaults = UserDefaults.standard
            let priorStoragePath = defaults.string(forKey: "GlobalCustomStorageURL")
            defaults.set(
                root.appendingPathComponent("Workspaces", isDirectory: true).path,
                forKey: "GlobalCustomStorageURL"
            )
            defer {
                if let priorStoragePath {
                    defaults.set(priorStoragePath, forKey: "GlobalCustomStorageURL")
                } else {
                    defaults.removeObject(forKey: "GlobalCustomStorageURL")
                }
            }
            let workspaceRoot = root.appendingPathComponent("Workspaces", isDirectory: true)
            let legacyStorage = workspaceRoot.appendingPathComponent("Legacy", isDirectory: true)
            try FileManager.default.createDirectory(at: legacyStorage, withIntermediateDirectories: true)
            let legacyWorkspace = makeWorkspace(name: "Legacy survives", storage: legacyStorage)
            try JSONEncoder().encode(legacyWorkspace).write(
                to: legacyStorage.appendingPathComponent("workspace.json")
            )
            try JSONEncoder().encode([WorkspaceIndexEntry(
                id: legacyWorkspace.id,
                name: legacyWorkspace.name,
                customStoragePath: legacyStorage,
                isSystemWorkspace: false,
                isHiddenInMenus: false
            )]).write(to: workspaceRoot.appendingPathComponent("workspacesIndex.json"))

            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "app-bridge-test",
                storageDirectory: root,
                eventDirectory: root.appendingPathComponent("events"),
                temporaryDirectory: root.appendingPathComponent("tmp"),
                externalReloadInterval: nil
            ))
            // Deliberately do not start the runtime first. The store/bridge readiness contract
            // must bootstrap before its first projection and preserve the legacy-loaded list.
            let owned = WindowStateCompositionFactory.make(
                windowID: -990,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                domainRuntime: runtime,
                workspaceFileContextStore: WorkspaceFileContextStore()
            )
            XCTAssertNotNil(owned.domainWorkspacePresentationBridge)
            XCTAssertNotNil(owned.mcpServer.domainRoutingCoordinator)
            await owned.workspaceManager.awaitInitialized()
            _ = try await waitForDomainWorkspace(runtime)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(owned.workspaceManager.workspaces.contains { $0.id == legacyWorkspace.id })
            XCTAssertFalse(owned.workspaceManager.workspaces.isEmpty)
            let registeredRouting = await runtime.routingCoordinator.snapshot()
            XCTAssertTrue(registeredRouting.windows.contains { $0.windowID == -990 })
            await owned.mcpServer.unregisterDomainRoutingWindow()
            let unregisteredRouting = await runtime.routingCoordinator.snapshot()
            XCTAssertFalse(unregisteredRouting.windows.contains { $0.windowID == -990 })
            _ = await runtime.shutdown()
        }

        private func waitForDomainWorkspace(
            _ runtime: MCPDomainRuntime
        ) async throws -> DomainWorkspaceSnapshot {
            for _ in 0 ..< 100 {
                if let workspace = await runtime.workspaceStore.snapshot().workspaces.first {
                    return workspace
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NSError(
                domain: "WorkspaceSavePreparationTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for runtime workspace creation"]
            )
        }

        private func makeComposition(windowID: Int) -> WindowStateComposition {
            let composition = WindowStateCompositionFactory.make(
                windowID: windowID,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                workspaceFileContextStore: WorkspaceFileContextStore()
            )
            retainedWorkspaceManagers.append(composition.workspaceManager)
            return composition
        }

        private func makeWorkspace(name: String, storage: URL) -> WorkspaceModel {
            let tab = ComposeTabState(name: name)
            return WorkspaceModel(
                name: name,
                repoPaths: [],
                customStoragePath: storage,
                composeTabs: [tab],
                activeComposeTabID: tab.id
            )
        }

        private func temporaryDirectory(named name: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceSavePreparationTests-\(name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            temporaryDirectories.append(url)
            return url
        }
    }

    private final class WorkspaceSavePreparationGate: @unchecked Sendable {
        struct Arrival {
            let workspaceID: UUID
            let fileURL: URL
        }

        private let condition = NSCondition()
        private let releaseFence = TestReleaseFence(name: "workspace save preparation gate")
        private var arrival: Arrival?
        private var arrivalWaiters: [UUID: CheckedContinuation<Arrival?, Never>] = [:]
        private var cancelledArrivalWaiters = Set<UUID>()
        private var isCancelled = false

        func arriveAndWait(workspaceID: UUID, fileURL: URL) async {
            recordArrival(Arrival(workspaceID: workspaceID, fileURL: fileURL))
            await releaseFence.enterAndWait()
        }

        func waitUntilArrivedAndBlocked() async throws -> Arrival {
            guard let arrival = await waitUntilArrived() else {
                throw CancellationError()
            }
            guard await releaseFence.waitUntilEntered() else {
                throw CancellationError()
            }
            return arrival
        }

        func release() {
            releaseFence.release()
        }

        func cancel() {
            condition.lock()
            isCancelled = true
            let pending = Array(arrivalWaiters.values)
            arrivalWaiters.removeAll()
            cancelledArrivalWaiters.removeAll()
            condition.broadcast()
            condition.unlock()
            pending.forEach { $0.resume(returning: nil) }
            releaseFence.release()
        }

        private func waitUntilArrived() async -> Arrival? {
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    registerArrivalWaiter(continuation, waiterID: waiterID)
                }
            } onCancel: {
                cancelArrivalWaiter(waiterID)
            }
        }

        private func recordArrival(_ value: Arrival) {
            condition.lock()
            guard !isCancelled else {
                condition.unlock()
                return
            }
            arrival = value
            let pending = Array(arrivalWaiters.values)
            arrivalWaiters.removeAll()
            cancelledArrivalWaiters.removeAll()
            condition.broadcast()
            condition.unlock()
            pending.forEach { $0.resume(returning: value) }
        }

        private func registerArrivalWaiter(
            _ continuation: CheckedContinuation<Arrival?, Never>,
            waiterID: UUID
        ) {
            condition.lock()
            if let arrival {
                condition.unlock()
                continuation.resume(returning: arrival)
            } else if isCancelled || Task.isCancelled || cancelledArrivalWaiters.remove(waiterID) != nil {
                condition.unlock()
                continuation.resume(returning: nil)
            } else {
                arrivalWaiters[waiterID] = continuation
                condition.unlock()
            }
        }

        private func cancelArrivalWaiter(_ waiterID: UUID) {
            condition.lock()
            let continuation = arrivalWaiters.removeValue(forKey: waiterID)
            if continuation == nil {
                cancelledArrivalWaiters.insert(waiterID)
            }
            condition.broadcast()
            condition.unlock()
            continuation?.resume(returning: nil)
        }
    }

#endif
