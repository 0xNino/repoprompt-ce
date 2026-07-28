import Foundation

package struct DomainCredentialScope: Codable, Hashable, Sendable {
    package let providerIdentifier: String
    package let runID: UUID
    package let principalID: UUID
    package let purpose: String
    package let accountIdentifierDigest: String?

    package init(
        providerIdentifier: String,
        runID: UUID,
        principalID: UUID,
        purpose: String,
        accountIdentifierDigest: String? = nil
    ) {
        self.providerIdentifier = providerIdentifier
        self.runID = runID
        self.principalID = principalID
        self.purpose = purpose
        self.accountIdentifierDigest = accountIdentifierDigest
    }
}

package struct DomainCredentialEnvelopeDescriptor: Hashable, Sendable {
    package let envelopeID: UUID
    package let runtimeID: UUID
    package let runtimeGeneration: UInt64
    package let scope: DomainCredentialScope
    package let expiresAt: ContinuousClock.Instant
}

package struct DomainCredentialPayload: Sendable, CustomStringConvertible {
    package let bytes: [UInt8]

    package init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    package var description: String {
        "<redacted credential payload: \(bytes.count) bytes>"
    }
}

package enum DomainCredentialEnvelopeError: Error, Equatable, Sendable {
    case unavailable
    case expired
    case alreadyConsumed
    case runtimeMismatch
    case scopeMismatch
    case revoked
}

package actor DomainCredentialEnvelopeStore {
    private enum State: Sendable {
        case active
        case consumed
        case revoked
    }

    private struct Record: Sendable {
        let descriptor: DomainCredentialEnvelopeDescriptor
        var bytes: [UInt8]
        var state: State
    }

    private let identity: DomainRuntimeIdentity
    private let clock = ContinuousClock()
    private var records: [UUID: Record] = [:]
    private var isShuttingDown = false

    package init(identity: DomainRuntimeIdentity) {
        self.identity = identity
    }

    package func issue(
        bytes: [UInt8],
        scope: DomainCredentialScope,
        lifetime: Duration = .seconds(60)
    ) throws -> DomainCredentialEnvelopeDescriptor {
        guard !isShuttingDown, !bytes.isEmpty else { throw DomainCredentialEnvelopeError.unavailable }
        let descriptor = DomainCredentialEnvelopeDescriptor(
            envelopeID: UUID(),
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            scope: scope,
            expiresAt: clock.now.advanced(by: lifetime)
        )
        records[descriptor.envelopeID] = Record(descriptor: descriptor, bytes: bytes, state: .active)
        return descriptor
    }

    package func redeem(
        _ descriptor: DomainCredentialEnvelopeDescriptor,
        scope: DomainCredentialScope
    ) throws -> DomainCredentialPayload {
        guard descriptor.runtimeID == identity.runtimeID,
              descriptor.runtimeGeneration == identity.lifecycleGeneration
        else {
            throw DomainCredentialEnvelopeError.runtimeMismatch
        }
        guard descriptor.scope == scope else { throw DomainCredentialEnvelopeError.scopeMismatch }
        guard var record = records[descriptor.envelopeID] else {
            throw DomainCredentialEnvelopeError.unavailable
        }
        switch record.state {
        case .consumed:
            throw DomainCredentialEnvelopeError.alreadyConsumed
        case .revoked:
            throw DomainCredentialEnvelopeError.revoked
        case .active:
            break
        }
        guard clock.now < record.descriptor.expiresAt else {
            zero(&record.bytes)
            record.state = .revoked
            records[descriptor.envelopeID] = record
            throw DomainCredentialEnvelopeError.expired
        }
        let payload = DomainCredentialPayload(bytes: record.bytes)
        zero(&record.bytes)
        record.state = .consumed
        records[descriptor.envelopeID] = record
        return payload
    }

    package func revoke(_ envelopeID: UUID) {
        guard var record = records[envelopeID] else { return }
        zero(&record.bytes)
        record.state = .revoked
        records[envelopeID] = record
    }

    package func shutdown() {
        isShuttingDown = true
        for id in records.keys {
            guard var record = records[id] else { continue }
            zero(&record.bytes)
            record.state = .revoked
            records[id] = record
        }
    }

    private func zero(_ bytes: inout [UInt8]) {
        _ = bytes.withUnsafeMutableBytes { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
        }
        bytes.removeAll(keepingCapacity: false)
    }
}

package struct DomainChildLaunchCarrier: Sendable {
    package static let endpointEnvironmentKey = "REPOPROMPT_MCP_PRIVATE_ENDPOINT"
    package static let launchTokenEnvironmentKey = "REPOPROMPT_MCP_LAUNCH_TOKEN"
    package static let credentialEnvelopeEnvironmentKey = "REPOPROMPT_MCP_CREDENTIAL_ENVELOPE"

    package let runID: UUID
    package let launchTokenID: UUID
    package let credentialEnvelope: DomainCredentialEnvelopeDescriptor?
    package let environment: [String: String]
}

package struct DomainPrivateChildLaunchHarness: Sendable {
    package typealias IssueLaunchToken = @Sendable (
        _ request: DomainRunLaunchReservationRequest
    ) async throws -> DomainRunLaunchToken

    private let endpointDescriptor: String
    private let issueLaunchToken: IssueLaunchToken
    private let credentialStore: DomainCredentialEnvelopeStore

    package init(
        endpointDescriptor: String,
        credentialStore: DomainCredentialEnvelopeStore,
        issueLaunchToken: @escaping IssueLaunchToken
    ) {
        self.endpointDescriptor = endpointDescriptor
        self.credentialStore = credentialStore
        self.issueLaunchToken = issueLaunchToken
    }

    package func prepare(
        request: DomainRunLaunchReservationRequest,
        credential: (bytes: [UInt8], scope: DomainCredentialScope)? = nil
    ) async throws -> DomainChildLaunchCarrier {
        let token = try await issueLaunchToken(request)
        let descriptor: DomainCredentialEnvelopeDescriptor?
        if let credential {
            descriptor = try await credentialStore.issue(bytes: credential.bytes, scope: credential.scope)
        } else {
            descriptor = nil
        }
        var environment = [
            DomainChildLaunchCarrier.endpointEnvironmentKey: endpointDescriptor,
            DomainChildLaunchCarrier.launchTokenEnvironmentKey: token.material
        ]
        if let descriptor {
            environment[DomainChildLaunchCarrier.credentialEnvelopeEnvironmentKey] =
                descriptor.envelopeID.uuidString
        }
        return DomainChildLaunchCarrier(
            runID: request.runID,
            launchTokenID: token.tokenID,
            credentialEnvelope: descriptor,
            environment: environment
        )
    }
}
