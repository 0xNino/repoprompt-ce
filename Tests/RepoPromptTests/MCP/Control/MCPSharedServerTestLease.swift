import Foundation

#if DEBUG
    @testable import RepoPromptApp

    actor MCPSharedServerTestLease {
        struct Ownership {
            fileprivate init() {}
        }

        static let shared = MCPSharedServerTestLease()

        private var occupied = false
        /// Lock-backed waiter queue so `onCancel` can remove/resume waiters **synchronously**
        /// without an unstructured `Task { await }` hop.
        private let waiterState = LeaseWaiterState()

        func withLease<T>(
            owner: String = #function,
            _ operation: (Ownership) async throws -> T
        ) async throws -> T {
            var ownsLease = false
            try await acquireLease()
            ownsLease = true
            defer {
                if ownsLease {
                    ownsLease = false
                    releaseLease()
                }
            }

            let leaseID = UUID()
            let baseline = await ServerNetworkManager.shared.debugTransportState()
            let bodyResult: Result<T, Swift.Error>
            do {
                bodyResult = try await .success(operation(Ownership()))
            } catch {
                bodyResult = .failure(error)
            }

            do {
                try await restoreTransportState(
                    baseline,
                    owner: owner,
                    leaseID: leaseID
                )
            } catch {
                switch bodyResult {
                case let .failure(bodyError):
                    throw LeaseError.bodyAndRestorationFailed(
                        owner: owner,
                        leaseID: leaseID,
                        body: String(reflecting: bodyError),
                        restoration: String(reflecting: error)
                    )
                case .success:
                    throw error
                }
            }

            return try bodyResult.get()
        }

        private func restoreTransportState(
            _ baseline: ServerNetworkManager.DebugTransportState,
            owner: String,
            leaseID: UUID
        ) async throws {
            let manager = ServerNetworkManager.shared
            let observed = await manager.debugTransportState()
            if observed != baseline {
                print(
                    "[MCPSharedServerTestLease] owner=\(owner) lease=\(leaseID.uuidString) restoring baseline={\(baseline)} observed={\(observed)}"
                )
            }

            if baseline.isRunning {
                if !observed.isRunning {
                    await manager.start()
                }
                await manager.setEnabled(baseline.isEnabled)
            } else {
                if observed.isRunning {
                    await manager.stop()
                }
                await manager.setEnabled(baseline.isEnabled)
            }

            let restored = await manager.debugTransportState()
            guard restored == baseline else {
                throw LeaseError.transportRestorationMismatch(
                    owner: owner,
                    leaseID: leaseID,
                    expected: baseline.description,
                    observed: observed.description,
                    actual: restored.description
                )
            }
        }

        private enum LeaseError: Swift.Error, CustomStringConvertible {
            case bodyAndRestorationFailed(owner: String, leaseID: UUID, body: String, restoration: String)
            case transportRestorationMismatch(
                owner: String,
                leaseID: UUID,
                expected: String,
                observed: String,
                actual: String
            )

            var description: String {
                switch self {
                case let .bodyAndRestorationFailed(owner, leaseID, body, restoration):
                    "Shared MCP lease owner \(owner) lease=\(leaseID) failed body=\(body) restoration=\(restoration)"
                case let .transportRestorationMismatch(owner, leaseID, expected, observed, actual):
                    "Shared MCP lease owner \(owner) lease=\(leaseID) transport restore mismatch expected={\(expected)} observed={\(observed)} actual={\(actual)}"
                }
            }
        }

        func waiterCountForTesting() -> Int {
            waiterState.waiterCount
        }

        private func acquireLease() async throws {
            guard occupied else {
                occupied = true
                do {
                    try Task.checkCancellation()
                } catch {
                    releaseLease()
                    throw error
                }
                return
            }

            try await waitForTurn()
            do {
                try Task.checkCancellation()
            } catch {
                releaseLease()
                throw error
            }
        }

        private func waitForTurn() async throws {
            let waiterID = waiterState.allocateWaiterID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiterState.enqueue(id: waiterID, continuation: continuation)
                }
            } onCancel: {
                // Synchronous sticky cancel — must not hop through the actor executor.
                waiterState.cancel(id: waiterID)
            }
        }

        private func releaseLease() {
            if let continuation = waiterState.dequeueNextReady() {
                continuation.resume()
                return
            }
            occupied = false
        }
    }

    /// Shared lease waiter queue. `@unchecked Sendable` lock state so cancellation handlers
    /// can run synchronously from any executor.
    private final class LeaseWaiterState: @unchecked Sendable {
        private let lock = NSLock()
        private var nextWaiterID = 0
        private var pendingWaiterIDs: Set<Int> = []
        private var cancelledWaiterIDs: Set<Int> = []
        private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []

        var waiterCount: Int {
            lock.withLock { waiters.count }
        }

        func allocateWaiterID() -> Int {
            lock.lock()
            let id = nextWaiterID
            nextWaiterID += 1
            pendingWaiterIDs.insert(id)
            lock.unlock()
            return id
        }

        func enqueue(id: Int, continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            if cancelledWaiterIDs.remove(id) != nil {
                pendingWaiterIDs.remove(id)
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            waiters.append((id, continuation))
            lock.unlock()
        }

        func cancel(id: Int) {
            lock.lock()
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: index)
                pendingWaiterIDs.remove(id)
                lock.unlock()
                waiter.continuation.resume(throwing: CancellationError())
                return
            }
            if pendingWaiterIDs.contains(id) {
                cancelledWaiterIDs.insert(id)
            }
            lock.unlock()
        }

        /// Returns the next non-cancelled waiter's continuation, or nil if the queue is empty.
        func dequeueNextReady() -> CheckedContinuation<Void, Error>? {
            lock.lock()
            while !waiters.isEmpty {
                let waiter = waiters.removeFirst()
                pendingWaiterIDs.remove(waiter.id)
                if cancelledWaiterIDs.remove(waiter.id) != nil {
                    lock.unlock()
                    waiter.continuation.resume(throwing: CancellationError())
                    lock.lock()
                    continue
                }
                lock.unlock()
                return waiter.continuation
            }
            lock.unlock()
            return nil
        }
    }
#endif
