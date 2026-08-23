@testable import RepoPromptApp
import XCTest

final class SecureStorageIdentityMigrationTests: XCTestCase {
    func testCopiesPresentValuesVerifiesThemAndPreservesSource() {
        let source = TestSecureStorageBackend(values: [.openAIAPI: "secret"])
        let bridge = TestSecureStorageBackend()
        let state = TestIdentityMigrationStateStore()
        let coordinator = makeCoordinator(source: source, bridge: bridge, state: state)

        let report = coordinator.prepareBridge()

        XCTAssertTrue(report.bridgeReady)
        XCTAssertTrue(report.completionPersisted)
        XCTAssertEqual(report.records.map(\.state), [.copied, .absent])
        XCTAssertEqual(source.value(for: .openAIAPI), "secret")
        XCTAssertEqual(bridge.value(for: .openAIAPI), "secret")
        XCTAssertFalse(source.calls.contains { $0.operation == .delete })
        XCTAssertFalse(bridge.calls.contains { $0.operation == .delete })
        XCTAssertEqual(
            state.manifest?.migratedAccountIdentifiers,
            [SecureStorageAccount.openAIAPI.identifier]
        )
        XCTAssertTrue((source.calls + bridge.calls).allSatisfy {
            $0.accessMode == .nonInteractive(reason: .launch)
        })
    }

    func testMatchingExistingBridgeValueIsVerifiedWithoutRewrite() {
        let source = TestSecureStorageBackend(values: [.openAIAPI: "secret"])
        let bridge = TestSecureStorageBackend(values: [.openAIAPI: "secret"])
        let coordinator = makeCoordinator(
            source: source,
            bridge: bridge,
            state: TestIdentityMigrationStateStore()
        )

        let report = coordinator.prepareBridge()

        XCTAssertTrue(report.bridgeReady)
        XCTAssertEqual(report.records.first?.state, .verified)
        XCTAssertFalse(bridge.calls.contains { $0.operation == .save })
    }

    func testConflictFailsClosedAndPreservesBothValues() {
        let source = TestSecureStorageBackend(values: [.openAIAPI: "source"])
        let bridge = TestSecureStorageBackend(values: [.openAIAPI: "bridge"])
        let state = TestIdentityMigrationStateStore()
        let coordinator = makeCoordinator(source: source, bridge: bridge, state: state)

        let report = coordinator.prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertEqual(report.records.first?.state, .conflict)
        XCTAssertEqual(source.value(for: .openAIAPI), "source")
        XCTAssertEqual(bridge.value(for: .openAIAPI), "bridge")
        XCTAssertNil(state.manifest)
        XCTAssertFalse((source.calls + bridge.calls).contains { $0.operation == .delete })
    }

    func testTargetOnlyValueBeforeCommitFailsClosed() {
        let source = TestSecureStorageBackend()
        let bridge = TestSecureStorageBackend(values: [.openAIAPI: "unproven"])

        let report = makeCoordinator(
            source: source,
            bridge: bridge,
            state: TestIdentityMigrationStateStore()
        ).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertEqual(report.records.first?.state, .conflict)
    }

    func testInteractionRequirementFailsClosedWithoutPromptingOrWriting() {
        let source = TestSecureStorageBackend()
        source.getErrors[.openAIAPI] = .interactionNotAllowed
        let bridge = TestSecureStorageBackend()

        let report = makeCoordinator(
            source: source,
            bridge: bridge,
            state: TestIdentityMigrationStateStore()
        ).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertEqual(report.records.first?.state, .interactionRequired)
        XCTAssertFalse(bridge.calls.contains { $0.operation == .save })
        XCTAssertTrue((source.calls + bridge.calls).allSatisfy {
            $0.accessMode == .nonInteractive(reason: .launch)
        })
    }

    func testReadBackMismatchDoesNotCommit() {
        let source = TestSecureStorageBackend(values: [.openAIAPI: "source"])
        let bridge = TestSecureStorageBackend()
        bridge.savedValueOverride = "different"
        let state = TestIdentityMigrationStateStore()

        let report = makeCoordinator(source: source, bridge: bridge, state: state).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertEqual(report.records.first?.state, .failed)
        XCTAssertNil(state.manifest)
        XCTAssertEqual(source.value(for: .openAIAPI), "source")
    }

    func testCommittedManifestVerifiesOnlyMigratedBridgeAccounts() {
        let source = TestSecureStorageBackend()
        let bridge = TestSecureStorageBackend(values: [.openAIAPI: "secret"])
        let state = TestIdentityMigrationStateStore(
            manifest: SecureStorageIdentityMigrationManifest(
                version: SecureStorageIdentityMigrationManifest.currentVersion,
                migratedAccountIdentifiers: [SecureStorageAccount.openAIAPI.identifier]
            )
        )

        let report = makeCoordinator(source: source, bridge: bridge, state: state).prepareBridge()

        XCTAssertTrue(report.bridgeReady)
        XCTAssertTrue(source.calls.isEmpty)
        XCTAssertEqual(report.records.map(\.state), [.verified, .absent])
    }

    func testCommittedManifestWithMissingBridgeValueBlocks() {
        let state = TestIdentityMigrationStateStore(
            manifest: SecureStorageIdentityMigrationManifest(
                version: SecureStorageIdentityMigrationManifest.currentVersion,
                migratedAccountIdentifiers: [SecureStorageAccount.openAIAPI.identifier]
            )
        )

        let report = makeCoordinator(
            source: TestSecureStorageBackend(),
            bridge: TestSecureStorageBackend(),
            state: state
        ).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertEqual(report.records.first?.state, .failed)
    }

    func testCommittedManifestWithUnknownAccountBlocks() {
        let state = TestIdentityMigrationStateStore(
            manifest: SecureStorageIdentityMigrationManifest(
                version: SecureStorageIdentityMigrationManifest.currentVersion,
                migratedAccountIdentifiers: ["unknown-account"]
            )
        )

        let report = makeCoordinator(
            source: TestSecureStorageBackend(),
            bridge: TestSecureStorageBackend(),
            state: state
        ).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertTrue(report.records.allSatisfy { $0.state == .failed })
    }

    func testManifestPersistenceFailureLeavesBridgeUnselected() {
        let state = TestIdentityMigrationStateStore(saveError: TestStateError.failed)
        let report = makeCoordinator(
            source: TestSecureStorageBackend(values: [.openAIAPI: "secret"]),
            bridge: TestSecureStorageBackend(),
            state: state
        ).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertFalse(report.completionPersisted)
    }

    private func makeCoordinator(
        source: SecureKeyValueStorageBackend,
        bridge: SecureKeyValueStorageBackend,
        state: SecureStorageIdentityMigrationStateStore
    ) -> SecureStorageIdentityMigrationCoordinator {
        SecureStorageIdentityMigrationCoordinator(
            accounts: [.openAIAPI, .anthropicAPI],
            sourceStore: source,
            bridgeStore: bridge,
            stateStore: state
        )
    }
}

private enum TestStateError: Error {
    case failed
}

private final class TestIdentityMigrationStateStore: SecureStorageIdentityMigrationStateStore {
    private(set) var manifest: SecureStorageIdentityMigrationManifest?
    private let saveError: Error?

    init(
        manifest: SecureStorageIdentityMigrationManifest? = nil,
        saveError: Error? = nil
    ) {
        self.manifest = manifest
        self.saveError = saveError
    }

    func load() throws -> SecureStorageIdentityMigrationManifest? {
        manifest
    }

    func save(_ manifest: SecureStorageIdentityMigrationManifest) throws {
        if let saveError { throw saveError }
        self.manifest = manifest
    }
}
