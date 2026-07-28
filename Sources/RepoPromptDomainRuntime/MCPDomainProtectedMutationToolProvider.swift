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

package enum DomainProtectedMutationError: Error, Equatable, LocalizedError, Sendable {
    case partialSuccessAfterCommit(operationID: String)

    package var errorDescription: String? {
        switch self {
        case let .partialSuccessAfterCommit(operationID):
            "Protected mutation crossed its durable commit boundary but reply settlement was interrupted. Inspect state before retrying operation ID \(operationID)."
        }
    }
}

package struct MCPDomainProtectedMutationToolProvider: Sendable {
    package let stage: DomainProtectedMutationStage
    private let policyStore: DomainMutationPolicyStore
    private let journal: DomainMutationJournal

    package init(
        stage: DomainProtectedMutationStage,
        policyStore: DomainMutationPolicyStore,
        journal: DomainMutationJournal
    ) {
        self.stage = stage
        self.policyStore = policyStore
        self.journal = journal
    }

    package func protectedBinding(
        _ binding: MCPDomainToolBinding
    ) -> MCPDomainToolBinding {
        guard Self.isProtectedFamily(binding.definition.name, stage: stage) else {
            return binding
        }
        let definition = binding.definition
        let policyStore = policyStore
        let journal = journal
        let stage = stage
        return MCPDomainToolBinding(definition: definition) { arguments in
            guard let operation = Self.operation(
                toolName: definition.name,
                arguments: arguments,
                stage: stage
            ) else {
                return try await binding(arguments)
            }
            guard let securityContext = MCPDomainInvocationSecurityContext.current else {
                throw DomainMutationPolicyError.principalMissing
            }

            if stage == .m4B, Self.isDurableMutationFamily(operation.toolName) {
                return try await Self.executeDurableMutation(
                    operation: operation,
                    arguments: arguments,
                    securityContext: securityContext,
                    binding: binding,
                    policyStore: policyStore,
                    journal: journal
                )
            }

            let authorization = try await policyStore.authorize(
                context: securityContext,
                toolName: operation.toolName,
                action: operation.action,
                workspaceID: securityContext.workspaceID
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

    private static func executeDurableMutation(
        operation: DomainProtectedMutationOperation,
        arguments: [String: Value],
        securityContext: DomainToolInvocationSecurityContext,
        binding: MCPDomainToolBinding,
        policyStore: DomainMutationPolicyStore,
        journal: DomainMutationJournal
    ) async throws -> Value {
        var effectiveArguments = arguments
        let suppliedOperationID = arguments["operation_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let operationID = suppliedOperationID.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        effectiveArguments["operation_id"] = .string(operationID)

        var authorizedRoots = securityContext.authorizedCanonicalRoots
        if operation.toolName == "manage_worktree",
           securityContext.principal.kind == .appProxy,
           arguments["allow_external_path"]?.boolValue == true,
           let path = arguments["path"]?.stringValue,
           path.hasPrefix("/")
        {
            authorizedRoots.insert(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        }
        let pathFence = try await DomainMutationPathFence.admit(
            requestedPaths: requestedPaths(operation: operation, arguments: effectiveArguments),
            authorizedRoots: authorizedRoots
        )
        let authorization = try await policyStore.authorize(
            context: securityContext,
            toolName: operation.toolName,
            action: operation.action,
            workspaceID: securityContext.workspaceID,
            canonicalRoots: pathFence.coveredRoots
        )
        try Task.checkCancellation()

        let fingerprint = try mutationFingerprint(
            operation: operation,
            arguments: effectiveArguments,
            workspaceID: securityContext.workspaceID,
            pathFence: pathFence
        )
        let key = "\(operation.toolName).\(operation.action):\(operationID)"
        let begin = try await journal.begin(
            key: key,
            operationID: operationID,
            toolName: operation.toolName,
            action: operation.action,
            fingerprint: fingerprint,
            ownerInvocationID: securityContext.invocationID,
            workspaceID: securityContext.workspaceID,
            workspaceRevision: securityContext.workspaceRevision,
            pathFence: pathFence
        )
        switch begin {
        case let .replay(result):
            return result
        case let .execute(ticket):
            let commitState = DomainMutationCommitState()
            let controller = DomainMutationCommitController {
                try await commitState.beginIfNeeded {
                    try Task.checkCancellation()
                    try await policyStore.revalidate(authorization)
                    try await DomainMutationPathFence.revalidate(pathFence)
                    try await journal.markCommitting(ticket)
                }
            }
            do {
                let result = try await MCPDomainMutationCommitContext.$controller.withValue(controller) {
                    try await binding(effectiveArguments)
                }
                let didBeginCommit = await commitState.hasBegunCommit()
                if Task.isCancelled, didBeginCommit {
                    try? await detachedFinishIndeterminate(journal: journal, ticket: ticket)
                    throw DomainProtectedMutationError.partialSuccessAfterCommit(operationID: operationID)
                }
                try await detachedFinishApplied(journal: journal, ticket: ticket, result: result)
                return result
            } catch let error as DomainProtectedMutationError {
                throw error
            } catch {
                let didBeginCommit = await commitState.hasBegunCommit()
                if didBeginCommit {
                    try? await detachedFinishIndeterminate(journal: journal, ticket: ticket)
                    throw DomainProtectedMutationError.partialSuccessAfterCommit(operationID: operationID)
                }
                try? await detachedFinishBeforeCommit(
                    journal: journal,
                    ticket: ticket,
                    cancelled: error is CancellationError
                )
                throw error
            }
        }
    }

    private static func isDurableMutationFamily(_ toolName: String) -> Bool {
        ["file_actions", "apply_edits", "manage_worktree"].contains(toolName)
    }

    private static func requestedPaths(
        operation: DomainProtectedMutationOperation,
        arguments: [String: Value]
    ) -> [String] {
        switch operation.toolName {
        case "file_actions":
            return [arguments["path"]?.stringValue, arguments["new_path"]?.stringValue].compactMap { $0 }
        case "apply_edits":
            return [arguments["path"]?.stringValue].compactMap { $0 }
        case "manage_worktree":
            return ["repo_root", "path", "worktree", "target"].compactMap { key in
                guard let path = arguments[key]?.stringValue, path.hasPrefix("/") else { return nil }
                return path
            }
        default:
            return []
        }
    }

    private static func mutationFingerprint(
        operation: DomainProtectedMutationOperation,
        arguments: [String: Value],
        workspaceID: UUID?,
        pathFence: DomainMutationPathFenceSnapshot
    ) throws -> String {
        struct Payload: Encodable {
            let toolName: String
            let action: String
            let arguments: [String: Value]
            let workspaceID: UUID?
            let pathFence: DomainMutationPathFenceSnapshot
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Payload(
            toolName: operation.toolName,
            action: operation.action,
            arguments: arguments,
            workspaceID: workspaceID,
            pathFence: pathFence
        ))
        return DomainContentDigest.sha256(data)
    }

    private static func detachedFinishApplied(
        journal: DomainMutationJournal,
        ticket: DomainMutationJournalTicket,
        result: Value
    ) async throws {
        try await Task.detached(priority: .utility) {
            try await journal.finishApplied(ticket, result: result)
        }.value
    }

    private static func detachedFinishBeforeCommit(
        journal: DomainMutationJournal,
        ticket: DomainMutationJournalTicket,
        cancelled: Bool
    ) async throws {
        try await Task.detached(priority: .utility) {
            try await journal.finishBeforeCommit(ticket, cancelled: cancelled)
        }.value
    }

    private static func detachedFinishIndeterminate(
        journal: DomainMutationJournal,
        ticket: DomainMutationJournalTicket
    ) async throws {
        try await Task.detached(priority: .utility) {
            try await journal.finishIndeterminateAfterCommit(ticket)
        }.value
    }
}
