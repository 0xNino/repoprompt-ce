import Foundation

package struct DomainWorkspaceStore: Sendable {
    private let authority: DomainWorkspaceContextAuthority

    init(authority: DomainWorkspaceContextAuthority) {
        self.authority = authority
    }

    package func snapshot() async -> DomainWorkspaceCatalogSnapshot {
        await authority.readySnapshot()
    }

    package func subscribe() async -> DomainWorkspaceSnapshotSubscription {
        await authority.readySubscription()
    }

    package func execute(_ command: DomainWorkspaceCommandEnvelope) async -> DomainCommandOutcome {
        await authority.execute(command)
    }

    package func reloadExternalChanges() async {
        await authority.reloadExternalChanges()
    }
}

package struct DomainContextStore: Sendable {
    private let authority: DomainWorkspaceContextAuthority

    init(authority: DomainWorkspaceContextAuthority) {
        self.authority = authority
    }

    package func snapshot(_ identity: DomainContextIdentity) async -> DomainContextSnapshot? {
        await authority.contextSnapshot(identity)
    }

    package func workspaceSnapshot(_ workspaceID: UUID) async -> DomainWorkspaceSnapshot? {
        await authority.workspaceSnapshot(workspaceID)
    }
}

actor DomainWorkspaceContextAuthority {
    private struct WorkspaceRecord: Sendable {
        var document: DomainWorkspaceDocument
        var savedDigest: String
        var revisions: DomainRevisionState
        var contextRevisions: [UUID: DomainRevisionState]
        var contextTombstones: [UUID: UInt64]
        var operations: [DomainRecordedOperation]
        var health: DomainAuthorityHealth
        var externalDocument: DomainWorkspaceDocument?
    }

    private let identity: DomainRuntimeIdentity
    private let persistence: DomainPersistenceCoordinator
    private let metrics: DomainRuntimeMetricsSink
    private var records: [UUID: WorkspaceRecord] = [:]
    private var globalOperations: [UUID: DomainRecordedOperation] = [:]
    private var health: DomainAuthorityHealth = .writable
    private var catalogRevision: UInt64 = 0
    private var publicationSequence: UInt64 = 0
    private var subscribers: [UUID: AsyncStream<DomainWorkspaceEvent>.Continuation] = [:]
    private var bootstrapTask: Task<DomainPersistenceBootstrap, Never>?
    private var didBootstrap = false

    init(
        identity: DomainRuntimeIdentity,
        persistence: DomainPersistenceCoordinator,
        metrics: DomainRuntimeMetricsSink
    ) {
        self.identity = identity
        self.persistence = persistence
        self.metrics = metrics
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        let task: Task<DomainPersistenceBootstrap, Never>
        if let bootstrapTask {
            task = bootstrapTask
        } else {
            let persistence = persistence
            let created = Task { await persistence.bootstrap() }
            bootstrapTask = created
            task = created
        }
        let loaded = await task.value
        guard !didBootstrap else { return }
        health = loaded.health
        catalogRevision = loaded.catalogRevision
        let durableOperations = loaded.deletedOperations
            + loaded.workspaces.flatMap(\.operations)
        globalOperations = Dictionary(
            durableOperations.map { ($0.operationID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        records = Dictionary(uniqueKeysWithValues: loaded.workspaces.map { workspace in
            let record = WorkspaceRecord(
                document: workspace.document,
                savedDigest: workspace.savedDigest,
                revisions: workspace.revisions,
                contextRevisions: workspace.contextRevisions,
                contextTombstones: workspace.contextTombstones,
                operations: workspace.operations,
                health: workspace.health,
                externalDocument: nil
            )
            return (workspace.document.workspaceID, record)
        })
        didBootstrap = true
        bootstrapTask = nil
        publish(
            kind: health.acceptsMutations ? .bootstrapped : .degraded,
            workspaceID: nil,
            contextID: nil,
            operationID: nil,
            revisions: nil,
            diagnostic: health.acceptsMutations ? nil : "runtime_bootstrap_degraded"
        )
    }

    func snapshot() -> DomainWorkspaceCatalogSnapshot {
        DomainWorkspaceCatalogSnapshot(
            runtimeIdentity: identity,
            isBootstrapped: didBootstrap,
            publicationSequence: publicationSequence,
            catalogRevision: catalogRevision,
            health: health,
            workspaces: records.values.map(makeSnapshot).sorted {
                let lhs = $0.document.metadata.name.localizedCaseInsensitiveCompare($1.document.metadata.name)
                if lhs != .orderedSame { return lhs == .orderedAscending }
                return $0.document.workspaceID.uuidString < $1.document.workspaceID.uuidString
            }
        )
    }

    func workspaceSnapshot(_ workspaceID: UUID) -> DomainWorkspaceSnapshot? {
        records[workspaceID].map(makeSnapshot)
    }

    func contextSnapshot(_ identity: DomainContextIdentity) -> DomainContextSnapshot? {
        guard let record = records[identity.workspaceID],
              let metadata = record.document.metadata.contexts.first(where: {
                  $0.identity.contextID == identity.contextID
              })
        else { return nil }
        return DomainContextSnapshot(
            metadata: metadata,
            revisions: record.contextRevisions[identity.contextID] ?? record.revisions,
            health: record.health
        )
    }

    func readySnapshot() async -> DomainWorkspaceCatalogSnapshot {
        await bootstrap()
        return snapshot()
    }

    func readySubscription() async -> DomainWorkspaceSnapshotSubscription {
        await bootstrap()
        return subscribe()
    }

    private func subscribe() -> DomainWorkspaceSnapshotSubscription {
        let token = UUID()
        let stream = AsyncStream<DomainWorkspaceEvent>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            subscribers[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(token) }
            }
        }
        return DomainWorkspaceSnapshotSubscription(snapshot: snapshot(), events: stream)
    }

    func execute(_ envelope: DomainWorkspaceCommandEnvelope) async -> DomainCommandOutcome {
        await bootstrap()
        let fingerprint = envelope.fingerprint
        let workspaceID = envelope.workspaceID
        if let record = workspaceID.flatMap({ records[$0] }),
           let prior = record.operations.last(where: { $0.operationID == envelope.operationID })
        {
            guard prior.fingerprint == fingerprint else {
                return collisionOutcome(envelope.operationID, workspace: makeSnapshot(record))
            }
            if case let .createWorkspace(document) = envelope.command {
                do {
                    catalogRevision = max(
                        catalogRevision,
                        try await persistence.repairRecoveredCreate(document: document, now: Date())
                    )
                } catch {
                    return persistenceFailureOutcome(envelope, record: record, error: error)
                }
            }
            publish(
                kind: .operationDeduplicated,
                workspaceID: workspaceID,
                contextID: nil,
                operationID: envelope.operationID,
                revisions: record.revisions,
                diagnostic: nil
            )
            return prior.outcome(workspace: makeSnapshot(record))
        }
        if let prior = globalOperations[envelope.operationID] {
            guard prior.fingerprint == fingerprint else {
                return collisionOutcome(envelope.operationID, workspace: nil)
            }
            if case let .createWorkspace(document) = envelope.command {
                do {
                    catalogRevision = max(
                        catalogRevision,
                        try await persistence.repairRecoveredCreate(document: document, now: Date())
                    )
                } catch {
                    return persistenceFailureOutcome(
                        envelope,
                        record: records[document.workspaceID],
                        error: error
                    )
                }
            }
            return prior.outcome(workspace: workspaceID.flatMap(workspaceSnapshot))
        }
        guard health.acceptsMutations else {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "runtime_authority_not_writable"
            )
        }
        if let expected = envelope.expectedCatalogRevision, expected != catalogRevision {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .conflict,
                errorCode: .stateConflict,
                diagnostic: "catalog_revision_mismatch"
            )
        }

        switch envelope.command {
        case let .createWorkspace(document):
            return await createWorkspace(document, envelope: envelope, fingerprint: fingerprint)
        case let .replaceWorkingDocument(document):
            return await replaceWorkingDocument(document, envelope: envelope, fingerprint: fingerprint)
        case let .saveWorkspaceDocument(workspaceID):
            return await saveWorkspace(workspaceID, envelope: envelope, fingerprint: fingerprint)
        case let .resolveExternalConflict(workspaceID, acceptExternal):
            return await resolveExternalConflict(
                workspaceID,
                acceptExternal: acceptExternal,
                envelope: envelope,
                fingerprint: fingerprint
            )
        case let .deleteWorkspace(workspaceID):
            return await deleteWorkspace(workspaceID, envelope: envelope, fingerprint: fingerprint)
        }
    }

    func reloadExternalChanges() async {
        await bootstrap()
        let observedCatalogRevision: UInt64?
        do {
            observedCatalogRevision = try await persistence.currentCatalogRevision()
        } catch {
            health = .degradedReadOnly(reason: "workspace_catalog_probe_failed")
            publish(
                kind: .degraded,
                workspaceID: nil,
                contextID: nil,
                operationID: nil,
                revisions: nil,
                diagnostic: "workspace_catalog_probe_failed"
            )
            return
        }
        let catalogChanged = observedCatalogRevision.map { $0 != catalogRevision }
            ?? (catalogRevision != 0)
        if catalogChanged {
            let durableCatalog = await persistence.bootstrap()
            catalogRevision = max(catalogRevision, durableCatalog.catalogRevision)
            if !durableCatalog.health.acceptsMutations {
                health = durableCatalog.health
            }
            for operation in durableCatalog.deletedOperations {
                globalOperations[operation.operationID] = operation
            }
            for workspaceID in durableCatalog.deletedWorkspaceIDs where records.removeValue(forKey: workspaceID) != nil {
                publish(
                    kind: .workspaceDeleted,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: nil,
                    diagnostic: "external_catalog_deletion"
                )
            }
            for workspace in durableCatalog.workspaces where records[workspace.document.workspaceID] == nil {
                records[workspace.document.workspaceID] = WorkspaceRecord(
                    document: workspace.document,
                    savedDigest: workspace.savedDigest,
                    revisions: workspace.revisions,
                    contextRevisions: workspace.contextRevisions,
                    contextTombstones: workspace.contextTombstones,
                    operations: workspace.operations,
                    health: workspace.health,
                    externalDocument: nil
                )
                publish(
                    kind: .externalReloaded,
                    workspaceID: workspace.document.workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: workspace.revisions,
                    diagnostic: "external_catalog_addition"
                )
            }
        }
        let snapshots = records.values.map(makeSnapshot)
        for current in snapshots {
            guard let savedDigest = records[current.document.workspaceID]?.savedDigest else { continue }
            let external = await persistence.externalDocument(for: current, savedDigest: savedDigest)
            switch external {
            case let .success(document?):
                guard var record = records[current.document.workspaceID] else { continue }
                if record.revisions.dirtyRevision != nil {
                    record.health = .externalConflict(reason: "saved_document_changed_while_working_state_dirty")
                    record.externalDocument = document
                    records[current.document.workspaceID] = record
                    publish(
                        kind: .externalConflict,
                        workspaceID: current.document.workspaceID,
                        contextID: nil,
                        operationID: nil,
                        revisions: record.revisions,
                        diagnostic: "external_document_conflict"
                    )
                } else {
                    let before = record.revisions
                    let next = before.workingRevision &+ 1
                    let revisions = DomainRevisionState(
                        workingRevision: next,
                        savedRevision: next,
                        dirtyRevision: nil
                    )
                    let contextUpdate = Self.updatedContextRevisions(
                        previousDocument: current.document,
                        nextDocument: document,
                        previousRevisions: record.contextRevisions,
                        workspaceRevision: revisions
                    )
                    do {
                        let persisted = try await persistence.persistExternalReload(
                            document: document,
                            expectedRevision: before.workingRevision,
                            newRevision: next,
                            contextRevisions: contextUpdate.revisions,
                            contextTombstones: record.contextTombstones.merging(contextUpdate.tombstones) { _, new in new },
                            operations: record.operations,
                            now: Date()
                        )
                        catalogRevision = max(catalogRevision, persisted.catalogRevision)
                        record.document = document
                        record.savedDigest = persisted.journal.savedDigest
                        record.revisions = persisted.journal.revisions
                        record.contextRevisions = persisted.journal.contextRevisions
                        record.contextTombstones = persisted.journal.contextTombstones
                        record.health = .writable
                        record.externalDocument = nil
                        records[current.document.workspaceID] = record
                        publish(
                            kind: .externalReloaded,
                            workspaceID: current.document.workspaceID,
                            contextID: nil,
                            operationID: nil,
                            revisions: record.revisions,
                            diagnostic: nil
                        )
                    } catch {
                        await refreshAfterCASConflict()
                        publish(
                            kind: .externalConflict,
                            workspaceID: current.document.workspaceID,
                            contextID: nil,
                            operationID: nil,
                            revisions: records[current.document.workspaceID]?.revisions,
                            diagnostic: "external_reload_cas_conflict"
                        )
                    }
                }
            case .success(nil):
                continue
            case .failure:
                guard var record = records[current.document.workspaceID] else { continue }
                record.health = .degradedReadOnly(reason: "external_workspace_decode_failed")
                records[current.document.workspaceID] = record
                publish(
                    kind: .degraded,
                    workspaceID: current.document.workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: record.revisions,
                    diagnostic: "external_workspace_decode_failed"
                )
            }
        }
    }

    private func createWorkspace(
        _ document: DomainWorkspaceDocument,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String
    ) async -> DomainCommandOutcome {
        if let existing = records[document.workspaceID] {
            if existing.document.contentDigest == document.contentDigest {
                return await unchangedOutcome(envelope, record: existing)
            }
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .conflict,
                errorCode: .stateConflict,
                diagnostic: "workspace_already_exists"
            )
        }
        guard envelope.expectedWorkspaceRevision == nil || envelope.expectedWorkspaceRevision == 0 else {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .conflict,
                errorCode: .stateConflict,
                diagnostic: "workspace_does_not_exist_at_expected_revision"
            )
        }
        let revisions = DomainRevisionState(
            workingRevision: 1,
            savedRevision: 1,
            dirtyRevision: nil
        )
        let contextRevisions = Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
            ($0.identity.contextID, revisions)
        })
        let provisional = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: nil,
            after: revisions,
            catalogRevision: catalogRevision &+ 1,
            resultingDigest: document.contentDigest
        )
        let recorded = DomainRecordedOperation(
            fingerprint: fingerprint,
            recordedAt: Date(),
            outcome: provisional
        )
        do {
            let persisted = try await persistence.persistCreated(
                document: document,
                expectedCatalogRevision: envelope.expectedCatalogRevision ?? catalogRevision,
                operationID: envelope.operationID,
                contextRevisions: contextRevisions,
                operation: recorded,
                now: recorded.recordedAt
            )
            catalogRevision = persisted.catalogRevision
            let record = WorkspaceRecord(
                document: document,
                savedDigest: persisted.journal.savedDigest,
                revisions: persisted.journal.revisions,
                contextRevisions: persisted.journal.contextRevisions,
                contextTombstones: persisted.journal.contextTombstones,
                operations: persisted.journal.operations,
                health: .writable,
                externalDocument: nil
            )
            records[document.workspaceID] = record
            globalOperations[envelope.operationID] = recorded
            let outcome = DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .applied,
                before: nil,
                after: record.revisions,
                catalogRevision: catalogRevision,
                resultingDigest: document.contentDigest,
                workspace: makeSnapshot(record)
            )
            publish(
                kind: .workspaceCreated,
                workspaceID: document.workspaceID,
                contextID: nil,
                operationID: envelope.operationID,
                revisions: record.revisions,
                diagnostic: nil
            )
            recordMetric(envelope: envelope, outcome: outcome, byteCount: document.documentBytes.count)
            return outcome
        } catch let error as DomainPersistenceError {
            if case .stateConflict = error {
                await refreshAfterCASConflict()
                return DomainCommandOutcome(
                    operationID: envelope.operationID,
                    disposition: .conflict,
                    before: nil,
                    after: records[document.workspaceID]?.revisions,
                    catalogRevision: catalogRevision,
                    resultingDigest: records[document.workspaceID]?.document.contentDigest,
                    errorCode: .stateConflict,
                    diagnostic: "durable_create_conflict",
                    workspace: records[document.workspaceID].map(makeSnapshot)
                )
            }
            return persistenceFailureOutcome(envelope, record: nil, error: error)
        } catch {
            return persistenceFailureOutcome(envelope, record: nil, error: error)
        }
    }

    private func deleteWorkspace(
        _ workspaceID: UUID,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String
    ) async -> DomainCommandOutcome {
        guard let record = records[workspaceID] else {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .invalid,
                errorCode: .workspaceUnavailable,
                diagnostic: "workspace_not_found"
            )
        }
        guard record.health.acceptsMutations else {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_not_writable"
            )
        }
        if let expected = envelope.expectedWorkspaceRevision,
           expected != record.revisions.workingRevision
        {
            return conflictOutcome(envelope, record: record, diagnostic: "workspace_revision_mismatch")
        }
        let provisional = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: record.revisions,
            after: nil,
            catalogRevision: catalogRevision &+ 1,
            resultingDigest: nil
        )
        let operation = DomainRecordedOperation(
            fingerprint: fingerprint,
            recordedAt: Date(),
            outcome: provisional
        )
        do {
            let deleted = try await persistence.persistDeleted(
                document: record.document,
                expectedWorkspaceRevision: record.revisions.workingRevision,
                expectedCatalogRevision: envelope.expectedCatalogRevision ?? catalogRevision,
                operation: operation,
                now: operation.recordedAt
            )
            records.removeValue(forKey: workspaceID)
            globalOperations[envelope.operationID] = operation
            catalogRevision = deleted.catalogRevision
            let outcome = DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .applied,
                before: record.revisions,
                after: nil,
                catalogRevision: catalogRevision,
                resultingDigest: nil
            )
            publish(
                kind: .workspaceDeleted,
                workspaceID: workspaceID,
                contextID: nil,
                operationID: envelope.operationID,
                revisions: nil,
                diagnostic: nil
            )
            recordMetric(envelope: envelope, outcome: outcome, byteCount: 0)
            return outcome
        } catch let error as DomainPersistenceError {
            if case .stateConflict = error {
                await refreshAfterCASConflict()
                return DomainCommandOutcome(
                    operationID: envelope.operationID,
                    disposition: .conflict,
                    before: record.revisions,
                    after: records[workspaceID]?.revisions,
                    catalogRevision: catalogRevision,
                    resultingDigest: records[workspaceID]?.document.contentDigest,
                    errorCode: .stateConflict,
                    diagnostic: "durable_delete_conflict",
                    workspace: records[workspaceID].map(makeSnapshot)
                )
            }
            return persistenceFailureOutcome(envelope, record: record, error: error)
        } catch {
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }
    }

    private func replaceWorkingDocument(
        _ document: DomainWorkspaceDocument,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String
    ) async -> DomainCommandOutcome {
        guard document.workspaceID == envelope.workspaceID else {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .invalid,
                errorCode: .invalidDocument,
                diagnostic: "workspace_identity_mismatch"
            )
        }
        if var record = records[document.workspaceID] {
            guard record.health.acceptsMutations else {
                return recordTransientOutcome(
                    envelope: envelope,
                    disposition: .readOnly,
                    errorCode: .runtimeReadOnlyDegraded,
                    diagnostic: "workspace_not_writable"
                )
            }
            if let expected = envelope.expectedWorkspaceRevision,
               expected != record.revisions.workingRevision
            {
                return conflictOutcome(envelope, record: record, diagnostic: "workspace_revision_mismatch")
            }
            let changedContextIDs = Self.changedContextIDs(from: record.document, to: document)
            if let expectedContext = envelope.expectedContextRevision {
                guard changedContextIDs.count == 1,
                      let changedContextID = changedContextIDs.first
                else {
                    return conflictOutcome(
                        envelope,
                        record: record,
                        diagnostic: "context_revision_scope_mismatch"
                    )
                }
                guard expectedContext == record.contextRevisions[changedContextID]?.workingRevision else {
                    return conflictOutcome(envelope, record: record, diagnostic: "context_revision_mismatch")
                }
            }
            guard record.document.contentDigest != document.contentDigest else {
                return await unchangedOutcome(envelope, record: record)
            }

            let changedContextID = changedContextIDs.count == 1 ? changedContextIDs.first : nil
            let before = record.revisions
            let nextWorking = before.workingRevision &+ 1
            let revisions = DomainRevisionState(
                workingRevision: nextWorking,
                savedRevision: before.savedRevision,
                dirtyRevision: nextWorking
            )
            let contextUpdate = Self.updatedContextRevisions(
                previousDocument: record.document,
                nextDocument: document,
                previousRevisions: record.contextRevisions,
                workspaceRevision: revisions
            )
            let provisional = DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .applied,
                before: before,
                after: revisions,
                catalogRevision: catalogRevision,
                resultingDigest: document.contentDigest,
                workspace: nil
            )
            let recorded = DomainRecordedOperation(fingerprint: fingerprint, recordedAt: Date(), outcome: provisional)
            let operations = record.operations + [recorded]
            do {
                let persisted = try await persistence.persistWorking(
                    document: document,
                    expectedRevision: before.workingRevision,
                    newRevision: revisions,
                    contextRevisions: contextUpdate.revisions,
                    contextTombstones: record.contextTombstones.merging(contextUpdate.tombstones) { _, new in new },
                    operations: operations,
                    now: recorded.recordedAt
                )
                catalogRevision = max(catalogRevision, persisted.catalogRevision)
            } catch let error as DomainPersistenceError {
                if case .stateConflict = error {
                    await refreshAfterCASConflict()
                    let refreshed = records[document.workspaceID]
                    return DomainCommandOutcome(
                        operationID: envelope.operationID,
                        disposition: .conflict,
                        before: before,
                        after: refreshed?.revisions,
                        catalogRevision: catalogRevision,
                        resultingDigest: refreshed?.document.contentDigest,
                        errorCode: .stateConflict,
                        diagnostic: "durable_workspace_revision_mismatch",
                        workspace: refreshed.map(makeSnapshot)
                    )
                }
                return persistenceFailureOutcome(envelope, record: record, error: error)
            } catch {
                return persistenceFailureOutcome(envelope, record: record, error: error)
            }
            record.document = document
            record.revisions = revisions
            record.contextRevisions = contextUpdate.revisions
            record.contextTombstones.merge(contextUpdate.tombstones) { _, new in new }
            record.operations = operations
            records[document.workspaceID] = record
            globalOperations[envelope.operationID] = recorded
            let applied = DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .applied,
                before: before,
                after: revisions,
                catalogRevision: catalogRevision,
                resultingDigest: document.contentDigest,
                workspace: makeSnapshot(record)
            )
            publish(
                kind: .workingStateCommitted,
                workspaceID: document.workspaceID,
                contextID: changedContextID,
                operationID: envelope.operationID,
                revisions: revisions,
                diagnostic: nil
            )
            recordMetric(envelope: envelope, outcome: applied, byteCount: document.documentBytes.count)
            return applied
        }

        return recordTransientOutcome(
            envelope: envelope,
            disposition: .invalid,
            errorCode: .workspaceUnavailable,
            diagnostic: "workspace_requires_explicit_create_command"
        )
    }

    private func saveWorkspace(
        _ workspaceID: UUID,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String
    ) async -> DomainCommandOutcome {
        guard var record = records[workspaceID] else {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .invalid,
                errorCode: .workspaceUnavailable,
                diagnostic: "workspace_not_found"
            )
        }
        guard record.health.acceptsMutations else {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_not_writable"
            )
        }
        if let expected = envelope.expectedWorkspaceRevision,
           expected != record.revisions.workingRevision
        {
            return conflictOutcome(envelope, record: record, diagnostic: "workspace_revision_mismatch")
        }
        guard record.revisions.dirtyRevision != nil else {
            return await unchangedOutcome(envelope, record: record)
        }
        let before = record.revisions
        let after = DomainRevisionState(
            workingRevision: before.workingRevision,
            savedRevision: before.workingRevision,
            dirtyRevision: nil
        )
        let provisional = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: before,
            after: after,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest
        )
        let recorded = DomainRecordedOperation(fingerprint: fingerprint, recordedAt: Date(), outcome: provisional)
        let operations = record.operations + [recorded]
        do {
            let saved = try await persistence.persistSaved(
                document: record.document,
                expectedWorkingRevision: before.workingRevision,
                operationID: envelope.operationID,
                contextRevisions: record.contextRevisions,
                contextTombstones: record.contextTombstones,
                operations: operations,
                now: recorded.recordedAt
            )
            catalogRevision = max(catalogRevision, saved.catalogRevision)
            record.savedDigest = saved.journal.savedDigest
            record.revisions = saved.journal.revisions
            record.contextRevisions = saved.journal.contextRevisions
            record.operations = operations
            records[workspaceID] = record
            globalOperations[envelope.operationID] = recorded
        } catch let error as DomainPersistenceError {
            if case .externalDocumentConflict = error {
                record.health = .externalConflict(reason: "saved_document_changed_before_commit")
                records[workspaceID] = record
                return conflictOutcome(envelope, record: record, diagnostic: "external_document_conflict")
            }
            return persistenceFailureOutcome(envelope, record: record, error: error)
        } catch {
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }
        let applied = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: before,
            after: record.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest,
            workspace: makeSnapshot(record)
        )
        publish(
            kind: .savedDocumentCommitted,
            workspaceID: workspaceID,
            contextID: nil,
            operationID: envelope.operationID,
            revisions: record.revisions,
            diagnostic: nil
        )
        recordMetric(envelope: envelope, outcome: applied, byteCount: record.document.documentBytes.count)
        return applied
    }

    private func resolveExternalConflict(
        _ workspaceID: UUID,
        acceptExternal: Bool,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String
    ) async -> DomainCommandOutcome {
        guard var record = records[workspaceID],
              case .externalConflict = record.health,
              let external = record.externalDocument
        else {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .invalid,
                errorCode: .workspaceUnavailable,
                diagnostic: "workspace_has_no_external_conflict"
            )
        }
        let before = record.revisions
        if let expected = envelope.expectedWorkspaceRevision,
           expected != before.workingRevision
        {
            return conflictOutcome(envelope, record: record, diagnostic: "workspace_revision_mismatch")
        }
        let now = Date()
        let after = acceptExternal
            ? DomainRevisionState(
                workingRevision: before.workingRevision &+ 1,
                savedRevision: before.workingRevision &+ 1,
                dirtyRevision: nil
            )
            : before
        let resultingDocument = acceptExternal ? external : record.document
        let provisional = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: before,
            after: after,
            catalogRevision: catalogRevision,
            resultingDigest: resultingDocument.contentDigest
        )
        let operation = DomainRecordedOperation(fingerprint: fingerprint, recordedAt: now, outcome: provisional)
        let operations = record.operations + [operation]
        do {
            if acceptExternal {
                let contextRevisions = Dictionary(uniqueKeysWithValues: external.metadata.contexts.map {
                    ($0.identity.contextID, after)
                })
                let persisted = try await persistence.persistExternalReload(
                    document: external,
                    expectedRevision: before.workingRevision,
                    newRevision: after.workingRevision,
                    contextRevisions: contextRevisions,
                    contextTombstones: record.contextTombstones,
                    operations: operations,
                    now: now
                )
                catalogRevision = max(catalogRevision, persisted.catalogRevision)
                record.document = external
                record.savedDigest = persisted.journal.savedDigest
                record.revisions = persisted.journal.revisions
                record.contextRevisions = persisted.journal.contextRevisions
            } else {
                let persisted = try await persistence.persistConflictRebase(
                    document: record.document,
                    externalSavedDigest: external.contentDigest,
                    expectedRevision: before.workingRevision,
                    contextRevisions: record.contextRevisions,
                    contextTombstones: record.contextTombstones,
                    operations: operations,
                    now: now
                )
                catalogRevision = max(catalogRevision, persisted.catalogRevision)
                record.savedDigest = persisted.journal.savedDigest
                record.revisions = persisted.journal.revisions
            }
        } catch let error as DomainPersistenceError {
            if case .stateConflict = error {
                await refreshAfterCASConflict()
                let refreshed = records[workspaceID]
                return DomainCommandOutcome(
                    operationID: envelope.operationID,
                    disposition: .conflict,
                    before: before,
                    after: refreshed?.revisions,
                    catalogRevision: catalogRevision,
                    resultingDigest: refreshed?.document.contentDigest,
                    errorCode: .stateConflict,
                    diagnostic: "durable_workspace_revision_mismatch",
                    workspace: refreshed.map(makeSnapshot)
                )
            }
            return persistenceFailureOutcome(envelope, record: record, error: error)
        } catch {
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }
        record.operations = operations
        globalOperations[envelope.operationID] = operation
        record.health = .writable
        record.externalDocument = nil
        records[workspaceID] = record
        let outcome = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: before,
            after: record.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest,
            workspace: makeSnapshot(record)
        )
        publish(
            kind: acceptExternal ? .externalReloaded : .workingStateCommitted,
            workspaceID: workspaceID,
            contextID: nil,
            operationID: envelope.operationID,
            revisions: record.revisions,
            diagnostic: acceptExternal ? "external_conflict_accepted" : "local_conflict_rebased"
        )
        return outcome
    }

    private func makeSnapshot(_ record: WorkspaceRecord) -> DomainWorkspaceSnapshot {
        DomainWorkspaceSnapshot(
            document: record.document,
            revisions: record.revisions,
            health: record.health,
            contexts: record.document.metadata.contexts.map { metadata in
                DomainContextSnapshot(
                    metadata: metadata,
                    revisions: record.contextRevisions[metadata.identity.contextID] ?? record.revisions,
                    health: record.health
                )
            }
        )
    }

    private func publish(
        kind: DomainWorkspaceEventKind,
        workspaceID: UUID?,
        contextID: UUID?,
        operationID: UUID?,
        revisions: DomainRevisionState?,
        diagnostic: String?
    ) {
        publicationSequence &+= 1
        let event = DomainWorkspaceEvent(
            runtimeID: identity.runtimeID,
            sequence: publicationSequence,
            kind: kind,
            workspaceID: workspaceID,
            contextID: contextID,
            operationID: operationID,
            revisions: revisions,
            timestamp: Date(),
            diagnostic: diagnostic
        )
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func removeSubscriber(_ token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    private func refreshAfterCASConflict() async {
        let previous = records
        let loaded = await persistence.bootstrap()
        health = loaded.health
        catalogRevision = loaded.catalogRevision
        for operation in loaded.deletedOperations + loaded.workspaces.flatMap(\.operations) {
            globalOperations[operation.operationID] = operation
        }
        records = Dictionary(uniqueKeysWithValues: loaded.workspaces.map { workspace in
            let prior = previous[workspace.document.workspaceID]
            let canPreserveConflict = prior?.document.contentDigest == workspace.document.contentDigest
                && prior?.revisions == workspace.revisions
            let priorConflictDocument: DomainWorkspaceDocument? = if canPreserveConflict,
                                                                    case .externalConflict = prior?.health
            {
                prior?.externalDocument
            } else {
                nil
            }
            return (workspace.document.workspaceID, WorkspaceRecord(
                document: workspace.document,
                savedDigest: workspace.savedDigest,
                revisions: workspace.revisions,
                contextRevisions: workspace.contextRevisions,
                contextTombstones: workspace.contextTombstones,
                operations: workspace.operations,
                health: priorConflictDocument == nil ? workspace.health : prior?.health ?? workspace.health,
                externalDocument: priorConflictDocument
            ))
        })
    }

    private func conflictOutcome(
        _ envelope: DomainWorkspaceCommandEnvelope,
        record: WorkspaceRecord,
        diagnostic: String
    ) -> DomainCommandOutcome {
        DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .conflict,
            before: record.revisions,
            after: record.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest,
            errorCode: .stateConflict,
            diagnostic: diagnostic,
            workspace: makeSnapshot(record)
        )
    }

    private func unchangedOutcome(
        _ envelope: DomainWorkspaceCommandEnvelope,
        record original: WorkspaceRecord
    ) async -> DomainCommandOutcome {
        var record = original
        let outcome = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .unchanged,
            before: record.revisions,
            after: record.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest,
            workspace: makeSnapshot(record)
        )
        let operation = DomainRecordedOperation(
            fingerprint: envelope.fingerprint,
            recordedAt: Date(),
            outcome: outcome
        )
        do {
            let persisted = try await persistence.persistUnchanged(
                document: record.document,
                expectedRevision: record.revisions.workingRevision,
                operation: operation,
                now: operation.recordedAt
            )
            catalogRevision = max(catalogRevision, persisted.catalogRevision)
            record.operations = persisted.journal.operations
            records[record.document.workspaceID] = record
            globalOperations[envelope.operationID] = operation
            return outcome
        } catch {
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }
    }

    private func collisionOutcome(
        _ operationID: UUID,
        workspace: DomainWorkspaceSnapshot?
    ) -> DomainCommandOutcome {
        DomainCommandOutcome(
            operationID: operationID,
            disposition: .invalid,
            before: workspace?.revisions,
            after: workspace?.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: workspace?.document.contentDigest,
            errorCode: .operationIDCollision,
            diagnostic: "operation_id_reused_with_different_command",
            workspace: workspace
        )
    }

    private func persistenceFailureOutcome(
        _ envelope: DomainWorkspaceCommandEnvelope,
        record: WorkspaceRecord?,
        error: Error
    ) -> DomainCommandOutcome {
        let code: DomainCommandErrorCode = switch error {
        case DomainPersistenceError.lockTimedOut: .lockTimedOut
        case DomainPersistenceError.cancelled: .cancelled
        default: .persistenceFailure
        }
        return DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .failed,
            before: record?.revisions,
            after: record?.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: record?.document.contentDigest,
            errorCode: code,
            diagnostic: String(describing: error),
            workspace: record.map(makeSnapshot)
        )
    }

    private func recordTransientOutcome(
        envelope: DomainWorkspaceCommandEnvelope,
        disposition: DomainCommandDisposition,
        errorCode: DomainCommandErrorCode,
        diagnostic: String
    ) -> DomainCommandOutcome {
        let workspace = envelope.workspaceID.flatMap(workspaceSnapshot)
        let outcome = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: disposition,
            before: workspace?.revisions,
            after: workspace?.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: workspace?.document.contentDigest,
            errorCode: errorCode,
            diagnostic: diagnostic,
            workspace: workspace
        )
        globalOperations[envelope.operationID] = DomainRecordedOperation(
            fingerprint: envelope.fingerprint,
            recordedAt: Date(),
            outcome: outcome
        )
        return outcome
    }

    private func recordMetric(
        envelope: DomainWorkspaceCommandEnvelope,
        outcome: DomainCommandOutcome,
        byteCount: Int
    ) {
        metrics.record(DomainRuntimeMetric(
            phase: .commit,
            name: "EditFlow.DomainRuntime.Commit",
            dimensions: [
                "runtime_id": identity.runtimeID.uuidString,
                "runtime_generation": "\(identity.lifecycleGeneration)",
                "runtime_mode": identity.mode.rawValue,
                "operation_id": envelope.operationID.uuidString,
                "workspace_id": envelope.workspaceID?.uuidString ?? "none",
                "context_revision": envelope.expectedContextRevision.map(String.init) ?? "none",
                "catalog_revision": "\(outcome.catalogRevision)",
                "working_revision": outcome.after.map { "\($0.workingRevision)" } ?? "none",
                "saved_revision": outcome.after.map { "\($0.savedRevision)" } ?? "none",
                "dirty_revision": outcome.after?.dirtyRevision.map(String.init) ?? "none",
                "disposition": outcome.disposition.rawValue,
                "byte_count": "\(byteCount)"
            ]
        ))
    }

    private static func changedContextIDs(
        from previous: DomainWorkspaceDocument?,
        to next: DomainWorkspaceDocument
    ) -> Set<UUID> {
        guard let previous else { return [] }
        let old = Dictionary(uniqueKeysWithValues: previous.metadata.contexts.map {
            ($0.identity.contextID, $0.contentDigest)
        })
        let new = Dictionary(uniqueKeysWithValues: next.metadata.contexts.map {
            ($0.identity.contextID, $0.contentDigest)
        })
        return Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
    }

    private static func updatedContextRevisions(
        previousDocument: DomainWorkspaceDocument,
        nextDocument: DomainWorkspaceDocument,
        previousRevisions: [UUID: DomainRevisionState],
        workspaceRevision: DomainRevisionState
    ) -> (revisions: [UUID: DomainRevisionState], tombstones: [UUID: UInt64]) {
        let old = Dictionary(uniqueKeysWithValues: previousDocument.metadata.contexts.map {
            ($0.identity.contextID, $0.contentDigest)
        })
        let new = Dictionary(uniqueKeysWithValues: nextDocument.metadata.contexts.map {
            ($0.identity.contextID, $0.contentDigest)
        })
        var revisions: [UUID: DomainRevisionState] = [:]
        for (contextID, digest) in new {
            if old[contextID] == digest, let existing = previousRevisions[contextID] {
                revisions[contextID] = existing
            } else {
                let previous = previousRevisions[contextID] ?? .initial
                let nextWorking = previous.workingRevision &+ 1
                revisions[contextID] = DomainRevisionState(
                    workingRevision: nextWorking,
                    savedRevision: previous.savedRevision,
                    dirtyRevision: nextWorking
                )
            }
        }
        let tombstones = Dictionary(uniqueKeysWithValues: old.keys.filter { new[$0] == nil }.map {
            ($0, workspaceRevision.workingRevision)
        })
        return (revisions, tombstones)
    }
}

private extension DomainWorkspaceCommandEnvelope {
    var workspaceID: UUID? {
        switch command {
        case let .createWorkspace(document): document.workspaceID
        case let .replaceWorkingDocument(document): document.workspaceID
        case let .saveWorkspaceDocument(workspaceID): workspaceID
        case let .deleteWorkspace(workspaceID): workspaceID
        case let .resolveExternalConflict(workspaceID, _): workspaceID
        }
    }
}
