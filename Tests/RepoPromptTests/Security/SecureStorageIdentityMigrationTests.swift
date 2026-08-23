import Foundation
@testable import RepoPromptApp
import XCTest

final class SecureStorageIdentityMigrationTests: XCTestCase {
    private let accounts: [SecureStorageAccount] = [.openAIAPI, .anthropicAPI]

    func testPreparationCopiesValuesCommitsBothManifestsAndPreservesSource() throws {
        let source = MigrationTestBackend(values: [SecureStorageAccount.openAIAPI.identifier: "secret"])
        let bridge = MigrationTestBackend()
        let state = TestIdentityMigrationStateStore()
        var attemptIdentifiers: [String] = []
        let coordinator = makeCoordinator(source: source, state: state) { attemptIdentifier in
            attemptIdentifiers.append(attemptIdentifier)
            return bridge
        }

        let report = coordinator.prepareBridge()

        XCTAssertTrue(report.bridgeReady)
        XCTAssertEqual(report.records.map(\.state), [.copied, .absent])
        XCTAssertEqual(source.value(for: SecureStorageAccount.openAIAPI.identifier), "secret")
        XCTAssertEqual(bridge.value(for: SecureStorageAccount.openAIAPI.identifier), "secret")
        XCTAssertFalse(source.calls.contains { $0.operation == .delete })
        XCTAssertEqual(state.savedManifests.map(\.status), [.preparing, .committed])

        let committed = try XCTUnwrap(state.manifest)
        XCTAssertEqual(committed.version, SecureStorageIdentityMigrationManifest.currentVersion)
        XCTAssertEqual(committed.status, .committed)
        XCTAssertEqual(committed.catalogIdentifiers, accounts.map(\.identifier).sorted())
        XCTAssertEqual(attemptIdentifiers, [committed.attemptIdentifier])
        XCTAssertEqual(
            bridge.value(for: SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount),
            SecureStorageIdentityMigrationCoordinator.encodeManifest(committed)
        )
        XCTAssertTrue((source.calls + bridge.calls).allSatisfy {
            $0.accessMode == .nonInteractive(reason: .launch)
        })
    }

    func testPreflightReadFailureWritesNeitherJournalNorBridge() {
        let source = MigrationTestBackend()
        source.getErrors[SecureStorageAccount.openAIAPI.identifier] = .interactionNotAllowed
        let bridge = MigrationTestBackend()
        let state = TestIdentityMigrationStateStore()
        var factoryCallCount = 0
        let coordinator = makeCoordinator(source: source, state: state) { _ in
            factoryCallCount += 1
            return bridge
        }

        let report = coordinator.prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertEqual(report.records.first?.state, .interactionRequired)
        XCTAssertTrue(report.blockedUpdateMessage?.contains("login Keychain is locked or unavailable") == true)
        XCTAssertTrue(state.savedManifests.isEmpty)
        XCTAssertEqual(factoryCallCount, 0)
        XCTAssertTrue(bridge.calls.isEmpty)
    }

    func testPreflightPreservesCancelledAndAuthenticationFailures() {
        let cancellationSource = MigrationTestBackend()
        cancellationSource.getErrors[SecureStorageAccount.openAIAPI.identifier] = .userInteractionCancelled

        let cancellationReport = makeCoordinator(
            source: cancellationSource,
            bridge: MigrationTestBackend(),
            state: TestIdentityMigrationStateStore()
        ).prepareBridge()

        XCTAssertEqual(cancellationReport.records.first?.state, .userInteractionCancelled)
        XCTAssertTrue(cancellationReport.blockedUpdateMessage?.contains("Keychain access was cancelled") == true)

        let authenticationSource = MigrationTestBackend()
        authenticationSource.getErrors[SecureStorageAccount.openAIAPI.identifier] = .authenticationFailed

        let authenticationReport = makeCoordinator(
            source: authenticationSource,
            bridge: MigrationTestBackend(),
            state: TestIdentityMigrationStateStore()
        ).prepareBridge()

        XCTAssertEqual(authenticationReport.records.first?.state, .authenticationFailed)
        XCTAssertTrue(authenticationReport.blockedUpdateMessage?.contains("Keychain authentication failed") == true)
    }

