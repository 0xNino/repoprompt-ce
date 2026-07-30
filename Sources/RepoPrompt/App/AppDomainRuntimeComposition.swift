import Foundation
import RepoPromptDomainRuntime

/// App-process composition for the M1 domain runtime and live catalog registry.
/// Workspace/context/provider authority remains app-owned until later milestones.
final class AppDomainRuntimeComposition: Sendable {
    static let shared = AppDomainRuntimeComposition()

    let runtime: MCPDomainRuntime

    private init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let root = applicationSupport.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        runtime = MCPDomainRuntime(
            configuration: DomainRuntimeConfiguration(
                mode: .app,
                profileIdentifier: "default",
                storageDirectory: root,
                eventDirectory: root.appendingPathComponent("Events", isDirectory: true),
                temporaryDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("RepoPrompt CE", isDirectory: true)
            )
        )
    }
}

/// Process-lifetime owner for application-scoped MCP services. Registration is
/// coalesced so app startup, readiness, and test fixtures all join the same work
/// and no caller receives a handle it could use to remove another caller's tools.
@MainActor
final class AppGlobalMCPServiceComposition {
    enum RegistrationStatus: Equatable {
        case idle
        case registering
        case registered
        case failed(String)

        var diagnosticDescription: String {
            switch self {
            case .idle:
                "idle"
            case .registering:
                "registering"
            case .registered:
                "registered"
            case let .failed(error):
                "failed(\(error))"
            }
        }
    }

    static let shared = AppGlobalMCPServiceComposition(
        runtime: AppDomainRuntimeComposition.shared.runtime,
        windowStates: .shared,
        networkManager: .shared
    )

    private struct RegistrationHandles {
        let appSettings: MCPDomainToolRegistrationHandle
        let windowRouting: MCPDomainToolRegistrationHandle
    }

    private let runtime: MCPDomainRuntime
    private let networkManager: ServerNetworkManager
    private let appSettingsService: AppSettingsMCPService
    private let windowRoutingService: WindowRoutingService
    private var registrationHandles: RegistrationHandles?
    private var registrationTask: Task<RegistrationHandles, Error>?
    private var status: RegistrationStatus = .idle

    private init(
        runtime: MCPDomainRuntime,
        windowStates: WindowStatesManager,
        networkManager: ServerNetworkManager
    ) {
        self.runtime = runtime
        self.networkManager = networkManager
        appSettingsService = AppSettingsMCPService()
        windowRoutingService = WindowRoutingService(
            windowStates: windowStates,
            networkMgr: networkManager
        )
    }

    func registrationStatus() -> RegistrationStatus {
        status
    }

    func ensureRegistered() async throws {
        if let registrationHandles,
           await ServiceRegistry.isActive(registrationHandles.appSettings),
           await ServiceRegistry.isActive(registrationHandles.windowRouting)
        {
            await restoreAvailabilityPublicationIfNeeded()
            status = .registered
            return
        }

        if let registrationTask {
            registrationHandles = try await registrationTask.value
            await restoreAvailabilityPublicationIfNeeded()
            status = .registered
            return
        }

        status = .registering
        let task = Task { @MainActor [runtime, networkManager, appSettingsService, windowRoutingService] in
            try await runtime.start()
            await windowRoutingService.prepareDomainTools()
            let appSettingsTools = await appSettingsService.tools
            let windowRoutingTools = await windowRoutingService.tools
            let requests = try [
                MCPDomainToolRegistrationRequest(
                    registrationID: appSettingsService.domainRegistrationID,
                    scope: .application,
                    bindings: appSettingsTools.map { try $0.domainBinding() }
                ),
                MCPDomainToolRegistrationRequest(
                    registrationID: windowRoutingService.domainRegistrationID,
                    scope: .application,
                    bindings: windowRoutingTools.map { try $0.domainBinding() }
                )
            ]
            let results = try await runtime.toolRegistry.registerAtomically(requests)
            if results.contains(where: { $0.disposition != .unchanged }) {
                ToolAvailabilityStore.shared.registerTools(appSettingsTools + windowRoutingTools)
                await networkManager.broadcastToolListChanged()
            }
            return RegistrationHandles(
                appSettings: results[0].handle,
                windowRouting: results[1].handle
            )
        }
        registrationTask = task

        do {
            registrationHandles = try await task.value
            registrationTask = nil
            await restoreAvailabilityPublicationIfNeeded()
            status = .registered
        } catch {
            registrationTask = nil
            status = .failed(String(reflecting: error))
            throw error
        }
    }

    private func restoreAvailabilityPublicationIfNeeded() async {
        let publishedNames = Set(ToolAvailabilityStore.shared.toolSummaries.map(\.name))
        guard !publishedNames.isSuperset(of: MCPGlobalToolName.orderedToolNames) else { return }

        let appSettingsTools = await appSettingsService.tools
        let windowRoutingTools = await windowRoutingService.tools
        ToolAvailabilityStore.shared.registerTools(appSettingsTools + windowRoutingTools)
    }
}
