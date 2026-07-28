import Foundation

package struct DomainAgentSessionRegistration: Codable, Equatable, Hashable, Sendable {
    package let runtimeID: UUID
    package let runtimeGeneration: UInt64
    package let sessionID: UUID
    package let generation: UInt64

    package init(
        runtimeID: UUID,
        runtimeGeneration: UInt64,
        sessionID: UUID,
        generation: UInt64
    ) {
        self.runtimeID = runtimeID
        self.runtimeGeneration = runtimeGeneration
        self.sessionID = sessionID
        self.generation = generation
    }
}

package struct DomainAgentSessionWaitCursor: Equatable, Hashable, Sendable {
    package let registration: DomainAgentSessionRegistration
    package let epoch: DomainAgentRunTurnEpoch?

    package init(
        registration: DomainAgentSessionRegistration,
        epoch: DomainAgentRunTurnEpoch?
    ) {
        self.registration = registration
        self.epoch = epoch
    }
}

package enum DomainAgentSessionDurableState: String, Codable, Sendable {
    case dormant
    case active
    case interrupted
    case terminal
}

package struct DomainAgentSessionDurableMetadata: Codable, Equatable, Sendable {
    package let sessionID: UUID
    package let owningRuntimeID: UUID
    package let owningRuntimeGeneration: UInt64
    package let registrationGeneration: UInt64
    package let lastEpochOrdinal: UInt64
    package let continuityGeneration: UInt64
    package let state: DomainAgentSessionDurableState
    package let resumable: Bool
    package let updatedAt: Date

    package var isLive: Bool {
        state == .active
    }
}

package struct DomainAgentSessionShutdownResult: Equatable, Sendable {
    package let cooperativeSessionIDs: [UUID]
    package let interruptedSessionIDs: [UUID]
}

package enum DomainAgentSessionResumeClaimResult: Equatable, Sendable {
    case accepted(DomainAgentSessionRegistration)
    case unavailable
    case alreadyActive
    case shuttingDown
}

private actor DomainAgentCancellationCompletionTracker {
    private var completed: Set<UUID> = []

    func markCompleted(_ sessionID: UUID) {
        completed.insert(sessionID)
    }

    func snapshot() -> Set<UUID> {
        completed
    }
}

