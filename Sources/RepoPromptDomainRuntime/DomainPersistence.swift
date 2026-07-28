import Darwin
import Foundation
import os

struct DomainPendingSave: Codable, Sendable {
    let operationID: UUID
    let documentDigest: String
}

struct DomainWorkingJournal: Codable, Sendable {
    static let schemaVersion = 1

    let version: Int
    let workspaceID: UUID
    let fileURL: URL
    let revisions: DomainRevisionState
    let savedDigest: String
    let workingDocument: Data?
    let contextRevisions: [UUID: DomainRevisionState]
    let contextDigests: [UUID: String]
    let contextTombstones: [UUID: UInt64]
    let operations: [DomainRecordedOperation]
    let pendingSave: DomainPendingSave?
    let updatedAt: Date

    init(
        workspaceID: UUID,
        fileURL: URL,
        revisions: DomainRevisionState,
        savedDigest: String,
        workingDocument: Data?,
        contextRevisions: [UUID: DomainRevisionState],
        contextDigests: [UUID: String],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        pendingSave: DomainPendingSave? = nil,
        updatedAt: Date
    ) {
        version = Self.schemaVersion
        self.workspaceID = workspaceID
        self.fileURL = fileURL
        self.revisions = revisions
        self.savedDigest = savedDigest
        self.workingDocument = workingDocument
        self.contextRevisions = contextRevisions
        self.contextDigests = contextDigests
        self.contextTombstones = contextTombstones
        self.operations = operations
        self.pendingSave = pendingSave
        self.updatedAt = updatedAt
    }
}

struct DomainSavedRevisionRecord: Codable, Sendable {
    static let schemaVersion = 1

    let version: Int
    let workspaceID: UUID
    let savedRevision: UInt64
    let documentDigest: String
    let operationID: UUID
    let updatedAt: Date

    init(workspaceID: UUID, savedRevision: UInt64, documentDigest: String, operationID: UUID, updatedAt: Date) {
        version = Self.schemaVersion
        self.workspaceID = workspaceID
        self.savedRevision = savedRevision
        self.documentDigest = documentDigest
        self.operationID = operationID
        self.updatedAt = updatedAt
    }
}

struct DomainDeletionTombstone: Codable, Sendable {
    static let schemaVersion = 1

    let version: Int
    let workspaceID: UUID
    let fileURL: URL
    let operation: DomainRecordedOperation
    let deletedAt: Date

    init(workspaceID: UUID, fileURL: URL, operation: DomainRecordedOperation, deletedAt: Date) {
        version = Self.schemaVersion
        self.workspaceID = workspaceID
        self.fileURL = fileURL
        self.operation = operation
        self.deletedAt = deletedAt
    }
}

struct DomainPersistenceBootstrap: Sendable {
    struct Workspace: Sendable {
        let document: DomainWorkspaceDocument
        let savedDigest: String
        let revisions: DomainRevisionState
        let contextRevisions: [UUID: DomainRevisionState]
        let contextTombstones: [UUID: UInt64]
        let operations: [DomainRecordedOperation]
        let health: DomainAuthorityHealth
    }

    let workspaces: [Workspace]
    let deletedOperations: [DomainRecordedOperation]
    let deletedWorkspaceIDs: Set<UUID>
    let health: DomainAuthorityHealth
    let catalogRevision: UInt64
}

struct DomainPersistenceWorkingCommit: Sendable {
    let journal: DomainWorkingJournal
    let catalogRevision: UInt64
}

struct DomainPersistenceSavedCommit: Sendable {
    let journal: DomainWorkingJournal
    let catalogRevision: UInt64
}

struct DomainPersistenceDeleteCommit: Sendable {
    let catalogRevision: UInt64
    let tombstone: DomainDeletionTombstone
}

enum DomainPersistenceError: Error, Equatable, Sendable {
    case stateConflict(expected: UInt64, actual: UInt64)
    case externalDocumentConflict
    case futureJournal(Int)
    case corruptJournal
    case operationIDCollision
    case invalidWorkspaceDocument
    case writeFailed(String)
    case lockTimedOut
    case cancelled
}

private final class DomainBlockingCancellation: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    func cancel() {
        state.withLock { $0 = true }
    }

    func check() throws {
        if state.withLock({ $0 }) {
            throw DomainPersistenceError.cancelled
        }
    }
}

