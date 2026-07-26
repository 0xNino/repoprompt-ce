import Darwin
import Foundation

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
    let health: DomainAuthorityHealth
    let catalogRevision: UInt64
}

struct DomainPersistenceWorkingCommit: Sendable {
    let journal: DomainWorkingJournal
}

struct DomainPersistenceSavedCommit: Sendable {
    let journal: DomainWorkingJournal
}

enum DomainPersistenceError: Error, Equatable, Sendable {
    case stateConflict(expected: UInt64, actual: UInt64)
    case externalDocumentConflict
    case futureJournal(Int)
    case corruptJournal
    case operationIDCollision
    case invalidWorkspaceDocument
    case writeFailed(String)
}

package actor DomainPersistenceCoordinator {
    private struct RuntimeWorkspaceCatalog: Codable {
        static let schemaVersion = 1

        struct Entry: Codable, Equatable {
            let workspaceID: UUID
            let fileURL: URL
        }

        let version: Int
        let revision: UInt64
        let entries: [Entry]
        let updatedAt: Date
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
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    package init(
        configuration: DomainRuntimeConfiguration,
        identity: DomainRuntimeIdentity,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.identity = identity
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
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
    private var lockDirectory: URL { runtimeRoot.appendingPathComponent("locks", isDirectory: true) }
    private var settingsDirectory: URL { runtimeRoot.appendingPathComponent("settings", isDirectory: true) }
    private var rollbackRoot: URL { runtimeRoot.appendingPathComponent("rollback", isDirectory: true) }
    private var policyURL: URL { settingsDirectory.appendingPathComponent("runtime-policy.json") }
    private var catalogURL: URL { runtimeRoot.appendingPathComponent("workspace-catalog.json") }
    private var indexURL: URL { workspaceRoot.appendingPathComponent("workspacesIndex.json") }

    private func journalURL(_ workspaceID: UUID) -> URL {
        journalDirectory.appendingPathComponent("\(workspaceID.uuidString).json")
    }

    private func revisionURL(_ workspaceID: UUID) -> URL {
        revisionDirectory.appendingPathComponent("\(workspaceID.uuidString).json")
    }

    private func lockURL(_ workspaceID: UUID) -> URL {
        lockDirectory.appendingPathComponent("workspace-\(workspaceID.uuidString).lock")
    }

    func bootstrap() -> DomainPersistenceBootstrap {
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

        let entries: [RuntimeWorkspaceCatalog.Entry]
        if let catalog {
            entries = catalog.entries
        } else {
            do {
                entries = try legacyCatalogEntries()
            } catch {
                return DomainPersistenceBootstrap(
                    workspaces: [],
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

    func persistWorking(
        document: DomainWorkspaceDocument,
        expectedRevision: UInt64,
        newRevision: DomainRevisionState,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date
    ) throws -> DomainPersistenceWorkingCommit {
        try ensureLazyMigration(now: now)
        try ensureCatalogEntry(for: document, now: now)
        let result: DomainPersistenceWorkingCommit = try DomainPersistenceLock.withLock(at: lockURL(document.workspaceID)) {
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
            return DomainPersistenceWorkingCommit(journal: journal)
        }
        return result
    }

    func persistSaved(
        document: DomainWorkspaceDocument,
        expectedWorkingRevision: UInt64,
        operationID: UUID,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date
    ) throws -> DomainPersistenceSavedCommit {
        try ensureLazyMigration(now: now)
        return try DomainPersistenceLock.withLock(at: lockURL(document.workspaceID)) {
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
            try DomainPersistenceLock.atomicWrite(try encoder.encode(journal), to: journalURL(document.workspaceID))
            try DomainPersistenceLock.atomicWrite(try encoder.encode(revision), to: revisionURL(document.workspaceID))
            return DomainPersistenceSavedCommit(journal: journal)
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
    ) throws -> DomainPersistenceSavedCommit {
        try ensureLazyMigration(now: now)
        return try DomainPersistenceLock.withLock(at: lockURL(document.workspaceID)) {
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
            return DomainPersistenceSavedCommit(journal: journal)
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
    ) throws -> DomainPersistenceWorkingCommit {
        try DomainPersistenceLock.withLock(at: lockURL(document.workspaceID)) {
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
            return DomainPersistenceWorkingCommit(journal: journal)
        }
    }

    package func externalDocument(
        for snapshot: DomainWorkspaceSnapshot,
        savedDigest: String
    ) -> Result<DomainWorkspaceDocument?, Error> {
        do {
            guard fileManager.fileExists(atPath: snapshot.document.fileURL.path) else {
                return .success(nil)
            }
            let bytes = try Data(contentsOf: snapshot.document.fileURL)
            let digest = DomainContentDigest.sha256(bytes)
            guard digest != savedDigest else { return .success(nil) }
            return .success(try DomainWorkspaceDocument.decode(documentBytes: bytes, fileURL: snapshot.document.fileURL))
        } catch {
            return .failure(error)
        }
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
            return journal
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

    private func ensureCatalogEntry(for document: DomainWorkspaceDocument, now: Date) throws {
        try DomainPersistenceLock.withLock(at: lockDirectory.appendingPathComponent("workspace-catalog.lock")) {
            let current: RuntimeWorkspaceCatalog
            if let data = try? Data(contentsOf: catalogURL) {
                current = try decoder.decode(RuntimeWorkspaceCatalog.self, from: data)
                guard current.version <= RuntimeWorkspaceCatalog.schemaVersion else {
                    throw DomainPersistenceError.futureJournal(current.version)
                }
            } else {
                current = RuntimeWorkspaceCatalog(
                    version: RuntimeWorkspaceCatalog.schemaVersion,
                    revision: 0,
                    entries: try legacyCatalogEntries(),
                    updatedAt: now
                )
            }
            let entry = RuntimeWorkspaceCatalog.Entry(
                workspaceID: document.workspaceID,
                fileURL: document.fileURL
            )
            guard !current.entries.contains(entry) else { return }
            var entries = current.entries.filter { $0.workspaceID != document.workspaceID }
            entries.append(entry)
            let next = RuntimeWorkspaceCatalog(
                version: RuntimeWorkspaceCatalog.schemaVersion,
                revision: current.revision &+ 1,
                entries: entries.sorted { $0.workspaceID.uuidString < $1.workspaceID.uuidString },
                updatedAt: now
            )
            try DomainPersistenceLock.atomicWrite(try encoder.encode(next), to: catalogURL)
        }
    }

    private func ensureLazyMigration(now: Date) throws {
        guard !fileManager.fileExists(atPath: policyURL.path) else { return }
        try DomainPersistenceLock.withLock(at: lockDirectory.appendingPathComponent("runtime-policy.lock")) {
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

enum DomainPersistenceLock {
    static func withLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw DomainPersistenceError.writeFailed("lock_open_failed_\(errno)")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw DomainPersistenceError.writeFailed("lock_acquire_failed_\(errno)")
        }
        defer { flock(descriptor, LOCK_UN) }
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
