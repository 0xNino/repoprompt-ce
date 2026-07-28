import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainAgentRunSessionStoreTests: XCTestCase {
    func testRuntimeGenerationEpochContinuityAndTerminalCommitAreFenced() async throws {
        let fixture = makeStoreFixture()
        let store = fixture.store
        let sessionID = UUID()
        let registration = await store.register(sessionID: sessionID)
        let initial = try acceptedEpoch(await store.beginEpoch(
            registration: registration,
            activationID: UUID(),
            expectedCurrentEpoch: nil,
            transitionKind: .initial
        ))
        let unrelated = try acceptedEpoch(await store.beginEpoch(
            registration: registration,
            activationID: initial.activationID,
            expectedCurrentEpoch: initial,
            transitionKind: .unrelated
        ))
        XCTAssertEqual(unrelated.ordinal, initial.ordinal + 1)
        XCTAssertEqual(unrelated.continuityGeneration, initial.continuityGeneration + 1)
        XCTAssertEqual(unrelated.runtimeID, fixture.identity.runtimeID)
        XCTAssertEqual(unrelated.runtimeGeneration, fixture.identity.lifecycleGeneration)

        let terminal = makeSnapshot(sessionID: sessionID, status: .completed)
        let commitID = UUID()
        let accepted = await store.publishTerminal(
            .init(epoch: unrelated, snapshot: terminal),
            registration: registration,
            commitID: commitID,
            successorKind: nil
        )
        XCTAssertEqual(accepted, .accepted(successorEpoch: nil))
        let duplicate = await store.publishTerminal(
            .init(epoch: unrelated, snapshot: terminal),
            registration: registration,
            commitID: commitID,
            successorKind: nil
        )
        XCTAssertEqual(duplicate, .accepted(successorEpoch: nil))
        let conflict = await store.publishTerminal(
            .init(epoch: unrelated, snapshot: terminal),
            registration: registration,
            commitID: UUID(),
            successorKind: nil
        )
        XCTAssertEqual(conflict, .rejected(reason: "different_commit_already_published"))

        let staleRuntime = DomainAgentSessionRegistration(
            runtimeID: UUID(),
            runtimeGeneration: registration.runtimeGeneration,
            sessionID: sessionID,
            generation: registration.generation
        )
        let staleCursor = await store.currentCursor(for: staleRuntime)
        XCTAssertNil(staleCursor)
        _ = await store.shutdown(deadline: .milliseconds(20))
    }

    func testParkedWaitCancellationAndShutdownDeadlineAreBounded() async throws {
        let fixture = makeStoreFixture()
        let store = fixture.store
        let cancelledRegistration = await store.register(sessionID: UUID())
        let cursor = DomainAgentSessionWaitCursor(registration: cancelledRegistration, epoch: nil)
        let waiter = Task {
            await store.waitUntilInteresting(cursor: cursor, timeoutSeconds: 10)
        }
        while await store.test_waiterCount(registration: cancelledRegistration) == 0 {
            await Task.yield()
        }
        waiter.cancel()
        let cancelledDisposition = await waiter.value
        XCTAssertEqual(cancelledDisposition, .cancelled)

        let interruptedRegistration = await store.register(sessionID: UUID())
        await store.installCancellationHandler(registration: interruptedRegistration) {
            try? await Task.sleep(for: .milliseconds(150))
        }
        let clock = ContinuousClock()
        let started = clock.now
        let result = await store.shutdown(deadline: .milliseconds(20))
        let elapsed = started.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .milliseconds(120))
        XCTAssertTrue(result.interruptedSessionIDs.contains(interruptedRegistration.sessionID))
        let remainsActive = await store.hasActiveRegistration(sessionID: interruptedRegistration.sessionID)
        XCTAssertFalse(remainsActive)
    }

    func testRestartRestoresMetadataDormantAndRequiresExplicitResumeClaim() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstIdentity = makeIdentity(runtimeID: UUID(), generation: 4)
        let first = DomainAgentRunSessionStore(identity: firstIdentity, storageDirectory: root)
        await first.bootstrap()
        let sessionID = UUID()
        let registration = await first.register(sessionID: sessionID)
        _ = await first.beginEpoch(
            registration: registration,
            activationID: UUID(),
            expectedCurrentEpoch: nil,
            transitionKind: .initial
        )
        _ = await first.shutdown(deadline: .milliseconds(10))

        let secondIdentity = makeIdentity(runtimeID: UUID(), generation: 5)
        let second = DomainAgentRunSessionStore(identity: secondIdentity, storageDirectory: root)
        await second.bootstrap()
        let restoredActive = await second.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(restoredActive)
        let restoredMetadata = await second.restoredMetadata()
        let restored = try XCTUnwrap(restoredMetadata.first(where: { $0.sessionID == sessionID }))
        XCTAssertFalse(restored.isLive)
        XCTAssertEqual(restored.state, .dormant)
        guard case let .accepted(claim) = await second.claimResumableSession(sessionID: sessionID) else {
            return XCTFail("Expected an explicit resumable claim")
        }
        XCTAssertEqual(claim.runtimeID, secondIdentity.runtimeID)
        XCTAssertEqual(claim.runtimeGeneration, secondIdentity.lifecycleGeneration)
        XCTAssertNotEqual(claim, registration)
        let claimedActive = await second.hasActiveRegistration(sessionID: sessionID)
        XCTAssertTrue(claimedActive)
        _ = await second.shutdown(deadline: .milliseconds(10))
    }

    private func acceptedEpoch(
        _ result: DomainAgentRunSessionStore.EpochBeginResult
    ) throws -> DomainAgentRunTurnEpoch {
        guard case let .accepted(epoch) = result else {
            throw TestError.expectedAcceptedEpoch
        }
        return epoch
    }
}

