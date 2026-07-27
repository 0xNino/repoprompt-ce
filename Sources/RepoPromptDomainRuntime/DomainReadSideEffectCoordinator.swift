import Foundation

package enum DomainReadSideEffectError: Error, Equatable, Sendable {
    case runtimeMismatch
    case operationCollision
    case stopped
}

/// Independent ordering domains for read-derived effects. Selection publication must not be
/// head-of-line blocked by Git artifact work (or vice versa), while effects in one class and
/// context retain strict revision order.
package enum DomainReadSideEffectClass: String, Hashable, Sendable {
    case selection
    case gitArtifacts
}

package struct DomainReadSideEffectReceipt: Equatable, Sendable {
    package let operationID: UUID
    package let context: DomainContextIdentity
    package let effectClass: DomainReadSideEffectClass
    package let revision: UInt64

    package init(
        operationID: UUID,
        context: DomainContextIdentity,
        effectClass: DomainReadSideEffectClass,
        revision: UInt64
    ) {
        self.operationID = operationID
        self.context = context
        self.effectClass = effectClass
        self.revision = revision
    }
}

/// Context- and effect-class-keyed revision authority for read-derived effects.
///
/// Accepted operations are strictly ordered within a lane. A terminal failure is observable by
/// the submitting caller but is not inherited by later operations or future high-water drains.
package actor DomainReadSideEffectCoordinator {
    private struct LaneKey: Hashable, Sendable {
        let context: DomainContextIdentity
        let effectClass: DomainReadSideEffectClass
    }

    private struct RecordedOperation: Sendable {
        let fingerprint: String
        let receipt: DomainReadSideEffectReceipt
    }

    private struct LaneState: Sendable {
        var acceptedRevision: UInt64 = 0
        var terminalRevision: UInt64 = 0
        var tasks: [UInt64: Task<Void, Error>] = [:]
        var operations: [UUID: RecordedOperation] = [:]
    }

    private let identity: DomainRuntimeIdentity
    private var states: [LaneKey: LaneState] = [:]
    private var stopped = false

    package init(identity: DomainRuntimeIdentity) {
        self.identity = identity
    }

    package func highWaterRevision(
        for handle: DomainReadContextHandle,
        effectClass: DomainReadSideEffectClass
    ) throws -> UInt64 {
        try validate(handle)
        return states[LaneKey(context: handle.context, effectClass: effectClass)]?.acceptedRevision ?? 0
    }

    package func submit(
        handle: DomainReadContextHandle,
        effectClass: DomainReadSideEffectClass,
        operationID: UUID,
        fingerprint: String,
        operation: @Sendable @escaping () async throws -> Void
    ) throws -> DomainReadSideEffectReceipt {
        try validate(handle)
        guard !stopped else { throw DomainReadSideEffectError.stopped }
        let key = LaneKey(context: handle.context, effectClass: effectClass)
        var state = states[key] ?? LaneState()
        if let recorded = state.operations[operationID] {
            guard recorded.fingerprint == fingerprint else {
                throw DomainReadSideEffectError.operationCollision
            }
            return recorded.receipt
        }

        let revision = state.acceptedRevision &+ 1
        let previous = state.tasks[state.acceptedRevision]
        let task = Task {
            // A previous terminal error belongs to its submitter. It must never poison this lane.
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            try await operation()
        }
        let receipt = DomainReadSideEffectReceipt(
            operationID: operationID,
            context: handle.context,
            effectClass: effectClass,
            revision: revision
        )
        state.acceptedRevision = revision
        state.tasks[revision] = task
        state.operations[operationID] = RecordedOperation(
            fingerprint: fingerprint,
            receipt: receipt
        )
        states[key] = state

        Task { [weak self] in
            _ = await task.result
            await self?.markTerminal(key: key, revision: revision)
        }
        return receipt
    }

    /// Waits for the exact submitted operation and preserves its success/failure/cancellation.
    /// Cancellation of the waiter cancels the not-yet-committed effect.
    package func wait(
        handle: DomainReadContextHandle,
        receipt: DomainReadSideEffectReceipt
    ) async throws {
        try validate(handle)
        let key = LaneKey(context: handle.context, effectClass: receipt.effectClass)
        guard receipt.context == handle.context,
              let task = states[key]?.tasks[receipt.revision]
        else { return }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
        }
    }

    /// Waits until the lane has reached a revision. Historical effect failures are terminal and
    /// intentionally do not fail an unrelated later read; cancellation of this request still does.
    package func drain(
        handle: DomainReadContextHandle,
        effectClass: DomainReadSideEffectClass,
        through revision: UInt64
    ) async throws {
        try validate(handle)
        try Task.checkCancellation()
        guard revision > 0 else { return }
        let key = LaneKey(context: handle.context, effectClass: effectClass)
        guard let state = states[key] else { return }
        if state.terminalRevision >= revision { return }
        guard let task = state.tasks[revision] else { return }
        _ = await task.result
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

    private func markTerminal(key: LaneKey, revision: UInt64) {
        guard var state = states[key] else { return }
        state.terminalRevision = max(state.terminalRevision, revision)
        if state.terminalRevision > 32 {
            let floor = state.terminalRevision - 32
            state.tasks = state.tasks.filter { $0.key >= floor }
            state.operations = state.operations.filter { $0.value.receipt.revision >= floor }
        }
        states[key] = state
    }
}
