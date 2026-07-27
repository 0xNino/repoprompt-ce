import Foundation
import MCP
import RepoPromptDomainRuntime

extension MCPServerViewModel {
    @MainActor
    func scheduleDomainWindowRegistration(
        activeWorkspaceID: UUID?,
        activeContextID: UUID?,
        presentationRevision: UInt64
    ) {
        guard let coordinator = domainRoutingCoordinator,
              !domainRoutingWindowIsClosing,
              domainWindowDescriptor == nil,
              domainWindowRegistrationTask == nil
        else { return }
        let windowID = windowID
        domainWindowRegistrationTask = Task {
            let outcome = await coordinator.openWindow(
                windowID: windowID,
                activeWorkspaceID: activeWorkspaceID,
                activeContextID: activeContextID,
                presentationRevision: presentationRevision,
                operationID: UUID()
            )
            return outcome.snapshot.windows.first { $0.windowID == windowID }
        }
    }

    @MainActor
    private func ensureDomainWindowRegistered(
        activeWorkspaceID: UUID?,
        activeContextID: UUID?,
        presentationRevision: UInt64
    ) async -> DomainWindowDescriptor? {
        if let domainWindowDescriptor { return domainWindowDescriptor }
        scheduleDomainWindowRegistration(
            activeWorkspaceID: activeWorkspaceID,
            activeContextID: activeContextID,
            presentationRevision: presentationRevision
        )
        guard let registrationTask = domainWindowRegistrationTask else { return nil }
        let descriptor = await registrationTask.value
        domainWindowRegistrationTask = nil
        domainWindowDescriptor = descriptor
        return descriptor
    }

    /// Publishes a presentation-cache transition to the runtime routing authority.
    /// M3 read providers may continue reading the local cache, but new binding decisions
    /// and run launch reservations must use the coordinator snapshot/token APIs.
    @MainActor
    func publishDomainRoutingBinding(connectionID: UUID, context: TabScopedContext) {
        guard let coordinator = domainRoutingCoordinator else { return }
        let binding: DomainBinding = if let workspaceID = context.workspaceID {
            if let runID = context.runID {
                .runScoped(
                    runID: runID,
                    context: DomainContextIdentity(workspaceID: workspaceID, contextID: context.tabID)
                )
            } else {
                .context(
                    DomainContextIdentity(workspaceID: workspaceID, contextID: context.tabID),
                    explicit: context.explicitlyBound
                )
            }
        } else {
            .appPresentationWindow(context.windowID)
        }
        Task { @MainActor [weak self] in
            guard let self,
                  let descriptor = await ensureDomainWindowRegistered(
                      activeWorkspaceID: context.workspaceID,
                      activeContextID: context.tabID,
                      presentationRevision: context.selectionRevision
                  ),
                  !self.domainRoutingWindowIsClosing
            else { return }
            let updatedDescriptor = DomainWindowDescriptor(
                windowID: descriptor.windowID,
                generation: descriptor.generation,
                activeWorkspaceID: context.workspaceID,
                activeContextID: context.tabID,
                isClosing: false,
                presentationRevision: context.selectionRevision
            )
            let updated = await coordinator.registerWindow(updatedDescriptor, operationID: UUID())
            guard updated.disposition != .staleGeneration else { return }
            domainWindowDescriptor = updated.snapshot.windows.first {
                $0.windowID == context.windowID
            }

            var registration = updated.snapshot.connections.first {
                $0.registration.connectionID == connectionID
            }?.registration
            if registration == nil {
                let registered = await coordinator.registerConnection(
                    connectionID: connectionID,
                    operationID: UUID()
                )
                registration = registered.snapshot.connections.first {
                    $0.registration.connectionID == connectionID
                }?.registration
            }
            guard let registration else { return }
            let bound = await coordinator.bind(
                connection: registration,
                binding: binding,
                operationID: UUID()
            )
            if bound.disposition != .applied, bound.disposition != .unchanged {
                logger.warning("Domain routing bind rejected: \(bound.diagnostic ?? String(describing: bound.disposition))")
            }
        }
    }

    @MainActor
    func publishDomainRoutingRelease(connectionID: UUID) {
        guard let coordinator = domainRoutingCoordinator else { return }
        Task {
            let snapshot = await coordinator.snapshot()
            guard let registration = snapshot.connections.first(where: {
                $0.registration.connectionID == connectionID
            })?.registration else { return }
            let released = await coordinator.unregisterConnection(
                registration,
                operationID: UUID()
            )
            if released.disposition != .applied, released.disposition != .unchanged {
                self.logger.warning(
                    "Domain routing release rejected: \(released.diagnostic ?? String(describing: released.disposition))"
                )
            }
        }
    }

