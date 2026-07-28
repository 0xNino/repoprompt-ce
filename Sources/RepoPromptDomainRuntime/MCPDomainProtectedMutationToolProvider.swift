import Foundation
import MCP

package enum DomainProtectedMutationStage: String, CaseIterable, Sendable {
    case m3Compatibility = "m3_compatibility"
    case m4A = "m4a"
    case m4B = "m4b"
}

package struct DomainProtectedMutationOperation: Hashable, Sendable {
    package let toolName: String
    package let action: String
}

package struct MCPDomainProtectedMutationToolProvider: Sendable {
    package let stage: DomainProtectedMutationStage
    private let policyStore: DomainMutationPolicyStore

    package init(
        stage: DomainProtectedMutationStage,
        policyStore: DomainMutationPolicyStore
    ) {
        self.stage = stage
        self.policyStore = policyStore
    }

    package func protectedBinding(
        _ binding: MCPDomainToolBinding
    ) -> MCPDomainToolBinding {
        guard Self.isProtectedFamily(binding.definition.name, stage: stage) else {
            return binding
        }
        let definition = binding.definition
        let policyStore = policyStore
        let stage = stage
        return MCPDomainToolBinding(definition: definition) { arguments in
            guard let operation = Self.operation(
                toolName: definition.name,
                arguments: arguments,
                stage: stage
            ) else {
                return try await binding(arguments)
            }
            let authorization = try await policyStore.authorize(
                context: MCPDomainInvocationSecurityContext.current,
                toolName: operation.toolName,
                action: operation.action
            )
            try Task.checkCancellation()
            try await policyStore.revalidate(authorization)
            return try await binding(arguments)
        }
    }

    package static func isProtectedFamily(
        _ toolName: String,
        stage: DomainProtectedMutationStage
    ) -> Bool {
        switch stage {
        case .m3Compatibility:
            false
        case .m4A:
            ["manage_selection", "prompt", "workspace_context", "bind_context", "manage_workspaces"]
                .contains(toolName)
        case .m4B:
            [
                "manage_selection", "prompt", "workspace_context", "bind_context", "manage_workspaces",
                "file_actions", "apply_edits", "manage_worktree",
            ].contains(toolName)
        }
    }

    package static func operation(
        toolName: String,
        arguments: [String: Value],
        stage: DomainProtectedMutationStage
    ) -> DomainProtectedMutationOperation? {
        guard isProtectedFamily(toolName, stage: stage) else { return nil }
        switch toolName {
        case "manage_selection":
            let action = arguments["op"]?.stringValue ?? "get"
            return ["add", "remove", "set", "clear", "promote", "demote"].contains(action)
                ? .init(toolName: toolName, action: action)
                : nil
        case "prompt":
            let action = arguments["op"]?.stringValue ?? "get"
            if ["set", "append", "clear", "select_preset"].contains(action) {
                return .init(toolName: toolName, action: action)
            }
            if stage == .m4B, action == "export" {
                return .init(toolName: toolName, action: action)
            }
            return nil
        case "workspace_context":
            let action = arguments["op"]?.stringValue ?? "snapshot"
            if action == "select_preset" || (stage == .m4B && action == "export") {
                return .init(toolName: toolName, action: action)
            }
            return nil
        case "bind_context":
            let action = arguments["op"]?.stringValue ?? "list"
            return action == "bind" ? .init(toolName: toolName, action: action) : nil
        case "manage_workspaces":
            let action = arguments["action"]?.stringValue ?? "list"
            return [
                "switch", "create", "hide", "unhide", "delete", "add_folder", "remove_folder",
                "select_tab", "create_tab", "close_tab",
            ].contains(action) ? .init(toolName: toolName, action: action) : nil
        case "file_actions" where stage == .m4B:
            let action = arguments["action"]?.stringValue ?? ""
            return action.isEmpty ? nil : .init(toolName: toolName, action: action)
        case "apply_edits" where stage == .m4B:
            let action: String = if arguments["rewrite"] != nil {
                "rewrite"
            } else if arguments["edits"] != nil {
                "batch"
            } else {
                "replace"
            }
            return .init(toolName: toolName, action: action)
        case "manage_worktree" where stage == .m4B:
            let action = arguments["op"]?.stringValue ?? "list"
            let mutating = ["create", "bind", "select", "unbind", "apply", "continue", "abort"].contains(action)
                || arguments["persist_visuals"]?.boolValue == true
            return mutating ? .init(toolName: toolName, action: action) : nil
        default:
            return nil
        }
    }
}
