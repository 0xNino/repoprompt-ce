import Foundation

package enum DomainCommandOrigin: Codable, Equatable, Sendable {
    case appPresentation(windowID: Int)
    case appMCP(connectionID: UUID?)
    case standalone
    case externalReload
}

package enum DomainWorkspaceCommand: Codable, Equatable, Sendable {
    case replaceWorkingDocument(DomainWorkspaceDocument)
    case saveWorkspaceDocument(workspaceID: UUID)
    case removeWorkspace(workspaceID: UUID)
    case resolveExternalConflict(workspaceID: UUID, acceptExternal: Bool)
}

package struct DomainWorkspaceCommandEnvelope: Codable, Equatable, Sendable {
    package let operationID: UUID
    package let expectedCatalogRevision: UInt64?
    package let expectedWorkspaceRevision: UInt64?
    package let expectedContextRevision: UInt64?
    package let origin: DomainCommandOrigin
    package let command: DomainWorkspaceCommand

    package init(
        operationID: UUID,
        expectedCatalogRevision: UInt64? = nil,
        expectedWorkspaceRevision: UInt64? = nil,
        expectedContextRevision: UInt64? = nil,
        origin: DomainCommandOrigin,
        command: DomainWorkspaceCommand
    ) {
        self.operationID = operationID
        self.expectedCatalogRevision = expectedCatalogRevision
        self.expectedWorkspaceRevision = expectedWorkspaceRevision
        self.expectedContextRevision = expectedContextRevision
        self.origin = origin
        self.command = command
    }

    package var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data(operationID.uuidString.utf8)
        return DomainContentDigest.sha256(data)
    }
}

package enum DomainCommandDisposition: String, Codable, Sendable {
    case applied
    case unchanged
    case conflict
    case readOnly
    case invalid
    case failed
    case deduplicated
}

package enum DomainCommandErrorCode: String, Codable, Sendable {
    case stateConflict = "state_conflict"
    case runtimeReadOnlyDegraded = "runtime_read_only_degraded"
    case operationIDCollision = "operation_id_collision"
    case workspaceUnavailable = "workspace_unavailable"
    case invalidDocument = "invalid_document"
    case persistenceFailure = "persistence_failure"
}

package struct DomainCommandOutcome: Codable, Equatable, Sendable {
    package let operationID: UUID
    package let disposition: DomainCommandDisposition
    package let before: DomainRevisionState?
    package let after: DomainRevisionState?
    package let catalogRevision: UInt64
    package let resultingDigest: String?
    package let errorCode: DomainCommandErrorCode?
    package let diagnostic: String?
    package let workspace: DomainWorkspaceSnapshot?

    package init(
        operationID: UUID,
        disposition: DomainCommandDisposition,
        before: DomainRevisionState?,
        after: DomainRevisionState?,
        catalogRevision: UInt64,
        resultingDigest: String?,
        errorCode: DomainCommandErrorCode? = nil,
        diagnostic: String? = nil,
        workspace: DomainWorkspaceSnapshot? = nil
    ) {
        self.operationID = operationID
        self.disposition = disposition
        self.before = before
        self.after = after
        self.catalogRevision = catalogRevision
        self.resultingDigest = resultingDigest
        self.errorCode = errorCode
        self.diagnostic = diagnostic
        self.workspace = workspace
    }
}

struct DomainRecordedOperation: Codable, Equatable, Sendable {
    let operationID: UUID
    let fingerprint: String
    let recordedAt: Date
    let disposition: DomainCommandDisposition
    let before: DomainRevisionState?
    let after: DomainRevisionState?
    let catalogRevision: UInt64
    let resultingDigest: String?
    let errorCode: DomainCommandErrorCode?
    let diagnostic: String?

    init(fingerprint: String, recordedAt: Date, outcome: DomainCommandOutcome) {
        operationID = outcome.operationID
        self.fingerprint = fingerprint
        self.recordedAt = recordedAt
        disposition = outcome.disposition
        before = outcome.before
        after = outcome.after
        catalogRevision = outcome.catalogRevision
        resultingDigest = outcome.resultingDigest
        errorCode = outcome.errorCode
        diagnostic = outcome.diagnostic
    }

    func outcome(workspace: DomainWorkspaceSnapshot?) -> DomainCommandOutcome {
        DomainCommandOutcome(
            operationID: operationID,
            disposition: .deduplicated,
            before: before,
            after: after,
            catalogRevision: catalogRevision,
            resultingDigest: resultingDigest,
            errorCode: errorCode,
            diagnostic: diagnostic,
            workspace: workspace
        )
    }
}
