import Foundation
import RepoPromptDomainRuntime

struct DomainWorkspaceSaveOperationIDs {
    let working: UUID
    let saved: UUID

    init(working: UUID = UUID(), saved: UUID = UUID()) {
        self.working = working
        self.saved = saved
    }
}

/// Revisioned app-process client for the runtime-owned workspace/context authority.
/// It is the only production persistence dependency injected into a workspace manager.
struct DomainWorkspaceAuthorityClient {
    let store: DomainWorkspaceStore
    let windowID: Int

    func snapshot() async -> DomainWorkspaceCatalogSnapshot {
        await store.snapshot()
    }

    func create(
        _ workspace: WorkspaceModel,
        fileURL: URL,
        operationID: UUID = UUID()
    ) async throws -> DomainCommandOutcome {
        let document = try document(for: workspace, fileURL: fileURL)
        let snapshot = await store.snapshot()
        return await executeStable(.init(
            operationID: operationID,
            expectedCatalogRevision: snapshot.catalogRevision,
            expectedWorkspaceRevision: 0,
            origin: .appPresentation(windowID: windowID),
            command: .createWorkspace(document)
        ))
    }

    func replaceWorking(
        _ workspace: WorkspaceModel,
        fileURL: URL,
        operationID: UUID = UUID()
    ) async throws -> DomainCommandOutcome {
        let document = try document(for: workspace, fileURL: fileURL)
        let current = await store.snapshot().workspaces.first {
            $0.document.workspaceID == workspace.id
        }
        return await executeStable(.init(
            operationID: operationID,
            expectedWorkspaceRevision: current?.revisions.workingRevision,
            origin: .appPresentation(windowID: windowID),
            command: .replaceWorkingDocument(document)
        ))
    }

    func save(
        _ workspace: WorkspaceModel,
        fileURL: URL,
        operationIDs: DomainWorkspaceSaveOperationIDs = .init()
    ) async throws -> DomainCommandOutcome {
        let working = try await replaceWorking(
            workspace,
            fileURL: fileURL,
            operationID: operationIDs.working
        )
        guard working.isSuccessfulDomainMutation else { return working }
        let expectedRevision = working.after?.workingRevision
            ?? working.workspace?.revisions.workingRevision
        return await executeStable(.init(
            operationID: operationIDs.saved,
            expectedWorkspaceRevision: expectedRevision,
            origin: .appPresentation(windowID: windowID),
            command: .saveWorkspaceDocument(workspaceID: workspace.id)
        ))
    }

    func delete(
        workspaceID: UUID,
        operationID: UUID = UUID()
    ) async -> DomainCommandOutcome {
        let snapshot = await store.snapshot()
        let current = snapshot.workspaces.first {
            $0.document.workspaceID == workspaceID
        }
        return await executeStable(.init(
            operationID: operationID,
            expectedCatalogRevision: snapshot.catalogRevision,
            expectedWorkspaceRevision: current?.revisions.workingRevision,
            origin: .appPresentation(windowID: windowID),
            command: .deleteWorkspace(workspaceID: workspaceID)
        ))
    }

    func resolveConflict(
        workspaceID: UUID,
        acceptExternal: Bool,
        operationID: UUID = UUID()
    ) async -> DomainCommandOutcome {
        let current = await store.snapshot().workspaces.first {
            $0.document.workspaceID == workspaceID
        }
        return await executeStable(.init(
            operationID: operationID,
            expectedWorkspaceRevision: current?.revisions.workingRevision,
            origin: .appPresentation(windowID: windowID),
            command: .resolveExternalConflict(
                workspaceID: workspaceID,
                acceptExternal: acceptExternal
            )
        ))
    }

    func reloadExternalChanges() async -> DomainWorkspaceCatalogSnapshot {
        await store.reloadExternalChanges()
        return await store.snapshot()
    }

    private func document(for workspace: WorkspaceModel, fileURL: URL) throws -> DomainWorkspaceDocument {
        let bytes = try JSONEncoder().encode(workspace)
        return try DomainWorkspaceDocument.decode(documentBytes: bytes, fileURL: fileURL)
    }

    /// Retries only the exact same envelope. A changed CAS expectation or payload is a new
    /// logical operation and must receive a new operation ID from the caller.
    private func executeStable(
        _ envelope: DomainWorkspaceCommandEnvelope
    ) async -> DomainCommandOutcome {
        let first = await store.execute(envelope)
        guard first.disposition == .failed,
              first.errorCode == .lockTimedOut || first.errorCode == .cancelled
        else { return first }
        guard !Task.isCancelled else { return first }
        await Task.yield()
        return await store.execute(envelope)
    }
}

private extension DomainCommandOutcome {
    var isSuccessfulDomainMutation: Bool {
        disposition == .applied || disposition == .unchanged || disposition == .deduplicated
    }
}

