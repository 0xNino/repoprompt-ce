import Foundation

/// A nonthrowing delay for lifecycle-owned tasks that must wake promptly when cancelled.
///
/// `Task.sleep` throws `CancellationError` during ordinary teardown. XCTest can surface that
/// throw as an issue even when the owner catches it, so long-lived presentation tasks use this
/// continuation-backed delay to make expected cancellation a value instead of an error.
enum TaskCancellationDelay {
    static func wait(nanoseconds: UInt64) async -> Bool {
        guard nanoseconds > 0 else { return !Task.isCancelled }
        let state = State()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.install(continuation, nanoseconds: nanoseconds)
            }
        } onCancel: {
            state.resolve(elapsed: false)
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var resolution: Bool?
        private var continuation: CheckedContinuation<Bool, Never>?
        private var workItem: DispatchWorkItem?

        func install(_ continuation: CheckedContinuation<Bool, Never>, nanoseconds: UInt64) {
            let workItem = DispatchWorkItem { [weak self] in
                self?.resolve(elapsed: true)
            }
            lock.lock()
            if let resolution {
                lock.unlock()
                continuation.resume(returning: resolution)
                return
            }
            self.continuation = continuation
            self.workItem = workItem
            lock.unlock()

            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .nanoseconds(Int(clamping: nanoseconds)),
                execute: workItem
            )
        }

        func resolve(elapsed: Bool) {
            lock.lock()
            guard resolution == nil else {
                lock.unlock()
                return
            }
            resolution = elapsed
            let continuation = continuation
            self.continuation = nil
            let workItem = workItem
            self.workItem = nil
            lock.unlock()

            if !elapsed {
                workItem?.cancel()
            }
            continuation?.resume(returning: elapsed)
        }
    }
}