    func testInterruptedPreparationResumesFromSourceAndCommits() throws {
        let source = MigrationTestBackend(values: [
            SecureStorageAccount.openAIAPI.identifier: "openai-v1",
            SecureStorageAccount.anthropicAPI.identifier: "anthropic"
        ])
        let bridge = MigrationTestBackend()
        bridge.createErrors[SecureStorageAccount.anthropicAPI.identifier] = .unexpectedStatus(-1)
        let state = TestIdentityMigrationStateStore()
        let coordinator = makeCoordinator(source: source, bridge: bridge, state: state)

        let firstReport = coordinator.prepareBridge()

        XCTAssertFalse(firstReport.bridgeReady)
        XCTAssertEqual(firstReport.records.map(\.state), [.copied, .failed])
        XCTAssertEqual(state.manifest?.status, .preparing)
        XCTAssertEqual(bridge.value(for: SecureStorageAccount.openAIAPI.identifier), "openai-v1")

        source.setValue("openai-v2", for: SecureStorageAccount.openAIAPI.identifier)
        bridge.createErrors.removeValue(forKey: SecureStorageAccount.anthropicAPI.identifier)

        let resumedReport = coordinator.prepareBridge()

        XCTAssertTrue(resumedReport.bridgeReady)
        XCTAssertEqual(resumedReport.records.map(\.state), [.copied, .copied])
        XCTAssertEqual(bridge.value(for: SecureStorageAccount.openAIAPI.identifier), "openai-v2")
        XCTAssertEqual(bridge.value(for: SecureStorageAccount.anthropicAPI.identifier), "anthropic")
        XCTAssertEqual(try XCTUnwrap(state.manifest).status, .committed)
    }

    func testPreparingJournalRemovesAttemptScopedValueWhenSourceWasDeleted() {
        let manifest = makeManifest(status: .preparing)
        let source = MigrationTestBackend()
        let bridge = MigrationTestBackend(values: [SecureStorageAccount.openAIAPI.identifier: "stale"])
        let state = TestIdentityMigrationStateStore(manifest: manifest)

        let report = makeCoordinator(source: source, bridge: bridge, state: state).prepareBridge()

        XCTAssertTrue(report.bridgeReady)
        XCTAssertNil(bridge.value(for: SecureStorageAccount.openAIAPI.identifier))
        XCTAssertTrue(bridge.calls.contains {
            $0.operation == .delete && $0.key == SecureStorageAccount.openAIAPI.identifier
        })
    }

    func testCommittedManifestUsesSingleBridgeManifestRead() throws {
        let manifest = makeManifest(status: .committed)
        let encoded = try XCTUnwrap(SecureStorageIdentityMigrationCoordinator.encodeManifest(manifest))
        XCTAssertEqual(
            encoded,
            #"{"attemptIdentifier":"attempt-123","catalogIdentifiers":["AnthropicAPI","OpenAIAPI"],"status":"committed","version":2}"#
        )
        let source = MigrationTestBackend()
        let bridge = MigrationTestBackend(values: [
            SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount: encoded
        ])
        let state = TestIdentityMigrationStateStore(manifest: manifest)

        let report = makeCoordinator(source: source, bridge: bridge, state: state).prepareBridge()

        XCTAssertTrue(report.bridgeReady)
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertTrue(source.calls.isEmpty)
        XCTAssertEqual(bridge.calls.map(\.key), [SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount])
    }

    func testCommittedJournalWithoutMatchingBridgeManifestBlocks() {
        let manifest = makeManifest(status: .committed)

        let report = makeCoordinator(
            source: MigrationTestBackend(),
            bridge: MigrationTestBackend(),
            state: TestIdentityMigrationStateStore(manifest: manifest)
        ).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertEqual(report.blockingState, .failed)
    }

    func testInvalidJournalBlocksWithoutReadingCredentials() {
        let invalidManifest = SecureStorageIdentityMigrationManifest(
            version: SecureStorageIdentityMigrationManifest.currentVersion,
            status: .committed,
            attemptIdentifier: "",
            catalogIdentifiers: accounts.map(\.identifier).sorted()
        )
        let source = MigrationTestBackend()
        let bridge = MigrationTestBackend()

        let report = makeCoordinator(
            source: source,
            bridge: bridge,
            state: TestIdentityMigrationStateStore(manifest: invalidManifest)
        ).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertTrue(source.calls.isEmpty)
        XCTAssertTrue(bridge.calls.isEmpty)
    }

    func testJournalAuthenticationFailureKeepsSpecificBlockedReason() {
        let source = MigrationTestBackend()
        let state = TestIdentityMigrationStateStore(loadError: KeychainService.KeychainError.authenticationFailed)

        let report = makeCoordinator(
            source: source,
            bridge: MigrationTestBackend(),
            state: state
        ).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertEqual(report.blockingState, .authenticationFailed)
        XCTAssertTrue(report.blockedUpdateMessage?.contains("Keychain authentication failed") == true)
        XCTAssertTrue(source.calls.isEmpty)
    }

