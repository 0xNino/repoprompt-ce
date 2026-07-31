import Foundation
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
        let previousPublish = domainRoutingPublishTask
        domainRoutingPublishTask = Task { @MainActor [weak self] in
            await previousPublish?.value
            guard let self, !self.domainRoutingWindowIsClosing else { return }
            guard let descriptor = await ensureDomainWindowRegistered(
                activeWorkspaceID: context.workspaceID,
                activeContextID: context.tabID,
                presentationRevision: context.selectionRevision
            ),
                !domainRoutingWindowIsClosing
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
            guard !domainRoutingWindowIsClosing, updated.disposition != .staleGeneration else { return }
            domainWindowDescriptor = updated.snapshot.windows.first {
                $0.windowID == context.windowID
            }

            var registration = updated.snapshot.connections.first {
                $0.registration.connectionID == connectionID
            }?.registration
            if registration == nil {
                // Re-checked above so a straggler cannot resurrect a connection binding
                // after `unregisterDomainRoutingWindow` tore the window down.
                let registered = await coordinator.registerConnection(
                    connectionID: connectionID,
                    operationID: UUID()
                )
                registration = registered.snapshot.connections.first {
                    $0.registration.connectionID == connectionID
                }?.registration
            }
            guard let registration, !domainRoutingWindowIsClosing else { return }
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
        let previousPublish = domainRoutingPublishTask
        domainRoutingPublishTask = Task { @MainActor [weak self] in
            await previousPublish?.value
            let snapshot = await coordinator.snapshot()
            guard let registration = snapshot.connections.first(where: {
                $0.registration.connectionID == connectionID
            })?.registration else { return }
            let released = await coordinator.unregisterConnection(
                registration,
                operationID: UUID()
            )
            if released.disposition != .applied, released.disposition != .unchanged {
                self?.logger.warning(
                    "Domain routing release rejected: \(released.diagnostic ?? String(describing: released.disposition))"
                )
            }
        }
    }

    /// Runs before the server is stopped so no presentation binding can outlive its window.
    @MainActor
    func unregisterDomainRoutingWindow() async {
        domainRoutingWindowIsClosing = true
        let pendingPublish = domainRoutingPublishTask
        domainRoutingPublishTask = nil
        await pendingPublish?.value
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