package actor DomainAgentRunSessionStore {
    package typealias Registration = DomainAgentSessionRegistration
    package typealias WaitCursor = DomainAgentSessionWaitCursor

    private static func timeoutNanoseconds(_ timeoutSeconds: TimeInterval) -> UInt64 {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else { return 0 }
        let maxSeconds = Double(UInt64.max) / 1_000_000_000
        return UInt64((min(timeoutSeconds, maxSeconds) * 1_000_000_000).rounded(.up))
    }

    package enum EpochBeginResult: Equatable, Sendable {
        case accepted(DomainAgentRunTurnEpoch)
        case stale(currentEpoch: DomainAgentRunTurnEpoch?)
        case rejected(reason: String)
    }

    package enum WaitDisposition: Equatable, Sendable {
        case snapshotReady(DomainAgentRunSnapshot)
        case noteworthySnapshot(NoteworthyWake)
        case epochAdvanced(DomainAgentRunTurnEpoch, DomainAgentRunEpochTransitionKind)
        case terminalPublicationRejected(epoch: DomainAgentRunTurnEpoch, reason: String)
        case timedOut
        case expired
        case cancelled
    }

    package enum WakeReason: String, Equatable, Sendable {
        case instructionDelivered = "instruction_delivered"
        case steeringRequested = "steering_requested"
    }

    package struct NoteworthyWake: Equatable, Sendable {
        package let snapshot: DomainAgentRunSnapshot
        package let reason: WakeReason
        package let steeringMessage: String?
        package let steeringOriginRunID: UUID?

        package init(
            snapshot: DomainAgentRunSnapshot,
            reason: WakeReason,
            steeringMessage: String?,
            steeringOriginRunID: UUID? = nil
        ) {
            self.snapshot = snapshot
            self.reason = reason
            self.steeringMessage = steeringMessage
            self.steeringOriginRunID = steeringOriginRunID
        }
    }

    private struct Waiter {
        let id: UUID
        let cursor: WaitCursor
        let continuation: CheckedContinuation<WaitDisposition, Never>
        let timeoutTask: Task<Void, Never>?
    }

    private struct EpochState {
        let epoch: DomainAgentRunTurnEpoch?
        var latestSnapshot: DomainAgentRunSnapshot?
        var pendingNoteworthyWake: NoteworthyWake?
        var terminalCommitID: UUID?
        var terminalSnapshot: DomainAgentRunSnapshot?
        var successorEpoch: DomainAgentRunTurnEpoch?
        var terminalPublicationFailure: String?

        init(epoch: DomainAgentRunTurnEpoch?) {
            self.epoch = epoch
        }
    }

    private struct Record {
        let registration: Registration
        var currentEpoch: DomainAgentRunTurnEpoch?
        var preEpochState = EpochState(epoch: nil)
        var epochStates: [UUID: EpochState] = [:]
        var waiters: [Waiter] = []
        var expiryTask: Task<Void, Never>?
        var nextEpochOrdinal: UInt64 = 1
        var continuityGeneration: UInt64 = 0
    }

    private static let terminalSnapshotTTL: TimeInterval = 300
    private static let retainedCommittedEpochLimit = 32

    private let identity: DomainRuntimeIdentity
    private let metadataURL: URL
    private var records: [UUID: Record] = [:]
    private var durableMetadata: [UUID: DomainAgentSessionDurableMetadata] = [:]
    private var cancellationHandlers: [UUID: @Sendable () async -> Void] = [:]
    private var nextGeneration: UInt64 = 1
    private var didBootstrap = false
    private var isShuttingDown = false
    private var metadataPersistenceTask: Task<Void, Never>?

    package init(identity: DomainRuntimeIdentity, storageDirectory: URL) {
        self.identity = identity
        metadataURL = storageDirectory
            .appendingPathComponent("DomainRuntime", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("agent-sessions.json")
    }

    package func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        let url = metadataURL
        let decoded: [DomainAgentSessionDurableMetadata] = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let values = try? JSONDecoder().decode([DomainAgentSessionDurableMetadata].self, from: data)
            else {
                return []
            }
            return values
        }.value
        for value in decoded {
            // Persisted executions are metadata only. A new runtime must explicitly register a
            // new activation before any session can be reported live.
            durableMetadata[value.sessionID] = DomainAgentSessionDurableMetadata(
                sessionID: value.sessionID,
                owningRuntimeID: identity.runtimeID,
                owningRuntimeGeneration: identity.lifecycleGeneration,
                registrationGeneration: value.registrationGeneration,
                lastEpochOrdinal: value.lastEpochOrdinal,
                continuityGeneration: value.continuityGeneration,
                state: value.state == .terminal ? .terminal : .dormant,
                resumable: value.resumable,
                updatedAt: value.updatedAt
            )
            nextGeneration = max(nextGeneration, value.registrationGeneration &+ 1)
        }
    }

    package func restoredMetadata() -> [DomainAgentSessionDurableMetadata] {
        durableMetadata.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    package func claimResumableSession(sessionID: UUID) -> DomainAgentSessionResumeClaimResult {
        guard !isShuttingDown else { return .shuttingDown }
        guard records[sessionID] == nil else { return .alreadyActive }
        guard let metadata = durableMetadata[sessionID], metadata.resumable else {
            return .unavailable
        }
        let registration = makeRegistration(sessionID: sessionID)
        var record = Record(registration: registration)
        record.nextEpochOrdinal = max(1, metadata.lastEpochOrdinal &+ 1)
        record.continuityGeneration = metadata.continuityGeneration
        records[sessionID] = record
        updateMetadata(for: record, state: .active, resumable: true)
        scheduleMetadataPersistence()
        return .accepted(registration)
    }

    package func register(sessionID: UUID) -> Registration {
        guard !isShuttingDown else {
            return Registration(
                runtimeID: identity.runtimeID,
                runtimeGeneration: identity.lifecycleGeneration,
                sessionID: sessionID,
                generation: 0
            )
        }
        if let previous = records.removeValue(forKey: sessionID) {
            previous.expiryTask?.cancel()
            expireWaiters(previous.waiters)
            cancellationHandlers.removeValue(forKey: sessionID)
            recordRejectedOperation(
                "register",
                supplied: previous.registration,
                current: nil,
                reason: "replaced_registration"
            )
        }
        let registration = makeRegistration(sessionID: sessionID)
        records[sessionID] = Record(registration: registration)
        updateMetadata(for: records[sessionID], state: .active, resumable: true)
        scheduleMetadataPersistence()
        return registration
    }

    package func registerIfMissing(sessionID: UUID) -> Registration? {
        guard !isShuttingDown, records[sessionID] == nil else { return nil }
        let registration = makeRegistration(sessionID: sessionID)
        records[sessionID] = Record(registration: registration)
        updateMetadata(for: records[sessionID], state: .active, resumable: true)
        scheduleMetadataPersistence()
        return registration
    }

    package func beginEpoch(
        registration: Registration,
        activationID: UUID,
        expectedCurrentEpoch: DomainAgentRunTurnEpoch?,
        transitionKind: DomainAgentRunEpochTransitionKind,
        seedSnapshot: DomainAgentRunSnapshot? = nil
    ) -> EpochBeginResult {
        guard var record = currentRecord(for: registration, operation: "begin_epoch") else {
            return .rejected(reason: "stale_activation")
        }
        guard record.currentEpoch == expectedCurrentEpoch else {
            recordRejectedOperation(
                "begin_epoch",
                supplied: registration,
                current: record.registration,
                reason: "unexpected_current_epoch"
            )
            return .stale(currentEpoch: record.currentEpoch)
        }

        if transitionKind == .unrelated {
            record.continuityGeneration &+= 1
        }
        let epoch = DomainAgentRunTurnEpoch(
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            sessionID: registration.sessionID,
            activationID: activationID,
            registrationGeneration: registration.generation,
            id: UUID(),
            ordinal: record.nextEpochOrdinal,
            continuityGeneration: record.continuityGeneration,
            transitionKind: transitionKind
        )
        record.nextEpochOrdinal &+= 1
        var state = EpochState(epoch: epoch)
        state.latestSnapshot = seedSnapshot
        record.epochStates[epoch.id] = state
        record.currentEpoch = epoch
        pruneCommittedEpochStates(in: &record)
        record.expiryTask?.cancel()
        record.expiryTask = nil
        let waiters = takeWaiters(from: &record) { $0.cursor.epoch != epoch }
        records[registration.sessionID] = record
        updateMetadata(for: record, state: .active, resumable: true)
        scheduleMetadataPersistence()
        resume(waiters, with: .epochAdvanced(epoch, transitionKind))
        return .accepted(epoch)
    }

    package func noteSnapshot(_ snapshot: DomainAgentRunSnapshot, cursor: WaitCursor) {
        ingestSnapshot(snapshot, cursor: cursor, wakeReason: nil)
    }

    package func noteSnapshotAndWakeWaiters(
        _ snapshot: DomainAgentRunSnapshot,
        cursor: WaitCursor,
        reason: WakeReason,
        steeringMessage: String? = nil,
        steeringOriginRunID: UUID? = nil
    ) {
        ingestSnapshot(
            snapshot,
            cursor: cursor,
            wakeReason: reason,
            steeringMessage: steeringMessage,
            steeringOriginRunID: steeringOriginRunID
        )
    }

    package func publishTerminal(
        _ envelope: DomainAgentRunTerminalPublicationEnvelope,
        registration: Registration,
        commitID: UUID,
        successorKind: DomainAgentRunEpochTransitionKind?
    ) -> DomainAgentRunTerminalPublicationResult {
        guard envelope.snapshot.sessionID == registration.sessionID,
              envelope.epoch.sessionID == registration.sessionID,
              envelope.epoch.registrationGeneration == registration.generation
        else {
            recordRejectedOperation(
                "publish_terminal_commit",
                supplied: registration,
                current: records[registration.sessionID]?.registration,
                reason: "session_or_activation_mismatch"
            )
            return .rejected(reason: "session_or_activation_mismatch")
        }
        guard var record = currentRecord(for: registration, operation: "publish_terminal_commit") else {
            return .rejected(reason: "stale_activation")
        }
        guard var state = record.epochStates[envelope.epoch.id], state.epoch == envelope.epoch else {
            recordRejectedOperation(
                "publish_terminal_commit",
                supplied: registration,
                current: record.registration,
                reason: "unknown_epoch"
            )
            return .rejected(reason: "unknown_epoch")
        }
        if state.terminalCommitID == commitID {
            if let successorEpoch = state.successorEpoch {
                return .accepted(successorEpoch: successorEpoch)
            }
            return record.currentEpoch == envelope.epoch
                ? .accepted(successorEpoch: nil)
                : .stale
        }
        if state.terminalCommitID != nil {
            let reason = "different_commit_already_published"
            state.terminalPublicationFailure = reason
            record.epochStates[envelope.epoch.id] = state
            let waiters = record.currentEpoch == envelope.epoch
                ? takeWaiters(from: &record) { $0.cursor.epoch == envelope.epoch }
                : []
            records[registration.sessionID] = record
            resume(waiters, with: .terminalPublicationRejected(epoch: envelope.epoch, reason: reason))
            recordRejectedOperation(
                "publish_terminal_commit",
                supplied: registration,
                current: record.registration,
                reason: reason
            )
            return .rejected(reason: reason)
        }

        state.terminalCommitID = commitID
        state.terminalSnapshot = envelope.snapshot
        state.latestSnapshot = envelope.snapshot
        state.pendingNoteworthyWake = nil

        guard record.currentEpoch == envelope.epoch else {
            record.epochStates[envelope.epoch.id] = state
            pruneCommittedEpochStates(in: &record)
            records[registration.sessionID] = record
            return .stale
        }

        if let successorKind {
            let successor: DomainAgentRunTurnEpoch
            if let existing = state.successorEpoch {
                successor = existing
            } else {
                if successorKind == .unrelated {
                    record.continuityGeneration &+= 1
                }
                successor = DomainAgentRunTurnEpoch(
                    runtimeID: identity.runtimeID,
                    runtimeGeneration: identity.lifecycleGeneration,
                    sessionID: registration.sessionID,
                    activationID: envelope.epoch.activationID,
                    registrationGeneration: registration.generation,
                    id: UUID(),
                    ordinal: record.nextEpochOrdinal,
                    continuityGeneration: record.continuityGeneration,
                    transitionKind: successorKind
                )
                record.nextEpochOrdinal &+= 1
                state.successorEpoch = successor
                record.epochStates[successor.id] = EpochState(epoch: successor)
            }
            record.epochStates[envelope.epoch.id] = state
            record.currentEpoch = successor
            pruneCommittedEpochStates(in: &record)
            record.expiryTask?.cancel()
            record.expiryTask = nil
            let waiters = takeWaiters(from: &record) { $0.cursor.epoch == envelope.epoch }
            records[registration.sessionID] = record
            updateMetadata(for: record, state: .active, resumable: true)
            scheduleMetadataPersistence()
            resume(waiters, with: .epochAdvanced(successor, successorKind))
            return .accepted(successorEpoch: successor)
        }

        record.epochStates[envelope.epoch.id] = state
        let waiters = takeWaiters(from: &record) { $0.cursor.epoch == envelope.epoch }
        scheduleExpiry(for: &record, cursor: WaitCursor(registration: registration, epoch: envelope.epoch))
        records[registration.sessionID] = record
        updateMetadata(for: record, state: .terminal, resumable: true)
        scheduleMetadataPersistence()
        resume(waiters, with: .snapshotReady(envelope.snapshot))
        return .accepted(successorEpoch: nil)
    }

    package func wakeCurrentWaiters(
        _ snapshot: DomainAgentRunSnapshot,
        cursor: WaitCursor,
        reason: WakeReason,
        steeringMessage: String? = nil,
        steeringOriginRunID: UUID? = nil
    ) {
        guard snapshot.sessionID == cursor.registration.sessionID else { return }
        guard var record = currentRecord(for: cursor.registration, operation: "wake") else { return }
        guard cursor.epoch == record.currentEpoch else { return }
        let acceptedSnapshot = acceptedSnapshot(snapshot, existing: latestSnapshot(in: record, cursor: cursor))
        if acceptedSnapshot == snapshot {
            updateLatestSnapshot(snapshot, in: &record, cursor: cursor)
        }
        let waiters = takeWaiters(from: &record) { $0.cursor == cursor }
        if acceptedSnapshot.isActionableForMCPWait {
            clearPendingWake(in: &record, cursor: cursor)
        }
        records[snapshot.sessionID] = record
        guard !waiters.isEmpty else { return }
        let disposition: WaitDisposition = acceptedSnapshot.isActionableForMCPWait
            ? .snapshotReady(acceptedSnapshot)
            : .noteworthySnapshot(NoteworthyWake(
                snapshot: acceptedSnapshot,
                reason: reason,
                steeringMessage: steeringMessage,
                steeringOriginRunID: steeringOriginRunID
            ))
        resume(waiters, with: disposition)
    }

    private func ingestSnapshot(
        _ snapshot: DomainAgentRunSnapshot,
        cursor: WaitCursor,
        wakeReason: WakeReason?,
        steeringMessage: String? = nil,
        steeringOriginRunID: UUID? = nil
    ) {
        guard snapshot.sessionID == cursor.registration.sessionID else {
            recordRejectedOperation(
                "publish",
                supplied: cursor.registration,
                current: records[cursor.registration.sessionID]?.registration,
                reason: "session_mismatch"
            )
            return
        }
        guard var record = currentRecord(for: cursor.registration, operation: "publish") else { return }
        guard cursor.epoch == record.currentEpoch else {
            recordRejectedOperation(
                "publish",
                supplied: cursor.registration,
                current: record.registration,
                reason: "stale_epoch"
            )
            return
        }

        let acceptedSnapshot = acceptedSnapshot(snapshot, existing: latestSnapshot(in: record, cursor: cursor))
        if acceptedSnapshot == snapshot {
            updateLatestSnapshot(snapshot, in: &record, cursor: cursor)
            if snapshot.isActionableForMCPWait {
                clearPendingWake(in: &record, cursor: cursor)
            }
        }

        let disposition: WaitDisposition? = if acceptedSnapshot.isActionableForMCPWait {
            .snapshotReady(acceptedSnapshot)
        } else if let wakeReason {
            .noteworthySnapshot(NoteworthyWake(
                snapshot: acceptedSnapshot,
                reason: wakeReason,
                steeringMessage: steeringMessage,
                steeringOriginRunID: steeringOriginRunID
            ))
        } else {
            nil
        }
        let waiters = disposition == nil ? [] : takeWaiters(from: &record) { $0.cursor == cursor }
        if case let .noteworthySnapshot(wake) = disposition, waiters.isEmpty {
            setPendingWake(wake, in: &record, cursor: cursor)
        } else if disposition != nil {
            clearPendingWake(in: &record, cursor: cursor)
        }
        if snapshot.status.isTerminal {
            scheduleExpiry(for: &record, cursor: cursor)
            updateMetadata(for: record, state: .terminal, resumable: true)
            scheduleMetadataPersistence()
        }
        records[snapshot.sessionID] = record
        if let disposition {
            resume(waiters, with: disposition)
        }
    }

    package func waitUntilInteresting(
        cursor: WaitCursor,
        timeoutSeconds: TimeInterval? = nil
    ) async -> WaitDisposition {
        guard let record = currentRecord(for: cursor.registration, operation: "wait") else {
            return .expired
        }
        if cursor.epoch != record.currentEpoch {
            guard let currentEpoch = record.currentEpoch else { return .expired }
            return .epochAdvanced(currentEpoch, transitionKind(from: cursor.epoch, to: currentEpoch))
        }
        if let failure = terminalPublicationFailure(in: record, cursor: cursor), let epoch = cursor.epoch {
            return .terminalPublicationRejected(epoch: epoch, reason: failure)
        }
        if let snapshot = latestSnapshot(in: record, cursor: cursor), snapshot.isActionableForMCPWait {
            return .snapshotReady(snapshot)
        }
        if let pending = pendingWake(in: record, cursor: cursor) {
            var updated = record
            clearPendingWake(in: &updated, cursor: cursor)
            records[cursor.registration.sessionID] = updated
            return .noteworthySnapshot(NoteworthyWake(
                snapshot: latestSnapshot(in: updated, cursor: cursor) ?? pending.snapshot,
                reason: pending.reason,
                steeringMessage: pending.steeringMessage,
                steeringOriginRunID: pending.steeringOriginRunID
            ))
        }
        if let timeoutSeconds, timeoutSeconds <= 0 {
            return .timedOut
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard var current = currentRecord(for: cursor.registration, operation: "wait_park") else {
                    continuation.resume(returning: .expired)
                    return
                }
                if cursor.epoch != current.currentEpoch {
                    guard let currentEpoch = current.currentEpoch else {
                        continuation.resume(returning: .expired)
                        return
                    }
                    continuation.resume(returning: .epochAdvanced(
                        currentEpoch,
                        transitionKind(from: cursor.epoch, to: currentEpoch)
                    ))
                    return
                }
                if let failure = terminalPublicationFailure(in: current, cursor: cursor), let epoch = cursor.epoch {
                    continuation.resume(returning: .terminalPublicationRejected(epoch: epoch, reason: failure))
                    return
                }
                if let snapshot = latestSnapshot(in: current, cursor: cursor), snapshot.isActionableForMCPWait {
                    continuation.resume(returning: .snapshotReady(snapshot))
                    return
                }
                if let pending = pendingWake(in: current, cursor: cursor) {
                    clearPendingWake(in: &current, cursor: cursor)
                    records[cursor.registration.sessionID] = current
                    continuation.resume(returning: .noteworthySnapshot(NoteworthyWake(
                        snapshot: latestSnapshot(in: current, cursor: cursor) ?? pending.snapshot,
                        reason: pending.reason,
                        steeringMessage: pending.steeringMessage,
                        steeringOriginRunID: pending.steeringOriginRunID
                    )))
                    return
                }
                let timeoutTask: Task<Void, Never>? = timeoutSeconds.map { timeout in
                    Task { [weak self] in
                        do {
                            try await Task.sleep(
                                nanoseconds: Self.timeoutNanoseconds(timeout)
                            )
                            await self?.timeoutWaiter(sessionID: cursor.registration.sessionID, waiterID: waiterID)
                        } catch {}
                    }
                }
                current.waiters.append(Waiter(
                    id: waiterID,
                    cursor: cursor,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                ))
                records[cursor.registration.sessionID] = current
            }
        } onCancel: {
            Task { await self.cancelWaiter(sessionID: cursor.registration.sessionID, waiterID: waiterID) }
        }
    }

    package func waitUntilInteresting(
        registration: Registration,
        timeoutSeconds: TimeInterval? = nil
    ) async -> WaitDisposition {
        guard let cursor = currentCursor(for: registration) else { return .expired }
        return await waitUntilInteresting(cursor: cursor, timeoutSeconds: timeoutSeconds)
    }

    package func snapshot(for cursor: WaitCursor) -> DomainAgentRunSnapshot? {
        guard let record = currentRecord(for: cursor.registration, operation: "snapshot") else { return nil }
        return latestSnapshot(in: record, cursor: cursor)
    }

    package func snapshot(for registration: Registration) -> DomainAgentRunSnapshot? {
        guard let cursor = currentCursor(for: registration) else { return nil }
        return snapshot(for: cursor)
    }

    package func currentCursor(for registration: Registration) -> WaitCursor? {
        guard let record = currentRecord(for: registration, operation: "current_cursor") else { return nil }
        return WaitCursor(registration: registration, epoch: record.currentEpoch)
    }

    package func currentRegistration(for sessionID: UUID) -> Registration? {
        records[sessionID]?.registration
    }

    package func currentEpoch(for registration: Registration) -> DomainAgentRunTurnEpoch? {
        currentRecord(for: registration, operation: "current_epoch")?.currentEpoch
    }

    package func hasActiveRegistration(sessionID: UUID) -> Bool {
        records[sessionID] != nil
    }

    package func cleanup(registration: Registration) {
        guard let record = currentRecord(for: registration, operation: "cleanup") else { return }
        records.removeValue(forKey: registration.sessionID)
        record.expiryTask?.cancel()
        expireWaiters(record.waiters)
        cancellationHandlers.removeValue(forKey: registration.sessionID)
        updateMetadata(for: record, state: .dormant, resumable: true)
        scheduleMetadataPersistence()
    }

    package func installCancellationHandler(
        registration: Registration,
        handler: @escaping @Sendable () async -> Void
    ) {
        guard currentRecord(for: registration, operation: "install_cancellation") != nil else { return }
        cancellationHandlers[registration.sessionID] = handler
    }

    package func shutdown(deadline: Duration = .seconds(5)) async -> DomainAgentSessionShutdownResult {
        guard !isShuttingDown else {
            return DomainAgentSessionShutdownResult(cooperativeSessionIDs: [], interruptedSessionIDs: [])
        }
        isShuttingDown = true
        let activeRecords = records
        let handlers = cancellationHandlers
        cancellationHandlers.removeAll()
        for record in activeRecords.values {
            record.expiryTask?.cancel()
            resume(record.waiters, with: .cancelled)
        }

        let tracker = DomainAgentCancellationCompletionTracker()
        var cancellationTasks: [UUID: Task<Void, Never>] = [:]
        for (sessionID, handler) in handlers {
            cancellationTasks[sessionID] = Task {
                await handler()
                await tracker.markCompleted(sessionID)
            }
        }
        let clock = ContinuousClock()
        let deadlineInstant = clock.now.advanced(by: deadline)
        let sessionsWithoutHandlers = Set(activeRecords.keys).subtracting(handlers.keys)
        var completedHandlers = await tracker.snapshot()
        while completedHandlers.count < handlers.count, clock.now < deadlineInstant {
            let remaining = clock.now.duration(to: deadlineInstant)
            do {
                try await Task.sleep(for: min(remaining, .milliseconds(10)))
            } catch {
                break
            }
            completedHandlers = await tracker.snapshot()
        }
        completedHandlers = await tracker.snapshot()
        for (sessionID, task) in cancellationTasks where !completedHandlers.contains(sessionID) {
            task.cancel()
        }
        let cooperativeSet = sessionsWithoutHandlers.union(completedHandlers)
        let cooperative = Array(cooperativeSet)
        let interrupted = activeRecords.keys.filter { !cooperativeSet.contains($0) }
        for record in activeRecords.values {
            updateMetadata(
                for: record,
                state: cooperativeSet.contains(record.registration.sessionID) ? .dormant : .interrupted,
                resumable: true
            )
        }
        records.removeAll()
        await persistMetadata()
        return DomainAgentSessionShutdownResult(
            cooperativeSessionIDs: cooperative.sorted { $0.uuidString < $1.uuidString },
            interruptedSessionIDs: interrupted.sorted { $0.uuidString < $1.uuidString }
        )
    }

    private func transitionKind(
        from previousEpoch: DomainAgentRunTurnEpoch?,
        to currentEpoch: DomainAgentRunTurnEpoch
    ) -> DomainAgentRunEpochTransitionKind {
        guard let previousEpoch else { return currentEpoch.transitionKind }
        guard previousEpoch.continuityGeneration == currentEpoch.continuityGeneration else {
            return .unrelated
        }
        return currentEpoch.transitionKind
    }

    private func pruneCommittedEpochStates(in record: inout Record) {
        var protectedEpochIDs = Set(record.waiters.compactMap { $0.cursor.epoch?.id })
        if let currentEpochID = record.currentEpoch?.id {
            protectedEpochIDs.insert(currentEpochID)
        }
        let removableEpochIDs = record.epochStates.values
            .filter { state in
                guard let epoch = state.epoch else { return false }
                return state.terminalCommitID != nil && !protectedEpochIDs.contains(epoch.id)
            }
            .sorted { lhs, rhs in
                (lhs.epoch?.ordinal ?? 0) > (rhs.epoch?.ordinal ?? 0)
            }
            .dropFirst(Self.retainedCommittedEpochLimit)
            .compactMap { $0.epoch?.id }
        for epochID in removableEpochIDs {
            record.epochStates.removeValue(forKey: epochID)
        }
    }

    private func acceptedSnapshot(
        _ snapshot: DomainAgentRunSnapshot,
        existing: DomainAgentRunSnapshot?
    ) -> DomainAgentRunSnapshot {
        guard let existing else { return snapshot }
        if existing.status.isTerminal {
            if snapshot.status.isTerminal, snapshot.updatedAt >= existing.updatedAt {
                return snapshot
            }
            return existing
        }
        if !snapshot.status.isTerminal, existing.updatedAt > snapshot.updatedAt {
            return existing
        }
        return snapshot
    }

    private func updateLatestSnapshot(_ snapshot: DomainAgentRunSnapshot, in record: inout Record, cursor: WaitCursor) {
        if let epoch = cursor.epoch {
            guard var state = record.epochStates[epoch.id], state.epoch == epoch else { return }
            state.latestSnapshot = snapshot
            record.epochStates[epoch.id] = state
        } else {
            record.preEpochState.latestSnapshot = snapshot
        }
    }

    private func latestSnapshot(in record: Record, cursor: WaitCursor) -> DomainAgentRunSnapshot? {
        if let epoch = cursor.epoch {
            return record.epochStates[epoch.id]?.latestSnapshot
        }
        return record.preEpochState.latestSnapshot
    }

    private func terminalPublicationFailure(in record: Record, cursor: WaitCursor) -> String? {
        guard let epoch = cursor.epoch else { return nil }
        return record.epochStates[epoch.id]?.terminalPublicationFailure
    }

    private func pendingWake(in record: Record, cursor: WaitCursor) -> NoteworthyWake? {
        if let epoch = cursor.epoch {
            return record.epochStates[epoch.id]?.pendingNoteworthyWake
        }
        return record.preEpochState.pendingNoteworthyWake
    }

    private func setPendingWake(
        _ wake: NoteworthyWake,
        in record: inout Record,
        cursor: WaitCursor
    ) {
        if let epoch = cursor.epoch {
            guard var state = record.epochStates[epoch.id] else { return }
            state.pendingNoteworthyWake = wake
            record.epochStates[epoch.id] = state
        } else {
            record.preEpochState.pendingNoteworthyWake = wake
        }
    }

    private func clearPendingWake(in record: inout Record, cursor: WaitCursor) {
        if let epoch = cursor.epoch {
            guard var state = record.epochStates[epoch.id] else { return }
            state.pendingNoteworthyWake = nil
            record.epochStates[epoch.id] = state
        } else {
            record.preEpochState.pendingNoteworthyWake = nil
        }
    }

    private func takeWaiters(
        from record: inout Record,
        matching predicate: (Waiter) -> Bool
    ) -> [Waiter] {
        var selected: [Waiter] = []
        record.waiters.removeAll { waiter in
            guard predicate(waiter) else { return false }
            selected.append(waiter)
            return true
        }
        return selected
    }

    private func resume(_ waiters: [Waiter], with disposition: WaitDisposition) {
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: disposition)
        }
    }

    private func cancelWaiter(sessionID: UUID, waiterID: UUID) {
        guard var record = records[sessionID],
              let index = record.waiters.firstIndex(where: { $0.id == waiterID })
        else { return }
        let waiter = record.waiters.remove(at: index)
        records[sessionID] = record
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: .cancelled)
    }

    private func timeoutWaiter(sessionID: UUID, waiterID: UUID) {
        guard var record = records[sessionID],
              let index = record.waiters.firstIndex(where: { $0.id == waiterID })
        else { return }
        let waiter = record.waiters.remove(at: index)
        records[sessionID] = record
        waiter.continuation.resume(returning: .timedOut)
    }

    private func scheduleExpiry(for record: inout Record, cursor: WaitCursor) {
        record.expiryTask?.cancel()
        record.expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.terminalSnapshotTTL * 1_000_000_000))
                await self?.expire(cursor: cursor)
            } catch {}
        }
    }

    private func expire(cursor: WaitCursor) {
        guard let record = currentRecord(for: cursor.registration, operation: "expire"),
              record.currentEpoch == cursor.epoch
        else { return }
        records.removeValue(forKey: cursor.registration.sessionID)
        expireWaiters(record.waiters)
    }

    private func makeRegistration(sessionID: UUID) -> Registration {
        let registration = Registration(
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            sessionID: sessionID,
            generation: nextGeneration
        )
        nextGeneration &+= 1
        return registration
    }

    private func currentRecord(for registration: Registration, operation: String) -> Record? {
        guard registration.runtimeID == identity.runtimeID,
              registration.runtimeGeneration == identity.lifecycleGeneration
        else {
            recordRejectedOperation(operation, supplied: registration, current: nil, reason: "stale_runtime")
            return nil
        }
        guard let record = records[registration.sessionID] else {
            recordRejectedOperation(operation, supplied: registration, current: nil, reason: "missing")
            return nil
        }
        guard record.registration == registration else {
            recordRejectedOperation(operation, supplied: registration, current: record.registration, reason: "stale_generation")
            return nil
        }
        return record
    }

    private func expireWaiters(_ waiters: [Waiter]) {
        resume(waiters, with: .expired)
    }

    private func recordRejectedOperation(
        _ operation: String,
        supplied _: Registration,
        current _: Registration?,
        reason: String
    ) {
        _ = operation
        _ = reason
    }

    private func updateMetadata(
        for record: Record?,
        state: DomainAgentSessionDurableState,
        resumable: Bool
    ) {
        guard let record else { return }
        durableMetadata[record.registration.sessionID] = DomainAgentSessionDurableMetadata(
            sessionID: record.registration.sessionID,
            owningRuntimeID: identity.runtimeID,
            owningRuntimeGeneration: identity.lifecycleGeneration,
            registrationGeneration: record.registration.generation,
            lastEpochOrdinal: record.currentEpoch?.ordinal ?? 0,
            continuityGeneration: record.currentEpoch?.continuityGeneration ?? record.continuityGeneration,
            state: state,
            resumable: resumable,
            updatedAt: Date()
        )
    }

    private func scheduleMetadataPersistence() {
        let snapshot = durableMetadata.values.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
        let url = metadataURL
        let previous = metadataPersistenceTask
        metadataPersistenceTask = Task {
            await previous?.value
            await Task.detached(priority: .utility) {
                try? Self.writeMetadata(snapshot, to: url)
            }.value
        }
    }

    private func persistMetadata() async {
        scheduleMetadataPersistence()
        await metadataPersistenceTask?.value
    }

    private nonisolated static func writeMetadata(
        _ metadata: [DomainAgentSessionDurableMetadata],
        to url: URL
    ) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(metadata)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}

#if DEBUG
    extension DomainAgentRunSessionStore {
        package func test_waiterCount(registration: Registration) -> Int {
            guard records[registration.sessionID]?.registration == registration else { return 0 }
            return records[registration.sessionID]?.waiters.count ?? 0
        }

        package func test_expire(cursor: WaitCursor) {
            expire(cursor: cursor)
        }

        package func test_setTerminalCommitID(_ commitID: UUID, cursor: WaitCursor) {
            guard var record = records[cursor.registration.sessionID],
                  record.registration == cursor.registration,
                  let epoch = cursor.epoch,
                  var state = record.epochStates[epoch.id]
            else { return }
            state.terminalCommitID = commitID
            record.epochStates[epoch.id] = state
            records[cursor.registration.sessionID] = record
        }
    }
#endif