    func testPreparingJournalPersistenceFailureLeavesBridgeUntouched() {
        let source = MigrationTestBackend(values: [SecureStorageAccount.openAIAPI.identifier: "secret"])
        let bridge = MigrationTestBackend()
        let state = TestIdentityMigrationStateStore(saveFailuresRemaining: 1)
        var factoryCallCount = 0
        let coordinator = makeCoordinator(source: source, state: state) { _ in
            factoryCallCount += 1
            return bridge
        }

        let report = coordinator.prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertEqual(factoryCallCount, 0)
        XCTAssertTrue(bridge.calls.isEmpty)
    }

    func testCorruptJournalIsResetAndMigrationRetriesFromIntactSource() {
        let journalBackend = MigrationTestBackend(values: [
            KeychainSecureStorageIdentityMigrationStateStore.account: "not-json"
        ])
        let state = KeychainSecureStorageIdentityMigrationStateStore(store: journalBackend)
        let source = MigrationTestBackend(values: [SecureStorageAccount.openAIAPI.identifier: "secret"])
        let bridge = MigrationTestBackend()

        let report = makeCoordinator(source: source, bridge: bridge, state: state).prepareBridge()

        XCTAssertTrue(report.bridgeReady)
        XCTAssertEqual(bridge.value(for: SecureStorageAccount.openAIAPI.identifier), "secret")
        XCTAssertTrue(journalBackend.calls.contains {
            $0.operation == .delete && $0.key == KeychainSecureStorageIdentityMigrationStateStore.account
        })
    }

    func testBridgeManifestPersistenceFailureLeavesJournalPreparing() {
        let source = MigrationTestBackend(values: [SecureStorageAccount.openAIAPI.identifier: "secret"])
        let bridge = MigrationTestBackend()
        bridge.createErrors[SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount] = .unexpectedStatus(-1)
        let state = TestIdentityMigrationStateStore()

        let report = makeCoordinator(source: source, bridge: bridge, state: state).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertEqual(state.manifest?.status, .preparing)
        XCTAssertEqual(state.savedManifests.map(\.status), [.preparing])
    }

    func testBridgeManifestAuthenticationFailureKeepsSpecificBlockedReason() {
        let source = MigrationTestBackend(values: [SecureStorageAccount.openAIAPI.identifier: "secret"])
        let bridge = MigrationTestBackend()
        bridge.createErrors[SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount] = .authenticationFailed
        let state = TestIdentityMigrationStateStore()

        let report = makeCoordinator(source: source, bridge: bridge, state: state).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertEqual(report.blockingState, .authenticationFailed)
        XCTAssertTrue(report.blockedUpdateMessage?.contains("Keychain authentication failed") == true)
        XCTAssertEqual(state.manifest?.status, .preparing)
    }

    func testAnchorValidationAcceptsOnlyExecutableRegularFileInsideResources() throws {
        let fixture = try makeAnchorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            SecureStorageIdentityMigrationBootstrap.validatedAnchorURL(
                relativePath: "IdentityMigration/anchor",
                resourceURL: fixture.resources
            ),
            fixture.anchor.standardizedFileURL
        )
    }

    func testConfiguredPhaseAcceptsOnlyKnownLiteralValues() {
        XCTAssertEqual(SecureStorageIdentityMigrationBootstrap.configuredPhase(from: "disabled"), .disabled)
        XCTAssertEqual(
            SecureStorageIdentityMigrationBootstrap.configuredPhase(from: "legacy-preparer"),
            .legacyPreparer
        )
        XCTAssertNil(SecureStorageIdentityMigrationBootstrap.configuredPhase(from: "legacy_preparer"))
        XCTAssertNil(SecureStorageIdentityMigrationBootstrap.configuredPhase(from: nil))
        XCTAssertNil(SecureStorageIdentityMigrationBootstrap.configuredPhase(from: 1))
    }

    func testAnchorValidationRejectsSymlinkAndPathEscape() throws {
        let fixture = try makeAnchorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let symlink = fixture.resources.appendingPathComponent("IdentityMigration/anchor-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.anchor)

        XCTAssertNil(SecureStorageIdentityMigrationBootstrap.validatedAnchorURL(
            relativePath: "IdentityMigration/anchor-link",
            resourceURL: fixture.resources
        ))
        XCTAssertNil(SecureStorageIdentityMigrationBootstrap.validatedAnchorURL(
            relativePath: "../outside-anchor",
            resourceURL: fixture.resources
        ))
    }

    private func makeManifest(
        status: SecureStorageIdentityMigrationManifest.Status
    ) -> SecureStorageIdentityMigrationManifest {
        SecureStorageIdentityMigrationManifest(
            version: SecureStorageIdentityMigrationManifest.currentVersion,
            status: status,
            attemptIdentifier: "attempt-123",
            catalogIdentifiers: accounts.map(\.identifier).sorted()
        )
    }

    private func makeCoordinator(
        source: SecureKeyValueStorageBackend,
        bridge: SecureKeyValueStorageBackend,
        state: SecureStorageIdentityMigrationStateStore
    ) -> SecureStorageIdentityMigrationCoordinator {
        makeCoordinator(source: source, state: state) { _ in bridge }
    }

    private func makeCoordinator(
        source: SecureKeyValueStorageBackend,
        state: SecureStorageIdentityMigrationStateStore,
        bridgeFactory: @escaping SecureStorageIdentityMigrationCoordinator.BridgeStoreFactory
    ) -> SecureStorageIdentityMigrationCoordinator {
        SecureStorageIdentityMigrationCoordinator(
            accounts: accounts,
            sourceStore: source,
            bridgeStoreFactory: bridgeFactory,
            stateStore: state
        )
    }

    private func makeAnchorFixture() throws -> (root: URL, resources: URL, anchor: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-identity-migration-tests-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("Resources")
        let anchorDirectory = resources.appendingPathComponent("IdentityMigration")
        try FileManager.default.createDirectory(at: anchorDirectory, withIntermediateDirectories: true)
        let anchor = anchorDirectory.appendingPathComponent("anchor")
        try Data("anchor".utf8).write(to: anchor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: anchor.path)
        return (root, resources, anchor)
    }
}

