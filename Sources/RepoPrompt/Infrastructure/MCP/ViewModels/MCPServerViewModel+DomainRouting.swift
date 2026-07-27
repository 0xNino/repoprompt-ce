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
        toolName: String,
        requirement: DomainReadContextRequirement
    ) async throws -> DomainReadInvocationContext {
        // History and oracle transcript lookup have always been workspace-independent. Do not even
        // capture MainActor routing metadata for them.
        guard requirement != .workspaceIndependent else {
            return DomainReadInvocationContext(handle: nil, connectionID: nil)
        }

        let metadata = await captureRequestMetadata()
        let connectionID = metadata.connectionID
        guard let coordinator = domainRoutingCoordinator,
              let connectionID
        else {
            return DomainReadInvocationContext(handle: nil, connectionID: connectionID)
        }

        // App compatibility remains the physical fallback for graceful/no-workspace tools and
        // focused tests. Routing errors must not preempt their historical backend diagnostics.
        let resolved: ResolvedTabContextSnapshot
        do {
            resolved = try resolveTabContextSnapshot(
                from: metadata,
                toolName: toolName,
                policy: .allowLegacyImplicitRouting
            )
        } catch {
            return DomainReadInvocationContext(handle: nil, connectionID: connectionID)
        }
        let context = resolved.snapshot
        guard let workspaceID = context.workspaceID,
              let workspaceManager,
              let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceID }),
              let domainWorkspaceAuthorityClient
        else {
            return DomainReadInvocationContext(handle: nil, connectionID: connectionID)
        }

        do {
            // This awaited transient registration closes the debounce race and works for ephemeral
            // workspaces without writing them to durable storage.
            _ = try await domainWorkspaceAuthorityClient.registerForRead(
                workspace,
                fileURL: workspaceManager.workspaceFileURL(for: workspace)
            )
        } catch {
            logger.debug("Domain read registration fell back to app authority for \(toolName): \(error.localizedDescription)")
            return DomainReadInvocationContext(handle: nil, connectionID: connectionID)
        }

        let routing = await coordinator.snapshot()
        var registration = routing.connections.first {
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
            return DomainReadInvocationContext(handle: nil, connectionID: connectionID)
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
            return DomainReadInvocationContext(handle: nil, connectionID: connectionID)
        }
        do {
            let handle = try await coordinator.resolveReadContext(connection: registration)
            return DomainReadInvocationContext(handle: handle, connectionID: connectionID)
        } catch {
            logger.debug("Domain read routing fell back to app authority for \(toolName): \(error.localizedDescription)")
            return DomainReadInvocationContext(handle: nil, connectionID: connectionID)
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