private enum DomainBlockingIO {
    static func run<T: Sendable>(
        _ operation: @escaping @Sendable (DomainBlockingCancellation) throws -> T
    ) async throws -> T {
        let cancellation = DomainBlockingCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try cancellation.check()
                        continuation.resume(returning: try operation(cancellation))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

package struct DomainPersistenceCoordinator: Sendable {
    private struct RuntimeWorkspaceCatalog: Codable {
        static let schemaVersion = 1

        struct Entry: Codable, Equatable {
            let workspaceID: UUID
            let fileURL: URL
        }

        let version: Int
        let revision: UInt64
        let entries: [Entry]
        let deletions: [DomainDeletionTombstone]?
        let updatedAt: Date

        init(
            version: Int,
            revision: UInt64,
            entries: [Entry],
            deletions: [DomainDeletionTombstone] = [],
            updatedAt: Date
        ) {
            self.version = version
            self.revision = revision
            self.entries = entries
            self.deletions = deletions
            self.updatedAt = updatedAt
        }
    }

    private struct LegacyWorkspaceIndexEntry: Codable {
        let id: UUID
        let name: String
        let customStoragePath: URL?
        let isSystemWorkspace: Bool
        let isHiddenInMenus: Bool
    }

    private struct RuntimePolicyDocument: Codable {
        static let schemaVersion = 1
        let version: Int
        let profileIdentifier: String
        let legacyDefaultsPreserved: Bool
        let rollbackDirectoryName: String
        let migratedAt: Date
    }

    private struct RollbackManifest: Codable {
        static let schemaVersion = 1
        struct Artifact: Codable {
            let relativePath: String
            let digest: String
        }

        let version: Int
        let profileIdentifier: String
        let runtimeID: UUID
        let runtimeGeneration: UInt64
        let createdAt: Date
        let artifacts: [Artifact]
        let legacyDefaultKeys: [String]
    }

    private let configuration: DomainRuntimeConfiguration
    private let identity: DomainRuntimeIdentity
    private let cancellation: DomainBlockingCancellation?

    package init(
        configuration: DomainRuntimeConfiguration,
        identity: DomainRuntimeIdentity
    ) {
        self.configuration = configuration
        self.identity = identity
        cancellation = nil
    }

    private init(
        configuration: DomainRuntimeConfiguration,
        identity: DomainRuntimeIdentity,
        cancellation: DomainBlockingCancellation
    ) {
        self.configuration = configuration
        self.identity = identity
        self.cancellation = cancellation
    }

    private var fileManager: FileManager { .default }
    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder { JSONDecoder() }

    private func blockingWorker(_ cancellation: DomainBlockingCancellation) -> Self {
        Self(configuration: configuration, identity: identity, cancellation: cancellation)
    }

    private func withLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        try DomainPersistenceLock.withLock(
            at: url,
            cancellation: cancellation,
            body
        )
    }

    private var workspaceRoot: URL {
        configuration.workspaceStorageDirectory
    }

    private var runtimeRoot: URL {
        let safe = configuration.profileIdentifier
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }
            .joined()
            .prefix(48)
        let digest = DomainContentDigest.sha256(Data(configuration.profileIdentifier.utf8)).prefix(12)
        return configuration.storageDirectory
            .appendingPathComponent("DomainRuntime", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("\(safe)-\(digest)", isDirectory: true)
    }

    private var journalDirectory: URL { runtimeRoot.appendingPathComponent("working-journals", isDirectory: true) }
    private var revisionDirectory: URL { runtimeRoot.appendingPathComponent("revisions", isDirectory: true) }
    private var deletionDirectory: URL { runtimeRoot.appendingPathComponent("deletion-tombstones", isDirectory: true) }
    private var lockDirectory: URL { runtimeRoot.appendingPathComponent("locks", isDirectory: true) }
    private var settingsDirectory: URL { runtimeRoot.appendingPathComponent("settings", isDirectory: true) }
    private var rollbackRoot: URL { runtimeRoot.appendingPathComponent("rollback", isDirectory: true) }
    private var policyURL: URL { settingsDirectory.appendingPathComponent("runtime-policy.json") }
    private var protectedMutationPolicyURL: URL {
        settingsDirectory.appendingPathComponent("protected-mutations.json")
    }
    private var protectedMutationPolicyLockURL: URL {
        lockDirectory.appendingPathComponent("protected-mutations.lock")
    }
    private var catalogURL: URL { runtimeRoot.appendingPathComponent("workspace-catalog.json") }
    private var indexURL: URL { workspaceRoot.appendingPathComponent("workspacesIndex.json") }

    private func journalURL(_ workspaceID: UUID) -> URL {
        journalDirectory.appendingPathComponent("\(workspaceID.uuidString).json")
    }

    private func revisionURL(_ workspaceID: UUID) -> URL {
        revisionDirectory.appendingPathComponent("\(workspaceID.uuidString).json")
    }

    private func deletionURL(_ workspaceID: UUID) -> URL {
        deletionDirectory.appendingPathComponent("\(workspaceID.uuidString).json")
    }

    private func lockURL(_ workspaceID: UUID) -> URL {
        lockDirectory.appendingPathComponent("workspace-\(workspaceID.uuidString).lock")
    }

    func bootstrap() async -> DomainPersistenceBootstrap {
        do {
            return try await DomainBlockingIO.run { cancellation in
                try cancellation.check()
                return blockingWorker(cancellation).bootstrapBlocking()
            }
        } catch {
            return DomainPersistenceBootstrap(
                workspaces: [],
                deletedOperations: [],
                deletedWorkspaceIDs: [],
                health: .degradedReadOnly(reason: "bootstrap_cancelled"),
                catalogRevision: 0
            )
        }
    }

    package func loadProtectedMutationPolicyData() async throws -> Data? {
        try await DomainBlockingIO.run { cancellation in
            try cancellation.check()
            let worker = blockingWorker(cancellation)
            guard worker.fileManager.fileExists(atPath: worker.protectedMutationPolicyURL.path) else {
                return nil
            }
            return try Data(contentsOf: worker.protectedMutationPolicyURL)
        }
    }

    package func compareAndSwapProtectedMutationPolicyData(
        expectedDigest: String?,
        data: Data
    ) async throws {
        try await DomainBlockingIO.run { cancellation in
            let worker = blockingWorker(cancellation)
            try cancellation.check()
            try worker.withLock(at: worker.protectedMutationPolicyLockURL) {
                try cancellation.check()
                let currentData = try? Data(contentsOf: worker.protectedMutationPolicyURL)
                let currentDigest = currentData.map(DomainContentDigest.sha256)
                guard currentDigest == expectedDigest else {
                    throw DomainPersistenceError.externalDocumentConflict
                }
                try DomainPersistenceLock.atomicWrite(data, to: worker.protectedMutationPolicyURL)
            }
        }
    }

    func persistCreated(
        document: DomainWorkspaceDocument,
        expectedCatalogRevision: UInt64?,
        operationID: UUID,
        contextRevisions: [UUID: DomainRevisionState],
        operation: DomainRecordedOperation,
        now: Date
    ) async throws -> DomainPersistenceSavedCommit {
        try await DomainBlockingIO.run { cancellation in
            try blockingWorker(cancellation).persistCreatedBlocking(
                document: document,
                expectedCatalogRevision: expectedCatalogRevision,
                operationID: operationID,
                contextRevisions: contextRevisions,
                operation: operation,
                now: now
            )
        }
    }

    func repairRecoveredCreate(
        document: DomainWorkspaceDocument,
        now: Date
    ) async throws -> UInt64 {
        try await DomainBlockingIO.run { cancellation in
            try blockingWorker(cancellation).withExistingWorkspaceLocks(document: document, now: now) { revision in
                revision
            }
        }
    }

    func persistUnchanged(
        document: DomainWorkspaceDocument,
        expectedRevision: UInt64,
        operation: DomainRecordedOperation,
        now: Date
    ) async throws -> DomainPersistenceWorkingCommit {
        try await DomainBlockingIO.run { cancellation in
            try blockingWorker(cancellation).persistUnchangedBlocking(
                document: document,
                expectedRevision: expectedRevision,
                operation: operation,
                now: now
            )
        }
    }

    func persistWorking(
        document: DomainWorkspaceDocument,
        expectedRevision: UInt64,
        newRevision: DomainRevisionState,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date
    ) async throws -> DomainPersistenceWorkingCommit {
        try await DomainBlockingIO.run { cancellation in
            try blockingWorker(cancellation).persistWorkingBlocking(
                document: document,
                expectedRevision: expectedRevision,
                newRevision: newRevision,
                contextRevisions: contextRevisions,
                contextTombstones: contextTombstones,
                operations: operations,
                now: now
            )
        }
    }

    func persistSaved(
        document: DomainWorkspaceDocument,
        expectedWorkingRevision: UInt64,
        operationID: UUID,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date
    ) async throws -> DomainPersistenceSavedCommit {
        try await DomainBlockingIO.run { cancellation in
            try blockingWorker(cancellation).persistSavedBlocking(
                document: document,
                expectedWorkingRevision: expectedWorkingRevision,
                operationID: operationID,
                contextRevisions: contextRevisions,
                contextTombstones: contextTombstones,
                operations: operations,
                now: now
            )
        }
    }

    func persistExternalReload(
        document: DomainWorkspaceDocument,
        expectedRevision: UInt64,
        newRevision: UInt64,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date
    ) async throws -> DomainPersistenceSavedCommit {
        try await DomainBlockingIO.run { cancellation in
            try blockingWorker(cancellation).persistExternalReloadBlocking(
                document: document,
                expectedRevision: expectedRevision,
                newRevision: newRevision,
                contextRevisions: contextRevisions,
                contextTombstones: contextTombstones,
                operations: operations,
                now: now
            )
        }
    }

    func persistConflictRebase(
        document: DomainWorkspaceDocument,
        externalSavedDigest: String,
        expectedRevision: UInt64,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date
    ) async throws -> DomainPersistenceWorkingCommit {
        try await DomainBlockingIO.run { cancellation in
            try blockingWorker(cancellation).persistConflictRebaseBlocking(
                document: document,
                externalSavedDigest: externalSavedDigest,
                expectedRevision: expectedRevision,
                contextRevisions: contextRevisions,
                contextTombstones: contextTombstones,
                operations: operations,
                now: now
            )
        }
    }

    func persistDeleted(
        document: DomainWorkspaceDocument,
        expectedWorkspaceRevision: UInt64,
        expectedCatalogRevision: UInt64?,
        operation: DomainRecordedOperation,
        now: Date
    ) async throws -> DomainPersistenceDeleteCommit {
        try await DomainBlockingIO.run { cancellation in
            try blockingWorker(cancellation).persistDeletedBlocking(
                document: document,
                expectedWorkspaceRevision: expectedWorkspaceRevision,
                expectedCatalogRevision: expectedCatalogRevision,
                operation: operation,
                now: now
            )
        }
    }

    func currentCatalogRevision() async throws -> UInt64? {
        try await DomainBlockingIO.run { cancellation in
            try cancellation.check()
            let worker = blockingWorker(cancellation)
            guard worker.fileManager.fileExists(atPath: worker.catalogURL.path) else { return nil }
            let data = try Data(contentsOf: worker.catalogURL)
            let catalog = try worker.decoder.decode(RuntimeWorkspaceCatalog.self, from: data)
            guard catalog.version <= RuntimeWorkspaceCatalog.schemaVersion else {
                throw DomainPersistenceError.futureJournal(catalog.version)
            }
            return catalog.revision
        }
    }

    func externalDocument(
        for snapshot: DomainWorkspaceSnapshot,
        savedDigest: String
    ) async -> Result<DomainWorkspaceDocument?, DomainPersistenceError> {
        do {
            return try await DomainBlockingIO.run { cancellation in
                try cancellation.check()
                return blockingWorker(cancellation).externalDocumentBlocking(
                    for: snapshot,
                    savedDigest: savedDigest
                )
            }
        } catch let error as DomainPersistenceError {
            return .failure(error)
        } catch {
            return .failure(.writeFailed(String(describing: error)))
        }
    }

    private func bootstrapBlocking() -> DomainPersistenceBootstrap {
        var globalHealth: DomainAuthorityHealth = .writable
        let catalog: RuntimeWorkspaceCatalog?
        if let data = try? Data(contentsOf: catalogURL) {
            do {
                let decoded = try decoder.decode(RuntimeWorkspaceCatalog.self, from: data)
                if decoded.version <= RuntimeWorkspaceCatalog.schemaVersion {
                    catalog = decoded
                } else {
                    catalog = nil
                    globalHealth = .degradedReadOnly(reason: "future_workspace_catalog")
                }
            } catch {
                catalog = nil
                globalHealth = .degradedReadOnly(reason: "workspace_catalog_decode_failed")
            }
        } else {
            catalog = nil
        }

        let deletionURLs = (try? fileManager.contentsOfDirectory(
            at: deletionDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        let sidecarTombstones = deletionURLs.compactMap { url -> DomainDeletionTombstone? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let tombstone = try? decoder.decode(DomainDeletionTombstone.self, from: data),
                  tombstone.version <= DomainDeletionTombstone.schemaVersion
            else { return nil }
            return tombstone
        }
        let deletionTombstones = Dictionary(
            (sidecarTombstones + (catalog?.deletions ?? [])).map { ($0.workspaceID, $0) },
            uniquingKeysWith: { _, latest in latest }
        ).values.sorted { $0.workspaceID.uuidString < $1.workspaceID.uuidString }
        let deletedIDs = Set(deletionTombstones.map(\.workspaceID))

        let entries: [RuntimeWorkspaceCatalog.Entry]
        if let catalog {
            entries = catalog.entries.filter { !deletedIDs.contains($0.workspaceID) }
        } else {
            do {
                entries = try legacyCatalogEntries().filter { !deletedIDs.contains($0.workspaceID) }
            } catch {
                return DomainPersistenceBootstrap(
                    workspaces: [],
                    deletedOperations: deletionTombstones.map(\.operation),
                    deletedWorkspaceIDs: deletedIDs,
                    health: .degradedReadOnly(reason: "workspace_index_decode_failed"),
                    catalogRevision: 0
                )
            }
        }

        var loaded: [DomainPersistenceBootstrap.Workspace] = []
        var loadedIDs = Set<UUID>()
        for entry in entries {
            if let result = loadWorkspace(workspaceID: entry.workspaceID, fileURL: entry.fileURL) {
                loaded.append(result.workspace)
                loadedIDs.insert(entry.workspaceID)
                if let reason = result.degradedReason {
                    globalHealth = .degradedReadOnly(reason: reason)
                }
            } else {
                globalHealth = .degradedReadOnly(reason: "workspace_document_unavailable")
            }
        }

        // A crash between an atomic journal commit and catalog publication is recovered by
        // scanning only the bounded runtime-owned journal directory.
        let journalURLs = (try? fileManager.contentsOfDirectory(
            at: journalDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for journalURL in journalURLs where journalURL.pathExtension == "json" {
            guard let workspaceID = UUID(uuidString: journalURL.deletingPathExtension().lastPathComponent),
                  !loadedIDs.contains(workspaceID),
                  !deletedIDs.contains(workspaceID),
                  case let .success(journal?) = loadJournal(workspaceID: workspaceID),
                  journal.version <= DomainWorkingJournal.schemaVersion,
                  let result = loadWorkspace(workspaceID: workspaceID, fileURL: journal.fileURL)
            else { continue }
            loaded.append(result.workspace)
            loadedIDs.insert(workspaceID)
            if let reason = result.degradedReason {
                globalHealth = .degradedReadOnly(reason: reason)
            }
        }

        return DomainPersistenceBootstrap(
            workspaces: loaded,
            deletedOperations: deletionTombstones.map(\.operation),
            deletedWorkspaceIDs: deletedIDs,
            health: globalHealth,
            catalogRevision: catalog?.revision ?? 0
        )
    }

    private func legacyCatalogEntries() throws -> [RuntimeWorkspaceCatalog.Entry] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        return try decoder.decode([LegacyWorkspaceIndexEntry].self, from: Data(contentsOf: indexURL)).map { entry in
            let fileURL = entry.customStoragePath?.appendingPathComponent("workspace.json")
                ?? workspaceRoot
                .appendingPathComponent("Workspace-\(entry.name)-\(entry.id.uuidString)", isDirectory: true)
                .appendingPathComponent("workspace.json")
            return RuntimeWorkspaceCatalog.Entry(workspaceID: entry.id, fileURL: fileURL)
        }
    }

    private func loadWorkspace(
        workspaceID: UUID,
        fileURL: URL
    ) -> (workspace: DomainPersistenceBootstrap.Workspace, degradedReason: String?)? {
        let savedBytes = try? Data(contentsOf: fileURL)
        switch loadJournal(workspaceID: workspaceID) {
        case let .success(journal?):
            guard journal.version <= DomainWorkingJournal.schemaVersion else {
                guard let savedBytes,
                      let saved = try? DomainWorkspaceDocument.decode(documentBytes: savedBytes, fileURL: fileURL)
                else { return nil }
                return (.init(
                    document: saved,
                    savedDigest: saved.contentDigest,
                    revisions: .initial,
                    contextRevisions: [:],
                    contextTombstones: [:],
                    operations: [],
                    health: .degradedReadOnly(reason: "future_working_journal")
                ), "future_working_journal")
            }
            if let recovered = resolvedPendingSave(journal) {
                return (.init(
                    document: recovered.document,
                    savedDigest: recovered.journal.savedDigest,
                    revisions: recovered.journal.revisions,
                    contextRevisions: recovered.journal.contextRevisions,
                    contextTombstones: recovered.journal.contextTombstones,
                    operations: recovered.journal.operations,
                    health: .writable
                ), nil)
            }
            guard let bytes = journal.workingDocument ?? savedBytes,
                  let document = try? DomainWorkspaceDocument.decode(documentBytes: bytes, fileURL: fileURL)
            else { return nil }
            return (.init(
                document: document,
                savedDigest: journal.savedDigest,
                revisions: journal.revisions,
                contextRevisions: journal.contextRevisions,
                contextTombstones: journal.contextTombstones,
                operations: journal.operations,
                health: .writable
            ), nil)
        case .success(nil):
            guard let savedBytes,
                  let document = try? DomainWorkspaceDocument.decode(documentBytes: savedBytes, fileURL: fileURL)
            else { return nil }
            let revisions = loadSavedRevision(workspaceID: workspaceID, digest: document.contentDigest)
            return (.init(
                document: document,
                savedDigest: document.contentDigest,
                revisions: revisions,
                contextRevisions: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                    ($0.identity.contextID, revisions)
                }),
                contextTombstones: [:],
                operations: [],
                health: .writable
            ), nil)
        case .failure:
            guard let savedBytes,
                  let document = try? DomainWorkspaceDocument.decode(documentBytes: savedBytes, fileURL: fileURL)
            else { return nil }
            return (.init(
                document: document,
                savedDigest: document.contentDigest,
                revisions: .initial,
                contextRevisions: [:],
                contextTombstones: [:],
                operations: [],
                health: .degradedReadOnly(reason: "working_journal_decode_failed")
            ), "working_journal_decode_failed")
        }
    }

    private func persistCreatedBlocking(
        document: DomainWorkspaceDocument,
        expectedCatalogRevision: UInt64?,
        operationID: UUID,
        contextRevisions: [UUID: DomainRevisionState],
        operation: DomainRecordedOperation,
        now: Date
    ) throws -> DomainPersistenceSavedCommit {
        try ensureLazyMigration(now: now)
        return try withLock(at: lockDirectory.appendingPathComponent("workspace-catalog.lock")) {
            let currentCatalog = try loadCurrentCatalog(now: now)
            if let expectedCatalogRevision,
               expectedCatalogRevision != currentCatalog.revision
            {
                throw DomainPersistenceError.stateConflict(
                    expected: expectedCatalogRevision,
                    actual: currentCatalog.revision
                )
            }
            guard !currentCatalog.entries.contains(where: {
                $0.workspaceID == document.workspaceID
            }) else {
                throw DomainPersistenceError.stateConflict(expected: 0, actual: 1)
            }

            let cleanRevisions = DomainRevisionState(
                workingRevision: 1,
                savedRevision: 1,
                dirtyRevision: nil
            )
            let journal = try withLock(at: lockURL(document.workspaceID)) {
                if case let .success(existing?) = loadJournal(workspaceID: document.workspaceID) {
                    throw DomainPersistenceError.stateConflict(
                        expected: 0,
                        actual: existing.revisions.workingRevision
                    )
                }
                guard !fileManager.fileExists(atPath: document.fileURL.path) else {
                    throw DomainPersistenceError.stateConflict(expected: 0, actual: 1)
                }
                let pendingRevisions = DomainRevisionState(
                    workingRevision: 1,
                    savedRevision: 0,
                    dirtyRevision: 1
                )
                let pending = DomainWorkingJournal(
                    workspaceID: document.workspaceID,
                    fileURL: document.fileURL,
                    revisions: pendingRevisions,
                    savedDigest: DomainContentDigest.sha256(Data()),
                    workingDocument: document.documentBytes,
                    contextRevisions: contextRevisions,
                    contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                        ($0.identity.contextID, $0.contentDigest)
                    }),
                    contextTombstones: [:],
                    operations: [operation],
                    pendingSave: DomainPendingSave(
                        operationID: operationID,
                        documentDigest: document.contentDigest
                    ),
                    updatedAt: now
                )
                try DomainPersistenceLock.atomicWrite(
                    try encoder.encode(pending),
                    to: journalURL(document.workspaceID)
                )
                try DomainPersistenceLock.atomicWrite(document.documentBytes, to: document.fileURL)
                let committed = DomainWorkingJournal(
                    workspaceID: document.workspaceID,
                    fileURL: document.fileURL,
                    revisions: cleanRevisions,
                    savedDigest: document.contentDigest,
                    workingDocument: nil,
                    contextRevisions: contextRevisions.mapValues { state in
                        DomainRevisionState(
                            workingRevision: state.workingRevision,
                            savedRevision: state.workingRevision,
                            dirtyRevision: nil
                        )
                    },
                    contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                        ($0.identity.contextID, $0.contentDigest)
                    }),
                    contextTombstones: [:],
                    operations: [operation],
                    updatedAt: now
                )
                try DomainPersistenceLock.atomicWrite(
                    try encoder.encode(committed),
                    to: journalURL(document.workspaceID)
                )
                try DomainPersistenceLock.atomicWrite(
                    try encoder.encode(DomainSavedRevisionRecord(
                        workspaceID: document.workspaceID,
                        savedRevision: 1,
                        documentDigest: document.contentDigest,
                        operationID: operationID,
                        updatedAt: now
                    )),
                    to: revisionURL(document.workspaceID)
                )
                return committed
            }