final class DomainInteractionBrokerTests: XCTestCase {
    func testNegotiatedElicitationPrecedesAppUIAndImmediateCompletionIsNotLost() async {
        let broker = DomainInteractionBroker()
        let recorder = InvocationRecorder()
        await broker.installNegotiatedElicitationProvider(DomainInteractionProvider(
            kind: .elicitation,
            present: { _ in
                await recorder.record("elicitation")
                return .string("elicited")
            }
        ))
        let request = DomainInteractionRequest(
            toolName: "ask_user",
            payload: [:],
            deadline: Date().addingTimeInterval(1)
        )
        let result = await broker.request(
            request,
            appUI: DomainInteractionProvider(kind: .appUI) { _ in
                await recorder.record("app")
                return .string("app")
            }
        )
        XCTAssertEqual(result, .response(.string("elicited"), provider: .elicitation))
        let calls = await recorder.values()
        let brokerSnapshot = await broker.snapshot()
        XCTAssertEqual(calls, ["elicitation"])
        XCTAssertTrue(brokerSnapshot.pendingRequestIDs.isEmpty)
    }

    func testTimeoutCancelsProviderOnceAndIgnoresLateResponse() async {
        let broker = DomainInteractionBroker()
        let recorder = InvocationRecorder()
        let provider = DomainInteractionProvider(
            kind: .appUI,
            present: { _ in
                try? await Task.sleep(for: .milliseconds(80))
                return .string("late")
            },
            cancel: { _ in await recorder.record("cancel") }
        )
        let result = await broker.request(
            .init(
                toolName: "ask_user",
                payload: [:],
                deadline: Date().addingTimeInterval(0.02)
            ),
            appUI: provider
        )
        XCTAssertEqual(result, .timedOut)
        try? await Task.sleep(for: .milliseconds(30))
        let cancellationCalls = await recorder.values()
        let brokerSnapshot = await broker.snapshot()
        XCTAssertEqual(cancellationCalls, ["cancel"])
        XCTAssertGreaterThanOrEqual(brokerSnapshot.ignoredLateResponseCount, 1)
        let unavailable = await broker.request(
            .init(toolName: "ask_user", payload: [:], deadline: Date().addingTimeInterval(1))
        )
        XCTAssertEqual(unavailable, .unavailable)
    }

