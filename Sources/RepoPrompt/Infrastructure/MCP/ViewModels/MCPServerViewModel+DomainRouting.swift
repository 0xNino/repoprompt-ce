import Foundation
import RepoPromptDomainRuntime

extension MCPServerViewModel {
    /// Publishes a presentation-cache transition to the runtime routing authority.
    /// M3 read providers may continue reading the local cache, but new binding decisions
    /// and run launch reservations must use the coordinator snapshot/token APIs.
    @MainActor
    func publishDomainRoutingBinding(connectionID: UUID, context: TabScopedContext) {
        guard let coordinator = domainRoutingCoordinator else { return }
        let windowDescriptor = DomainWindowDescriptor(
            windowID: context.windowID,
            generation: domainWindowGeneration,
            activeWorkspaceID: context.workspaceID,
            activeContextID: context.tabID,
            isClosing: false,
            presentationRevision: context.selectionRevision
        )
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
        Task {
            _ = await coordinator.registerWindow(windowDescriptor, operationID: UUID())
            var routing = await coordinator.snapshot()
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
            guard let registration else { return }
            _ = await coordinator.bind(
                connection: registration,
                binding: binding,
                operationID: UUID()
            )
            routing = await coordinator.snapshot()
            _ = routing.revision
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
            _ = await coordinator.bind(
                connection: registration,
                binding: .unbound,
                operationID: UUID()
            )
        }
    }
}
