import Foundation

package enum DomainClientPrincipalKind: String, Codable, CaseIterable, Sendable {
    case appProxy = "app_proxy"
    case runScoped = "run_scoped"
    case ttyAdministrator = "tty_administrator"
}

package enum DomainClientPrincipalAssurance: String, Codable, CaseIterable, Sendable {
    case displayNameOnly = "display_name_only"
    case verifiedProcess = "verified_process"
    case hostLaunchToken = "host_launch_token"
    case localTTY = "local_tty"
}

package struct DomainClientPrincipal: Codable, Hashable, Sendable {
    package let principalID: UUID
    package let stableKey: String?
    package let displayName: String
    package let kind: DomainClientPrincipalKind
    package let assurance: DomainClientPrincipalAssurance
    package let processID: Int32?
    package let runID: UUID?
    package let provider: String?

    package init(
        principalID: UUID,
        stableKey: String?,
        displayName: String,
        kind: DomainClientPrincipalKind,
        assurance: DomainClientPrincipalAssurance,
        processID: Int32?,
        runID: UUID?,
        provider: String?
    ) {
        self.principalID = principalID
        self.stableKey = stableKey
        self.displayName = displayName
        self.kind = kind
        self.assurance = assurance
        self.processID = processID
        self.runID = runID
        self.provider = provider
    }
}

package struct DomainToolInvocationSecurityContext: Hashable, Sendable {
    package let principal: DomainClientPrincipal
    package let connectionID: UUID
    package let connectionGeneration: UInt64
    package let invocationID: UUID
    package let runtimeID: UUID
    package let runtimeGeneration: UInt64
    package let ephemeralGrantedToolNames: Set<String>

    package init(
        principal: DomainClientPrincipal,
        connectionID: UUID,
        connectionGeneration: UInt64,
        invocationID: UUID,
        runtimeID: UUID,
        runtimeGeneration: UInt64,
        ephemeralGrantedToolNames: Set<String>
    ) {
        self.principal = principal
        self.connectionID = connectionID
        self.connectionGeneration = connectionGeneration
        self.invocationID = invocationID
        self.runtimeID = runtimeID
        self.runtimeGeneration = runtimeGeneration
        self.ephemeralGrantedToolNames = ephemeralGrantedToolNames
    }
}

package enum MCPDomainInvocationSecurityContext {
    @TaskLocal package static var current: DomainToolInvocationSecurityContext?
}