    func testCallerCancellationSettlesOnceAndLateProviderResponseCannotResurrectRequest() async {
        let broker = DomainInteractionBroker()
        let recorder = InvocationRecorder()
        let request = DomainInteractionRequest(
            toolName: "ask_user",
            payload: [:],
            deadline: Date().addingTimeInterval(1)
        )
        let task = Task {
            await broker.request(
                request,
                appUI: DomainInteractionProvider(
                    kind: .appUI,
                    present: { _ in
                        try? await Task.sleep(for: .milliseconds(80))
                        return .string("late")
                    },
                    cancel: { _ in await recorder.record("cancel") }
                )
            )
        }
        while await broker.snapshot().pendingRequestIDs.isEmpty {
            await Task.yield()
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        try? await Task.sleep(for: .milliseconds(30))
        let cancellationCalls = await recorder.values()
        let snapshot = await broker.snapshot()
        XCTAssertEqual(cancellationCalls, ["cancel"])
        XCTAssertTrue(snapshot.pendingRequestIDs.isEmpty)
        XCTAssertGreaterThanOrEqual(snapshot.ignoredLateResponseCount, 1)
    }
}

final class DomainCredentialAndChildLaunchTests: XCTestCase {
    func testCredentialEnvelopeIsMinimumScopeSingleUseAndRedacted() async throws {
        let identity = makeIdentity()
        let store = DomainCredentialEnvelopeStore(identity: identity)
        let scope = DomainCredentialScope(
            providerIdentifier: "codex",
            runID: UUID(),
            principalID: UUID(),
            purpose: "agent_run"
        )
        let descriptor = try await store.issue(bytes: [1, 2, 3, 4], scope: scope)
        let wrongScope = DomainCredentialScope(
            providerIdentifier: "claude",
            runID: scope.runID,
            principalID: scope.principalID,
            purpose: scope.purpose
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await store.redeem(descriptor, scope: wrongScope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .scopeMismatch)
        }
        let payload = try await store.redeem(descriptor, scope: scope)
        XCTAssertEqual(payload.bytes, [1, 2, 3, 4])
        XCTAssertEqual(payload.description, "<redacted credential payload: 4 bytes>")
        await XCTAssertThrowsErrorAsync {
            _ = try await store.redeem(descriptor, scope: scope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .alreadyConsumed)
        }

        let revoked = try await store.issue(bytes: [5], scope: scope)
        await store.revoke(revoked.envelopeID)
        await XCTAssertThrowsErrorAsync {
            _ = try await store.redeem(revoked, scope: scope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .revoked)
        }
        let expired = try await store.issue(bytes: [6], scope: scope, lifetime: .zero)
        await XCTAssertThrowsErrorAsync {
            _ = try await store.redeem(expired, scope: scope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .expired)
        }
        let shutdown = try await store.issue(bytes: [7], scope: scope)
        await store.shutdown()
        await XCTAssertThrowsErrorAsync {
            _ = try await store.redeem(shutdown, scope: scope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .revoked)
        }
    }

