import Foundation
import RepoPromptDomainRuntime

@MainActor
protocol MCPAppToolProviding {
    var group: MCPAppToolGroup { get }
    func buildTools() -> [Tool]
}

@MainActor
final class MCPAppToolCatalogRegistration: WindowScopedService {
    let domainRegistrationID = MCPDomainToolRegistrationID()
    let windowID: Int

    private let providers: [any MCPAppToolProviding]
    private let sharedBindings: [MCPDomainToolBinding]
    private let runtime: MCPAppToolBinder
    private var toolsCache: [Tool]?

    init(
        windowID: Int,
        providers: [any MCPAppToolProviding],
        sharedBindings: [MCPDomainToolBinding] = [],
        runtime: MCPAppToolBinder
    ) {
        #if DEBUG || EDIT_FLOW_PERF
            let constructionState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.construction)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.construction, constructionState) }
        #endif
        self.windowID = windowID
        self.providers = providers
        self.sharedBindings = sharedBindings
        self.runtime = runtime
    }

    var longRunningInteractionAdapter: DomainLongRunningInteractionAdapter? {
        providers.compactMap { ($0 as? MCPAskUserToolProvider)?.domainInteractionAdapter }.first
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
            var providersByGroup: [MCPAppToolGroup: [any MCPAppToolProviding]] = [:]
            for provider in providers {
                providersByGroup[provider.group, default: []].append(provider)
            }
            let appAdapterBindings: [MCPDomainToolBinding]
            do {
                appAdapterBindings = try MCPAppToolGroup.allCases.flatMap { group in
                    try providersByGroup[group]?.flatMap { provider in
                        try provider.buildTools().map { try $0.domainBinding() }
                    } ?? []
                }
            } catch {
                preconditionFailure("Invalid app adapter tool definition: \(error)")
            }
            var bindingsByName: [String: MCPDomainToolBinding] = [:]
            for binding in appAdapterBindings + sharedBindings {
                precondition(
                    bindingsByName.updateValue(binding, forKey: binding.definition.name) == nil,
                    "Duplicate MCP tool definition: \(binding.definition.name)"
                )
            }
            let orderedBindings = MCPAppToolGroup.orderedToolNames.compactMap { bindingsByName[$0] }
            precondition(
                orderedBindings.count == bindingsByName.count,
                "App tool registration contains a non-canonical MCP tool"
            )
            let built: [Tool]
            do {
                built = try orderedBindings.map {
                    try Tool(domainBinding: $0, runtime: runtime)
                }
            } catch {
                preconditionFailure("Invalid canonical domain tool definition: \(error)")
            }
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
