import Foundation

package enum DomainReadSideEffectError: Error, Equatable, Sendable {
    case runtimeMismatch
    case operationCollision
    case stopped
}

package struct DomainReadSideEffectReceipt: Equatable, Sendable {
    package let operationID: UUID
    package let context: DomainContextIdentity
    package let revision: UInt64

    package init(operationID: UUID, context: DomainContextIdentity, revision: UInt64) {
        self.operationID = operationID
        self.context = context
        self.revision = revision
    }
}

/// Context-keyed revision authority for read-derived selection and artifact effects.
///
/// The physical sink remains app/headless composition owned. This actor only assigns stable
/// revisions, rejects operation-ID collisions, serializes effects for one context, and exposes
/// bounded high-water drains without serializing unrelated contexts or read backends.
package actor DomainReadSideEffectCoordinator {
    private struct RecordedOperation: Sendable {
        let fingerprint: String
        let receipt: DomainReadSideEffectReceipt
    }

    private struct ContextState: Sendable {
        var acceptedRevision: UInt64 = 0
        var completedRevision: UInt64 = 0
        var tasks: [UInt64: Task<Void, Error>] = [:]
        var operations: [UUID: RecordedOperation] = [:]
    }

    private let identity: DomainRuntimeIdentity
    private var states: [DomainContextIdentity: ContextState] = [:]
    private var stopped = false

    package init(identity: DomainRuntimeIdentity) {
        self.identity = identity
    }

    package func highWaterRevision(for handle: DomainReadContextHandle) throws -> UInt64 {
        try validate(handle)
        return states[handle.context]?.acceptedRevision ?? 0
    }

    package func submit(
        handle: DomainReadContextHandle,
        operationID: UUID,
        fingerprint: String,
        operation: @Sendable @escaping () async throws -> Void
    ) throws -> DomainReadSideEffectReceipt {
        try validate(handle)
        guard !stopped else { throw DomainReadSideEffectError.stopped }
        var state = states[handle.context] ?? ContextState()
        if let recorded = state.operations[operationID] {
            guard recorded.fingerprint == fingerprint else {
                throw DomainReadSideEffectError.operationCollision
            }
            return recorded.receipt
        }

        let revision = state.acceptedRevision &+ 1
        let previous = state.tasks[state.acceptedRevision]
        let task = Task {
            if let previous { try await previous.value }
            try Task.checkCancellation()
            try await operation()
        }
        let receipt = DomainReadSideEffectReceipt(
            operationID: operationID,
            context: handle.context,
            revision: revision
        )
        state.acceptedRevision = revision
        state.tasks[revision] = task
        state.operations[operationID] = RecordedOperation(
            fingerprint: fingerprint,
            receipt: receipt
        )
        states[handle.context] = state

        Task { [weak self] in
            do {
                try await task.value
                await self?.markCompleted(context: handle.context, revision: revision)
            } catch {
                // Keep the failed revision task available so drains observe the same failure.
            }
        }
        return receipt
    }

    package func drain(
        handle: DomainReadContextHandle,
        through revision: UInt64
    ) async throws {
        try validate(handle)
        try Task.checkCancellation()
        guard revision > 0 else { return }
        guard let state = states[handle.context] else { return }
        if state.completedRevision >= revision { return }
        guard let task = state.tasks[revision] else { return }
        try await task.value
        try Task.checkCancellation()
    }

    package func shutdown() {
        stopped = true
        for state in states.values {
            for task in state.tasks.values { task.cancel() }
        }
    }

    private func validate(_ handle: DomainReadContextHandle) throws {
        guard handle.runtimeID == identity.runtimeID,
              handle.runtimeGeneration == identity.lifecycleGeneration
        else {
            throw DomainReadSideEffectError.runtimeMismatch
        }
    }

    private func markCompleted(context: DomainContextIdentity, revision: UInt64) {
        guard var state = states[context] else { return }
        state.completedRevision = max(state.completedRevision, revision)
        if state.completedRevision > 32 {
            let floor = state.completedRevision - 32
            state.tasks = state.tasks.filter { $0.key >= floor }
        }
        states[context] = state
    }
}