    func testInjectedPrivateChildHarnessCarriesSingleUseTokenAndEnvelopeReference() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = MCPDomainRuntime(
            configuration: .init(
                mode: .standalone,
                profileIdentifier: "m5-child-harness",
                storageDirectory: root,
                eventDirectory: root.appendingPathComponent("Events"),
                temporaryDirectory: root.appendingPathComponent("Temporary"),
                externalReloadInterval: nil
            ),
            lifecycleGeneration: 7
        )
        try await runtime.start()
        let workspaceID = UUID()
        let contextID = UUID()
        let documentURL = root.appendingPathComponent("child-harness-workspace.json")
        let documentObject: [String: Any] = [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "M5 Child Harness",
            "repoPaths": [root.path],
            "isSystemWorkspace": false,
            "isHiddenInMenus": false,
            "activeComposeTabID": contextID.uuidString,
            "composeTabs": [[
                "id": contextID.uuidString,
                "name": "Context",
                "prompt": ""
            ]]
        ]
        let documentBytes = try JSONSerialization.data(withJSONObject: documentObject, options: [.sortedKeys])
        let document = try DomainWorkspaceDocument.decode(
            documentBytes: documentBytes,
            fileURL: documentURL
        )
        let created = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(document)
        ))
        XCTAssertEqual(created.disposition, .applied)
        let harness = DomainPrivateChildLaunchHarness(
            endpointDescriptor: "injected-private-child://fixture",
            credentialStore: runtime.credentialEnvelopeStore
        ) { request in
            try await runtime.routingCoordinator.issueLaunchToken(request)
        }
        let request = DomainRunLaunchReservationRequest(
            runID: UUID(),
            context: .init(workspaceID: workspaceID, contextID: contextID),
            expectedContextRevision: 1,
            windowID: nil,
            clientPrincipal: "agent",
            providerIdentifier: "codex",
            runPurpose: "explore"
        )
        let scope = DomainCredentialScope(
            providerIdentifier: "codex",
            runID: request.runID,
            principalID: UUID(),
            purpose: "explore"
        )
        let carrier = try await harness.prepare(
            request: request,
            credential: (bytes: [7, 8], scope: scope)
        )
        XCTAssertEqual(
            carrier.environment[DomainChildLaunchCarrier.endpointEnvironmentKey],
            "injected-private-child://fixture"
        )
        XCTAssertFalse(
            carrier.environment[DomainChildLaunchCarrier.launchTokenEnvironmentKey]?.isEmpty ?? true
        )
        XCTAssertEqual(
            carrier.environment[DomainChildLaunchCarrier.credentialEnvelopeEnvironmentKey],
            carrier.credentialEnvelope?.envelopeID.uuidString
        )
        let descriptor = try XCTUnwrap(carrier.credentialEnvelope)
        let payload = try await runtime.credentialEnvelopeStore.redeem(descriptor, scope: scope)
        XCTAssertEqual(payload.bytes, [7, 8])
        await XCTAssertThrowsErrorAsync {
            _ = try await runtime.credentialEnvelopeStore.redeem(descriptor, scope: scope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .alreadyConsumed)
        }
        let material = try XCTUnwrap(
            carrier.environment[DomainChildLaunchCarrier.launchTokenEnvironmentKey]
        )
        let accepted = await runtime.routingCoordinator.redeemLaunchToken(
            material: material,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: runtime.identity.lifecycleGeneration,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: request.clientPrincipal,
            providerIdentifier: request.providerIdentifier
        )
        guard case .accepted = accepted else {
            return XCTFail("Injected harness token was not accepted: \(accepted)")
        }
        let replay = await runtime.routingCoordinator.redeemLaunchToken(
            material: material,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: runtime.identity.lifecycleGeneration,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: request.clientPrincipal,
            providerIdentifier: request.providerIdentifier
        )
        XCTAssertEqual(replay, .alreadyConsumed)
        _ = await runtime.shutdown()
    }
}

final class DomainActivityAndLongRunningProviderTests: XCTestCase {
    func testActivityPublicationIsMonotonicAndTerminalCommitIsExactlyOnce() async throws {
        let center = DomainActivityCenter(identity: makeIdentity(), terminalLimit: 2)
        let startedToken = await center.begin(kind: .oracle, toolName: "ask_oracle")
        let token = try XCTUnwrap(startedToken)
        let initial = await center.snapshot()
        XCTAssertEqual(initial.publicationSequence, 1)
        let update = await center.update(token, state: .waitingForInteraction)
        XCTAssertEqual(update, .accepted)
        let commitID = UUID()
        let finish = await center.finish(token, state: .completed, commitID: commitID)
        let duplicate = await center.finish(token, state: .completed, commitID: commitID)
        let conflict = await center.finish(token, state: .failed, commitID: UUID())
        XCTAssertEqual(finish, .accepted)
        XCTAssertEqual(duplicate, .duplicateTerminal)
        XCTAssertEqual(conflict, .rejectedTerminalConflict)
        let terminal = await center.snapshot()
        XCTAssertEqual(terminal.publicationSequence, 3)
        XCTAssertTrue(terminal.active.isEmpty)
        XCTAssertEqual(terminal.recentTerminal.first?.state, .completed)
        await center.shutdown()
        let afterShutdown = await center.begin(kind: .agentRun, toolName: "agent_run")
        XCTAssertNil(afterShutdown)
    }

