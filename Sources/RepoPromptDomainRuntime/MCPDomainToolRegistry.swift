import CryptoKit
import Foundation

package enum MCPDomainToolRegistryError: Error, Equatable, Sendable {
    case emptyRegistration
    case invalidWindowID(Int)
    case duplicateToolName(String)
    case unknownToolName(String)
    case scopeMismatch(toolName: String, expected: MCPDomainToolScopeKind, actual: MCPDomainToolScopeKind)
    case bindingAlreadyRegistered(toolName: String, scope: MCPDomainToolRegistrationScope)
    case conflictingDefinition(toolName: String)
}

package struct MCPDomainToolCatalogSnapshot: Sendable {
    package let revision: UInt64
    package let definitions: [MCPDomainToolDefinition]
    package let fingerprintsByToolName: [String: MCPDomainToolFingerprint]
    package let activeScopesByToolName: [String: Set<MCPDomainToolRegistrationScope>]
    package let catalogFingerprint: String

    package var toolNames: [String] { definitions.map(\.name) }
}

package enum MCPDomainRegistryRemoval: Equatable, Sendable {
    case removed
    case unchanged
}

package enum MCPDomainToolRegistrationDisposition: Equatable, Sendable {
    case inserted
    case replaced
    case unchanged
}

package struct MCPDomainToolRegistrationResult: Equatable, Sendable {
    package let handle: MCPDomainToolRegistrationHandle
    package let disposition: MCPDomainToolRegistrationDisposition
}

