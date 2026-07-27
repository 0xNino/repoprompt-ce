import Foundation

/// A nonthrowing delay for lifecycle-owned tasks that must wake promptly when cancelled.
///
/// Cancellation is ordinary control flow for these owned tasks: callers need to distinguish an
/// elapsed interval from owner shutdown without throwing out of the child task. The underlying
/// timer is cancelled on every terminal path so teardown does not leave dormant scheduled work.
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
        private var timer: DispatchSourceTimer?

        func install(_ continuation: CheckedContinuation<Bool, Never>, nanoseconds: UInt64) {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + .nanoseconds(Int(clamping: nanoseconds)))
            timer.setEventHandler { [weak self] in
                self?.resolve(elapsed: true)
            }

            lock.lock()
            if let resolution {
                lock.unlock()
                timer.activate()
                timer.cancel()
                continuation.resume(returning: resolution)
                return
            }
            self.continuation = continuation
            self.timer = timer
            timer.activate()
            lock.unlock()
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
            let timer = timer
            self.timer = nil
            lock.unlock()

            timer?.cancel()
            continuation?.resume(returning: elapsed)
        }
    }
}
