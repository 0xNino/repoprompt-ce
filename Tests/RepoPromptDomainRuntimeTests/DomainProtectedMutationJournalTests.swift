import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainProtectedMutationJournalTests: XCTestCase {
    func testInternalMutationKeyReplaysWhilePublicCorrelationIDCanBeReused() async throws {
        let fixture = try M4BFixture()
        let calls = MutationCounter()
        let binding = fixture.binding { _ in
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            return .string("applied")
        }
        let arguments = fixture.arguments(operationID: "correlation-1")

        let first = try await fixture.invoke(binding, arguments: arguments, requestIdentitySeed: "request-1")
        let replay = try await fixture.invoke(
            binding,
            arguments: arguments,
            workspaceRevision: 8,
            requestIdentitySeed: "request-1"
        )
        XCTAssertEqual(first.stringValue, "applied")
        XCTAssertEqual(replay.stringValue, "applied")
        let callsAfterReplay = await calls.value
        XCTAssertEqual(callsAfterReplay, 1)

        var reusedCorrelation = arguments
        reusedCorrelation["content"] = .string("different")
        let distinctRequest = try await fixture.invoke(
            binding,
            arguments: reusedCorrelation,
            requestIdentitySeed: "request-2"
        )
        XCTAssertEqual(distinctRequest.stringValue, "applied")
        let callsAfterDistinctRequest = await calls.value
        XCTAssertEqual(callsAfterDistinctRequest, 2)

        await XCTAssertThrowsErrorAsync(
            try await fixture.invoke(
                binding,
                arguments: reusedCorrelation,
                requestIdentitySeed: "request-1"
            )
        ) { error in
            XCTAssertEqual(error as? DomainMutationJournalError, .operationIDCollision("correlation-1"))
        }
        let callsAfterCollision = await calls.value
        XCTAssertEqual(callsAfterCollision, 2)
    }

    func testRootAndSymlinkFencesApplyAtAdmissionAndPrecommit() async throws {
        let fixture = try M4BFixture()
        let outside = fixture.storage.appendingPathComponent("outside", isDirectory: true)
        let safe = fixture.root.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        let link = fixture.root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let calls = MutationCounter()
        let neverCalled = fixture.binding { _ in
            await calls.increment()
            return .string("unexpected")
        }

        await XCTAssertThrowsErrorAsync(
            try await fixture.invoke(
                neverCalled,
                arguments: fixture.arguments(operationID: "outside", path: link.appendingPathComponent("file.txt").path)
            )
        ) { error in
            XCTAssertTrue(error is DomainMutationPathFenceError)
        }
        let callsAfterAdmission = await calls.value
        XCTAssertEqual(callsAfterAdmission, 0)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: safe)
        let swapped = fixture.binding { _ in
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            return .string("unexpected")
        }
        await XCTAssertThrowsErrorAsync(
            try await fixture.invoke(
                swapped,
                arguments: fixture.arguments(operationID: "swap", path: link.appendingPathComponent("file.txt").path)
            )
        ) { error in
            XCTAssertEqual(error as? DomainMutationPathFenceError, .pathResolutionChanged(link.appendingPathComponent("file.txt").path))
        }
        let callsAfterPrecommit = await calls.value
        XCTAssertEqual(callsAfterPrecommit, 0)
    }

    func testLogicalRootMappingFencesTranslatedPhysicalWorktreeTarget() async throws {
        let fixture = try M4BFixture()
        let worktreeRoot = fixture.storage.appendingPathComponent("bound-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let physicalTarget = worktreeRoot.appendingPathComponent("Sources/Translated.swift").path
        let binding = fixture.binding(rootMappings: [
            DomainMutationPhysicalRootMapping(
                canonicalRoot: fixture.root.path,
                physicalRoot: worktreeRoot.path
            ),
        ]) { _ in
            try await MCPDomainMutationCommitContext.willCommit()
            return .string("translated")
        }

        let result = try await fixture.invoke(
            binding,
            arguments: fixture.arguments(
                operationID: "translated-correlation",
                path: physicalTarget
            ),
            requestIdentitySeed: "translated-request"
        )
        XCTAssertEqual(result.stringValue, "translated")
        let snapshot = try await fixture.runtime.mutationJournal.snapshot()
        let record = snapshot.records["file_actions.create:request:translated-request"]
        XCTAssertEqual(record?.pathFence?.entries.first?.requestedPath, physicalTarget)
        XCTAssertEqual(record?.pathFence?.coveredRoots, [worktreeRoot.standardizedFileURL.path])
    }

    func testNonexistentParentIdentitySwapFailsImmediatelyBeforeCommit() async throws {
        let fixture = try M4BFixture()
        let parent = fixture.root.appendingPathComponent("existing-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("missing/created.txt").path
        let calls = MutationCounter()
        let binding = fixture.binding { _ in
            try FileManager.default.removeItem(at: parent)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            return .string("unexpected")
        }

        await XCTAssertThrowsErrorAsync(
            try await fixture.invoke(
                binding,
                arguments: fixture.arguments(operationID: "parent-swap", path: target),
                requestIdentitySeed: "parent-swap-request"
            )
        ) { error in
            XCTAssertTrue(error is DomainMutationPathFenceError)
        }
        let callsAfterParentSwap = await calls.value
        XCTAssertEqual(callsAfterParentSwap, 0)
    }

    func testCancellationBeforeCommitIsSafeToRetry() async throws {
        let fixture = try M4BFixture()
        let gate = MutationGate()
        let behavior = MutationAttemptBehavior()
        let calls = MutationCounter()
        let binding = fixture.binding { _ in
            if await behavior.next() == 1 {
                try await gate.wait()
            }
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            return .string("retried")
        }
        let arguments = fixture.arguments(operationID: "cancel-before")
        let task = Task {
            try await fixture.invoke(binding, arguments: arguments, requestIdentitySeed: "cancel-before-request")
        }
        await gate.waitUntilEntered()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        let snapshot = try await fixture.runtime.mutationJournal.snapshot()
        XCTAssertEqual(
            snapshot.records["file_actions.create:request:cancel-before-request"]?.status,
            .cancelledBeforeCommit
        )
        let retry = try await fixture.invoke(
            binding,
            arguments: arguments,
            requestIdentitySeed: "cancel-before-request"
        )
        XCTAssertEqual(retry.stringValue, "retried")
        let callsAfterRetry = await calls.value
        XCTAssertEqual(callsAfterRetry, 1)
    }

    func testCancellationAfterCommitIsIndeterminateAcrossRestart() async throws {
        let fixture = try M4BFixture()
        let gate = MutationGate()
        let calls = MutationCounter()
        let binding = fixture.binding { _ in
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            try await gate.wait()
            return .string("late")
        }
        let arguments = fixture.arguments(operationID: "cancel-after")
        let task = Task {
            try await fixture.invoke(binding, arguments: arguments, requestIdentitySeed: "cancel-after-request")
        }
        await gate.waitUntilEntered()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected partial-success error")
        } catch let error as DomainProtectedMutationError {
            XCTAssertEqual(error, .partialSuccessAfterCommit(operationID: "cancel-after"))
        }
        let callsAfterCommit = await calls.value
        XCTAssertEqual(callsAfterCommit, 1)

        let restarted = try M4BFixture(storage: fixture.storage, root: fixture.root)
        let restartedCalls = MutationCounter()
        let restartedBinding = restarted.binding { _ in
            await restartedCalls.increment()
            return .string("duplicate")
        }
        await XCTAssertThrowsErrorAsync(
            try await restarted.invoke(
                restartedBinding,
                arguments: arguments,
                requestIdentitySeed: "cancel-after-request"
            )
        ) { error in
            XCTAssertEqual(error as? DomainMutationJournalError, .interruptedCommit("cancel-after"))
        }
        let callsAfterRestart = await restartedCalls.value
        XCTAssertEqual(callsAfterRestart, 0)
    }

    func testNWriterContentionUsesOneOwnerThenReplays() async throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4b-n-writer-\(UUID().uuidString)", isDirectory: true)
        let root = storage.appendingPathComponent("root", isDirectory: true)
        let first = try M4BFixture(storage: storage, root: root)
        let second = try M4BFixture(storage: storage, root: root)
        let gate = MutationGate()
        let calls = MutationCounter()
        let firstBinding = first.binding { _ in
            try await gate.wait()
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            return .string("winner")
        }
        let secondBinding = second.binding { _ in
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            return .string("duplicate")
        }
        let arguments = first.arguments(operationID: "n-writer")
        let owner = Task {
            try await first.invoke(firstBinding, arguments: arguments, requestIdentitySeed: "n-writer-request")
        }
        await gate.waitUntilEntered()

        await XCTAssertThrowsErrorAsync(
            try await second.invoke(
                secondBinding,
                arguments: arguments,
                requestIdentitySeed: "n-writer-request"
            )
        ) { error in
            XCTAssertEqual(error as? DomainMutationJournalError, .operationInProgress("n-writer"))
        }
        await gate.release()
        let ownerResult = try await owner.value
        XCTAssertEqual(ownerResult.stringValue, "winner")
        let replay = try await second.invoke(
            secondBinding,
            arguments: arguments,
            requestIdentitySeed: "n-writer-request"
        )
        XCTAssertEqual(replay.stringValue, "winner")
        let callsAfterContention = await calls.value
        XCTAssertEqual(callsAfterContention, 1)
    }
}

