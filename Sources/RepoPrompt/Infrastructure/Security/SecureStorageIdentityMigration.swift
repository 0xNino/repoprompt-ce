import Foundation

enum SecureStorageIdentityMigrationRecordState: Equatable {
    case absent
    case copied
    case verified
    case interactionRequired
    case userInteractionCancelled
    case authenticationFailed
    case failed

    var isReady: Bool {
        switch self {
        case .absent, .copied, .verified:
            true
        case .interactionRequired, .userInteractionCancelled, .authenticationFailed, .failed:
            false
        }
    }

    static func failureState(for error: Error) -> SecureStorageIdentityMigrationRecordState {
        switch error {
        case KeychainService.KeychainError.interactionNotAllowed:
            .interactionRequired
        case KeychainService.KeychainError.userInteractionCancelled:
            .userInteractionCancelled
        case KeychainService.KeychainError.authenticationFailed:
            .authenticationFailed
        default:
            .failed
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
    let blockingState: SecureStorageIdentityMigrationRecordState?

    var blockedUpdateMessage: String? {
        guard !bridgeReady else { return nil }
        let states = records.map(\.state) + [blockingState].compactMap(\.self)
        if states.contains(.userInteractionCancelled) {
            return "Updates are paused because Keychain access was cancelled. Quit and reopen RepoPrompt CE to retry, then approve Keychain access if prompted. Your existing credentials were not deleted."
        }
        if states.contains(.authenticationFailed) {
            return "Updates are paused because Keychain authentication failed. Unlock your login Keychain, then quit and reopen RepoPrompt CE to retry. Your existing credentials were not deleted."
        }
        if states.contains(.interactionRequired) {
            return "Updates are paused because the login Keychain is locked or unavailable. Unlock it, then quit and reopen RepoPrompt CE to retry. Your existing credentials were not deleted."
        }
        return "Updates are paused because secure credential migration could not be verified. Quit and reopen RepoPrompt CE to retry. Your existing credentials were not deleted."
    }
}

struct SecureStorageIdentityMigrationManifest: Codable, Equatable {
    static let currentVersion = 2

    enum Status: String, Codable {
        case preparing
        case committed
    }

    let version: Int
    let status: Status
    let attemptIdentifier: String
    let catalogIdentifiers: [String]

    func changingStatus(to status: Status) -> SecureStorageIdentityMigrationManifest {
        SecureStorageIdentityMigrationManifest(
            version: version,
            status: status,
            attemptIdentifier: attemptIdentifier,
            catalogIdentifiers: catalogIdentifiers
        )
    }
}

protocol SecureStorageIdentityMigrationStateStore {
    func load() throws -> SecureStorageIdentityMigrationManifest?
    func save(_ manifest: SecureStorageIdentityMigrationManifest) throws
    func reset() throws
}

/// A Keychain item is the durable migration journal and authority. Production preparers
/// create it with the same validated dual-identity ACL as the bridge so the successor can
/// discover the committed bridge marker. Unlike preferences, another same-user process
/// cannot silently rewrite it without satisfying that Keychain ACL.
struct KeychainSecureStorageIdentityMigrationStateStore: SecureStorageIdentityMigrationStateStore {
    static let account = "RepoPromptIdentityMigrationStateV2"

    enum StoreError: Error {
        case invalidManifest
        case verificationFailed
    }

    private let store: SecureKeyValueStorageBackend
    private let accessMode = KeychainAccessMode.nonInteractive(reason: .launch)

    init(
        store: SecureKeyValueStorageBackend = KeychainService(
            serviceName: KeychainService.identityMigrationLegacyStateServiceName
        )
    ) {
        self.store = store
    }

    func load() throws -> SecureStorageIdentityMigrationManifest? {
        let value: String
        do {
            value = try store.get(for: Self.account, accessMode: accessMode)
        } catch KeychainService.KeychainError.itemNotFound {
            return nil
        }
        guard let data = value.data(using: .utf8),
              let manifest = try? JSONDecoder().decode(SecureStorageIdentityMigrationManifest.self, from: data)
        else {
            throw StoreError.invalidManifest
        }
        return manifest
    }

    func save(_ manifest: SecureStorageIdentityMigrationManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard let value = String(data: data, encoding: .utf8) else {
            throw StoreError.invalidManifest
        }
        try store.save(value, for: Self.account, accessMode: accessMode)
        guard try store.get(for: Self.account, accessMode: accessMode) == value else {
            throw StoreError.verificationFailed
        }
    }

    func reset() throws {
        try store.delete(for: Self.account, accessMode: accessMode)
        do {
            _ = try store.get(for: Self.account, accessMode: accessMode)
            throw StoreError.verificationFailed
        } catch KeychainService.KeychainError.itemNotFound {
            return
        }
    }
}

/// Copies the closed secure-storage inventory into a new service whose item ACL trusts
/// both signing identities. A legacy-Keychain journal is committed before mutation, so
/// interrupted attempts can reconcile only items carrying that attempt's random marker.
final class SecureStorageIdentityMigrationCoordinator {
    typealias BridgeStoreFactory = (String) -> SecureKeyValueStorageBackend

    private enum CoordinatorError: Error {
        case manifestEncodingFailed
        case manifestConflict
        case manifestVerificationFailed
    }

    static let bridgeManifestAccount = "RepoPromptIdentityMigrationBridgeManifestV2"

    private let accounts: [SecureStorageAccount]
    private let sourceStore: SecureKeyValueStorageBackend
    private let bridgeStoreFactory: BridgeStoreFactory
    private let stateStore: SecureStorageIdentityMigrationStateStore
    private let accessMode = KeychainAccessMode.nonInteractive(reason: .launch)

    init(
        accounts: [SecureStorageAccount] = SecureStorageAccountCatalog.allAccounts,
        sourceStore: SecureKeyValueStorageBackend,
        bridgeStoreFactory: @escaping BridgeStoreFactory,
        stateStore: SecureStorageIdentityMigrationStateStore
    ) {
        self.accounts = accounts
        self.sourceStore = sourceStore
        self.bridgeStoreFactory = bridgeStoreFactory
        self.stateStore = stateStore
    }

    func prepareBridge() -> SecureStorageIdentityMigrationReport {
        let existingManifest: SecureStorageIdentityMigrationManifest?
        do {
            existingManifest = try stateStore.load()
        } catch KeychainSecureStorageIdentityMigrationStateStore.StoreError.invalidManifest {
            do {
                try stateStore.reset()
            } catch {
                return blockedReport(error: error)
            }
            return prepareBridge()
        } catch {
            return blockedReport(error: error)
        }

        if let existingManifest {
            guard isStructurallyValid(existingManifest) else { return blockedReport() }
            switch existingManifest.status {
            case .preparing:
                return resumePreparation(existingManifest)
            case .committed:
                return verifyCommittedBridge(existingManifest)
            }
        }

        let sourceResults = readAll(from: sourceStore)
        let preflightRecords = recordsForReadFailures(sourceResults)
        guard preflightRecords.allSatisfy(\.state.isReady) else {
            return failedReport(records: preflightRecords)
        }

        let manifest = SecureStorageIdentityMigrationManifest(
            version: SecureStorageIdentityMigrationManifest.currentVersion,
            status: .preparing,
            attemptIdentifier: UUID().uuidString.lowercased(),
            catalogIdentifiers: expectedCatalogIdentifiers
        )
        do {
            try stateStore.save(manifest)
        } catch {
            return failedReport(records: preflightRecords, error: error)
        }
        return resumePreparation(manifest, sourceResults: sourceResults)
    }

    private struct ReadResult {
        let value: String?
        let failureState: SecureStorageIdentityMigrationRecordState?
    }

    private var expectedCatalogIdentifiers: [String] {
        accounts.map(\.identifier).sorted()
    }

    private func isStructurallyValid(_ manifest: SecureStorageIdentityMigrationManifest) -> Bool {
        manifest.version == SecureStorageIdentityMigrationManifest.currentVersion
            && !manifest.attemptIdentifier.isEmpty
            && manifest.catalogIdentifiers == expectedCatalogIdentifiers
    }

    private func readAll(from store: SecureKeyValueStorageBackend) -> [SecureStorageAccount: ReadResult] {
        Dictionary(uniqueKeysWithValues: accounts.map { account in
            (account, read(account.identifier, from: store))
        })
    }

    private func read(_ key: String, from store: SecureKeyValueStorageBackend) -> ReadResult {
        do {
            return try ReadResult(
                value: store.get(for: key, accessMode: accessMode),
                failureState: nil
            )
        } catch KeychainService.KeychainError.itemNotFound {
            return ReadResult(value: nil, failureState: nil)
        } catch KeychainService.KeychainError.interactionNotAllowed {
            return ReadResult(value: nil, failureState: .interactionRequired)
        } catch KeychainService.KeychainError.userInteractionCancelled {
            return ReadResult(value: nil, failureState: .userInteractionCancelled)
        } catch KeychainService.KeychainError.authenticationFailed {
            return ReadResult(value: nil, failureState: .authenticationFailed)
        } catch {
            return ReadResult(value: nil, failureState: .failed)
        }
    }

    private func recordsForReadFailures(
        _ results: [SecureStorageAccount: ReadResult]
    ) -> [SecureStorageIdentityMigrationRecord] {
        accounts.map { account in
            let result = results[account]
            return SecureStorageIdentityMigrationRecord(
                account: account,
                state: result?.failureState ?? (result?.value == nil ? .absent : .verified)
            )
        }
    }

    private func resumePreparation(
        _ manifest: SecureStorageIdentityMigrationManifest,
        sourceResults suppliedSourceResults: [SecureStorageAccount: ReadResult]? = nil
    ) -> SecureStorageIdentityMigrationReport {
        let bridgeStore = bridgeStoreFactory(manifest.attemptIdentifier)
        let sourceResults = suppliedSourceResults ?? readAll(from: sourceStore)
        let bridgeResults = readAll(from: bridgeStore)
        let preflightRecords = zipResults(source: sourceResults, bridge: bridgeResults)
        guard preflightRecords.allSatisfy(\.state.isReady) else {
            return failedReport(records: preflightRecords)
        }

        var records: [SecureStorageIdentityMigrationRecord] = []
        for account in accounts {
            guard let source = sourceResults[account], let bridge = bridgeResults[account] else {
                records.append(SecureStorageIdentityMigrationRecord(account: account, state: .failed))
                continue
            }
            records.append(reconcile(account, source: source, bridge: bridge, bridgeStore: bridgeStore))
        }
        guard records.allSatisfy(\.state.isReady) else {
            return failedReport(records: records)
        }

        if let verificationFailure = verifyValuesMatch(bridgeStore: bridgeStore) {
            return failedReport(records: records, blockingState: verificationFailure)
        }

        let committedManifest = manifest.changingStatus(to: .committed)
        do {
            try persistBridgeManifest(committedManifest, bridgeStore: bridgeStore)
        } catch {
            return failedReport(records: records, error: error)
        }
        do {
            try stateStore.save(committedManifest)
        } catch {
            return failedReport(records: records, error: error)
        }
        return SecureStorageIdentityMigrationReport(
            records: records,
            bridgeReady: true,
            blockingState: nil
        )
    }

    private func zipResults(
        source: [SecureStorageAccount: ReadResult],
        bridge: [SecureStorageAccount: ReadResult]
    ) -> [SecureStorageIdentityMigrationRecord] {
        accounts.map { account in
            let failure = source[account]?.failureState ?? bridge[account]?.failureState
            return SecureStorageIdentityMigrationRecord(
                account: account,
                state: failure ?? .verified
            )
        }
    }

    private func reconcile(
        _ account: SecureStorageAccount,
        source: ReadResult,
        bridge: ReadResult,
        bridgeStore: SecureKeyValueStorageBackend
    ) -> SecureStorageIdentityMigrationRecord {
        guard source.failureState == nil, bridge.failureState == nil else {
            return SecureStorageIdentityMigrationRecord(
                account: account,
                state: source.failureState ?? bridge.failureState ?? .failed
            )
        }

        do {
            switch (source.value, bridge.value) {
            case (nil, nil):
                return SecureStorageIdentityMigrationRecord(account: account, state: .absent)
            case let (sourceValue?, nil):
                try bridgeStore.create(sourceValue, for: account.identifier, accessMode: accessMode)
                let verified = try bridgeStore.get(for: account.identifier, accessMode: accessMode)
                return SecureStorageIdentityMigrationRecord(
                    account: account,
                    state: verified == sourceValue ? .copied : .failed
                )
            case let (sourceValue?, bridgeValue?):
                if sourceValue == bridgeValue {
                    return SecureStorageIdentityMigrationRecord(account: account, state: .verified)
                }
                // The random item marker and preparing journal prove this is an
                // interrupted attempt. The source remains authoritative until commit.
                try bridgeStore.save(sourceValue, for: account.identifier, accessMode: accessMode)
                let verified = try bridgeStore.get(for: account.identifier, accessMode: accessMode)
                return SecureStorageIdentityMigrationRecord(
                    account: account,
                    state: verified == sourceValue ? .copied : .failed
                )
            case (nil, _?):
                try bridgeStore.delete(for: account.identifier, accessMode: accessMode)
                do {
                    _ = try bridgeStore.get(for: account.identifier, accessMode: accessMode)
                    return SecureStorageIdentityMigrationRecord(account: account, state: .failed)
                } catch KeychainService.KeychainError.itemNotFound {
                    return SecureStorageIdentityMigrationRecord(account: account, state: .absent)
                }
            }
        } catch {
            return SecureStorageIdentityMigrationRecord(
                account: account,
                state: SecureStorageIdentityMigrationRecordState.failureState(for: error)
            )
        }
    }

    private func verifyValuesMatch(
        bridgeStore: SecureKeyValueStorageBackend
    ) -> SecureStorageIdentityMigrationRecordState? {
        let sourceResults = readAll(from: sourceStore)
        let bridgeResults = readAll(from: bridgeStore)
        for account in accounts {
            guard let source = sourceResults[account],
                  let bridge = bridgeResults[account]
            else {
                return .failed
            }
            if let failureState = source.failureState ?? bridge.failureState {
                return failureState
            }
            guard source.value == bridge.value else { return .failed }
        }
        return nil
    }

    private func persistBridgeManifest(
        _ manifest: SecureStorageIdentityMigrationManifest,
        bridgeStore: SecureKeyValueStorageBackend
    ) throws {
        guard let encoded = Self.encodeManifest(manifest) else {
            throw CoordinatorError.manifestEncodingFailed
        }
        let existingValue: String?
        do {
            existingValue = try bridgeStore.get(for: Self.bridgeManifestAccount, accessMode: accessMode)
        } catch KeychainService.KeychainError.itemNotFound {
            existingValue = nil
        }
        if let existingValue {
            guard existingValue == encoded else { throw CoordinatorError.manifestConflict }
        } else {
            try bridgeStore.create(encoded, for: Self.bridgeManifestAccount, accessMode: accessMode)
        }
        guard try bridgeStore.get(
            for: Self.bridgeManifestAccount,
            accessMode: accessMode
        ) == encoded else {
            throw CoordinatorError.manifestVerificationFailed
        }
    }

    private func verifyCommittedBridge(
        _ manifest: SecureStorageIdentityMigrationManifest
    ) -> SecureStorageIdentityMigrationReport {
        let bridgeStore = bridgeStoreFactory(manifest.attemptIdentifier)
        guard let encoded = Self.encodeManifest(manifest) else {
            return blockedReport()
        }
        do {
            guard try bridgeStore.get(
                for: Self.bridgeManifestAccount,
                accessMode: accessMode
            ) == encoded else {
                return blockedReport()
            }
        } catch {
            return blockedReport(error: error)
        }
        return SecureStorageIdentityMigrationReport(
            records: [],
            bridgeReady: true,
            blockingState: nil
        )
    }

    static func encodeManifest(_ manifest: SecureStorageIdentityMigrationManifest) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func failedReport(
        records: [SecureStorageIdentityMigrationRecord],
        error: Error? = nil,
        blockingState: SecureStorageIdentityMigrationRecordState? = nil
    ) -> SecureStorageIdentityMigrationReport {
        SecureStorageIdentityMigrationReport(
            records: records,
            bridgeReady: false,
            blockingState: error.map {
                SecureStorageIdentityMigrationRecordState.failureState(for: $0)
            } ?? blockingState
        )
    }

    private func blockedReport(error: Error? = nil) -> SecureStorageIdentityMigrationReport {
        failedReport(records: [], error: error)
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
    static let phaseInfoKey = "RepoPromptIdentityMigrationPhase"
    static let anchorRelativePathInfoKey = "RepoPromptIdentityMigrationAnchorRelativePath"
    static let successorBundleIdentifier = "com.repoprompt.ce"
    static let successorTeamIdentifier = "69N6K965SF"
    static let successorDeveloperIDRequirement =
        "anchor apple generic and identifier \"\(successorBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(successorTeamIdentifier)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    enum Phase: String {
        case disabled
        case legacyPreparer = "legacy-preparer"
    }

    static func configuredPhase(from value: Any?) -> Phase? {
        guard let rawPhase = value as? String else { return nil }
        return Phase(rawValue: rawPhase)
    }

    static func prepareIfConfigured(bundle: Bundle = .main) {
        IdentityMigrationRuntimeState.shared.setBlockedMessage(nil)
        guard SecureKeyValueStorageFactory.currentDecision().domain == .officialDeveloperID else { return }
        guard let phase = configuredPhase(from: bundle.object(forInfoDictionaryKey: phaseInfoKey))
        else {
            blockUpdates("Updates are paused because this build has an unrecognized secure credential migration configuration.")
            return
        }

        switch phase {
        case .disabled:
            activateCommittedBridgeIfPresent()
        case .legacyPreparer:
            prepareLegacyBridge(bundle: bundle)
        }
    }

    private static func prepareLegacyBridge(bundle: Bundle) {
        guard bundle.bundleIdentifier == RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
              let executableURL = bundle.executableURL,
              let resourceURL = bundle.resourceURL,
              let relativeAnchorPath = bundle.object(forInfoDictionaryKey: anchorRelativePathInfoKey) as? String,
              !relativeAnchorPath.isEmpty,
              let anchorURL = validatedAnchorURL(relativePath: relativeAnchorPath, resourceURL: resourceURL),
              RuntimeCodeSigningDetector.validatesStaticCode(
                  at: bundle.bundleURL,
                  requirementSource: RuntimeCodeSigningPolicy.developerIDRequirement
              ),
              RuntimeCodeSigningDetector.validatesStaticCode(
                  at: anchorURL,
                  requirementSource: successorDeveloperIDRequirement
              )
        else {
            blockUpdates("Updates are paused because the secure credential migration package is incomplete or has an invalid identity anchor.")
            return
        }

        let attributeProvider = TrustedApplicationsKeychainAttributeProvider(
            descriptor: "RepoPrompt CE identity migration bridge",
            applications: [
                TrustedApplicationCodeRequirement(
                    trustedApplicationPath: executableURL.path,
                    codeURL: bundle.bundleURL,
                    requirementSource: RuntimeCodeSigningPolicy.developerIDRequirement
                ),
                TrustedApplicationCodeRequirement(
                    trustedApplicationPath: anchorURL.path,
                    codeURL: anchorURL,
                    requirementSource: successorDeveloperIDRequirement
                )
            ]
        )
        let stateStore = KeychainSecureStorageIdentityMigrationStateStore(
            store: KeychainService(
                serviceName: KeychainService.identityMigrationLegacyStateServiceName,
                itemCreationAttributeProvider: attributeProvider
            )
        )
        let coordinator = SecureStorageIdentityMigrationCoordinator(
            sourceStore: KeychainService.officialV2Shared,
            bridgeStoreFactory: { attemptIdentifier in
                bridgeStore(
                    attemptIdentifier: attemptIdentifier,
                    itemCreationAttributeProvider: attributeProvider
                )
            },
            stateStore: stateStore
        )
        let report = coordinator.prepareBridge()
        guard report.bridgeReady,
              let manifest = try? stateStore.load(),
              manifest.status == .committed
        else {
            blockUpdates(report.blockedUpdateMessage)
            return
        }

        SecureKeyValueStorageFactory.installOfficialBackendOverride(
            bridgeStore(
                attemptIdentifier: manifest.attemptIdentifier,
                itemCreationAttributeProvider: attributeProvider
            )
        )
    }

    private static func activateCommittedBridgeIfPresent() {
        let stateStore = KeychainSecureStorageIdentityMigrationStateStore()
        let manifest: SecureStorageIdentityMigrationManifest?
        do {
            manifest = try stateStore.load()
        } catch {
            blockUpdates(for: error)
            return
        }
        guard let manifest else { return }
        guard manifest.version == SecureStorageIdentityMigrationManifest.currentVersion,
              manifest.status == .committed,
              !manifest.attemptIdentifier.isEmpty,
              manifest.catalogIdentifiers == SecureStorageAccountCatalog.allAccounts.map(\.identifier).sorted(),
              let encoded = SecureStorageIdentityMigrationCoordinator.encodeManifest(manifest)
        else {
            blockUpdates("Updates are paused because the secure credential migration journal is incomplete.")
            return
        }

        let itemIdentityAttributes = bridgeItemIdentityAttributes(manifest.attemptIdentifier)
        let readOnlyBridge = KeychainService(
            serviceName: KeychainService.identityMigrationBridgeServiceName,
            itemIdentityAttributes: itemIdentityAttributes
        )
        do {
            guard try readOnlyBridge.get(
                for: SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount,
                accessMode: .nonInteractive(reason: .launch)
            ) == encoded
            else {
                blockUpdates("Updates are paused because the secure credential migration bridge could not be verified.")
                return
            }
        } catch {
            blockUpdates(for: error)
            return
        }

        let accessProvider = ExistingKeychainItemAccessAttributeProvider(
            serviceName: KeychainService.identityMigrationBridgeServiceName,
            account: SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount,
            itemIdentityAttributes: itemIdentityAttributes
        )
        SecureKeyValueStorageFactory.installOfficialBackendOverride(
            bridgeStore(
                attemptIdentifier: manifest.attemptIdentifier,
                itemCreationAttributeProvider: accessProvider
            )
        )
    }

    private static func bridgeStore(
        attemptIdentifier: String,
        itemCreationAttributeProvider: KeychainItemCreationAttributeProvider
    ) -> KeychainService {
        KeychainService(
            serviceName: KeychainService.identityMigrationBridgeServiceName,
            itemCreationAttributeProvider: itemCreationAttributeProvider,
            itemIdentityAttributes: bridgeItemIdentityAttributes(attemptIdentifier)
        )
    }

    private static func bridgeItemIdentityAttributes(_ attemptIdentifier: String) -> [String: Any] {
        [kSecAttrGeneric as String: Data(attemptIdentifier.utf8)]
    }

    static func validatedAnchorURL(relativePath: String, resourceURL: URL) -> URL? {
        let resolvedResources = resourceURL.resolvingSymlinksInPath().standardizedFileURL
        let unresolvedCandidate = resolvedResources
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        let resolvedCandidate = unresolvedCandidate.resolvingSymlinksInPath().standardizedFileURL
        guard unresolvedCandidate.path.hasPrefix(resolvedResources.path + "/"),
              resolvedCandidate == unresolvedCandidate,
              let values = try? unresolvedCandidate.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .isSymbolicLinkKey,
                  .isExecutableKey
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.isExecutable == true
        else {
            return nil
        }
        return unresolvedCandidate
    }

    private static func blockUpdates(_ message: String?) {
        IdentityMigrationRuntimeState.shared.setBlockedMessage(
            message ?? "Updates are paused because secure credential migration could not be verified."
        )
    }

    private static func blockUpdates(for error: Error) {
        let report = SecureStorageIdentityMigrationReport(
            records: [],
            bridgeReady: false,
            blockingState: SecureStorageIdentityMigrationRecordState.failureState(for: error)
        )
        blockUpdates(report.blockedUpdateMessage)
    }
}