    @MainActor
    func resolveDomainReadContext(
        toolName: String
    ) async throws -> DomainReadContextHandle {
        guard let coordinator = domainRoutingCoordinator else {
            throw MCPError.internalError("Domain routing unavailable while executing \(toolName)")
        }
        let metadata = await captureRequestMetadata()
        guard let connectionID = metadata.connectionID else {
            throw MCPError.invalidParams("\(toolName) requires an active MCP connection")
        }
        let resolved = try resolveTabContextSnapshot(
            from: metadata,
            toolName: toolName,
            policy: .allowLegacyImplicitRouting
        )
        let context = resolved.snapshot
        guard let workspaceID = context.workspaceID else {
            throw MCPError.invalidParams("\(toolName) requires a loaded workspace context")
        }
        guard let descriptor = await ensureDomainWindowRegistered(
            activeWorkspaceID: workspaceID,
            activeContextID: context.tabID,
            presentationRevision: context.selectionRevision
        ) else {
            throw MCPError.internalError("Domain window registration unavailable while executing \(toolName)")
        }
        let updatedDescriptor = DomainWindowDescriptor(
            windowID: descriptor.windowID,
            generation: descriptor.generation,
            activeWorkspaceID: workspaceID,
            activeContextID: context.tabID,
            isClosing: false,
            presentationRevision: context.selectionRevision
        )
        let routed = await coordinator.registerWindow(updatedDescriptor, operationID: UUID())
        guard routed.disposition != .staleGeneration else {
            throw MCPError.internalError("Domain window generation became stale while executing \(toolName)")
        }
        domainWindowDescriptor = routed.snapshot.windows.first { $0.windowID == descriptor.windowID }

        var registration = routed.snapshot.connections.first {
            $0.registration.connectionID == connectionID
        }?.registration
        if registration == nil {
            let registered = await coordinator.registerConnection(
                connectionID: connectionID,
                operationID: UUID()
            )
            registration = registered.snapshot.connections.first {
                $0.registration.connectionID == connectionID
            }?.registration
        }
        guard let registration else {
            throw MCPError.internalError("Domain connection registration unavailable while executing \(toolName)")
        }
        let binding: DomainBinding = if let runID = context.runID {
            .runScoped(
                runID: runID,
                context: DomainContextIdentity(workspaceID: workspaceID, contextID: context.tabID)
            )
        } else {
            .context(
                DomainContextIdentity(workspaceID: workspaceID, contextID: context.tabID),
                explicit: context.explicitlyBound
            )
        }
        let bound = await coordinator.bind(
            connection: registration,
            binding: binding,
            operationID: UUID()
        )
        guard bound.disposition == .applied || bound.disposition == .unchanged else {
            throw MCPError.internalError(
                "Domain context binding rejected while executing \(toolName): \(bound.diagnostic ?? String(describing: bound.disposition))"
            )
        }
        return try await coordinator.resolveReadContext(connection: registration)
    }

    @MainActor
    func validateDomainReadContext(
        _ handle: DomainReadContextHandle,
        toolName: String
    ) async throws {
        let current = try await resolveDomainReadContext(toolName: toolName)
        guard current.runtimeID == handle.runtimeID,
              current.runtimeGeneration == handle.runtimeGeneration,
              current.connectionID == handle.connectionID,
              current.connectionGeneration == handle.connectionGeneration,
              current.context == handle.context,
              current.workspaceRevision == handle.workspaceRevision,
              current.contextRevision == handle.contextRevision,
              current.routingRevision == handle.routingRevision,
              current.bindingKind == handle.bindingKind
        else {
            throw MCPError.internalError("Domain read context changed while executing \(toolName)")
        }
    }

    /// Runs before the server is stopped so no presentation binding can outlive its window.
    @MainActor
    func unregisterDomainRoutingWindow() async {
        domainRoutingWindowIsClosing = true
        domainWindowRegistrationTask?.cancel()
        if domainWindowDescriptor == nil,
           let registrationTask = domainWindowRegistrationTask
        {
            domainWindowDescriptor = await registrationTask.value
        }
        domainWindowRegistrationTask = nil
        guard let coordinator = domainRoutingCoordinator,
              let descriptor = domainWindowDescriptor
        else { return }
        let routing = await coordinator.snapshot()
        for connection in routing.connections where windowIDByConnection[connection.registration.connectionID] == descriptor.windowID {
            _ = await coordinator.unregisterConnection(
                connection.registration,
                operationID: UUID()
            )
        }
        _ = await coordinator.unregisterWindow(
            windowID: descriptor.windowID,
            generation: descriptor.generation,
            operationID: UUID()
        )
        domainWindowDescriptor = nil
    }
}
