import Foundation
import RepoPromptDomainRuntime

/// Revisioned app-process client for the runtime-owned workspace/context authority.
/// It is the only production persistence dependency injected into a workspace manager.
struct DomainWorkspaceAuthorityClient {
    let store: DomainWorkspaceStore
    let windowID: Int

    func snapshot() async -> DomainWorkspaceCatalogSnapshot {
        await store.snapshot()
    }

    func replaceWorking(_ workspace: WorkspaceModel, fileURL: URL) async throws -> DomainCommandOutcome {
        let bytes = try JSONEncoder().encode(workspace)
        let document = try DomainWorkspaceDocument.decode(documentBytes: bytes, fileURL: fileURL)
        var lastOutcome: DomainCommandOutcome?
        for _ in 0 ..< 3 {
            let current = await store.snapshot().workspaces.first {
                $0.document.workspaceID == workspace.id
            }
            let outcome = await store.execute(.init(
                operationID: UUID(),
                expectedWorkspaceRevision: current?.revisions.workingRevision ?? 0,
                origin: .appPresentation(windowID: windowID),
                command: .replaceWorkingDocument(document)
            ))
            lastOutcome = outcome
            if outcome.disposition != .conflict { return outcome }
            await Task.yield()
        }
        return lastOutcome!
    }

    func save(_ workspace: WorkspaceModel, fileURL: URL) async throws -> DomainCommandOutcome {
        let working = try await replaceWorking(workspace, fileURL: fileURL)
        guard working.disposition == .applied
            || working.disposition == .unchanged
            || working.disposition == .deduplicated
        else { return working }
        let fallbackSnapshot = await store.snapshot()
        let expectedRevision = working.after?.workingRevision
            ?? working.workspace?.revisions.workingRevision
            ?? fallbackSnapshot.workspaces.first(where: {
                $0.document.workspaceID == workspace.id
            })?.revisions.workingRevision
        return await store.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: expectedRevision,
            origin: .appPresentation(windowID: windowID),
            command: .saveWorkspaceDocument(workspaceID: workspace.id)
        ))
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

    init(workspaceManager: WorkspaceManagerViewModel, client: DomainWorkspaceAuthorityClient) {
        self.workspaceManager = workspaceManager
        self.client = client
    }

    deinit {
        subscriptionTask?.cancel()
    }

    func start() {
        guard subscriptionTask == nil else { return }
        subscriptionTask = Task { [weak self, client] in
            let subscription = await client.store.subscribe()
            self?.project(subscription.snapshot, force: true)
            for await event in subscription.events {
                guard !Task.isCancelled else { return }
                await self?.consume(event)
            }
        }
    }

    private func consume(_ event: DomainWorkspaceEvent) async {
        guard event.sequence > lastPublicationSequence else { return }
        let gap = lastPublicationSequence != 0 && event.sequence != lastPublicationSequence &+ 1
        let snapshot = await client.snapshot()
        project(snapshot, force: gap || event.kind == .externalReloaded || event.kind == .degraded)
    }

    private func project(_ snapshot: DomainWorkspaceCatalogSnapshot, force: Bool) {
        guard snapshot.publicationSequence >= lastPublicationSequence else { return }
        lastPublicationSequence = snapshot.publicationSequence
        let changed = force || snapshot.workspaces.contains {
            projectedDigests[$0.document.workspaceID] != $0.document.contentDigest
        } || projectedDigests.count != snapshot.workspaces.count
        guard changed else { return }

        let decoded: [WorkspaceModel] = snapshot.workspaces.compactMap {
            try? JSONDecoder().decode(WorkspaceModel.self, from: $0.document.documentBytes)
        }
        projectedDigests = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map {
            ($0.document.workspaceID, $0.document.contentDigest)
        })
        workspaceManager?.applyDomainWorkspaceProjection(
            decoded,
            preferredActiveWorkspaceID: workspaceManager?.activeWorkspaceID,
            publicationSequence: snapshot.publicationSequence
        )
    }
}
