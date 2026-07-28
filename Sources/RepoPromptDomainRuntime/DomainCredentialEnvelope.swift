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

package enum DomainCredentialPayloadError: Error, Equatable, Sendable {
    case alreadyConsumed
}

private final class DomainSecureCredentialBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: UnsafeMutableRawPointer
    let byteCount: Int
    private var isZeroed = false

    init(bytes: [UInt8]) {
        precondition(!bytes.isEmpty)
        byteCount = bytes.count
        storage = UnsafeMutableRawPointer.allocate(
            byteCount: bytes.count,
            alignment: MemoryLayout<UInt8>.alignment
        )
        bytes.withUnsafeBytes { source in
            guard let baseAddress = source.baseAddress else { return }
            storage.copyMemory(from: baseAddress, byteCount: bytes.count)
        }
    }

    private init(copying source: UnsafeRawPointer, byteCount: Int) {
        self.byteCount = byteCount
        storage = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<UInt8>.alignment
        )
        storage.copyMemory(from: source, byteCount: byteCount)
    }

    deinit {
        lock.lock()
        zeroLocked()
        lock.unlock()
        storage.deallocate()
    }

    func clone() throws -> DomainSecureCredentialBuffer {
        lock.lock()
        defer { lock.unlock() }
        guard !isZeroed else { throw DomainCredentialPayloadError.alreadyConsumed }
        return DomainSecureCredentialBuffer(copying: UnsafeRawPointer(storage), byteCount: byteCount)
    }

    func consume<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) throws -> Result {
        lock.lock()
        defer {
            zeroLocked()
            lock.unlock()
        }
        guard !isZeroed else { throw DomainCredentialPayloadError.alreadyConsumed }
        return try body(UnsafeRawBufferPointer(start: storage, count: byteCount))
    }

    func zeroInPlace() {
        lock.lock()
        zeroLocked()
        lock.unlock()
    }

    private func zeroLocked() {
        guard !isZeroed else { return }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        isZeroed = true
    }

    #if DEBUG
        func testSnapshot() -> [UInt8] {
            lock.lock()
            defer { lock.unlock() }
            let bytes = storage.assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: bytes, count: byteCount))
        }

        func testIsZeroed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard isZeroed else { return false }
            let bytes = storage.assumingMemoryBound(to: UInt8.self)
            return UnsafeBufferPointer(start: bytes, count: byteCount).allSatisfy { $0 == 0 }
        }
    #endif
}

package final class DomainCredentialPayload: @unchecked Sendable, CustomStringConvertible {
    private let storage: DomainSecureCredentialBuffer
    private let originalByteCount: Int

    fileprivate init(storage: DomainSecureCredentialBuffer) {
        self.storage = storage
        originalByteCount = storage.byteCount
    }

    package func withConsumedBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) throws -> Result {
        try storage.consume(body)
    }

    package var description: String {
        "<redacted credential payload: \(originalByteCount) bytes>"
    }

    #if DEBUG
        package func test_ownedStorageBytes() -> [UInt8] {
            storage.testSnapshot()
        }

        package func test_isOwnedStorageZeroed() -> Bool {
            storage.testIsZeroed()
        }
    #endif
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
        let storage: DomainSecureCredentialBuffer
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
        records[descriptor.envelopeID] = Record(
            descriptor: descriptor,
            storage: DomainSecureCredentialBuffer(bytes: bytes),
            state: .active
        )
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
            record.storage.zeroInPlace()
            record.state = .revoked
            records[descriptor.envelopeID] = record
            throw DomainCredentialEnvelopeError.expired
        }
        let payloadStorage: DomainSecureCredentialBuffer
        do {
            payloadStorage = try record.storage.clone()
        } catch {
            throw DomainCredentialEnvelopeError.alreadyConsumed
        }
        record.storage.zeroInPlace()
        record.state = .consumed
        records[descriptor.envelopeID] = record
        return DomainCredentialPayload(storage: payloadStorage)
    }

    package func revoke(_ envelopeID: UUID) {
        guard var record = records[envelopeID] else { return }
        record.storage.zeroInPlace()
        record.state = .revoked
        records[envelopeID] = record
    }

    package func shutdown() {
        isShuttingDown = true
        for id in records.keys {
            guard var record = records[id] else { continue }
            record.storage.zeroInPlace()
            record.state = .revoked
            records[id] = record
        }
    }

    #if DEBUG
        package func test_ownedStorageBytes(envelopeID: UUID) -> [UInt8]? {
            records[envelopeID]?.storage.testSnapshot()
        }

        package func test_isOwnedStorageZeroed(envelopeID: UUID) -> Bool? {
            records[envelopeID]?.storage.testIsZeroed()
        }
    #endif
}

package struct DomainChildLaunchCarrier: Sendable {
    package static let endpointEnvironmentKey = "REPOPROMPT_MCP_PRIVATE_ENDPOINT"
    package static let launchTokenEnvironmentKey = "REPOPROMPT_MCP_LAUNCH_TOKEN"
    package static let credentialEnvelopeEnvironmentKey = "REPOPROMPT_MCP_CREDENTIAL_ENVELOPE"
    package static let clientPrincipalEnvironmentKey = "REPOPROMPT_MCP_CLIENT_PRINCIPAL"
    package static let providerIdentifierEnvironmentKey = "REPOPROMPT_MCP_PROVIDER_IDENTIFIER"
    package static let runIDEnvironmentKey = "REPOPROMPT_MCP_RUN_ID"

    package let runID: UUID
    package let launchTokenID: UUID
    package let credentialEnvelope: DomainCredentialEnvelopeDescriptor?
    package let environment: [String: String]

    package init(
        runID: UUID,
        launchTokenID: UUID,
        credentialEnvelope: DomainCredentialEnvelopeDescriptor?,
        environment: [String: String]
    ) {
        self.runID = runID
        self.launchTokenID = launchTokenID
        self.credentialEnvelope = credentialEnvelope
        self.environment = environment
    }
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
            DomainChildLaunchCarrier.launchTokenEnvironmentKey: token.material,
            DomainChildLaunchCarrier.clientPrincipalEnvironmentKey: request.clientPrincipal,
            DomainChildLaunchCarrier.providerIdentifierEnvironmentKey: request.providerIdentifier,
            DomainChildLaunchCarrier.runIDEnvironmentKey: request.runID.uuidString
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
