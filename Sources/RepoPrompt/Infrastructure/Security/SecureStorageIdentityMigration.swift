import Foundation

enum SecureStorageIdentityMigrationRecordState: Equatable {
    case absent
    case copied
    case verified
    case conflict
    case interactionRequired
    case failed

    var isReady: Bool {
        switch self {
        case .absent, .copied, .verified:
            true
        case .conflict, .interactionRequired, .failed:
            false
        }
    }
}

struct SecureStorageIdentityMigrationRecord: Equatable, Identifiable {
    let account: SecureStorageAccount
    let state: SecureStorageIdentityMigrationRecordState

    var id: String {
        account.identifier
    }
}

struct SecureStorageIdentityMigrationReport: Equatable {
    let records: [SecureStorageIdentityMigrationRecord]
    let bridgeReady: Bool
    let completionPersisted: Bool

    var blockedUpdateMessage: String? {
        guard !bridgeReady else { return nil }
        return "Updates are paused because secure credential migration could not be verified. Your existing credentials were not deleted or replaced."
    }
}

struct SecureStorageIdentityMigrationManifest: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let migratedAccountIdentifiers: [String]
}

protocol SecureStorageIdentityMigrationStateStore {
    func load() throws -> SecureStorageIdentityMigrationManifest?
    func save(_ manifest: SecureStorageIdentityMigrationManifest) throws
}

struct UserDefaultsSecureStorageIdentityMigrationStateStore: SecureStorageIdentityMigrationStateStore {
    static let suiteName = "com.repoprompt.ce.identity-migration"
    static let manifestKey = "secure-storage-bridge-v1-manifest"

    enum StoreError: Error {
        case unavailable
        case invalidManifest
    }

    private let defaults: UserDefaults

    init?() {
        guard let defaults = UserDefaults(suiteName: Self.suiteName) else { return nil }
        self.defaults = defaults
    }

    func load() throws -> SecureStorageIdentityMigrationManifest? {
        guard let data = defaults.data(forKey: Self.manifestKey) else { return nil }
        guard let manifest = try? JSONDecoder().decode(SecureStorageIdentityMigrationManifest.self, from: data),
              manifest.version == SecureStorageIdentityMigrationManifest.currentVersion
        else {
            throw StoreError.invalidManifest
        }
        return manifest
    }

    func save(_ manifest: SecureStorageIdentityMigrationManifest) throws {
        let data = try JSONEncoder().encode(manifest)
        defaults.set(data, forKey: Self.manifestKey)
        guard defaults.synchronize() else { throw StoreError.unavailable }
    }
}

/// Copies the closed secure-storage inventory into a new service whose item ACL trusts
/// both signing identities. All operations are noninteractive. Source items are never
/// changed or deleted, and the bridge is not selected until every present value has been
/// read back byte-for-byte and the completion manifest has been persisted.
final class SecureStorageIdentityMigrationCoordinator {
    private let accounts: [SecureStorageAccount]
    private let sourceStore: SecureKeyValueStorageBackend
    private let bridgeStore: SecureKeyValueStorageBackend
    private let stateStore: SecureStorageIdentityMigrationStateStore
    private let accessMode = KeychainAccessMode.nonInteractive(reason: .launch)

    init(
        accounts: [SecureStorageAccount] = SecureStorageAccountCatalog.allAccounts,
        sourceStore: SecureKeyValueStorageBackend,
        bridgeStore: SecureKeyValueStorageBackend,
        stateStore: SecureStorageIdentityMigrationStateStore
    ) {
        self.accounts = accounts
        self.sourceStore = sourceStore
        self.bridgeStore = bridgeStore
        self.stateStore = stateStore
    }