package actor MCPDomainToolRegistry {
    private struct Registration: Sendable {
        let handle: MCPDomainToolRegistrationHandle
        let scope: MCPDomainToolRegistrationScope
        let bindingsByName: [String: MCPDomainToolBinding]
        let fingerprintsByName: [String: MCPDomainToolFingerprint]
    }

    package nonisolated let registryID: UUID

    private var revision: UInt64 = 0
    private var nextGeneration: UInt64 = 0
    private var registrations: [MCPDomainToolRegistrationID: Registration] = [:]

    package init(registryID: UUID = UUID()) {
        self.registryID = registryID
    }

    @discardableResult
    package func register(
        registrationID: MCPDomainToolRegistrationID,
        scope: MCPDomainToolRegistrationScope,
        bindings: [MCPDomainToolBinding]
    ) throws -> MCPDomainToolRegistrationHandle {
        try registerWithResult(
            registrationID: registrationID,
            scope: scope,
            bindings: bindings
        ).handle
    }

    package func registerWithResult(
        registrationID: MCPDomainToolRegistrationID,
        scope: MCPDomainToolRegistrationScope,
        bindings: [MCPDomainToolBinding]
    ) throws -> MCPDomainToolRegistrationResult {
        guard !bindings.isEmpty else {
            throw MCPDomainToolRegistryError.emptyRegistration
        }
        if case let .window(id) = scope, id <= 0 {
            throw MCPDomainToolRegistryError.invalidWindowID(id)
        }

        var proposedBindings: [String: MCPDomainToolBinding] = [:]
        var proposedFingerprints: [String: MCPDomainToolFingerprint] = [:]
        for binding in bindings {
            let name = binding.definition.name
            guard proposedBindings[name] == nil else {
                throw MCPDomainToolRegistryError.duplicateToolName(name)
            }
            guard let entry = MCPDomainToolCatalog.entry(named: name) else {
                throw MCPDomainToolRegistryError.unknownToolName(name)
            }
            guard entry.scope == scope.kind else {
                throw MCPDomainToolRegistryError.scopeMismatch(
                    toolName: name,
                    expected: entry.scope,
                    actual: scope.kind
                )
            }
            proposedBindings[name] = binding
            proposedFingerprints[name] = try MCPDomainToolFingerprint(definition: binding.definition)
        }

        for (otherID, registration) in registrations where otherID != registrationID {
            if registration.scope == scope,
               let duplicate = registration.bindingsByName.keys.first(where: { proposedBindings[$0] != nil })
            {
                throw MCPDomainToolRegistryError.bindingAlreadyRegistered(toolName: duplicate, scope: scope)
            }
            if let conflict = registration.fingerprintsByName.first(where: { entry in
                proposedFingerprints[entry.key].map { $0 != entry.value } == true
            }) {
                throw MCPDomainToolRegistryError.conflictingDefinition(toolName: conflict.key)
            }
        }

        if let existing = registrations[registrationID],
           existing.scope == scope,
           existing.fingerprintsByName == proposedFingerprints
        {
            return MCPDomainToolRegistrationResult(
                handle: existing.handle,
                disposition: .unchanged
            )
        }

        nextGeneration &+= 1
        let handle = MCPDomainToolRegistrationHandle(
            registryID: registryID,
            registrationID: registrationID,
            generation: nextGeneration
        )
        let disposition: MCPDomainToolRegistrationDisposition = registrations[registrationID] == nil
            ? .inserted
            : .replaced
        registrations[registrationID] = Registration(
            handle: handle,
            scope: scope,
            bindingsByName: proposedBindings,
            fingerprintsByName: proposedFingerprints
        )
        revision &+= 1
        return MCPDomainToolRegistrationResult(handle: handle, disposition: disposition)
    }

    package func unregister(
        registrationID: MCPDomainToolRegistrationID,
        expectedGeneration: UInt64? = nil
    ) -> MCPDomainRegistryRemoval {
        guard let registration = registrations[registrationID] else {
            return .unchanged
        }
        if let expectedGeneration, registration.handle.generation != expectedGeneration {
            return .unchanged
        }
        registrations.removeValue(forKey: registrationID)
        revision &+= 1
        return .removed
    }

    package func unregister(_ handle: MCPDomainToolRegistrationHandle) -> MCPDomainRegistryRemoval {
        guard handle.registryID == registryID else { return .unchanged }
        return unregister(
            registrationID: handle.registrationID,
            expectedGeneration: handle.generation
        )
    }

    package func isRegistered(_ registrationID: MCPDomainToolRegistrationID) -> Bool {
        registrations[registrationID] != nil
    }

    package func isActive(_ handle: MCPDomainToolRegistrationHandle) -> Bool {
        guard handle.registryID == registryID else { return false }
        return registrations[handle.registrationID]?.handle.generation == handle.generation
    }

    package func resolve(
        toolName: String,
        scope: MCPDomainToolRegistrationScope
    ) -> MCPDomainResolvedTool? {
        guard let registration = registrations.values.first(where: {
            $0.scope == scope && $0.bindingsByName[toolName] != nil
        }), let binding = registration.bindingsByName[toolName]
        else {
            return nil
        }
        return resolvedTool(registration: registration, binding: binding)
    }

    package func resolveUniqueWindowTool(toolName: String) -> MCPDomainResolvedTool? {
        let matches = registrations.values.compactMap { registration -> (Registration, MCPDomainToolBinding)? in
            guard case .window = registration.scope,
                  let binding = registration.bindingsByName[toolName]
            else {
                return nil
            }
            return (registration, binding)
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        return resolvedTool(registration: match.0, binding: match.1)
    }

    package func snapshot() -> MCPDomainToolCatalogSnapshot {
        var definitionsByName: [String: MCPDomainToolDefinition] = [:]
        var fingerprintsByName: [String: MCPDomainToolFingerprint] = [:]
        var activeScopes: [String: Set<MCPDomainToolRegistrationScope>] = [:]
        for registration in registrations.values {
            for (name, binding) in registration.bindingsByName {
                definitionsByName[name] = binding.definition
                fingerprintsByName[name] = registration.fingerprintsByName[name]
                activeScopes[name, default: []].insert(registration.scope)
            }
        }
        let definitions = MCPDomainToolCatalog.orderedToolNames.compactMap { definitionsByName[$0] }
        let fingerprints = Dictionary(uniqueKeysWithValues: definitions.compactMap { definition in
            fingerprintsByName[definition.name].map { (definition.name, $0) }
        })
        let catalogBytes = definitions.compactMap { fingerprints[$0.name]?.digest }.joined(separator: "\n")
        let catalogFingerprint = SHA256.hash(data: Data(catalogBytes.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return MCPDomainToolCatalogSnapshot(
            revision: revision,
            definitions: definitions,
            fingerprintsByToolName: fingerprints,
            activeScopesByToolName: activeScopes,
            catalogFingerprint: catalogFingerprint
        )
    }

    private func resolvedTool(
        registration: Registration,
        binding: MCPDomainToolBinding
    ) -> MCPDomainResolvedTool {
        MCPDomainResolvedTool(
            handle: registration.handle,
            scope: registration.scope,
            binding: binding
        )
    }
}