/// MainActor-only projection of immutable runtime snapshots into the existing app view model graph.
/// Active-window choice is deliberately resolved here; it is never persisted as domain routing truth.
@MainActor
final class DomainWorkspacePresentationBridge {
    private weak var workspaceManager: WorkspaceManagerViewModel?
    private let client: DomainWorkspaceAuthorityClient
    private var subscriptionTask: Task<Void, Never>?
    private var lastPublicationSequence: UInt64 = 0
    private var projectedDigests: [UUID: String] = [:]
    private var projectedModels: [UUID: WorkspaceModel] = [:]

    init(workspaceManager: WorkspaceManagerViewModel, client: DomainWorkspaceAuthorityClient) {
        self.workspaceManager = workspaceManager
        self.client = client
    }

    deinit {
        subscriptionTask?.cancel()
    }

    #if DEBUG
        func waitUntilProjected(
            through publicationSequence: UInt64,
            timeout: Duration = .seconds(5)
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            repeat {
                if lastPublicationSequence >= publicationSequence { return true }
                guard await TaskCancellationDelay.wait(nanoseconds: 10_000_000) else { return false }
            } while clock.now < deadline
            return lastPublicationSequence >= publicationSequence
        }
    #endif

    func start() {
        guard subscriptionTask == nil else { return }
        subscriptionTask = Task { [weak self, client] in
            guard let self else { return }
            let subscription = await client.store.subscribe()
            guard subscription.snapshot.isBootstrapped else { return }

            var initial = subscription.snapshot
            if initial.workspaces.isEmpty,
               let candidate = workspaceManager?.runtimeOwnedDefaultWorkspaceCandidate()
            {
                let fileURL = workspaceManager?.workspaceFileURL(for: candidate)
                if let fileURL {
                    do {
                        let outcome = try await client.create(candidate, fileURL: fileURL)
                        if !outcome.isSuccessfulDomainMutation {
                            workspaceManager?.reportDomainAuthorityIssue(outcome, operation: "create_default")
                        }
                    } catch {
                        workspaceManager?.reportDomainAuthorityFailure(
                            error,
                            workspaceID: candidate.id,
                            operation: "create_default"
                        )
                    }
                    initial = await client.snapshot()
                }
            }
            project(initial, force: true)
            for await event in subscription.events {
                guard !Task.isCancelled else { return }
                await consume(event)
            }
        }
    }

    private func consume(_ event: DomainWorkspaceEvent) async {
        guard event.sequence > lastPublicationSequence else { return }
        let gap = lastPublicationSequence != 0 && event.sequence != lastPublicationSequence &+ 1
        let snapshot = await client.snapshot()
        project(
            snapshot,
            force: gap || event.kind == .externalReloaded || event.kind == .degraded
        )
    }

    private func project(_ snapshot: DomainWorkspaceCatalogSnapshot, force: Bool) {
        guard snapshot.isBootstrapped,
              snapshot.publicationSequence >= lastPublicationSequence
        else { return }
        let nextDigests = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map {
            ($0.document.workspaceID, $0.document.contentDigest)
        })
        let changedIDs = Set(snapshot.workspaces.compactMap { workspace -> UUID? in
            projectedDigests[workspace.document.workspaceID] == workspace.document.contentDigest
                ? nil
                : workspace.document.workspaceID
        })
        let removedIDs = Set(projectedModels.keys).subtracting(nextDigests.keys)
        guard force || !changedIDs.isEmpty || !removedIDs.isEmpty else {
            lastPublicationSequence = snapshot.publicationSequence
            return
        }

        var nextModels = projectedModels
        for workspaceID in removedIDs {
            nextModels.removeValue(forKey: workspaceID)
        }
        do {
            for workspace in snapshot.workspaces where changedIDs.contains(workspace.document.workspaceID) {
                nextModels[workspace.document.workspaceID] = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: workspace.document.documentBytes,
                    fileURL: workspace.document.fileURL
                )
            }
        } catch {
            workspaceManager?.reportDomainProjectionFailure(error)
            return
        }

        let decoded = snapshot.workspaces.compactMap {
            nextModels[$0.document.workspaceID]
        }
        guard decoded.count == snapshot.workspaces.count else {
            workspaceManager?.reportDomainProjectionFailure(DomainProjectionError.incompleteSnapshot)
            return
        }
        projectedModels = nextModels
        projectedDigests = nextDigests
        lastPublicationSequence = snapshot.publicationSequence
        workspaceManager?.applyDomainWorkspaceProjection(
            decoded,
            fileURLsByWorkspaceID: Dictionary(uniqueKeysWithValues: snapshot.workspaces.map {
                ($0.document.workspaceID, $0.document.fileURL)
            }),
            preferredActiveWorkspaceID: workspaceManager?.activeWorkspaceID,
            publicationSequence: snapshot.publicationSequence
        )
    }
}

private enum DomainProjectionError: LocalizedError {
    case incompleteSnapshot

    var errorDescription: String? {
        "Runtime workspace projection was incomplete; the previous complete snapshot was retained."
    }
}