private final class M4BFixture: @unchecked Sendable {
    let runtime: MCPDomainRuntime
    let storage: URL
    let root: URL

    init(storage: URL? = nil, root: URL? = nil) throws {
        let storage = storage ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("m4b-runtime-\(UUID().uuidString)", isDirectory: true)
        let root = root ?? storage.appendingPathComponent("root", isDirectory: true)
        self.storage = storage
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        runtime = MCPDomainRuntime(
            configuration: .init(
                mode: .app,
                profileIdentifier: "m4b-test",
                storageDirectory: storage,
                eventDirectory: storage.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storage.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil,
            ),
            runtimeID: UUID(),
            lifecycleGeneration: 1,
            processID: 42
        )
    }

    func arguments(operationID: String, path: String? = nil) -> [String: Value] {
        [
            "action": .string("create"),
            "operation_id": .string(operationID),
            "path": .string(path ?? root.appendingPathComponent("file.txt").path),
            "content": .string("content"),
        ]
    }

    func binding(
        rootMappings: [DomainMutationPhysicalRootMapping]? = nil,
        operation: @Sendable @escaping ([String: Value]) async throws -> Value
    ) -> MCPDomainToolBinding {
        let mappings = rootMappings ?? [
            DomainMutationPhysicalRootMapping(canonicalRoot: root.path, physicalRoot: root.path),
        ]
        return runtime.protectedMutationProvider.protectedBinding(MCPDomainToolBinding(
            definition: MCPDomainToolDefinition(
                name: "file_actions",
                description: "fixture",
                inputSchema: .object(["type": .string("object")]),
                annotations: .init(readOnlyHint: false, destructiveHint: true)
            ),
            operation: { arguments in
                guard let path = arguments["path"]?.stringValue else {
                    throw DomainMutationPathFenceError.relativePath("missing fixture path")
                }
                try await MCPDomainMutationCommitContext.admitPhysicalTargets(
                    [path],
                    rootMappings: mappings
                )
                return try await operation(arguments)
            }
        ))
    }

