//
//  MCPToolCatalogReadiness.swift
//  RepoPrompt
//
//  Ensures the MCP tool catalog is fully ready before serving tools/list.
//  This prevents clients from caching an incomplete tool list.
//

import Foundation
import RepoPromptDomainRuntime

#if DEBUG
    private var mcpToolCatalogReadinessDebugLoggingEnabled = false
    private func mcpToolCatalogReadinessLog(_ message: @autoclosure () -> String) {
        guard mcpToolCatalogReadinessDebugLoggingEnabled else { return }
        print("[MCPToolCatalogReadiness] \(message())")
    }
#else
    private func mcpToolCatalogReadinessLog(_ message: @autoclosure () -> String) {}
#endif

/// Coordinates tool catalog readiness for MCP connections.
/// Ensures that before a connection can list tools, all required services
/// are registered and their tools are built.
actor MCPToolCatalogReadiness {
    static let shared = MCPToolCatalogReadiness()

    private init() {}

    /// Default timeout for readiness wait
    static let defaultTimeout: TimeInterval = 5.0

    /// Wait for the tool catalog to be ready for a given window.
    /// This ensures required services are registered and tools are built.
    ///
    /// - Parameters:
    ///   - windowID: The window ID to wait for (nil to skip window-specific checks)
    ///   - timeout: Maximum time to wait
    /// - Returns: true if ready, false if timeout
    func awaitReady(windowID: Int?, timeout: TimeInterval = defaultTimeout) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, timeout)))
        var pollInterval: TimeInterval = 0.025

        while true {
            if Task.isCancelled { return false }
            guard clock.now < deadline else { break }

            let isReady = await checkServicesReady(windowID: windowID)
            if Task.isCancelled { return false }
            guard clock.now <= deadline else { break }
            if isReady {
                mcpToolCatalogReadinessLog("Tool catalog ready for window \(windowID.map(String.init) ?? "nil")")
                return true
            }

            let nextPoll = min(
                clock.now.advanced(by: .seconds(pollInterval)),
                deadline
            )
            do {
                try await clock.sleep(until: nextPoll, tolerance: .milliseconds(2))
            } catch {
                return false
            }
            pollInterval = min(pollInterval * 2, 0.2)
        }

        return false
    }

    /// Ensure tools are built for a window by accessing them.
    /// This forces lazy tool cache population and AWAITS completion.
    func warmToolCache(windowID: Int) async {
        // Get the MCPServerViewModel on MainActor
        let mcpServer: MCPServerViewModel? = await MainActor.run {
            WindowStatesManager.shared.window(withID: windowID)?.mcpServer
        }

        guard let mcpServer else {
            mcpToolCatalogReadinessLog("Cannot warm tool cache - window \(windowID) not found")
            return
        }

        // Actually await the catalog service tools to force cache build.
        // This will hop to MainActor internally since MCPServerViewModel is @MainActor.
        #if DEBUG || EDIT_FLOW_PERF
            let readinessWarmAccessState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.readinessWarmAccess)
        #endif
        _ = await mcpServer.windowMCPTools
        #if DEBUG || EDIT_FLOW_PERF
            EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.readinessWarmAccess, readinessWarmAccessState)
        #endif
        mcpToolCatalogReadinessLog("Tool cache warmed for window \(windowID)")
    }

    /// Check if required services are ready (MainActor)
    @MainActor
    private func checkServicesReady(windowID: Int?) async -> Bool {
        let snapshot = await AppDomainRuntimeComposition.shared.catalogSnapshot()
        let globalCatalogReady = MCPGlobalToolName.orderedToolNames.allSatisfy { toolName in
            snapshot.activeScopesByToolName[toolName]?.contains(.application) == true
        }
        guard globalCatalogReady else {
            mcpToolCatalogReadinessLog("Application-scoped global domain registrations are not ready")
            return false
        }

        guard let windowID else { return true }
        guard let window = WindowStatesManager.shared.window(withID: windowID) else {
            mcpToolCatalogReadinessLog("Window \(windowID) not found during readiness check")
            return false
        }

        if !window.mcpServer.windowToolsEnabled {
            if window.mcpServer.windowToolsAreRequested {
                mcpToolCatalogReadinessLog("Window \(windowID) requested tools but registration is not ready")
                return false
            }
            mcpToolCatalogReadinessLog("Window \(windowID) intentionally has tools disabled after global readiness")
            return true
        }
        let requiredScope = MCPDomainToolRegistrationScope.window(id: windowID)
        let windowCatalogReady = MCPAppToolGroup.orderedToolNames.allSatisfy { toolName in
            snapshot.activeScopesByToolName[toolName]?.contains(requiredScope) == true
        }
        if !windowCatalogReady {
            mcpToolCatalogReadinessLog("Window domain tool registration for window \(windowID) not ready")
        }
        return windowCatalogReady
    }
}
