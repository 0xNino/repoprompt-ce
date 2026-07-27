import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainReadSideEffectCoordinatorTests: XCTestCase {
    func testEffectsAreRevisionedAndSerializedPerContext() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let recorder = EffectRecorder()

        let first = try await coordinator.submit(
            handle: handle,
            operationID: UUID(),
            fingerprint: "first"
        ) {
            await recorder.append("first")
        }
        let second = try await coordinator.submit(
            handle: handle,
            operationID: UUID(),
            fingerprint: "second"
        ) {
            await recorder.append("second")
        }

        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(second.revision, 2)
        try await coordinator.drain(handle: handle, through: second.revision)
        let effects = await recorder.snapshot()
        XCTAssertEqual(effects, ["first", "second"])
    }

    func testExactRetryDeduplicatesAndCollisionFailsClosed() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let operationID = UUID()

        let first = try await coordinator.submit(
            handle: handle,
            operationID: operationID,
            fingerprint: "same"
        ) {}
        let retry = try await coordinator.submit(
            handle: handle,
            operationID: operationID,
            fingerprint: "same"
        ) {
            XCTFail("Deduplicated operation must not execute twice")
        }
        XCTAssertEqual(first, retry)

        do {
            _ = try await coordinator.submit(
                handle: handle,
                operationID: operationID,
                fingerprint: "different"
            ) {}
            XCTFail("Expected collision")
        } catch let error as DomainReadSideEffectError {
            XCTAssertEqual(error, .operationCollision)
        }
    }

    func testShutdownRejectsNewEffectsAndCancelsPendingWork() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let gate = AsyncGate()
        let receipt = try await coordinator.submit(
            handle: handle,
            operationID: UUID(),
            fingerprint: "pending"
        ) {
            try await gate.wait()
        }
        await coordinator.shutdown()
        do {
            try await coordinator.drain(handle: handle, through: receipt.revision)
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        do {
            _ = try await coordinator.submit(
                handle: handle,
                operationID: UUID(),
                fingerprint: "late"
            ) {}
            XCTFail("Expected stopped coordinator")
        } catch let error as DomainReadSideEffectError {
            XCTAssertEqual(error, .stopped)
        }
    }

    private func makeIdentity() -> DomainRuntimeIdentity {
        DomainRuntimeIdentity(
            runtimeID: UUID(),
            lifecycleGeneration: 1,
            processID: 1,
            mode: .standalone,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeHandle(identity: DomainRuntimeIdentity) -> DomainReadContextHandle {
        DomainReadContextHandle(
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            connectionID: UUID(),
            connectionGeneration: 1,
            context: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
            workspaceRevision: 1,
            contextRevision: 1,
            routingRevision: 1,
            bindingKind: .runScoped(runID: UUID())
        )
    }
}

private actor EffectRecorder {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Error>?

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
