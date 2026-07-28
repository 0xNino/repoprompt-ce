import Foundation
import MCP

package enum MCPDomainHostLifecycle: String, CaseIterable, Sendable {
    case accepting
    case draining
    case drained
}

package enum MCPDomainHostError: Error, Equatable, Sendable {
    case draining
    case duplicateInvocationID(UUID)
    case unknownTool(String)
    case scopeUnavailable(toolName: String, scope: MCPDomainToolRegistrationScope)
    case staleRegistration(toolName: String)
    case runtimeGenerationMismatch
    case connectionRegistrationInvalid
}

package struct MCPDomainHostResolution: Sendable {
    package let toolName: String
    package let scope: MCPDomainToolRegistrationScope
    package let registrationHandle: MCPDomainToolRegistrationHandle
    package let definition: MCPDomainToolDefinition

    package init(
        toolName: String,
        scope: MCPDomainToolRegistrationScope,
        registrationHandle: MCPDomainToolRegistrationHandle,
        definition: MCPDomainToolDefinition
    ) {
        self.toolName = toolName
        self.scope = scope
        self.registrationHandle = registrationHandle
        self.definition = definition
    }
}

package struct MCPDomainHostInvocation: Sendable {
    package let invocationID: UUID
    package let connectionID: UUID
    package let resolution: MCPDomainHostResolution
    package let arguments: [String: Value]
    package let securityContext: DomainToolInvocationSecurityContext

    package init(
        invocationID: UUID,
        connectionID: UUID,
        resolution: MCPDomainHostResolution,
        arguments: [String: Value],
        securityContext: DomainToolInvocationSecurityContext
    ) {
        self.invocationID = invocationID
        self.connectionID = connectionID
        self.resolution = resolution
        self.arguments = arguments
        self.securityContext = securityContext
    }
}

package struct MCPDomainHostSnapshot: Equatable, Sendable {
    package let lifecycle: MCPDomainHostLifecycle
    package let activeInvocationCount: Int
    package let activeConnectionCount: Int
}

package struct MCPDomainHostDrainResult: Equatable, Sendable {
    package let settledInvocationCount: Int
    package let detachedInvocationCount: Int
    package let deadlineExpired: Bool
}

