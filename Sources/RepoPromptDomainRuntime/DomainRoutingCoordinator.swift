import Foundation
import Security

package struct DomainWindowDescriptor: Codable, Equatable, Sendable {
    package let windowID: Int
    package let generation: UInt64
    package let activeWorkspaceID: UUID?
    package let activeContextID: UUID?
    package let isClosing: Bool
    package let presentationRevision: UInt64

    package init(
        windowID: Int,
        generation: UInt64,
        activeWorkspaceID: UUID?,
        activeContextID: UUID?,
        isClosing: Bool,
        presentationRevision: UInt64
    ) {
        self.windowID = windowID
        self.generation = generation
        self.activeWorkspaceID = activeWorkspaceID
        self.activeContextID = activeContextID
        self.isClosing = isClosing
        self.presentationRevision = presentationRevision
    }
}

package struct DomainConnectionRegistration: Codable, Hashable, Sendable {
    package let connectionID: UUID
    package let generation: UInt64
    package let runtimeID: UUID

    package init(connectionID: UUID, generation: UInt64, runtimeID: UUID) {
        self.connectionID = connectionID
        self.generation = generation
        self.runtimeID = runtimeID
    }
}

package enum DomainBinding: Codable, Equatable, Sendable {
    case unbound
    case context(DomainContextIdentity, explicit: Bool)
    case appPresentationWindow(Int)
    case runScoped(runID: UUID, context: DomainContextIdentity)
}

package struct DomainConnectionBindingSnapshot: Codable, Equatable, Sendable {
    package let registration: DomainConnectionRegistration
    package let binding: DomainBinding
}

package struct DomainRoutingSnapshot: Codable, Equatable, Sendable {
    package let runtimeID: UUID
    package let revision: UInt64
    package let windows: [DomainWindowDescriptor]
    package let connections: [DomainConnectionBindingSnapshot]
    package let pendingRunContexts: [UUID: DomainContextIdentity]
}

package enum DomainRoutingDisposition: String, Codable, Sendable {
    case applied
    case unchanged
    case conflict
    case rejected
    case staleGeneration
}

package struct DomainRoutingOutcome: Codable, Equatable, Sendable {
    package let operationID: UUID
    package let disposition: DomainRoutingDisposition
    package let snapshot: DomainRoutingSnapshot
    package let diagnostic: String?
}

package struct DomainRunLaunchToken: Sendable {
    package let tokenID: UUID
    package let material: String

    init(tokenID: UUID, material: String) {
        self.tokenID = tokenID
        self.material = material
    }
}

package struct DomainRunLaunchReservationRequest: Sendable {
    package let runID: UUID
    package let context: DomainContextIdentity
    package let expectedContextRevision: UInt64
    package let windowID: Int?
    package let clientPrincipal: String
    package let providerIdentifier: String
    package let runPurpose: String
    package let restrictedTools: Set<String>
    package let additionalTools: Set<String>
    package let expectedProcessID: Int32?
    package let lifetime: Duration

    package init(
        runID: UUID,
        context: DomainContextIdentity,
        expectedContextRevision: UInt64,
        windowID: Int?,
        clientPrincipal: String,
        providerIdentifier: String,
        runPurpose: String,
        restrictedTools: Set<String> = [],
        additionalTools: Set<String> = [],
        expectedProcessID: Int32? = nil,
        lifetime: Duration = .seconds(60)
    ) {
        self.runID = runID
        self.context = context
        self.expectedContextRevision = expectedContextRevision
        self.windowID = windowID
        self.clientPrincipal = clientPrincipal
        self.providerIdentifier = providerIdentifier
        self.runPurpose = runPurpose
        self.restrictedTools = restrictedTools
        self.additionalTools = additionalTools
        self.expectedProcessID = expectedProcessID
        self.lifetime = lifetime
    }
}

package enum DomainRunLaunchRedemptionResult: Equatable, Sendable {
    case accepted(DomainConnectionBindingSnapshot)
    case unknown
    case expired
    case alreadyConsumed
    case generationMismatch
    case identityMismatch
    case revoked
}

package enum DomainRunLaunchTokenError: Error, Equatable, Sendable {
    case contextUnavailable
    case staleContextRevision(expected: UInt64, actual: UInt64)
    case randomGenerationFailed
}

