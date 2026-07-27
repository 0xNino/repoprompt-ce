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
    static let shared = AppGlobalMCPServiceComposition()

    private struct RegistrationHandles {
        let appSettings: MCPDomainToolRegistrationHandle
        let windowRouting: MCPDomainToolRegistrationHandle
    }

    private let runtime: MCPDomainRuntime
    private let appSettingsService: AppSettingsMCPService
    private let windowRoutingService: WindowRoutingService
    private var registrationHandles: RegistrationHandles?
    private var registrationTask: Task<RegistrationHandles, Error>?

    private init(
        runtime: MCPDomainRuntime = AppDomainRuntimeComposition.shared.runtime,
        windowStates: WindowStatesManager = .shared,
        networkManager: ServerNetworkManager = .shared
    ) {
        self.runtime = runtime
        appSettingsService = AppSettingsMCPService()
        windowRoutingService = WindowRoutingService(
            windowStates: windowStates,
            networkMgr: networkManager
        )
    }

    func ensureRegistered() async throws {
        if let registrationHandles,
           await ServiceRegistry.isActive(registrationHandles.appSettings),
           await ServiceRegistry.isActive(registrationHandles.windowRouting)
        {
            return
        }

        if let registrationTask {
            registrationHandles = try await registrationTask.value
            return
        }

        let task = Task { @MainActor [runtime, appSettingsService, windowRoutingService] in
            try await runtime.start()
            let appSettings = try await ServiceRegistry.register(appSettingsService)
            let windowRouting = try await windowRoutingService.registerDomainTools()
            return RegistrationHandles(
                appSettings: appSettings.handle,
                windowRouting: windowRouting.handle
            )
        }
        registrationTask = task

        do {
            registrationHandles = try await task.value
            registrationTask = nil
        } catch {
            registrationTask = nil
            throw error
        }
    }
}
