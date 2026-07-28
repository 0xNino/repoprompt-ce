import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class MCPDomainHostTests: XCTestCase {
    func testHostResolvesAndInvokesExactRegisteredBinding() async throws {
        let fixture = try await makeFixture()
        let resolution = try await fixture.runtime.domainHost.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: MCPDomainToolRegistrationScope.window(id: 1)
        )
        let invocationID = UUID()
        let value = try await fixture.runtime.domainHost.invoke(MCPDomainHostInvocation(
            invocationID: invocationID,
            connectionID: fixture.connection.connectionID,
            resolution: resolution,
            arguments: ["path": .string("README.md")],
            securityContext: securityContext(
                identity: fixture.runtime.identity,
                connection: fixture.connection,
                invocationID: invocationID
            )
        ))

        XCTAssertEqual(value.stringValue, "README.md")
        let snapshot = await fixture.runtime.domainHost.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .accepting)
        XCTAssertEqual(snapshot.activeInvocationCount, 0)
        XCTAssertEqual(snapshot.connectionsWithActiveInvocationsCount, 0)
    }

    func testHostRejectsStaleResolutionAfterRegistrationReplacement() async throws {
        let fixture = try await makeFixture()
        let stale = try await fixture.runtime.domainHost.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: MCPDomainToolRegistrationScope.window(id: 1)
        )
        _ = try await fixture.runtime.toolRegistry.registerWithResult(
            registrationID: fixture.registrationID,
            scope: MCPDomainToolRegistrationScope.window(id: 1),
            bindings: [Self.binding(description: "replacement")]
        )
        let invocationID = UUID()

        do {
            _ = try await fixture.runtime.domainHost.invoke(MCPDomainHostInvocation(
                invocationID: invocationID,
                connectionID: fixture.connection.connectionID,
                resolution: stale,
                arguments: [:],
                securityContext: securityContext(
                    identity: fixture.runtime.identity,
                    connection: fixture.connection,
                    invocationID: invocationID
                )
            ))
            XCTFail("Stale host resolution invoked a replacement binding")
        } catch let error as MCPDomainHostError {
            XCTAssertEqual(error, .staleRegistration(toolName: MCPWindowToolName.readFile))
        }
    }

    func testConnectionCancellationAndDrainRejectNewInvocation() async throws {
        let blocker = InvocationBlocker()
        let fixture = try await makeFixture(binding: Self.binding { arguments in
            await blocker.wait()
            return arguments["path"] ?? .string("done")
        })
        let resolution = try await fixture.runtime.domainHost.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: MCPDomainToolRegistrationScope.window(id: 1)
        )
        let invocationID = UUID()
        let invocation = MCPDomainHostInvocation(
            invocationID: invocationID,
            connectionID: fixture.connection.connectionID,
            resolution: resolution,
            arguments: ["path": .string("settled")],
            securityContext: securityContext(
                identity: fixture.runtime.identity,
                connection: fixture.connection,
                invocationID: invocationID
            )
        )
        let task = Task { try await fixture.runtime.domainHost.invoke(invocation) }
        await blocker.awaitStarted()

        await fixture.runtime.domainHost.cancelInvocations(connectionID: fixture.connection.connectionID)
        let draining = await fixture.runtime.domainHost.drain(timeout: Duration.milliseconds(10))
        XCTAssertTrue(draining.deadlineExpired)
        XCTAssertFalse(draining.callerCancelled)
        XCTAssertEqual(draining.detachedInvocationCount, 1)

        let rejectedID = UUID()
        do {
            _ = try await fixture.runtime.domainHost.invoke(MCPDomainHostInvocation(
                invocationID: rejectedID,
                connectionID: fixture.connection.connectionID,
                resolution: resolution,
                arguments: [:],
                securityContext: securityContext(
                    identity: fixture.runtime.identity,
                    connection: fixture.connection,
                    invocationID: rejectedID
                )
            ))
            XCTFail("Draining host accepted a new invocation")
        } catch let error as MCPDomainHostError {
            XCTAssertEqual(error, .draining)
        }

        await blocker.resume()
        _ = try await task.value
        let final = await fixture.runtime.domainHost.snapshot()
        XCTAssertEqual(final.lifecycle, MCPDomainHostLifecycle.drained)
        XCTAssertEqual(final.activeInvocationCount, 0)
    }

    func testDrainRacingSuspendedAdmissionRejectsLateInvocation() async throws {
        let admissionGate = InvocationBlocker()
        let fixture = try await makeFixture()
        let host = MCPDomainHost(
            identity: fixture.runtime.identity,
            registry: fixture.runtime.toolRegistry,
            routingCoordinator: fixture.runtime.routingCoordinator,
            beforeFinalAdmission: { await admissionGate.wait() }
        )
        let resolution = try await host.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: MCPDomainToolRegistrationScope.window(id: 1)
        )
        let invocationID = UUID()
        let invocation = MCPDomainHostInvocation(
            invocationID: invocationID,
            connectionID: fixture.connection.connectionID,
            resolution: resolution,
            arguments: [:],
            securityContext: securityContext(
                identity: fixture.runtime.identity,
                connection: fixture.connection,
                invocationID: invocationID
            )
        )
        let invocationTask = Task {
            try await host.invoke(invocation)
        }
        await admissionGate.awaitStarted()

        let drain = await host.drain(timeout: .milliseconds(25))
        XCTAssertFalse(drain.deadlineExpired)
        XCTAssertFalse(drain.callerCancelled)
        XCTAssertEqual(drain.detachedInvocationCount, 0)
        await admissionGate.resume()

        do {
            _ = try await invocationTask.value
            XCTFail("Invocation crossed the final admission fence after drain")
        } catch let error as MCPDomainHostError {
            XCTAssertEqual(error, .draining)
        }
        let snapshot = await host.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .drained)
        XCTAssertEqual(snapshot.activeInvocationCount, 0)
    }

    func testCancelledDrainCallerReturnsWithoutSpinning() async throws {
        let blocker = InvocationBlocker()
        let fixture = try await makeFixture(binding: Self.binding { arguments in
            await blocker.wait()
            return arguments["path"] ?? .string("settled")
        })
        let resolution = try await fixture.runtime.domainHost.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: MCPDomainToolRegistrationScope.window(id: 1)
        )
        let invocationID = UUID()
        let invocation = MCPDomainHostInvocation(
            invocationID: invocationID,
            connectionID: fixture.connection.connectionID,
            resolution: resolution,
            arguments: [:],
            securityContext: securityContext(
                identity: fixture.runtime.identity,
                connection: fixture.connection,
                invocationID: invocationID
            )
        )
        let host = fixture.runtime.domainHost
        let invocationTask = Task {
            try await host.invoke(invocation)
        }
        await blocker.awaitStarted()
        await fixture.runtime.domainHost.beginDrain()

        let clock = ContinuousClock()
        let startedAt = clock.now
        let drainTask = Task {
            await fixture.runtime.domainHost.drain(timeout: .seconds(5))
        }
        drainTask.cancel()
        let drain = await drainTask.value
        XCTAssertTrue(drain.callerCancelled)
        XCTAssertFalse(drain.deadlineExpired)
        XCTAssertEqual(drain.detachedInvocationCount, 1)
        XCTAssertLessThan(startedAt.duration(to: clock.now), .milliseconds(250))

        await blocker.resume()
        _ = try await invocationTask.value
    }

    private struct Fixture {
        let runtime: MCPDomainRuntime
        let connection: DomainConnectionRegistration
        let registrationID: MCPDomainToolRegistrationID
    }

    private func makeFixture(
        binding: MCPDomainToolBinding = MCPDomainHostTests.binding()
    ) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-domain-host-\(UUID().uuidString)", isDirectory: true)
        let runtime = MCPDomainRuntime(
            configuration: .init(
                mode: .standalone,
                profileIdentifier: "host-test",
                storageDirectory: directory,
                eventDirectory: directory,
                temporaryDirectory: directory,
                externalReloadInterval: nil,
                hostDrainTimeout: .milliseconds(25)
            )
        )
        try await runtime.start()
        let registrationID = MCPDomainToolRegistrationID()
        _ = try await runtime.toolRegistry.register(
            registrationID: registrationID,
            scope: MCPDomainToolRegistrationScope.window(id: 1),
            bindings: [binding]
        )
        let connectionID = UUID()
        _ = await runtime.routingCoordinator.registerConnection(
            connectionID: connectionID,
            operationID: UUID()
        )
        let connection = try await runtime.routingCoordinator.currentRegistration(
            connectionID: connectionID
        )
        return Fixture(
            runtime: runtime,
            connection: connection,
            registrationID: registrationID
        )
    }

    private static func binding(
        description: String = "host fixture",
        operation: @Sendable @escaping ([String: Value]) async throws -> Value = { arguments in
            arguments["path"] ?? .string("ok")
        }
    ) -> MCPDomainToolBinding {
        MCPDomainToolBinding(
            definition: MCPDomainToolDefinition(
                name: MCPWindowToolName.readFile,
                description: description,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            ),
            operation: operation
        )
    }

    private func securityContext(
        identity: DomainRuntimeIdentity,
        connection: DomainConnectionRegistration,
        invocationID: UUID
    ) -> DomainToolInvocationSecurityContext {
        DomainToolInvocationSecurityContext(
            principal: DomainClientPrincipal(
                principalID: connection.connectionID,
                stableKey: "host-test",
                displayName: "Host Test",
                kind: .appProxy,
                assurance: .verifiedProcess,
                processID: 42,
                runID: nil,
                provider: nil,
                verifiedIdentityFingerprint: "fixture"
            ),
            connectionID: connection.connectionID,
            connectionGeneration: connection.generation,
            invocationID: invocationID,
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            hasAuthoritativeRoutingContext: false,
            ephemeralGrantedToolNames: [MCPWindowToolName.readFile]
        )
    }
}

private actor InvocationBlocker {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation = $0 }
    }

    func awaitStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
