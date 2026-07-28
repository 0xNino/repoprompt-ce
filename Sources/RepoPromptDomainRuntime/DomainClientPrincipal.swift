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
    /// Kernel-observed process identifier eligible for verified-process assurance.
    package let processID: Int32?
    /// Client-declared handshake metadata. Never grants authority.
    package let claimedProcessID: Int32?
    package let runID: UUID?
    package let provider: String?
    /// Kernel-derived executable identity. Display names and provider labels are never grant authority.
    package let verifiedIdentityFingerprint: String?

    package init(
        principalID: UUID,
        stableKey: String?,
        displayName: String,
        kind: DomainClientPrincipalKind,
        assurance: DomainClientPrincipalAssurance,
        processID: Int32?,
        runID: UUID?,
        provider: String?,
        verifiedIdentityFingerprint: String? = nil,
        claimedProcessID: Int32? = nil
    ) {
        self.principalID = principalID
        self.stableKey = stableKey
        self.displayName = displayName
        self.kind = kind
        self.assurance = assurance
        self.processID = processID
        self.claimedProcessID = claimedProcessID
        self.runID = runID
        self.provider = provider
        self.verifiedIdentityFingerprint = verifiedIdentityFingerprint
    }
}

package struct DomainToolInvocationSecurityContext: Hashable, Sendable {
    package let principal: DomainClientPrincipal
    package let connectionID: UUID
    package let connectionGeneration: UInt64
    package let invocationID: UUID
    /// Server-owned request identity used for journal dedupe. Public operation_id remains correlation-only.
    package let mutationRequestKey: String
    package let runtimeID: UUID
    package let runtimeGeneration: UInt64
    package let workspaceID: UUID?
    package let workspaceRevision: UInt64?
    package let authorizedCanonicalRoots: Set<String>
    /// False when no authoritative routing registration/context could be resolved.
    package let hasAuthoritativeRoutingContext: Bool
    package let ephemeralGrantedToolNames: Set<String>

    package init(
        principal: DomainClientPrincipal,
        connectionID: UUID,
        connectionGeneration: UInt64,
        invocationID: UUID,
        mutationRequestKey: String? = nil,
        runtimeID: UUID,
        runtimeGeneration: UInt64,
        workspaceID: UUID? = nil,
        workspaceRevision: UInt64? = nil,
        authorizedCanonicalRoots: Set<String> = [],
        hasAuthoritativeRoutingContext: Bool = true,
        ephemeralGrantedToolNames: Set<String>
    ) {
        self.principal = principal
        self.connectionID = connectionID
        self.connectionGeneration = connectionGeneration
        self.invocationID = invocationID
        self.mutationRequestKey = mutationRequestKey ?? invocationID.uuidString
        self.runtimeID = runtimeID
        self.runtimeGeneration = runtimeGeneration
        self.workspaceID = workspaceID
        self.workspaceRevision = workspaceRevision
        self.authorizedCanonicalRoots = authorizedCanonicalRoots
        self.hasAuthoritativeRoutingContext = hasAuthoritativeRoutingContext
        self.ephemeralGrantedToolNames = ephemeralGrantedToolNames
    }
}

package enum MCPDomainInvocationSecurityContext {
    @TaskLocal package static var current: DomainToolInvocationSecurityContext?
}
