import Foundation
import MCP

package struct MCPDomainReadSideEffectEmitter: Sendable {
    private let submitOperation: @Sendable (
        _ operationID: UUID,
        _ fingerprint: String,
        _ operation: @Sendable @escaping () async throws -> Void
    ) async throws -> DomainReadSideEffectReceipt
    private let drainOperation: @Sendable (_ revision: UInt64) async throws -> Void

    init(
        submit: @Sendable @escaping (
            _ operationID: UUID,
            _ fingerprint: String,
            _ operation: @Sendable @escaping () async throws -> Void
        ) async throws -> DomainReadSideEffectReceipt,
        drain: @Sendable @escaping (_ revision: UInt64) async throws -> Void
    ) {
        submitOperation = submit
        drainOperation = drain
    }

    package func submit(
        operationID: UUID = UUID(),
        fingerprint: String,
        operation: @Sendable @escaping () async throws -> Void
    ) async throws -> DomainReadSideEffectReceipt {
        try await submitOperation(operationID, fingerprint, operation)
    }

    package func submitAndWait(
        operationID: UUID = UUID(),
        fingerprint: String,
        operation: @Sendable @escaping () async throws -> Void
    ) async throws -> DomainReadSideEffectReceipt {
        let receipt = try await submitOperation(operationID, fingerprint, operation)
        try await drainOperation(receipt.revision)
        return receipt
    }
}

package struct MCPDomainReadToolBackend: Sendable {
    package typealias Execute = @Sendable (
        _ toolName: String,
        _ context: DomainReadContextHandle,
        _ arguments: [String: Value],
        _ sideEffects: MCPDomainReadSideEffectEmitter
    ) async throws -> Value

    package let execute: Execute

    package init(execute: @escaping Execute) {
        self.execute = execute
    }
}

/// Sole provider/schema implementation for M3 read/discovery families.
///
/// Concrete app and standalone compositions inject physical backends, but both execute the same
/// definitions, context fencing, cancellation boundaries, drain semantics, and effect revisions.
package struct MCPDomainReadToolProvider: Sendable {
    package typealias ResolveContext = @Sendable (_ toolName: String) async throws -> DomainReadContextHandle

    private let resolveContext: ResolveContext
    private let backend: MCPDomainReadToolBackend
    private let sideEffects: DomainReadSideEffectCoordinator

    package init(
        resolveContext: @escaping ResolveContext,
        backend: MCPDomainReadToolBackend,
        sideEffects: DomainReadSideEffectCoordinator
    ) {
        self.resolveContext = resolveContext
        self.backend = backend
        self.sideEffects = sideEffects
    }

    package var bindings: [MCPDomainToolBinding] {
        MCPDomainReadToolDefinitions.definitions.map { definition in
            MCPDomainToolBinding(definition: definition) { arguments in
                try await execute(
                    toolName: definition.name,
                    arguments: arguments
                )
            }
        }
    }

    package func binding(named name: String) -> MCPDomainToolBinding? {
        bindings.first { $0.definition.name == name }
    }

    private func execute(
        toolName: String,
        arguments: [String: Value]
    ) async throws -> Value {
        try Task.checkCancellation()
        try validateTopLevelArguments(toolName: toolName, arguments: arguments)
        var handle = try await resolveContext(toolName)
        try Task.checkCancellation()

        if requiresReadSideEffectDrain(toolName: toolName, arguments: arguments) {
            let revision = try await sideEffects.highWaterRevision(for: handle)
            try await sideEffects.drain(handle: handle, through: revision)
            try Task.checkCancellation()
            // A drain may publish a new canonical selection/context revision. Resolve a fresh
            // authority handle rather than carrying the pre-drain revision into the backend.
            handle = try await resolveContext(toolName)
        }

        let resolvedHandle = handle
        let emitter = MCPDomainReadSideEffectEmitter(
            submit: { operationID, fingerprint, operation in
                try await sideEffects.submit(
                    handle: resolvedHandle,
                    operationID: operationID,
                    fingerprint: fingerprint,
                    operation: operation
                )
            },
            drain: { revision in
                try await sideEffects.drain(handle: resolvedHandle, through: revision)
            }
        )
        let value = try await backend.execute(toolName, resolvedHandle, arguments, emitter)
        try Task.checkCancellation()
        return value
    }

    private func validateTopLevelArguments(
        toolName: String,
        arguments: [String: Value]
    ) throws {
        switch toolName {
        case "read_file":
            guard arguments["path"]?.stringValue != nil else {
                throw MCPError.invalidParams("missing path")
            }
        case "file_search":
            let pattern = arguments["pattern"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !pattern.isEmpty else {
                throw MCPError.invalidParams("pattern cannot be empty; provide a non-empty search term. If you intend to enumerate files, use get_file_tree or specify a path mode with a wildcard like '*.swift'.")
            }
        default:
            break
        }
    }

    private func requiresReadSideEffectDrain(
        toolName: String,
        arguments: [String: Value]
    ) -> Bool {
        switch toolName {
        case "get_code_structure":
            return arguments["paths"] == nil
        case "get_file_tree":
            return arguments["mode"]?.stringValue?.lowercased() == "selected"
        case "workspace_context":
            return (arguments["op"]?.stringValue ?? "snapshot").lowercased() == "snapshot"
        case "prompt":
            return arguments["op"]?.stringValue?.lowercased() == "export"
        case "git":
            return arguments["op"]?.stringValue?.lowercased() == "diff"
                && arguments["artifacts"]?.boolValue == true
                && arguments["scope"]?.stringValue?.lowercased() == "selected"
        default:
            return false
        }
    }
}