package actor DomainRoutingCoordinator {
    private enum TokenState: Sendable {
        case active
        case consumed
        case revoked
    }

    private struct TokenRecord: Sendable {
        let tokenID: UUID
        let digest: String
        let request: DomainRunLaunchReservationRequest
        let issuedAt: ContinuousClock.Instant
        let expiresAt: ContinuousClock.Instant
        var state: TokenState
    }

    private let identity: DomainRuntimeIdentity
    private let contextStore: DomainContextStore
    private let metrics: DomainRuntimeMetricsSink
    private let clock = ContinuousClock()
    private var revision: UInt64 = 0
    private var windows: [Int: DomainWindowDescriptor] = [:]
    private var connections: [UUID: DomainConnectionBindingSnapshot] = [:]
    private var nextConnectionGeneration: [UUID: UInt64] = [:]
    private var pendingRunContexts: [UUID: DomainContextIdentity] = [:]
    private var tokenRecords: [String: TokenRecord] = [:]
    private var routingOperations: [UUID: DomainRoutingOutcome] = [:]

    init(
        identity: DomainRuntimeIdentity,
        contextStore: DomainContextStore,
        metrics: DomainRuntimeMetricsSink
    ) {
        self.identity = identity
        self.contextStore = contextStore
        self.metrics = metrics
    }

    package func snapshot() -> DomainRoutingSnapshot {
        DomainRoutingSnapshot(
            runtimeID: identity.runtimeID,
            revision: revision,
            windows: windows.values.sorted { $0.windowID < $1.windowID },
            connections: connections.values.sorted {
                $0.registration.connectionID.uuidString < $1.registration.connectionID.uuidString
            },
            pendingRunContexts: pendingRunContexts
        )
    }

    package func registerWindow(
        _ descriptor: DomainWindowDescriptor,
        operationID: UUID,
        expectedRevision: UInt64? = nil
    ) -> DomainRoutingOutcome {
        if let prior = routingOperations[operationID] { return prior }
        guard expectedRevision == nil || expectedRevision == revision else {
            return finish(operationID, disposition: .conflict, diagnostic: "routing_revision_mismatch")
        }
        if let current = windows[descriptor.windowID], current.generation > descriptor.generation {
            return finish(operationID, disposition: .staleGeneration, diagnostic: "window_generation_stale")
        }
        if windows[descriptor.windowID] == descriptor {
            return finish(operationID, disposition: .unchanged, diagnostic: nil)
        }
        windows[descriptor.windowID] = descriptor
        revision &+= 1
        return finish(operationID, disposition: .applied, diagnostic: nil)
    }

    package func unregisterWindow(
        windowID: Int,
        generation: UInt64,
        operationID: UUID
    ) -> DomainRoutingOutcome {
        if let prior = routingOperations[operationID] { return prior }
        guard let current = windows[windowID] else {
            return finish(operationID, disposition: .unchanged, diagnostic: nil)
        }
        guard current.generation == generation else {
            return finish(operationID, disposition: .staleGeneration, diagnostic: "window_generation_replaced")
        }
        windows.removeValue(forKey: windowID)
        for (connectionID, snapshot) in connections {
            if case let .appPresentationWindow(boundWindowID) = snapshot.binding,
               boundWindowID == windowID
            {
                connections[connectionID] = DomainConnectionBindingSnapshot(
                    registration: snapshot.registration,
                    binding: .unbound
                )
            }
        }
        revision &+= 1
        return finish(operationID, disposition: .applied, diagnostic: nil)
    }

    package func registerConnection(connectionID: UUID, operationID: UUID) -> DomainRoutingOutcome {
        if let prior = routingOperations[operationID] { return prior }
        let generation = nextConnectionGeneration[connectionID, default: 0] &+ 1
        nextConnectionGeneration[connectionID] = generation
        connections[connectionID] = DomainConnectionBindingSnapshot(
            registration: DomainConnectionRegistration(
                connectionID: connectionID,
                generation: generation,
                runtimeID: identity.runtimeID
            ),
            binding: .unbound
        )
        revision &+= 1
        return finish(operationID, disposition: .applied, diagnostic: nil)
    }

    package func bind(
        connection: DomainConnectionRegistration,
        binding: DomainBinding,
        operationID: UUID,
        expectedRevision: UInt64? = nil
    ) async -> DomainRoutingOutcome {
        if let prior = routingOperations[operationID] { return prior }
        guard expectedRevision == nil || expectedRevision == revision else {
            return finish(operationID, disposition: .conflict, diagnostic: "routing_revision_mismatch")
        }
        guard let current = connections[connection.connectionID], current.registration == connection else {
            return finish(operationID, disposition: .staleGeneration, diagnostic: "connection_generation_stale")
        }
        if case .runScoped = current.binding,
           current.binding != binding
        {
            return finish(operationID, disposition: .rejected, diagnostic: "run_scoped_binding_is_immutable")
        }
        switch binding {
        case let .context(context, _), let .runScoped(_, context):
            guard await contextStore.snapshot(context) != nil else {
                return finish(operationID, disposition: .rejected, diagnostic: "context_unavailable")
            }
        case let .appPresentationWindow(windowID):
            guard let window = windows[windowID], !window.isClosing else {
                return finish(operationID, disposition: .rejected, diagnostic: "window_target_unavailable")
            }
        case .unbound:
            break
        }
        if current.binding == binding {
            return finish(operationID, disposition: .unchanged, diagnostic: nil)
        }
        connections[connection.connectionID] = DomainConnectionBindingSnapshot(
            registration: connection,
            binding: binding
        )
        revision &+= 1
        return finish(operationID, disposition: .applied, diagnostic: nil)
    }

    package func issueLaunchToken(
        _ request: DomainRunLaunchReservationRequest
    ) async throws -> DomainRunLaunchToken {
        guard let context = await contextStore.snapshot(request.context) else {
            throw DomainRunLaunchTokenError.contextUnavailable
        }
        guard context.revisions.workingRevision == request.expectedContextRevision else {
            throw DomainRunLaunchTokenError.staleContextRevision(
                expected: request.expectedContextRevision,
                actual: context.revisions.workingRevision
            )
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DomainRunLaunchTokenError.randomGenerationFailed
        }
        let material = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let digest = DomainContentDigest.sha256(Data(material.utf8))
        let now = clock.now
        let tokenID = UUID()
        tokenRecords[digest] = TokenRecord(
            tokenID: tokenID,
            digest: digest,
            request: request,
            issuedAt: now,
            expiresAt: now.advanced(by: request.lifetime),
            state: .active
        )
        pendingRunContexts[request.runID] = request.context
        revision &+= 1
        metrics.record(DomainRuntimeMetric(
            phase: .backend,
            name: "EditFlow.DomainRuntime.LaunchTokenIssued",
            dimensions: [
                "runtime_id": identity.runtimeID.uuidString,
                "runtime_generation": "\(identity.lifecycleGeneration)",
                "routing_revision": "\(revision)",
                "run_id": request.runID.uuidString
            ]
        ))
        return DomainRunLaunchToken(tokenID: tokenID, material: material)
    }

    package func redeemLaunchToken(
        material: String,
        runtimeID: UUID,
        runtimeGeneration: UInt64,
        connectionID: UUID,
        processID: Int32?,
        clientPrincipal: String,
        providerIdentifier: String
    ) -> DomainRunLaunchRedemptionResult {
        let digest = DomainContentDigest.sha256(Data(material.utf8))
        guard var record = tokenRecords[digest] else { return .unknown }
        switch record.state {
        case .consumed:
            return .alreadyConsumed
        case .revoked:
            return .revoked
        case .active:
            break
        }
        guard clock.now < record.expiresAt else {
            record.state = .revoked
            tokenRecords[digest] = record
            return .expired
        }
        guard runtimeID == identity.runtimeID,
              runtimeGeneration == identity.lifecycleGeneration
        else {
            return .generationMismatch
        }
        guard record.request.clientPrincipal == clientPrincipal,
              record.request.providerIdentifier == providerIdentifier
        else {
            return .identityMismatch
        }
        if let expected = record.request.expectedProcessID, expected != processID {
            return .identityMismatch
        }
        let generation = nextConnectionGeneration[connectionID, default: 0] &+ 1
        nextConnectionGeneration[connectionID] = generation
        let registration = DomainConnectionRegistration(
            connectionID: connectionID,
            generation: generation,
            runtimeID: identity.runtimeID
        )
        let binding = DomainConnectionBindingSnapshot(
            registration: registration,
            binding: .runScoped(runID: record.request.runID, context: record.request.context)
        )
        connections[connectionID] = binding
        record.state = .consumed
        tokenRecords[digest] = record
        pendingRunContexts.removeValue(forKey: record.request.runID)
        revision &+= 1
        return .accepted(binding)
    }

    package func revokeLaunchToken(_ tokenID: UUID) {
        for (digest, var record) in tokenRecords where record.tokenID == tokenID {
            record.state = .revoked
            pendingRunContexts.removeValue(forKey: record.request.runID)
            tokenRecords[digest] = record
        }
        revision &+= 1
    }

    package func shutdown() {
        for (digest, var record) in tokenRecords {
            if case .active = record.state {
                record.state = .revoked
                tokenRecords[digest] = record
            }
        }
        pendingRunContexts.removeAll()
        revision &+= 1
    }

    private func finish(
        _ operationID: UUID,
        disposition: DomainRoutingDisposition,
        diagnostic: String?
    ) -> DomainRoutingOutcome {
        let outcome = DomainRoutingOutcome(
            operationID: operationID,
            disposition: disposition,
            snapshot: snapshot(),
            diagnostic: diagnostic
        )
        routingOperations[operationID] = outcome
        if routingOperations.count > 4096 {
            routingOperations.removeValue(forKey: routingOperations.keys.first!)
        }
        return outcome
    }
}