            var entries = currentCatalog.entries.filter {
                $0.workspaceID != document.workspaceID
            }
            entries.append(.init(
                workspaceID: document.workspaceID,
                fileURL: document.fileURL
            ))
            let nextCatalog = RuntimeWorkspaceCatalog(
                version: RuntimeWorkspaceCatalog.schemaVersion,
                revision: currentCatalog.revision &+ 1,
                entries: entries.sorted { $0.workspaceID.uuidString < $1.workspaceID.uuidString },
                deletions: (currentCatalog.deletions ?? []).filter {
                    $0.workspaceID != document.workspaceID
                },
                updatedAt: now
            )
            do {
                try DomainPersistenceLock.atomicWrite(try encoder.encode(nextCatalog), to: catalogURL)
            } catch {
                // Catalog publication is the create authority point. Roll back the earlier
                // intent/document artifacts when publication fails in-process; a process crash
                // is instead recovered from the create-marked journal on the next mutation.
                try? fileManager.removeItem(at: journalURL(document.workspaceID))
                try? fileManager.removeItem(at: revisionURL(document.workspaceID))
                try? fileManager.removeItem(at: document.fileURL)
                throw error
            }
            return DomainPersistenceSavedCommit(
                journal: journal,
                catalogRevision: nextCatalog.revision
            )
        }
    }

    private func persistUnchangedBlocking(
        document: DomainWorkspaceDocument,
        expectedRevision: UInt64,
        operation: DomainRecordedOperation,
        now: Date
    ) throws -> DomainPersistenceWorkingCommit {
        try ensureLazyMigration(now: now)
        return try withExistingWorkspaceLocks(document: document, now: now) { catalogRevision in
            let durable = try readCurrentJournalOrSeed(document: document)
            guard durable.revisions.workingRevision == expectedRevision else {
                throw DomainPersistenceError.stateConflict(
                    expected: expectedRevision,
                    actual: durable.revisions.workingRevision
                )
            }
            let journal = DomainWorkingJournal(
                workspaceID: durable.workspaceID,
                fileURL: durable.fileURL,
                revisions: durable.revisions,
                savedDigest: durable.savedDigest,
                workingDocument: durable.workingDocument,
                contextRevisions: durable.contextRevisions,
                contextDigests: durable.contextDigests,
                contextTombstones: durable.contextTombstones,
                operations: Self.trimmedOperations(durable.operations + [operation], now: now),
                pendingSave: durable.pendingSave,
                updatedAt: now
            )
            try DomainPersistenceLock.atomicWrite(try encoder.encode(journal), to: journalURL(document.workspaceID))
            return DomainPersistenceWorkingCommit(journal: journal, catalogRevision: catalogRevision)
        }
    }

    private func persistWorkingBlocking(
        document: DomainWorkspaceDocument,
        expectedRevision: UInt64,
        newRevision: DomainRevisionState,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date
    ) throws -> DomainPersistenceWorkingCommit {
        try ensureLazyMigration(now: now)
        return try withExistingWorkspaceLocks(document: document, now: now) { catalogRevision in
            let durable = try readCurrentJournalOrSeed(document: document)
            guard durable.revisions.workingRevision == expectedRevision else {
                throw DomainPersistenceError.stateConflict(
                    expected: expectedRevision,
                    actual: durable.revisions.workingRevision
                )
            }
            let journal = DomainWorkingJournal(
                workspaceID: document.workspaceID,
                fileURL: document.fileURL,
                revisions: newRevision,
                savedDigest: durable.savedDigest,
                workingDocument: newRevision.dirtyRevision == nil ? nil : document.documentBytes,
                contextRevisions: contextRevisions,
                contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                    ($0.identity.contextID, $0.contentDigest)
                }),
                contextTombstones: contextTombstones,
                operations: Self.trimmedOperations(operations, now: now),
                updatedAt: now
            )
            try DomainPersistenceLock.atomicWrite(try encoder.encode(journal), to: journalURL(document.workspaceID))
            return DomainPersistenceWorkingCommit(journal: journal, catalogRevision: catalogRevision)
        }
    }

    private func persistSavedBlocking(
        document: DomainWorkspaceDocument,
        expectedWorkingRevision: UInt64,
        operationID: UUID,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date
    ) throws -> DomainPersistenceSavedCommit {
        try ensureLazyMigration(now: now)
        return try withExistingWorkspaceLocks(document: document, now: now) { catalogRevision in
            let durable = try readCurrentJournalOrSeed(document: document)
            guard durable.revisions.workingRevision == expectedWorkingRevision else {
                throw DomainPersistenceError.stateConflict(
                    expected: expectedWorkingRevision,
                    actual: durable.revisions.workingRevision
                )
            }
            if let diskBytes = try? Data(contentsOf: document.fileURL) {
                let diskDigest = DomainContentDigest.sha256(diskBytes)
                guard diskDigest == durable.savedDigest || diskDigest == document.contentDigest else {
                    throw DomainPersistenceError.externalDocumentConflict
                }
            }
            let cleanRevisions = DomainRevisionState(
                workingRevision: durable.revisions.workingRevision,
                savedRevision: durable.revisions.workingRevision,
                dirtyRevision: nil
            )
            let pendingJournal = DomainWorkingJournal(
                workspaceID: document.workspaceID,
                fileURL: document.fileURL,
                revisions: durable.revisions,
                savedDigest: durable.savedDigest,
                workingDocument: document.documentBytes,
                contextRevisions: contextRevisions,
                contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                    ($0.identity.contextID, $0.contentDigest)
                }),
                contextTombstones: contextTombstones,
                operations: Self.trimmedOperations(operations, now: now),
                pendingSave: DomainPendingSave(
                    operationID: operationID,
                    documentDigest: document.contentDigest
                ),
                updatedAt: now
            )
            try DomainPersistenceLock.atomicWrite(
                try encoder.encode(pendingJournal),
                to: journalURL(document.workspaceID)
            )
            try DomainPersistenceLock.atomicWrite(document.documentBytes, to: document.fileURL)
            let revision = DomainSavedRevisionRecord(
                workspaceID: document.workspaceID,
                savedRevision: cleanRevisions.savedRevision,
                documentDigest: document.contentDigest,
                operationID: operationID,
                updatedAt: now
            )
            let journal = DomainWorkingJournal(
                workspaceID: document.workspaceID,
                fileURL: document.fileURL,
                revisions: cleanRevisions,
                savedDigest: document.contentDigest,
                workingDocument: nil,
                contextRevisions: contextRevisions.mapValues { state in
                    DomainRevisionState(
                        workingRevision: state.workingRevision,
                        savedRevision: state.workingRevision,
                        dirtyRevision: nil
                    )
                },
                contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                    ($0.identity.contextID, $0.contentDigest)
                }),
                contextTombstones: contextTombstones,
                operations: Self.trimmedOperations(operations, now: now),
                updatedAt: now
            )
            // The saved document is the authority point. Final sidecars are recoverable from
            // the pending journal plus document digest, so a post-document sidecar failure must
            // not report a false failed commit to a retrying caller.
            do {
                try DomainPersistenceLock.atomicWrite(try encoder.encode(journal), to: journalURL(document.workspaceID))
                try DomainPersistenceLock.atomicWrite(try encoder.encode(revision), to: revisionURL(document.workspaceID))
            } catch {
                // Leave the durable pending journal in place. resolvedPendingSave(_:) presents
                // and persists the same clean revision on the next load/mutation.
            }
            return DomainPersistenceSavedCommit(journal: journal, catalogRevision: catalogRevision)
        }
    }

    private func persistExternalReloadBlocking(
        document: DomainWorkspaceDocument,
        expectedRevision: UInt64,
        newRevision: UInt64,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date
    ) throws -> DomainPersistenceSavedCommit {
        try ensureLazyMigration(now: now)
        return try withExistingWorkspaceLocks(document: document, now: now) { catalogRevision in
            let current = try readCurrentJournalOrSeed(document: document)
            guard current.revisions.workingRevision == expectedRevision else {
                throw DomainPersistenceError.stateConflict(
                    expected: expectedRevision,
                    actual: current.revisions.workingRevision
                )
            }
            let revisions = DomainRevisionState(
                workingRevision: newRevision,
                savedRevision: newRevision,
                dirtyRevision: nil
            )
            let operationID = UUID()
            let revisionRecord = DomainSavedRevisionRecord(
                workspaceID: document.workspaceID,
                savedRevision: newRevision,
                documentDigest: document.contentDigest,
                operationID: operationID,
                updatedAt: now
            )
            let journal = DomainWorkingJournal(
                workspaceID: document.workspaceID,
                fileURL: document.fileURL,
                revisions: revisions,
                savedDigest: document.contentDigest,
                workingDocument: nil,
                contextRevisions: contextRevisions.mapValues { state in
                    DomainRevisionState(
                        workingRevision: state.workingRevision,
                        savedRevision: state.workingRevision,
                        dirtyRevision: nil
                    )
                },
                contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                    ($0.identity.contextID, $0.contentDigest)
                }),
                contextTombstones: contextTombstones,
                operations: Self.trimmedOperations(operations, now: now),
                updatedAt: now
            )
            try DomainPersistenceLock.atomicWrite(try encoder.encode(journal), to: journalURL(document.workspaceID))
            try DomainPersistenceLock.atomicWrite(
                try encoder.encode(revisionRecord),
                to: revisionURL(document.workspaceID)
            )
            return DomainPersistenceSavedCommit(journal: journal, catalogRevision: catalogRevision)
        }
    }

    private func persistConflictRebaseBlocking(
        document: DomainWorkspaceDocument,
        externalSavedDigest: String,
        expectedRevision: UInt64,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date
    ) throws -> DomainPersistenceWorkingCommit {
        try ensureLazyMigration(now: now)
        return try withExistingWorkspaceLocks(document: document, now: now) { catalogRevision in
            let current = try readCurrentJournalOrSeed(document: document)
            guard current.revisions.workingRevision == expectedRevision else {
                throw DomainPersistenceError.stateConflict(
                    expected: expectedRevision,
                    actual: current.revisions.workingRevision
                )
            }
            let journal = DomainWorkingJournal(
                workspaceID: document.workspaceID,
                fileURL: document.fileURL,
                revisions: current.revisions,
                savedDigest: externalSavedDigest,
                workingDocument: document.documentBytes,
                contextRevisions: contextRevisions,
                contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                    ($0.identity.contextID, $0.contentDigest)
                }),
                contextTombstones: contextTombstones,
                operations: Self.trimmedOperations(operations, now: now),
                updatedAt: now
            )
            try DomainPersistenceLock.atomicWrite(try encoder.encode(journal), to: journalURL(document.workspaceID))
            return DomainPersistenceWorkingCommit(journal: journal, catalogRevision: catalogRevision)
        }
    }

    private func persistDeletedBlocking(
        document: DomainWorkspaceDocument,
        expectedWorkspaceRevision: UInt64,
        expectedCatalogRevision: UInt64?,
        operation: DomainRecordedOperation,
        now: Date
    ) throws -> DomainPersistenceDeleteCommit {
        try ensureLazyMigration(now: now)
        return try withLock(at: lockDirectory.appendingPathComponent("workspace-catalog.lock")) {
            let currentCatalog = try loadCurrentCatalog(now: now)
            if let expectedCatalogRevision,
               expectedCatalogRevision != currentCatalog.revision
            {
                throw DomainPersistenceError.stateConflict(
                    expected: expectedCatalogRevision,
                    actual: currentCatalog.revision
                )
            }
            return try withLock(at: lockURL(document.workspaceID)) {
                let current = try readCurrentJournalOrSeed(document: document)
                guard current.revisions.workingRevision == expectedWorkspaceRevision else {
                    throw DomainPersistenceError.stateConflict(
                        expected: expectedWorkspaceRevision,
                        actual: current.revisions.workingRevision
                    )
                }
                let tombstone = DomainDeletionTombstone(
                    workspaceID: document.workspaceID,
                    fileURL: document.fileURL,
                    operation: operation,
                    deletedAt: now
                )
                let entries = currentCatalog.entries.filter {
                    $0.workspaceID != document.workspaceID
                }
                var deletions = (currentCatalog.deletions ?? []).filter {
                    $0.workspaceID != document.workspaceID
                }
                deletions.append(tombstone)
                let next = RuntimeWorkspaceCatalog(
                    version: RuntimeWorkspaceCatalog.schemaVersion,
                    revision: currentCatalog.revision &+ 1,
                    entries: entries,
                    deletions: deletions,
                    updatedAt: now
                )
                // Catalog deletion is the crash-safe authority point. The sidecar and artifact
                // cleanup follow while both identity and workspace locks remain held.
                try DomainPersistenceLock.atomicWrite(try encoder.encode(next), to: catalogURL)
                // The catalog embeds the full tombstone. Its sidecar is a recoverable
                // convenience and cannot turn an already-authoritative delete into failure.
                try? DomainPersistenceLock.atomicWrite(
                    try encoder.encode(tombstone),
                    to: deletionURL(document.workspaceID)
                )
                try? fileManager.removeItem(at: journalURL(document.workspaceID))
                try? fileManager.removeItem(at: revisionURL(document.workspaceID))
                try? fileManager.removeItem(at: document.fileURL)
                return DomainPersistenceDeleteCommit(
                    catalogRevision: next.revision,
                    tombstone: tombstone
                )
            }
        }
    }

    private func externalDocumentBlocking(
        for snapshot: DomainWorkspaceSnapshot,
        savedDigest: String
    ) -> Result<DomainWorkspaceDocument?, DomainPersistenceError> {
        do {
            guard fileManager.fileExists(atPath: snapshot.document.fileURL.path) else {
                return .success(nil)
            }
            let bytes = try Data(contentsOf: snapshot.document.fileURL)
            let digest = DomainContentDigest.sha256(bytes)
            guard digest != savedDigest else { return .success(nil) }
            return .success(try DomainWorkspaceDocument.decode(documentBytes: bytes, fileURL: snapshot.document.fileURL))
        } catch {
            return .failure(.invalidWorkspaceDocument)
        }
    }

    private func resolvedPendingSave(
        _ journal: DomainWorkingJournal
    ) -> (journal: DomainWorkingJournal, document: DomainWorkspaceDocument)? {
        guard let pendingSave = journal.pendingSave,
              let savedBytes = try? Data(contentsOf: journal.fileURL),
              DomainContentDigest.sha256(savedBytes) == pendingSave.documentDigest,
              let document = try? DomainWorkspaceDocument.decode(
                  documentBytes: savedBytes,
                  fileURL: journal.fileURL
              )
        else { return nil }
        let cleanRevisions = DomainRevisionState(
            workingRevision: journal.revisions.workingRevision,
            savedRevision: journal.revisions.workingRevision,
            dirtyRevision: nil
        )
        return (DomainWorkingJournal(
            workspaceID: journal.workspaceID,
            fileURL: journal.fileURL,
            revisions: cleanRevisions,
            savedDigest: pendingSave.documentDigest,
            workingDocument: nil,
            contextRevisions: journal.contextRevisions.mapValues { state in
                DomainRevisionState(
                    workingRevision: state.workingRevision,
                    savedRevision: state.workingRevision,
                    dirtyRevision: nil
                )
            },
            contextDigests: journal.contextDigests,
            contextTombstones: journal.contextTombstones,
            operations: journal.operations,
            updatedAt: journal.updatedAt
        ), document)
    }

    private func loadJournal(workspaceID: UUID) -> Result<DomainWorkingJournal?, Error> {
        let url = journalURL(workspaceID)
        guard fileManager.fileExists(atPath: url.path) else { return .success(nil) }
        do {
            let journal = try decoder.decode(DomainWorkingJournal.self, from: Data(contentsOf: url))
            return .success(journal)
        } catch {
            return .failure(error)
        }
    }

    private func loadSavedRevision(workspaceID: UUID, digest: String) -> DomainRevisionState {
        let url = revisionURL(workspaceID)
        guard let data = try? Data(contentsOf: url),
              let record = try? decoder.decode(DomainSavedRevisionRecord.self, from: data),
              record.version <= DomainSavedRevisionRecord.schemaVersion,
              record.documentDigest == digest
        else { return .initial }
        return DomainRevisionState(
            workingRevision: record.savedRevision,
            savedRevision: record.savedRevision,
            dirtyRevision: nil
        )
    }

    private func readCurrentJournalOrSeed(document: DomainWorkspaceDocument) throws -> DomainWorkingJournal {
        switch loadJournal(workspaceID: document.workspaceID) {
        case let .success(journal?):
            guard journal.version <= DomainWorkingJournal.schemaVersion else {
                throw DomainPersistenceError.futureJournal(journal.version)
            }
            return resolvedPendingSave(journal)?.journal ?? journal
        case .success(nil):
            let savedBytes = (try? Data(contentsOf: document.fileURL)) ?? document.documentBytes
            let savedDigest = DomainContentDigest.sha256(savedBytes)
            let revisions = loadSavedRevision(workspaceID: document.workspaceID, digest: savedDigest)
            return DomainWorkingJournal(
                workspaceID: document.workspaceID,
                fileURL: document.fileURL,
                revisions: revisions,
                savedDigest: savedDigest,
                workingDocument: nil,
                contextRevisions: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                    ($0.identity.contextID, revisions)
                }),
                contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                    ($0.identity.contextID, $0.contentDigest)
                }),
                contextTombstones: [:],
                operations: [],
                updatedAt: identity.createdAt
            )
        case .failure:
            throw DomainPersistenceError.corruptJournal
        }
    }

    private func withExistingWorkspaceLocks<T>(
        document: DomainWorkspaceDocument,
        now: Date,
        _ body: (UInt64) throws -> T
    ) throws -> T {
        try withLock(at: lockDirectory.appendingPathComponent("workspace-catalog.lock")) {
            let catalog = try loadCurrentCatalog(now: now)
            let isDeleted = (catalog.deletions ?? []).contains {
                $0.workspaceID == document.workspaceID
            }
            guard !isDeleted else {
                throw DomainPersistenceError.stateConflict(
                    expected: catalog.revision,
                    actual: catalog.revision &+ 1
                )
            }
            return try withLock(at: lockURL(document.workspaceID)) {
                if let entry = catalog.entries.first(where: {
                    $0.workspaceID == document.workspaceID
                }) {
                    guard entry.fileURL.standardizedFileURL == document.fileURL.standardizedFileURL else {
                        throw DomainPersistenceError.stateConflict(
                            expected: catalog.revision,
                            actual: catalog.revision &+ 1
                        )
                    }
                    return try body(catalog.revision)
                }

                // A process may die after the create intent/document commit but before catalog
                // publication. Only that runtime-owned create marker may complete identity here;
                // an ordinary stale writer can never recreate a deleted/missing catalog entry.
                let recovered = try readCurrentJournalOrSeed(document: document)
                guard recovered.fileURL.standardizedFileURL == document.fileURL.standardizedFileURL,
                      recovered.operations.contains(where: { $0.before == nil })
                else {
                    throw DomainPersistenceError.stateConflict(
                        expected: catalog.revision,
                        actual: catalog.revision &+ 1
                    )
                }
                var entries = catalog.entries
                entries.append(.init(
                    workspaceID: document.workspaceID,
                    fileURL: document.fileURL
                ))
                let repairedCatalog = RuntimeWorkspaceCatalog(
                    version: RuntimeWorkspaceCatalog.schemaVersion,
                    revision: catalog.revision &+ 1,
                    entries: entries.sorted { $0.workspaceID.uuidString < $1.workspaceID.uuidString },
                    deletions: catalog.deletions ?? [],
                    updatedAt: now
                )
                try DomainPersistenceLock.atomicWrite(
                    try encoder.encode(repairedCatalog),
                    to: catalogURL
                )
                return try body(repairedCatalog.revision)
            }
        }
    }

    private func loadCurrentCatalog(now: Date) throws -> RuntimeWorkspaceCatalog {
        if fileManager.fileExists(atPath: catalogURL.path) {
            let current = try decoder.decode(
                RuntimeWorkspaceCatalog.self,
                from: Data(contentsOf: catalogURL)
            )
            guard current.version <= RuntimeWorkspaceCatalog.schemaVersion else {
                throw DomainPersistenceError.futureJournal(current.version)
            }
            return current
        }
        return RuntimeWorkspaceCatalog(
            version: RuntimeWorkspaceCatalog.schemaVersion,
            revision: 0,
            entries: try legacyCatalogEntries(),
            updatedAt: now
        )
    }

    private func ensureLazyMigration(now: Date) throws {
        guard !fileManager.fileExists(atPath: policyURL.path) else { return }
        try withLock(at: lockDirectory.appendingPathComponent("runtime-policy.lock")) {
            guard !fileManager.fileExists(atPath: policyURL.path) else { return }
            let rollbackName = "migration-\(Int(now.timeIntervalSince1970))-\(identity.runtimeID.uuidString)"
            let rollbackDirectory = rollbackRoot.appendingPathComponent(rollbackName, isDirectory: true)
            var artifacts: [RollbackManifest.Artifact] = []
            if let indexBytes = try? Data(contentsOf: indexURL) {
                let destination = rollbackDirectory.appendingPathComponent("workspacesIndex.json")
                try DomainPersistenceLock.atomicWrite(indexBytes, to: destination)
                artifacts.append(.init(relativePath: "workspacesIndex.json", digest: DomainContentDigest.sha256(indexBytes)))
            }
            for entry in (try? decoder.decode([LegacyWorkspaceIndexEntry].self, from: Data(contentsOf: indexURL))) ?? [] {
                let url = entry.customStoragePath?.appendingPathComponent("workspace.json")
                    ?? workspaceRoot
                    .appendingPathComponent("Workspace-\(entry.name)-\(entry.id.uuidString)", isDirectory: true)
                    .appendingPathComponent("workspace.json")
                guard let bytes = try? Data(contentsOf: url) else { continue }
                let relative = "workspaces/\(entry.id.uuidString).json"
                try DomainPersistenceLock.atomicWrite(bytes, to: rollbackDirectory.appendingPathComponent(relative))
                artifacts.append(.init(relativePath: relative, digest: DomainContentDigest.sha256(bytes)))
            }
            if !fileManager.fileExists(atPath: catalogURL.path) {
                let catalog = RuntimeWorkspaceCatalog(
                    version: RuntimeWorkspaceCatalog.schemaVersion,
                    revision: 0,
                    entries: try legacyCatalogEntries(),
                    updatedAt: now
                )
                try DomainPersistenceLock.atomicWrite(try encoder.encode(catalog), to: catalogURL)
            }
            if !configuration.legacyRuntimeDefaults.isEmpty {
                let defaultsURL = rollbackDirectory.appendingPathComponent("legacy-runtime-defaults.json")
                let defaultsBytes = try encoder.encode(configuration.legacyRuntimeDefaults)
                try DomainPersistenceLock.atomicWrite(defaultsBytes, to: defaultsURL)
                artifacts.append(.init(
                    relativePath: "legacy-runtime-defaults.json",
                    digest: DomainContentDigest.sha256(defaultsBytes)
                ))
            }
            let manifest = RollbackManifest(
                version: RollbackManifest.schemaVersion,
                profileIdentifier: configuration.profileIdentifier,
                runtimeID: identity.runtimeID,
                runtimeGeneration: identity.lifecycleGeneration,
                createdAt: now,
                artifacts: artifacts,
                legacyDefaultKeys: configuration.legacyRuntimeDefaults.keys.sorted()
            )
            try DomainPersistenceLock.atomicWrite(
                try encoder.encode(manifest),
                to: rollbackDirectory.appendingPathComponent("manifest.json")
            )
            let policy = RuntimePolicyDocument(
                version: RuntimePolicyDocument.schemaVersion,
                profileIdentifier: configuration.profileIdentifier,
                legacyDefaultsPreserved: true,
                rollbackDirectoryName: rollbackName,
                migratedAt: now
            )
            try DomainPersistenceLock.atomicWrite(try encoder.encode(policy), to: policyURL)
        }
    }

    private static func trimmedOperations(_ operations: [DomainRecordedOperation], now: Date) -> [DomainRecordedOperation] {
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        return Array(operations.filter { $0.recordedAt >= cutoff }.suffix(4096))
    }
}