/// Protocol-neutral owner for catalog resolution and exact domain-binding invocation.
/// Transports and the app presentation shell resolve routing/admission before entry;
/// this actor owns registry-generation fencing, invocation cancellation, and drain.
package actor MCPDomainHost {
    private struct ActiveInvocation {
        let connectionID: UUID
        let task: Task<Value, Error>
    }

    package nonisolated let identity: DomainRuntimeIdentity
    package nonisolated let registry: MCPDomainToolRegistry
    package nonisolated let routingCoordinator: DomainRoutingCoordinator

    private var lifecycle: MCPDomainHostLifecycle = .accepting
    private var activeInvocations: [UUID: ActiveInvocation] = [:]
    private var invocationIDsByConnection: [UUID: Set<UUID>] = [:]

    package init(
        identity: DomainRuntimeIdentity,
        registry: MCPDomainToolRegistry,
        routingCoordinator: DomainRoutingCoordinator
    ) {
        self.identity = identity
        self.registry = registry
        self.routingCoordinator = routingCoordinator
    }

    package func catalogSnapshot() async -> MCPDomainToolCatalogSnapshot {
        await registry.snapshot()
    }

    package func resolve(
        toolName: String,
        scope: MCPDomainToolRegistrationScope
    ) async throws -> MCPDomainHostResolution {
        guard MCPDomainToolCatalog.entry(named: toolName) != nil else {
            throw MCPDomainHostError.unknownTool(toolName)
        }
        guard let resolved = await registry.resolve(toolName: toolName, scope: scope) else {
            throw MCPDomainHostError.scopeUnavailable(toolName: toolName, scope: scope)
        }
        return makeResolution(resolved)
    }

    package func resolveUniqueWindowTool(toolName: String) async throws -> MCPDomainHostResolution? {
        guard MCPDomainToolCatalog.entry(named: toolName) != nil else {
            throw MCPDomainHostError.unknownTool(toolName)
        }
        guard let resolved = await registry.resolveUniqueWindowTool(toolName: toolName) else {
            return nil
        }
        return makeResolution(resolved)
    }

    package func invoke(_ invocation: MCPDomainHostInvocation) async throws -> Value {
        guard lifecycle == .accepting else {
            throw MCPDomainHostError.draining
        }
        guard activeInvocations[invocation.invocationID] == nil else {
            throw MCPDomainHostError.duplicateInvocationID(invocation.invocationID)
        }
        try validateSecurityContext(invocation)

        guard let resolved = await registry.resolve(
            toolName: invocation.resolution.toolName,
            scope: invocation.resolution.scope
        ) else {
            throw MCPDomainHostError.scopeUnavailable(
                toolName: invocation.resolution.toolName,
                scope: invocation.resolution.scope
            )
        }
        guard resolved.handle == invocation.resolution.registrationHandle,
              await registry.isActive(resolved.handle)
        else {
            throw MCPDomainHostError.staleRegistration(toolName: invocation.resolution.toolName)
        }

        let currentRegistration: DomainConnectionRegistration
        do {
            currentRegistration = try await routingCoordinator.currentRegistration(
                connectionID: invocation.connectionID
            )
        } catch {
            throw MCPDomainHostError.connectionRegistrationInvalid
        }
        guard currentRegistration.runtimeID == identity.runtimeID,
              currentRegistration.generation == invocation.securityContext.connectionGeneration
        else {
            throw MCPDomainHostError.connectionRegistrationInvalid
        }

        let task = Task {
            try Task.checkCancellation()
            guard await self.registry.isActive(resolved.handle) else {
                throw MCPDomainHostError.staleRegistration(toolName: invocation.resolution.toolName)
            }
            return try await MCPDomainInvocationSecurityContext.$current.withValue(
                invocation.securityContext
            ) {
                try await resolved.binding(invocation.arguments)
            }
        }
        activeInvocations[invocation.invocationID] = ActiveInvocation(
            connectionID: invocation.connectionID,
            task: task
        )
        invocationIDsByConnection[invocation.connectionID, default: []].insert(invocation.invocationID)

        return try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                finishInvocation(invocation.invocationID)
                return value
            } catch {
                finishInvocation(invocation.invocationID)
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }

    package func cancelInvocations(connectionID: UUID) {
        let invocationIDs = invocationIDsByConnection[connectionID] ?? []
        for invocationID in invocationIDs {
            activeInvocations[invocationID]?.task.cancel()
        }
    }

    package func beginDrain() {
        guard lifecycle == .accepting else { return }
        lifecycle = .draining
        for invocation in activeInvocations.values {
            invocation.task.cancel()
        }
        if activeInvocations.isEmpty {
            lifecycle = .drained
        }
    }

    package func drain(timeout: Duration) async -> MCPDomainHostDrainResult {
        beginDrain()
        let initialCount = activeInvocations.count
        guard initialCount > 0 else {
            lifecycle = .drained
            return MCPDomainHostDrainResult(
                settledInvocationCount: 0,
                detachedInvocationCount: 0,
                deadlineExpired: false
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !activeInvocations.isEmpty, clock.now < deadline {
            let remaining = clock.now.duration(to: deadline)
            try? await Task.sleep(for: min(remaining, .milliseconds(10)))
        }

        let detachedCount = activeInvocations.count
        let deadlineExpired = detachedCount > 0 && clock.now >= deadline
        if detachedCount == 0 {
            lifecycle = .drained
        }
        return MCPDomainHostDrainResult(
            settledInvocationCount: max(0, initialCount - detachedCount),
            detachedInvocationCount: detachedCount,
            deadlineExpired: deadlineExpired && detachedCount > 0
        )
    }

    package func snapshot() -> MCPDomainHostSnapshot {
        MCPDomainHostSnapshot(
            lifecycle: lifecycle,
            activeInvocationCount: activeInvocations.count,
            activeConnectionCount: invocationIDsByConnection.count
        )
    }

    private func makeResolution(_ resolved: MCPDomainResolvedTool) -> MCPDomainHostResolution {
        MCPDomainHostResolution(
            toolName: resolved.binding.definition.name,
            scope: resolved.scope,
            registrationHandle: resolved.handle,
            definition: resolved.binding.definition
        )
    }

    private func validateSecurityContext(_ invocation: MCPDomainHostInvocation) throws {
        let context = invocation.securityContext
        guard context.runtimeID == identity.runtimeID,
              context.runtimeGeneration == identity.lifecycleGeneration
        else {
            throw MCPDomainHostError.runtimeGenerationMismatch
        }
        guard context.connectionID == invocation.connectionID,
              context.invocationID == invocation.invocationID
        else {
            throw MCPDomainHostError.connectionRegistrationInvalid
        }
    }

    private func finishInvocation(_ invocationID: UUID) {
        guard let invocation = activeInvocations.removeValue(forKey: invocationID) else { return }
        invocationIDsByConnection[invocation.connectionID]?.remove(invocationID)
        if invocationIDsByConnection[invocation.connectionID]?.isEmpty == true {
            invocationIDsByConnection.removeValue(forKey: invocation.connectionID)
        }
        if lifecycle == .draining, activeInvocations.isEmpty {
            lifecycle = .drained
        }
    }
}
