import Foundation
import MCP
import RepoPromptDomainRuntime

extension MCPServerViewModel {
    struct DomainReadAppExecutionContext {
        let metadata: RequestMetadata
        let resolvedTabContext: ResolvedTabContextSnapshot
        let lookupContext: WorkspaceLookupContext
        let targetWindowID: Int
    }

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
    func publishDomainRoutingBinding(connectionID: UUID, context: TabContextSnapshot) {
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
            domainRoutingConnectionIDs.insert(connectionID)
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
        guard let coordinator = domainRoutingCoordinator else {
            domainRoutingConnectionIDs.remove(connectionID)
            return
        }
        Task {
            let snapshot = await coordinator.snapshot()
            guard let registration = snapshot.connections.first(where: {
                $0.registration.connectionID == connectionID
            })?.registration else {
                domainRoutingConnectionIDs.remove(connectionID)
                return
            }
            let released = await coordinator.unregisterConnection(
                registration,
                operationID: UUID()
            )
            if released.disposition == .applied || released.disposition == .unchanged {
                await AppDomainRuntimeComposition.shared.runtime.domainHost.releaseConnection(
                    connectionID: registration.connectionID,
                    connectionGeneration: registration.generation
                )
            }
            if released.disposition != .applied, released.disposition != .unchanged {
                self.logger.warning(
                    "Domain routing release rejected: \(released.diagnostic ?? String(describing: released.disposition))"
                )
            }
            domainRoutingConnectionIDs.remove(connectionID)
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

        // App compatibility remains the physical fallback for graceful/no-workspace tools and
        // focused tests. Routing errors must not preempt their historical backend diagnostics.
        let resolved: ResolvedTabContextSnapshot
        do {
            resolved = try resolveTabContextSnapshot(
                from: metadata,
                toolName: toolName,
                policy: .requireExplicitOrRunScoped
            )
        } catch {
            return try domainReadUnavailable(
                toolName: toolName,
                requirement: requirement,
                connectionID: connectionID,
                diagnostic: "tab context unavailable: \(error.localizedDescription)"
            )
        }
        let context = resolved.snapshot
        if domainRoutingCoordinator == nil
            || connectionID == nil
            || domainWorkspaceAuthorityClient == nil
        {
            return try await registerFallbackDomainReadContext(
                toolName: toolName,
                requirement: requirement,
                metadata: metadata,
                resolved: resolved
            )
        }
        guard let coordinator = domainRoutingCoordinator,
              let connectionID
        else {
            return try domainReadUnavailable(
                toolName: toolName,
                requirement: requirement,
                connectionID: connectionID,
                diagnostic: "connection or routing coordinator unavailable"
            )
        }
        guard let targetWindow = WindowStatesManager.shared.window(withID: context.windowID),
              !targetWindow.isClosing
        else {
            return try domainReadUnavailable(
                toolName: toolName,
                requirement: requirement,
                connectionID: connectionID,
                diagnostic: "target window unavailable"
            )
        }
        let targetServer = targetWindow.mcpServer
        let targetWorkspaceManager = targetWindow.workspaceManager
        guard let workspaceID = context.workspaceID,
              let workspace = targetWorkspaceManager.workspaces.first(where: { $0.id == workspaceID }),
              let targetWorkspaceAuthorityClient = targetServer.domainWorkspaceAuthorityClient
        else {
            return try domainReadUnavailable(
                toolName: toolName,
                requirement: requirement,
                connectionID: connectionID,
                diagnostic: "workspace authority unavailable"
            )
        }

        do {
            // The shared provider may be owned by a different window than the routed tab. Register
            // against the resolved target window so awaited reads also cover ephemeral workspaces.
            _ = try await targetWorkspaceAuthorityClient.registerForRead(
                workspace,
                fileURL: targetWorkspaceManager.workspaceFileURL(for: workspace)
            )
        } catch {
            return try domainReadUnavailable(
                toolName: toolName,
                requirement: requirement,
                connectionID: connectionID,
                diagnostic: "transient authority registration failed: \(error.localizedDescription)"
            )
        }

        let routing = await coordinator.snapshot()
        let existingConnection = routing.connections.first {
            $0.registration.connectionID == connectionID
        }
        var registration = existingConnection?.registration
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
            return try domainReadUnavailable(
                toolName: toolName,
                requirement: requirement,
                connectionID: connectionID,
                diagnostic: "connection registration unavailable"
            )
        }
        domainRoutingConnectionIDs.insert(connectionID)
        let targetContext = DomainContextIdentity(
            workspaceID: workspaceID,
            contextID: context.tabID
        )
        let binding: DomainBinding = if let runID = context.runID {
            .runScoped(runID: runID, context: targetContext)
        } else {
            .context(targetContext, explicit: context.explicitlyBound)
        }
        if existingConnection == nil || existingConnection?.binding == .unbound {
            let bound = await coordinator.bind(
                connection: registration,
                binding: binding,
                operationID: UUID()
            )
            guard bound.disposition == .applied || bound.disposition == .unchanged else {
                return try domainReadUnavailable(
                    toolName: toolName,
                    requirement: requirement,
                    connectionID: connectionID,
                    diagnostic: bound.diagnostic ?? "context binding rejected"
                )
            }
        }
        do {
            let handle = try await coordinator.resolveReadContext(connection: registration)
            guard handle.context == targetContext else {
                return try domainReadUnavailable(
                    toolName: toolName,
                    requirement: requirement,
                    connectionID: connectionID,
                    diagnostic: "bound context changed before execution"
                )
            }
            let invocation = DomainReadInvocationContext(handle: handle, connectionID: connectionID)
            domainReadAppExecutionContexts[invocation.invocationID] = await DomainReadAppExecutionContext(
                metadata: metadata,
                resolvedTabContext: resolved,
                lookupContext: targetServer.lookupContext(for: context),
                targetWindowID: context.windowID
            )
            return invocation
        } catch {
            return try domainReadUnavailable(
                toolName: toolName,
                requirement: requirement,
                connectionID: connectionID,
                diagnostic: "domain context resolution failed: \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    private func registerFallbackDomainReadContext(
        toolName: String,
        requirement: DomainReadContextRequirement,
        metadata: RequestMetadata,
        resolved: ResolvedTabContextSnapshot
    ) async throws -> DomainReadInvocationContext {
        let context = resolved.snapshot
        guard let identity = domainReadFallbackRuntimeIdentity,
              let workspaceID = context.workspaceID
        else {
            return try domainReadUnavailable(
                toolName: toolName,
                requirement: requirement,
                connectionID: metadata.connectionID,
                diagnostic: "registered fallback authority unavailable"
            )
        }
        let connectionID = metadata.connectionID ?? UUID()
        let revision = max(context.selectionRevision, 1)
        let bindingKind: DomainReadBindingKind = if let runID = context.runID {
            .runScoped(runID: runID)
        } else if context.explicitlyBound {
            .explicit
        } else {
            .appPresentation
        }
        let handle = DomainReadContextHandle(
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            connectionID: connectionID,
            connectionGeneration: 1,
            context: DomainContextIdentity(workspaceID: workspaceID, contextID: context.tabID),
            workspaceRevision: revision,
            contextRevision: revision,
            routingRevision: 0,
            bindingKind: bindingKind
        )
        let invocation = DomainReadInvocationContext(
            handle: handle,
            connectionID: metadata.connectionID,
            refreshesDomainRouting: false
        )
        let targetServer = WindowStatesManager.shared.window(withID: context.windowID)?.mcpServer ?? self
        domainReadAppExecutionContexts[invocation.invocationID] = await DomainReadAppExecutionContext(
            metadata: metadata,
            resolvedTabContext: resolved,
            lookupContext: targetServer.lookupContext(for: context),
            targetWindowID: context.windowID
        )
        return invocation
    }

    @MainActor
    func domainReadAppExecutionContext(
        for invocation: DomainReadInvocationContext
    ) -> DomainReadAppExecutionContext? {
        domainReadAppExecutionContexts[invocation.invocationID]
    }

    @MainActor
    func releaseDomainReadAppExecutionContext(
        for invocation: DomainReadInvocationContext
    ) {
        domainReadAppExecutionContexts.removeValue(forKey: invocation.invocationID)
    }

    private func domainReadUnavailable(
        toolName: String,
        requirement: DomainReadContextRequirement,
        connectionID: UUID?,
        diagnostic: String
    ) throws -> DomainReadInvocationContext {
        guard requirement == .workspaceRequired else {
            return DomainReadInvocationContext(handle: nil, connectionID: connectionID)
        }
        throw MCPError.internalError("Domain authority unavailable for \(toolName): \(diagnostic)")
    }

    /// Runs before the server is stopped so no presentation binding can outlive its window.
    @MainActor
    func unregisterDomainRoutingWindow() async {
        domainRoutingWindowIsClosing = true
        domainReadAppExecutionContexts.removeAll()
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
        let ownedConnectionIDs = domainRoutingConnectionIDs
        domainRoutingConnectionIDs.removeAll()
        for connection in routing.connections where ownedConnectionIDs.contains(connection.registration.connectionID) {
            let released = await coordinator.unregisterConnection(
                connection.registration,
                operationID: UUID()
            )
            if released.disposition == .applied || released.disposition == .unchanged {
                await AppDomainRuntimeComposition.shared.runtime.domainHost.releaseConnection(
                    connectionID: connection.registration.connectionID,
                    connectionGeneration: connection.registration.generation
                )
            }
        }
        _ = await coordinator.unregisterWindow(
            windowID: descriptor.windowID,
            generation: descriptor.generation,
            operationID: UUID()
        )
        domainWindowDescriptor = nil
    }
}