    func prepareBridge() -> SecureStorageIdentityMigrationReport {
        do {
            if let manifest = try stateStore.load() {
                return verifyCommittedBridge(manifest)
            }
        } catch {
            return blockedReport()
        }

        var records: [SecureStorageIdentityMigrationRecord] = []
        var migratedAccountIdentifiers: [String] = []

        for account in accounts {
            let source = read(account, from: sourceStore)
            let bridge = read(account, from: bridgeStore)
            let record = prepare(account, source: source, bridge: bridge)
            records.append(record)
            if source.value != nil {
                migratedAccountIdentifiers.append(account.identifier)
            }
        }

        guard records.allSatisfy(\.state.isReady) else {
            return SecureStorageIdentityMigrationReport(
                records: records,
                bridgeReady: false,
                completionPersisted: false
            )
        }

        let manifest = SecureStorageIdentityMigrationManifest(
            version: SecureStorageIdentityMigrationManifest.currentVersion,
            migratedAccountIdentifiers: migratedAccountIdentifiers.sorted()
        )
        do {
            try stateStore.save(manifest)
        } catch {
            return SecureStorageIdentityMigrationReport(
                records: records,
                bridgeReady: false,
                completionPersisted: false
            )
        }

        return SecureStorageIdentityMigrationReport(
            records: records,
            bridgeReady: true,
            completionPersisted: true
        )
    }

    private struct ReadResult {
        let value: String?
        let failureState: SecureStorageIdentityMigrationRecordState?
    }

    private func read(
        _ account: SecureStorageAccount,
        from store: SecureKeyValueStorageBackend
    ) -> ReadResult {
        do {
            return try ReadResult(
                value: store.get(for: account.identifier, accessMode: accessMode),
                failureState: nil
            )
        } catch KeychainService.KeychainError.itemNotFound {
            return ReadResult(value: nil, failureState: nil)
        } catch KeychainService.KeychainError.interactionNotAllowed {
            return ReadResult(value: nil, failureState: .interactionRequired)
        } catch {
            return ReadResult(value: nil, failureState: .failed)
        }
    }

    private func prepare(
        _ account: SecureStorageAccount,
        source: ReadResult,
        bridge: ReadResult
    ) -> SecureStorageIdentityMigrationRecord {
        if let failureState = source.failureState ?? bridge.failureState {
            return SecureStorageIdentityMigrationRecord(account: account, state: failureState)
        }

        switch (source.value, bridge.value) {
        case (nil, nil):
            return SecureStorageIdentityMigrationRecord(account: account, state: .absent)
        case let (sourceValue?, nil):
            do {
                try bridgeStore.save(sourceValue, for: account.identifier, accessMode: accessMode)
                let verified = try bridgeStore.get(for: account.identifier, accessMode: accessMode)
                return SecureStorageIdentityMigrationRecord(
                    account: account,
                    state: verified == sourceValue ? .copied : .failed
                )
            } catch KeychainService.KeychainError.interactionNotAllowed {
                return SecureStorageIdentityMigrationRecord(account: account, state: .interactionRequired)
            } catch {
                return SecureStorageIdentityMigrationRecord(account: account, state: .failed)
            }
        case let (sourceValue?, bridgeValue?):
            return SecureStorageIdentityMigrationRecord(
                account: account,
                state: sourceValue == bridgeValue ? .verified : .conflict
            )
        case (nil, _?):
            // Before the manifest is committed, a target-only value has no proven origin.
            return SecureStorageIdentityMigrationRecord(account: account, state: .conflict)
        }
    }

    private func verifyCommittedBridge(
        _ manifest: SecureStorageIdentityMigrationManifest
    ) -> SecureStorageIdentityMigrationReport {
        let migrated = Set(manifest.migratedAccountIdentifiers)
        let known = Set(accounts.map(\.identifier))
        guard manifest.version == SecureStorageIdentityMigrationManifest.currentVersion,
              migrated.count == manifest.migratedAccountIdentifiers.count,
              migrated.isSubset(of: known)
        else {
            return blockedReport()
        }
        var records: [SecureStorageIdentityMigrationRecord] = []
        var ready = true

        for account in accounts {
            guard migrated.contains(account.identifier) else {
                records.append(SecureStorageIdentityMigrationRecord(account: account, state: .absent))
                continue
            }
            let result = read(account, from: bridgeStore)
            let state: SecureStorageIdentityMigrationRecordState = if result.value != nil {
                .verified
            } else if let failureState = result.failureState {
                failureState
            } else {
                .failed
            }
            ready = ready && state.isReady
            records.append(SecureStorageIdentityMigrationRecord(account: account, state: state))
        }

        return SecureStorageIdentityMigrationReport(
            records: records,
            bridgeReady: ready,
            completionPersisted: true
        )
    }

