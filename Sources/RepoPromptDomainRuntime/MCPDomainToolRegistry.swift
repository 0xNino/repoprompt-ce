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

package actor MCPDomainToolRegistry {
    private struct Registration: Sendable {
        let handle: MCPDomainToolRegistrationHandle
        let scope: MCPDomainToolRegistrationScope
        let bindingsByName: [String: MCPDomainToolBinding]
    }

    package nonisolated let registryID: UUID

    private var revision: UInt64 = 0
    private var nextGeneration: UInt64 = 0
    private var registrations: [MCPDomainToolRegistrationID: Registration] = [:]
    private var canonicalFingerprints: [String: MCPDomainToolFingerprint] = [:]

    package init(registryID: UUID = UUID()) {
        self.registryID = registryID
    }

    @discardableResult
    package func register(
        registrationID: MCPDomainToolRegistrationID,
        scope: MCPDomainToolRegistrationScope,
        bindings: [MCPDomainToolBinding]
    ) throws -> MCPDomainToolRegistrationHandle {
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
            let fingerprint = try MCPDomainToolFingerprint(definition: binding.definition)
            if let existing = canonicalFingerprints[name], existing != fingerprint {
                throw MCPDomainToolRegistryError.conflictingDefinition(toolName: name)
            }
            proposedBindings[name] = binding
            proposedFingerprints[name] = fingerprint
        }

        for registration in registrations.values
            where registration.handle.registrationID != registrationID && registration.scope == scope
        {
            if let duplicate = registration.bindingsByName.keys.first(where: { proposedBindings[$0] != nil }) {
                throw MCPDomainToolRegistryError.bindingAlreadyRegistered(toolName: duplicate, scope: scope)
            }
        }

        nextGeneration &+= 1
        let handle = MCPDomainToolRegistrationHandle(
            registryID: registryID,
            registrationID: registrationID,
            generation: nextGeneration
        )
        registrations[registrationID] = Registration(
            handle: handle,
            scope: scope,
            bindingsByName: proposedBindings
        )
        canonicalFingerprints.merge(proposedFingerprints) { existing, _ in existing }
        revision &+= 1
        return handle
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
        let registration = registrations.values.first {
            $0.scope == scope && $0.bindingsByName[toolName] != nil
        }
        guard let registration, let binding = registration.bindingsByName[toolName] else {
            return nil
        }
        return MCPDomainResolvedTool(
            handle: registration.handle,
            scope: scope,
            binding: binding
        )
    }

    package func snapshot() -> MCPDomainToolCatalogSnapshot {
        var definitionsByName: [String: MCPDomainToolDefinition] = [:]
        var activeScopes: [String: Set<MCPDomainToolRegistrationScope>] = [:]
        for registration in registrations.values {
            for (name, binding) in registration.bindingsByName {
                definitionsByName[name] = binding.definition
                activeScopes[name, default: []].insert(registration.scope)
            }
        }
        let definitions = MCPDomainToolCatalog.orderedToolNames.compactMap { definitionsByName[$0] }
        let fingerprints = Dictionary(uniqueKeysWithValues: definitions.compactMap { definition in
            canonicalFingerprints[definition.name].map { (definition.name, $0) }
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
}