private enum DomainPersistenceLock {
    private static let waitTimeoutNanoseconds: UInt64 = 2_000_000_000
    private static let retryDelayMicroseconds: useconds_t = 10_000

    static func withLock<T>(
        at url: URL,
        cancellation: DomainBlockingCancellation?,
        _ body: () throws -> T
    ) throws -> T {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw DomainPersistenceError.writeFailed("lock_open_failed_\(errno)")
        }
        defer { close(descriptor) }
        let deadline = DispatchTime.now().uptimeNanoseconds &+ waitTimeoutNanoseconds
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw DomainPersistenceError.writeFailed("lock_acquire_failed_\(errno)")
            }
            try cancellation?.check()
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw DomainPersistenceError.lockTimedOut
            }
            usleep(retryDelayMicroseconds)
        }
        defer { flock(descriptor, LOCK_UN) }
        try cancellation?.check()
        return try body()
    }

    static func atomicWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw DomainPersistenceError.writeFailed("temp_open_failed_\(errno)")
        }
        var descriptorIsOpen = true
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: written),
                        rawBuffer.count - written
                    )
                    guard count > 0 else {
                        throw DomainPersistenceError.writeFailed("write_failed_\(errno)")
                    }
                    written += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw DomainPersistenceError.writeFailed("fsync_failed_\(errno)")
            }
            close(descriptor)
            descriptorIsOpen = false
            guard rename(temporary.path, destination.path) == 0 else {
                throw DomainPersistenceError.writeFailed("rename_failed_\(errno)")
            }
            let directoryDescriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
            if directoryDescriptor >= 0 {
                _ = fsync(directoryDescriptor)
                close(directoryDescriptor)
            }
        } catch {
            if descriptorIsOpen {
                close(descriptor)
            }
            unlink(temporary.path)
            throw error
        }
    }
}