private enum TestStateError: Error {
    case failed
}

private final class TestIdentityMigrationStateStore: SecureStorageIdentityMigrationStateStore {
    private(set) var manifest: SecureStorageIdentityMigrationManifest?
    private(set) var savedManifests: [SecureStorageIdentityMigrationManifest] = []
    var loadError: Error?
    var saveFailuresRemaining: Int

    init(
        manifest: SecureStorageIdentityMigrationManifest? = nil,
        loadError: Error? = nil,
        saveFailuresRemaining: Int = 0
    ) {
        self.manifest = manifest
        self.loadError = loadError
        self.saveFailuresRemaining = saveFailuresRemaining
    }

    func load() throws -> SecureStorageIdentityMigrationManifest? {
        if let loadError { throw loadError }
        return manifest
    }

    func save(_ manifest: SecureStorageIdentityMigrationManifest) throws {
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw TestStateError.failed
        }
        savedManifests.append(manifest)
        self.manifest = manifest
    }

    func reset() throws {
        manifest = nil
    }
}

private final class MigrationTestBackend: SecureKeyValueStorageBackend, @unchecked Sendable {
    enum Operation: Equatable {
        case get
        case save
        case create
        case delete
    }

    struct Call: Equatable {
        let operation: Operation
        let key: String
        let accessMode: KeychainAccessMode
    }

    let persistsValuesAcrossLaunches = true
    var getErrors: [String: KeychainService.KeychainError] = [:]
    var saveErrors: [String: KeychainService.KeychainError] = [:]
    var createErrors: [String: KeychainService.KeychainError] = [:]
    var deleteErrors: [String: KeychainService.KeychainError] = [:]

    private var values: [String: String]
    private(set) var calls: [Call] = []
    private let lock = NSRecursiveLock()

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func save(_ value: String, for key: String, accessMode: KeychainAccessMode) throws {
        try withLock {
            calls.append(Call(operation: .save, key: key, accessMode: accessMode))
            if let error = saveErrors[key] { throw error }
            values[key] = value
        }
    }

    func create(_ value: String, for key: String, accessMode: KeychainAccessMode) throws {
        try withLock {
            calls.append(Call(operation: .create, key: key, accessMode: accessMode))
            if let error = createErrors[key] { throw error }
            guard values[key] == nil else { throw KeychainService.KeychainError.duplicateItem }
            values[key] = value
        }
    }

    func get(for key: String, accessMode: KeychainAccessMode) throws -> String {
        try withLock {
            calls.append(Call(operation: .get, key: key, accessMode: accessMode))
            if let error = getErrors[key] { throw error }
            guard let value = values[key] else { throw KeychainService.KeychainError.itemNotFound }
            return value
        }
    }

    func delete(for key: String, accessMode: KeychainAccessMode) throws {
        try withLock {
            calls.append(Call(operation: .delete, key: key, accessMode: accessMode))
            if let error = deleteErrors[key] { throw error }
            values.removeValue(forKey: key)
        }
    }

    func setValue(_ value: String?, for key: String) {
        withLock { values[key] = value }
    }

    func value(for key: String) -> String? {
        withLock { values[key] }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