    func testLongRunningProviderPreservesSchemaRequiresApprovalAndCarriesInjectedLaunch() async throws {
        let runtime = makeRuntime(mode: .app)
        try await runtime.start()
        defer { Task { await runtime.shutdown() } }
        let recorder = InvocationRecorder()
        let carrier = DomainChildLaunchCarrier(
            runID: UUID(),
            launchTokenID: UUID(),
            credentialEnvelope: nil,
            environment: [
                DomainChildLaunchCarrier.endpointEnvironmentKey: "injected://child",
                DomainChildLaunchCarrier.launchTokenEnvironmentKey: "token"
            ]
        )
        let provider = MCPDomainLongRunningToolProvider(
            identity: runtime.identity,
            policyStore: runtime.mutationPolicyStore,
            interactionBroker: runtime.interactionBroker,
            activityCenter: runtime.activityCenter,
            prepareChildLaunch: { _, _, _ in carrier }
        )
        let definition = MCPDomainToolDefinition(
            name: "ask_oracle",
            description: "unchanged fixture",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["message": .object(["type": .string("string")])])
            ]),
            annotations: .init(readOnlyHint: false, openWorldHint: true)
        )
        let binding = MCPDomainToolBinding(definition: definition) { _ in
            let launch = DomainChildLaunchContext.current
            await recorder.record(launch?.environment[DomainChildLaunchCarrier.launchTokenEnvironmentKey] ?? "missing")
            return .string("ok")
        }
        let wrapped = provider.wrapping(binding)
        XCTAssertEqual(wrapped.definition, definition)

        do {
            _ = try await wrapped(["message": .string("hello")])
            XCTFail("Unattributed AI work must fail closed")
        } catch {}
        let deniedCalls = await recorder.values()
        XCTAssertTrue(deniedCalls.isEmpty)

        let security = makeRunSecurityContext(
            identity: runtime.identity,
            grantedTools: ["ask_oracle"],
            hasAuthoritativeRoutingContext: false
        )
        let value = try await MCPDomainInvocationSecurityContext.$current.withValue(security) {
            try await wrapped(["message": .string("hello")])
        }
        XCTAssertEqual(value, .string("ok"))
        let successfulCalls = await recorder.values()
        XCTAssertEqual(successfulCalls, ["token"])
        let activities = await runtime.activityCenter.snapshot()
        XCTAssertTrue(activities.active.isEmpty)
        XCTAssertEqual(activities.recentTerminal.map(\.state), [.completed, .failed])
    }

    func testLongRunningProviderCoversFrozenFamiliesAndInteractionFallbackOrder() async throws {
        XCTAssertEqual(MCPDomainLongRunningToolProvider.migratedToolNames, [
            "oracle_utils",
            "ask_oracle",
            "oracle_send",
            "context_builder",
            "ask_user",
            "agent_explore",
            "agent_run",
            "agent_manage",
            "share_thoughts",
            "set_status",
            "wait_for_next_user_instruction"
        ])
        let runtime = makeRuntime(mode: .standalone)
        try await runtime.start()
        let appRecorder = InvocationRecorder()
        let binding = MCPDomainToolBinding(
            definition: .init(
                name: "ask_user",
                description: "frozen ask-user fixture",
                inputSchema: .object(["type": .string("object")])
            )
        ) { _ in
            await appRecorder.record("app")
            return .string("app")
        }
        let wrapped = runtime.longRunningToolProvider.wrapping(
            binding,
            interactionUIAvailable: false
        )
        await runtime.interactionBroker.installNegotiatedElicitationProvider(
            DomainInteractionProvider(kind: .elicitation) { _ in .string("elicitation") }
        )
        let elicited = try await wrapped(["questions": .array([]), "timeout_seconds": .int(1)])
        XCTAssertEqual(elicited, .string("elicitation"))
        let appCallsAfterElicitation = await appRecorder.values()
        XCTAssertTrue(appCallsAfterElicitation.isEmpty)

        await runtime.interactionBroker.installNegotiatedElicitationProvider(nil)
        do {
            _ = try await wrapped(["questions": .array([]), "timeout_seconds": .int(1)])
            XCTFail("Missing elicitation and app UI must fail immediately")
        } catch {
            XCTAssertTrue(String(describing: error).contains("interaction_unavailable"))
        }
        let appCallsAfterUnavailable = await appRecorder.values()
        XCTAssertTrue(appCallsAfterUnavailable.isEmpty)
        _ = await runtime.shutdown()
    }
}

