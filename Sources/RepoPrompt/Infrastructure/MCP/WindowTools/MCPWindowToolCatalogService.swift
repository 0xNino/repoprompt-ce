import Foundation
import RepoPromptDomainRuntime

@MainActor
protocol MCPWindowToolProviding {
    var group: MCPWindowToolGroup { get }
    func buildTools() -> [Tool]
}

@MainActor
final class MCPWindowToolCatalogService: WindowScopedService {
    let domainRegistrationID = MCPDomainToolRegistrationID()
    let windowID: Int

    private let providers: [any MCPWindowToolProviding]
    private let sharedBindings: [MCPDomainToolBinding]
    private let sharedBindingRuntime: MCPWindowToolRuntime?
    private var toolsCache: [Tool]?

    init(
        windowID: Int,
        providers: [any MCPWindowToolProviding],
        sharedBindings: [MCPDomainToolBinding] = [],
        sharedBindingRuntime: MCPWindowToolRuntime? = nil
    ) {
        #if DEBUG || EDIT_FLOW_PERF
            let constructionState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.construction)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.construction, constructionState) }
        #endif
        self.windowID = windowID
        self.providers = providers
        self.sharedBindings = sharedBindings
        self.sharedBindingRuntime = sharedBindingRuntime
    }

    var tools: [Tool] {
        get async {
            #if DEBUG || EDIT_FLOW_PERF
                let actorBodyTotalState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowCatalogToolsActorBodyTotal)
                defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowCatalogToolsActorBodyTotal, actorBodyTotalState) }
            #endif
            if let toolsCache {
                return toolsCache
            }
            #if DEBUG || EDIT_FLOW_PERF
                let materializationState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowCatalogToolsMaterialization)
                defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowCatalogToolsMaterialization, materializationState) }
            #endif
            var providersByGroup: [MCPWindowToolGroup: [any MCPWindowToolProviding]] = [:]
            for provider in providers {
                providersByGroup[provider.group, default: []].append(provider)
            }
            let legacyTools = MCPWindowToolGroup.allCases.flatMap { group in
                providersByGroup[group]?.flatMap { $0.buildTools() } ?? []
            }
            let sharedTools: [Tool]
            do {
                if sharedBindings.isEmpty {
                    sharedTools = []
                } else {
                    guard let sharedBindingRuntime else {
                        preconditionFailure("Shared domain tool bindings require the app execution runtime")
                    }
                    sharedTools = try sharedBindings.map {
                        try Tool(domainBinding: $0, runtime: sharedBindingRuntime)
                    }
                }
            } catch {
                preconditionFailure("Invalid shared domain tool definition: \(error)")
            }
            var toolsByName: [String: Tool] = [:]
            for tool in legacyTools + sharedTools {
                precondition(toolsByName.updateValue(tool, forKey: tool.name) == nil, "Duplicate MCP tool definition: \(tool.name)")
            }
            let built = MCPWindowToolGroup.orderedToolNames.compactMap { toolsByName[$0] }
            precondition(built.count == toolsByName.count, "Window catalog contains a non-canonical MCP tool")
            toolsCache = built
            return built
        }
    }

    func invalidateToolsCache() {
        #if DEBUG || EDIT_FLOW_PERF
            let invalidateToolsCacheState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.invalidateToolsCache)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.invalidateToolsCache, invalidateToolsCacheState) }
        #endif
        toolsCache = nil
    }
}
