import Foundation
import RepoPromptDomainRuntime

/// App adapter over the runtime-owned catalog registry. This facade stores no services,
/// schemas, registrations, or tool definitions of its own.
enum ServiceRegistry {
    @MainActor
    @discardableResult
    static func register(_ service: any Service) async -> MCPDomainToolRegistrationHandle? {
        let tools = await service.tools
        do {
            let handle = try await AppDomainRuntimeComposition.shared.runtime.toolRegistry.register(
                registrationID: registrationID(for: service),
                scope: registrationScope(for: service),
                bindings: tools.map { try $0.domainBinding() }
            )
            #if DEBUG || EDIT_FLOW_PERF
                let serviceTools = EditFlowPerf.measure(
                    EditFlowPerf.Stage.MCPWindowToolCatalog.serviceRegistryToolsPublication
                ) {
                    tools
                }
                ToolAvailabilityStore.shared.registerTools(serviceTools)
            #else
                ToolAvailabilityStore.shared.registerTools(tools)
            #endif
            await ServerNetworkManager.shared.broadcastToolListChanged()
            return handle
        } catch {
            assertionFailure("Domain tool registration failed: \(error)")
            return nil
        }
    }

    @MainActor
    static func unregister(_ service: any Service) async {
        let registry = AppDomainRuntimeComposition.shared.runtime.toolRegistry
        let removal = await registry.unregister(registrationID: registrationID(for: service))
        if removal == .removed {
            await ServerNetworkManager.shared.broadcastToolListChanged()
        }
    }

    @MainActor
    static func isRegistered(_ service: any Service) async -> Bool {
        await AppDomainRuntimeComposition.shared.runtime.toolRegistry.isRegistered(
            registrationID(for: service)
        )
    }

    static func catalogSnapshot() async -> MCPDomainToolCatalogSnapshot {
        let registry = await MainActor.run {
            AppDomainRuntimeComposition.shared.runtime.toolRegistry
        }
        return await registry.snapshot()
    }

    static func resolve(
        toolName: String,
        scope: MCPDomainToolRegistrationScope
    ) async -> MCPDomainResolvedTool? {
        let registry = await MainActor.run {
            AppDomainRuntimeComposition.shared.runtime.toolRegistry
        }
        return await registry.resolve(toolName: toolName, scope: scope)
    }

    static func isActive(_ handle: MCPDomainToolRegistrationHandle) async -> Bool {
        let registry = await MainActor.run {
            AppDomainRuntimeComposition.shared.runtime.toolRegistry
        }
        return await registry.isActive(handle)
    }

    @MainActor
    private static func registrationID(
        for service: any Service
    ) -> MCPDomainToolRegistrationID {
        let pointer = Unmanaged<AnyObject>.passUnretained(service as AnyObject).toOpaque()
        return MCPDomainToolRegistrationID(rawValue: UInt(bitPattern: pointer))
    }

    @MainActor
    private static func registrationScope(
        for service: any Service
    ) -> MCPDomainToolRegistrationScope {
        if let windowService = service as? WindowScopedService {
            return .window(id: windowService.windowID)
        }
        return .application
    }
}