private enum TestError: Error {
    case expectedAcceptedEpoch
}

private actor InvocationRecorder {
    private var recorded: [String] = []

    func record(_ value: String) {
        recorded.append(value)
    }

    func values() -> [String] {
        recorded
    }
}

private func makeStoreFixture() -> (
    identity: DomainRuntimeIdentity,
    store: DomainAgentRunSessionStore
) {
    let identity = makeIdentity()
    return (
        identity,
        DomainAgentRunSessionStore(identity: identity, storageDirectory: temporaryDirectory())
    )
}

private func makeIdentity(
    runtimeID: UUID = UUID(),
    generation: UInt64 = 1,
    mode: DomainRuntimeMode = .standalone
) -> DomainRuntimeIdentity {
    DomainRuntimeIdentity(
        runtimeID: runtimeID,
        lifecycleGeneration: generation,
        processID: 42,
        mode: mode,
        createdAt: Date()
    )
}

private func makeRuntime(mode: DomainRuntimeMode) -> MCPDomainRuntime {
    let root = temporaryDirectory()
    return MCPDomainRuntime(
        configuration: .init(
            mode: mode,
            profileIdentifier: "m5-owner-test",
            storageDirectory: root,
            eventDirectory: root.appendingPathComponent("Events"),
            temporaryDirectory: root.appendingPathComponent("Temporary"),
            externalReloadInterval: nil,
            protectedMutationStage: .m4B
        )
    )
}

private func makeRunSecurityContext(
    identity: DomainRuntimeIdentity,
    grantedTools: Set<String>,
    hasAuthoritativeRoutingContext: Bool
) -> DomainToolInvocationSecurityContext {
    DomainToolInvocationSecurityContext(
        principal: .init(
            principalID: UUID(),
            stableKey: "agent",
            displayName: "Agent",
            kind: .runScoped,
            assurance: .verifiedProcess,
            processID: identity.processID,
            runID: UUID(),
            provider: "fixture",
            verifiedIdentityFingerprint: "fixture"
        ),
        connectionID: UUID(),
        connectionGeneration: 1,
        invocationID: UUID(),
        runtimeID: identity.runtimeID,
        runtimeGeneration: identity.lifecycleGeneration,
        hasAuthoritativeRoutingContext: hasAuthoritativeRoutingContext,
        ephemeralGrantedToolNames: grantedTools
    )
}

private func makeSnapshot(
    sessionID: UUID,
    status: DomainAgentRunSnapshot.Status
) -> DomainAgentRunSnapshot {
    DomainAgentRunSnapshot(
        sessionID: sessionID,
        tabID: nil,
        sessionName: "Fixture",
        agentRaw: "codex",
        agentDisplayName: "Codex",
        modelRaw: "fixture",
        reasoningEffortRaw: nil,
        status: status,
        statusText: status.rawValue,
        latestAssistantPreview: nil,
        interaction: nil,
        transcriptItemCount: 1,
        updatedAt: Date(),
        parentSessionID: nil,
        failureReason: nil,
        worktreeBindings: [],
        activeWorktreeMerges: []
    )
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("repoprompt-m5-\(UUID().uuidString)", isDirectory: true)
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
