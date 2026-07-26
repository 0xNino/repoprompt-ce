import Foundation

package enum DomainRuntimeMode: String, CaseIterable, Sendable {
    case app
    case standalone
}

package struct DomainRuntimeConfiguration: Sendable {
    package let mode: DomainRuntimeMode
    package let profileIdentifier: String
    package let storageDirectory: URL
    package let workspaceStorageDirectory: URL
    package let eventDirectory: URL
    package let temporaryDirectory: URL
    package let legacyRuntimeDefaults: [String: Data]
    package let externalReloadInterval: Duration?
    package let metrics: DomainRuntimeMetricsSink

    package init(
        mode: DomainRuntimeMode,
        profileIdentifier: String,
        storageDirectory: URL,
        workspaceStorageDirectory: URL? = nil,
        eventDirectory: URL,
        temporaryDirectory: URL,
        legacyRuntimeDefaults: [String: Data] = [:],
        externalReloadInterval: Duration? = .seconds(1),
        metrics: DomainRuntimeMetricsSink = .disabled
    ) {
        self.mode = mode
        self.profileIdentifier = profileIdentifier
        self.storageDirectory = storageDirectory
        self.workspaceStorageDirectory = workspaceStorageDirectory
            ?? storageDirectory.appendingPathComponent("Workspaces", isDirectory: true)
        self.eventDirectory = eventDirectory
        self.temporaryDirectory = temporaryDirectory
        self.legacyRuntimeDefaults = legacyRuntimeDefaults
        self.externalReloadInterval = externalReloadInterval
        self.metrics = metrics
    }
}

package struct DomainRuntimeIdentity: Hashable, Sendable {
    package let runtimeID: UUID
    package let lifecycleGeneration: UInt64
    package let processID: Int32
    package let mode: DomainRuntimeMode
    package let createdAt: Date

    package init(
        runtimeID: UUID,
        lifecycleGeneration: UInt64,
        processID: Int32,
        mode: DomainRuntimeMode,
        createdAt: Date
    ) {
        self.runtimeID = runtimeID
        self.lifecycleGeneration = lifecycleGeneration
        self.processID = processID
        self.mode = mode
        self.createdAt = createdAt
    }
}

package enum DomainRuntimeLifecycle: String, CaseIterable, Sendable {
    case created
    case starting
    case ready
    case draining
    case stopped
    case degraded
}

package struct DomainRuntimeSnapshot: Sendable {
    package let identity: DomainRuntimeIdentity
    package let lifecycle: DomainRuntimeLifecycle
    package let publicationSequence: UInt64
    package let catalogRevision: UInt64
    package let workspacePublicationSequence: UInt64
    package let workspaceCatalogRevision: UInt64
    package let workspaceHealth: DomainAuthorityHealth
    package let routingRevision: UInt64
}

package struct DomainShutdownResult: Sendable {
    package let identity: DomainRuntimeIdentity
    package let previousLifecycle: DomainRuntimeLifecycle
    package let finalLifecycle: DomainRuntimeLifecycle
}

package enum DomainRuntimeLifecycleError: Error, Equatable, Sendable {
    case stoppedRuntimeCannotRestart
}

package actor MCPDomainRuntime {
    package nonisolated let identity: DomainRuntimeIdentity
    package nonisolated let configuration: DomainRuntimeConfiguration
    package nonisolated let toolRegistry: MCPDomainToolRegistry
    package nonisolated let workspaceStore: DomainWorkspaceStore
    package nonisolated let contextStore: DomainContextStore
    package nonisolated let routingCoordinator: DomainRoutingCoordinator

    private let workspaceAuthority: DomainWorkspaceContextAuthority
    private var lifecycle: DomainRuntimeLifecycle = .created
    private var publicationSequence: UInt64 = 0
    private var externalReloadTask: Task<Void, Never>?

    package init(
        configuration: DomainRuntimeConfiguration,
        runtimeID: UUID = UUID(),
        lifecycleGeneration: UInt64 = 1,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        createdAt: Date = Date(),
        registryID: UUID = UUID()
    ) {
        self.configuration = configuration
        let runtimeIdentity = DomainRuntimeIdentity(
            runtimeID: runtimeID,
            lifecycleGeneration: lifecycleGeneration,
            processID: processID,
            mode: configuration.mode,
            createdAt: createdAt
        )
        identity = runtimeIdentity
        toolRegistry = MCPDomainToolRegistry(registryID: registryID)

        let persistence = DomainPersistenceCoordinator(
            configuration: configuration,
            identity: runtimeIdentity
        )
        let authority = DomainWorkspaceContextAuthority(
            identity: runtimeIdentity,
            persistence: persistence,
            metrics: configuration.metrics
        )
        workspaceAuthority = authority
        let workspaceStore = DomainWorkspaceStore(authority: authority)
        let contextStore = DomainContextStore(authority: authority)
        self.workspaceStore = workspaceStore
        self.contextStore = contextStore
        routingCoordinator = DomainRoutingCoordinator(
            identity: runtimeIdentity,
            contextStore: contextStore,
            metrics: configuration.metrics
        )
    }

    package func start() async throws {
        switch lifecycle {
        case .created:
            lifecycle = .starting
            publishSnapshot()
            await workspaceAuthority.bootstrap()
            let workspaceSnapshot = await workspaceAuthority.snapshot()
            lifecycle = workspaceSnapshot.health.acceptsMutations ? .ready : .degraded
            publishSnapshot()
            startExternalReloadPollingIfNeeded()
        case .starting, .ready, .degraded:
            return
        case .draining, .stopped:
            throw DomainRuntimeLifecycleError.stoppedRuntimeCannotRestart
        }
    }

    package func shutdown() async -> DomainShutdownResult {
        let previousLifecycle = lifecycle
        guard lifecycle != .stopped else {
            return DomainShutdownResult(
                identity: identity,
                previousLifecycle: previousLifecycle,
                finalLifecycle: .stopped
            )
        }
        lifecycle = .draining
        publishSnapshot()
        externalReloadTask?.cancel()
        externalReloadTask = nil
        await routingCoordinator.shutdown()
        lifecycle = .stopped
        publishSnapshot()
        return DomainShutdownResult(
            identity: identity,
            previousLifecycle: previousLifecycle,
            finalLifecycle: .stopped
        )
    }

    package func snapshot() async -> DomainRuntimeSnapshot {
        let catalog = await toolRegistry.snapshot()
        let workspaces = await workspaceAuthority.snapshot()
        let routing = await routingCoordinator.snapshot()
        return DomainRuntimeSnapshot(
            identity: identity,
            lifecycle: lifecycle,
            publicationSequence: publicationSequence,
            catalogRevision: catalog.revision,
            workspacePublicationSequence: workspaces.publicationSequence,
            workspaceCatalogRevision: workspaces.catalogRevision,
            workspaceHealth: workspaces.health,
            routingRevision: routing.revision
        )
    }

    private func startExternalReloadPollingIfNeeded() {
        guard externalReloadTask == nil,
              let interval = configuration.externalReloadInterval
        else { return }
        externalReloadTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.workspaceStore.reloadExternalChanges()
            }
        }
    }

    private func publishSnapshot() {
        publicationSequence &+= 1
    }
}