    private func blockedReport() -> SecureStorageIdentityMigrationReport {
        SecureStorageIdentityMigrationReport(
            records: accounts.map {
                SecureStorageIdentityMigrationRecord(account: $0, state: .failed)
            },
            bridgeReady: false,
            completionPersisted: false
        )
    }
}

final class IdentityMigrationRuntimeState: @unchecked Sendable {
    static let shared = IdentityMigrationRuntimeState()

    private let lock = NSLock()
    private var blockedMessage: String?

    func setBlockedMessage(_ message: String?) {
        lock.lock()
        blockedMessage = message
        lock.unlock()
    }

    func updatesBlockedMessage() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return blockedMessage
    }
}

enum SecureStorageIdentityMigrationBootstrap {
    static let legacyBundleIdentifier = "com.pvncher.repoprompt.ce"
    static let phaseInfoKey = "RepoPromptIdentityMigrationPhase"
    static let anchorRelativePathInfoKey = "RepoPromptIdentityMigrationAnchorRelativePath"

    enum Phase: String {
        case disabled
        case legacyPreparer = "legacy-preparer"
    }

    static func prepareIfConfigured(bundle: Bundle = .main) {
        guard let rawPhase = bundle.object(forInfoDictionaryKey: phaseInfoKey) as? String,
              let phase = Phase(rawValue: rawPhase),
              phase != .disabled
        else {
            return
        }

        guard phase == .legacyPreparer,
              bundle.bundleIdentifier == legacyBundleIdentifier,
              SecureKeyValueStorageFactory.currentDecision().domain == .officialDeveloperID,
              let executableURL = bundle.executableURL,
              let resourceURL = bundle.resourceURL,
              let relativeAnchorPath = bundle.object(forInfoDictionaryKey: anchorRelativePathInfoKey) as? String,
              !relativeAnchorPath.isEmpty
        else {
            blockUpdates()
            return
        }

        let anchorURL = resourceURL.appendingPathComponent(relativeAnchorPath).standardizedFileURL
        let resourcePath = resourceURL.standardizedFileURL.path
        guard anchorURL.path.hasPrefix(resourcePath + "/"),
              FileManager.default.isExecutableFile(atPath: anchorURL.path),
              let stateStore = UserDefaultsSecureStorageIdentityMigrationStateStore()
        else {
            blockUpdates()
            return
        }

        let attributeProvider = TrustedApplicationsKeychainAttributeProvider(
            descriptor: "RepoPrompt CE identity migration bridge",
            executablePaths: [executableURL.path, anchorURL.path]
        )
        let bridgeStore = KeychainService(
            serviceName: KeychainService.identityMigrationBridgeServiceName,
            itemCreationAttributeProvider: attributeProvider
        )
        let coordinator = SecureStorageIdentityMigrationCoordinator(
            sourceStore: KeychainService.officialV2Shared,
            bridgeStore: bridgeStore,
            stateStore: stateStore
        )
        let report = coordinator.prepareBridge()
        guard report.bridgeReady else {
            IdentityMigrationRuntimeState.shared.setBlockedMessage(report.blockedUpdateMessage)
            return
        }

        SecureKeyValueStorageFactory.installOfficialBackendOverride(bridgeStore)
        IdentityMigrationRuntimeState.shared.setBlockedMessage(nil)
    }

    private static func blockUpdates() {
        IdentityMigrationRuntimeState.shared.setBlockedMessage(
            "Updates are paused because the secure credential migration package is incomplete."
        )
    }
}