    func invoke(
        _ binding: MCPDomainToolBinding,
        arguments: [String: Value],
        workspaceRevision: UInt64 = 7,
        requestIdentitySeed: String = UUID().uuidString
    ) async throws -> Value {
        var context = DomainToolInvocationSecurityContext(
            principal: DomainClientPrincipal(
                principalID: UUID(),
                stableKey: "app:test",
                displayName: "test app proxy",
                kind: .runScoped,
                assurance: .hostLaunchToken,
                processID: 42,
                runID: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"),
                provider: "test",
                verifiedIdentityFingerprint: "test-app-fingerprint"
            ),
            connectionID: UUID(),
            connectionGeneration: 1,
            invocationID: UUID(),
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: runtime.identity.lifecycleGeneration,
            workspaceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            workspaceRevision: workspaceRevision,
            authorizedCanonicalRoots: [root.path],
            ephemeralGrantedToolNames: ["file_actions"]
        )
        context.overrideMutationRequestKeyForTesting(requestIdentitySeed)
        return try await MCPDomainInvocationSecurityContext.$current.withValue(context) {
            try await binding(arguments)
        }
    }
}

private actor MutationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor MutationAttemptBehavior {
    private var attempt = 0
    func next() -> Int {
        attempt += 1
        return attempt
    }
}

private actor MutationGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var entered = false

    func wait() async throws {
        entered = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        verify(error)
    }
}
