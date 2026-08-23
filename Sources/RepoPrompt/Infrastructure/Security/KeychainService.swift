//
//  KeychainService.swift
//  RepoPrompt
//
//  Secure Keychain-based storage for sensitive data
//

import Foundation
import Security

/// Controls whether a Keychain operation may display macOS authentication/approval UI.
enum KeychainAccessMode: Equatable {
    case interactive
    case nonInteractive(reason: KeychainAccessReason)

    var isNonInteractive: Bool {
        if case .nonInteractive = self {
            return true
        }
        return false
    }
}

/// Sanitized reason metadata for noninteractive Keychain access.
enum KeychainAccessReason: Equatable {
    case launch
    case bulkSettingsLoad
    case permissionDecision
    case backgroundAvailabilityCheck
    case test
}

protocol SecItemClient {
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus
    func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

struct SystemSecItemClient: SecItemClient {
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        SecItemAdd(query, result)
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

protocol KeychainItemCreationAttributeProvider {
    func attributesForNewItem() throws -> [String: Any]
}

enum KeychainItemCreationAttributeError: Error, LocalizedError, Equatable {
    case trustedApplicationCreationFailed(path: String, status: OSStatus)
    case trustedApplicationValidationFailed(path: String)
    case accessCreationFailed(status: OSStatus)
    case referenceItemLookupFailed(status: OSStatus)
    case referenceItemInvalid
    case referenceItemAccessFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case let .trustedApplicationCreationFailed(path, status):
            "Could not create a Keychain trusted-application requirement for \(path) (status \(status))"
        case let .trustedApplicationValidationFailed(path):
            "The Keychain trusted application failed code-signing validation: \(path)"
        case let .accessCreationFailed(status):
            "Could not create the Keychain access policy (status \(status))"
        case let .referenceItemLookupFailed(status):
            "Could not find the Keychain access-policy reference item (status \(status))"
        case .referenceItemInvalid:
            "The Keychain access-policy reference item is invalid"
        case let .referenceItemAccessFailed(status):
            "Could not copy the Keychain access policy from the reference item (status \(status))"
        }
    }
}

/// Builds a classic macOS Keychain ACL from signed executables. The migration preparer
/// supplies its current executable plus an embedded executable signed for the successor
/// identity. Security.framework derives the designated requirements; no credential data
/// or authorization prompt is involved in constructing this policy.
struct TrustedApplicationCodeRequirement {
    let trustedApplicationPath: String
    let codeURL: URL
    let requirementSource: String
}

final class TrustedApplicationsKeychainAttributeProvider: KeychainItemCreationAttributeProvider {
    let descriptor: String
    let applications: [TrustedApplicationCodeRequirement]

    private let lock = NSRecursiveLock()
    private var cachedAttributes: [String: Any]?

    init(descriptor: String, applications: [TrustedApplicationCodeRequirement]) {
        self.descriptor = descriptor
        self.applications = applications
    }

    func attributesForNewItem() throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedAttributes { return cachedAttributes }

        var trustedApplications: [SecTrustedApplication] = []
        trustedApplications.reserveCapacity(applications.count)

        for application in applications {
            guard RuntimeCodeSigningDetector.validatesStaticCode(
                at: application.codeURL,
                requirementSource: application.requirementSource
            ) else {
                throw KeychainItemCreationAttributeError.trustedApplicationValidationFailed(
                    path: application.trustedApplicationPath
                )
            }
            var trustedApplication: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(
                application.trustedApplicationPath,
                &trustedApplication
            )
            guard status == errSecSuccess, let trustedApplication else {
                throw KeychainItemCreationAttributeError.trustedApplicationCreationFailed(
                    path: application.trustedApplicationPath,
                    status: status
                )
            }
            guard RuntimeCodeSigningDetector.validatesStaticCode(
                at: application.codeURL,
                requirementSource: application.requirementSource
            ) else {
                throw KeychainItemCreationAttributeError.trustedApplicationValidationFailed(
                    path: application.trustedApplicationPath
                )
            }
            trustedApplications.append(trustedApplication)
        }

        var access: SecAccess?
        let status = SecAccessCreate(descriptor as CFString, trustedApplications as CFArray, &access)
        guard status == errSecSuccess, let access else {
            throw KeychainItemCreationAttributeError.accessCreationFailed(status: status)
        }
        let attributes = [kSecAttrAccess as String: access]
        cachedAttributes = attributes
        return attributes
    }
}

/// Reuses the ACL from a bridge manifest whose creation was committed by the legacy
/// preparer. This lets later legacy builds create additional bridge records without
/// carrying a new successor-signed anchor in every package.
struct ExistingKeychainItemAccessAttributeProvider: KeychainItemCreationAttributeProvider {
    let serviceName: String
    let account: String
    let itemIdentityAttributes: [String: Any]

    func attributesForNewItem() throws -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        query.merge(itemIdentityAttributes) { _, replacement in replacement }

        var result: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(query as CFDictionary, &result)
        guard lookupStatus == errSecSuccess else {
            throw KeychainItemCreationAttributeError.referenceItemLookupFailed(status: lookupStatus)
        }
        guard let result,
              CFGetTypeID(result) == SecKeychainItemGetTypeID()
        else {
            throw KeychainItemCreationAttributeError.referenceItemInvalid
        }

        let item = unsafeBitCast(result, to: SecKeychainItem.self)
        var access: SecAccess?
        let accessStatus = SecKeychainItemCopyAccess(item, &access)
        guard accessStatus == errSecSuccess, let access else {
            throw KeychainItemCreationAttributeError.referenceItemAccessFailed(status: accessStatus)
        }
        return [kSecAttrAccess as String: access]
    }
}

/// Secure storage service for one explicitly selected CE macOS Keychain domain.
final class KeychainService: SecureKeyValueStorageBackend, @unchecked Sendable {
    static let legacyCanonicalServiceName = "com.pvncher.repoprompt.ce.keychain"
    static let officialV2ServiceName = "com.pvncher.repoprompt.ce.developer-id.keychain.v2"
    static let identityMigrationBridgeServiceName = "com.repoprompt.ce.identity-migration.keychain.v1"
    static let identityMigrationLegacyStateServiceName = "com.pvncher.repoprompt.ce.identity-migration.state.v2"
    static let localSelfSignedServiceNamePrefix = "com.pvncher.repoprompt.ce.local-self-signed."
    static let debugServiceName = "com.pvncher.repoprompt.ce.debug.keychain"

    static let officialV2Shared = KeychainService(serviceName: officialV2ServiceName)
    static let debugShared = KeychainService(serviceName: debugServiceName)

    static func localSelfSignedServiceName(fingerprint: String, generation: Int) -> String {
        let normalizedFingerprint = fingerprint.filter(\.isHexDigit).lowercased()
        precondition(normalizedFingerprint.count == 64, "Local certificate fingerprint must be SHA-256")
        precondition(generation > 0, "Local secure-storage generation must be positive")
        return "\(localSelfSignedServiceNamePrefix)\(normalizedFingerprint).keychain.v\(generation)"
    }

    static func localSelfSigned(fingerprint: String, generation: Int) -> KeychainService {
        KeychainService(serviceName: localSelfSignedServiceName(fingerprint: fingerprint, generation: generation))
    }

    static func legacyRepairSource(secItemClient: SecItemClient = SystemSecItemClient()) -> KeychainService {
        KeychainService(serviceName: legacyCanonicalServiceName, secItemClient: secItemClient)
    }

    let serviceName: String
    private let secItemClient: SecItemClient
    private let itemCreationAttributeProvider: KeychainItemCreationAttributeProvider?
    private let itemIdentityAttributes: [String: Any]
    private let operationLock = NSRecursiveLock()

    let persistsValuesAcrossLaunches = true

    init(
        serviceName: String = KeychainService.officialV2ServiceName,
        secItemClient: SecItemClient = SystemSecItemClient(),
        itemCreationAttributeProvider: KeychainItemCreationAttributeProvider? = nil,
        itemIdentityAttributes: [String: Any] = [:]
    ) {
        self.serviceName = serviceName
        self.secItemClient = secItemClient
        self.itemCreationAttributeProvider = itemCreationAttributeProvider
        self.itemIdentityAttributes = itemIdentityAttributes
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try body()
    }

    private func query(_ values: [String: Any], accessMode: KeychainAccessMode) -> [String: Any] {
        var query = values
        query.merge(itemIdentityAttributes) { _, replacement in replacement }
        if accessMode.isNonInteractive {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }
        return query
    }

    private func keychainError(for status: OSStatus) -> KeychainError {
        switch status {
        case errSecItemNotFound:
            .itemNotFound
        case errSecDuplicateItem:
            .duplicateItem
        case errSecInteractionNotAllowed:
            .interactionNotAllowed
        case errSecUserCanceled:
            .userInteractionCancelled
        case errSecAuthFailed:
            .authenticationFailed
        default:
            .unexpectedStatus(status)
        }
    }

    enum KeychainError: Error, LocalizedError, Equatable {
        case itemNotFound
        case duplicateItem
        case invalidData
        case interactionNotAllowed
        case userInteractionCancelled
        case authenticationFailed
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .itemNotFound:
                "Item not found in keychain"
            case .duplicateItem:
                "Item already exists"
            case .invalidData:
                "Invalid data format"
            case .interactionNotAllowed:
                "Keychain interaction is not allowed in the current access mode"
            case .userInteractionCancelled:
                "Keychain interaction was cancelled"
            case .authenticationFailed:
                "Keychain authentication failed"
            case let .unexpectedStatus(status):
                "Keychain error: \(status)"
            }
        }
    }

    // MARK: - Save to Keychain

    /// Save a UTF-8 string to this service only.
    func save(
        _ value: String,
        for key: String,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        try withLock {
            guard let data = value.data(using: .utf8) else {
                throw KeychainError.invalidData
            }

            let itemQuery = query([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key
            ], accessMode: accessMode)

            let attributes: [String: Any] = [
                kSecValueData as String: data
            ]

            let updateStatus = secItemClient.update(itemQuery as CFDictionary, attributes as CFDictionary)
            switch updateStatus {
            case errSecSuccess:
                return
            case errSecItemNotFound:
                break
            default:
                throw keychainError(for: updateStatus)
            }

            try add(data, for: key, accessMode: accessMode)
        }
    }

    /// Atomically creates a UTF-8 value without falling back to an update. The
    /// migration bridge uses this to avoid retaining an unproven existing ACL.
    func create(
        _ value: String,
        for key: String,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        try withLock {
            guard let data = value.data(using: .utf8) else {
                throw KeychainError.invalidData
            }
            try add(data, for: key, accessMode: accessMode)
        }
    }

    private func add(
        _ data: Data,
        for key: String,
        accessMode: KeychainAccessMode
    ) throws {
        // kSecAttrAccess is the classic file-based Keychain ACL. Apple documents
        // kSecAttrAccessible as a data-protection-Keychain-only attribute on macOS.
        // A login Keychain may ignore kSecAttrAccessible here, but omitting an
        // inapplicable attribute keeps the item model explicit and portable.
        var newItem: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        if let itemCreationAttributeProvider {
            try newItem.merge(itemCreationAttributeProvider.attributesForNewItem()) { _, replacement in
                replacement
            }
        }
        let addQuery = query(newItem, accessMode: accessMode)

        let addStatus = secItemClient.add(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw keychainError(for: addStatus)
        }
    }

    // MARK: - Retrieve from Keychain

    /// Retrieve a UTF-8 string from this service only.
    func get(
        for key: String,
        accessMode: KeychainAccessMode = .interactive
    ) throws -> String {
        let data = try withLock {
            let itemQuery = query([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ], accessMode: accessMode)

            var result: AnyObject?
            let status = secItemClient.copyMatching(itemQuery as CFDictionary, &result)

            guard status == errSecSuccess else {
                throw keychainError(for: status)
            }

            guard let data = result as? Data else {
                throw KeychainError.invalidData
            }
            return data
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    // MARK: - Delete from Keychain

    /// Delete an item from this service only.
    func delete(for key: String, accessMode: KeychainAccessMode = .interactive) throws {
        try withLock {
            let itemQuery = query([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key
            ], accessMode: accessMode)

            let status = secItemClient.delete(itemQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw keychainError(for: status)
            }
        }
    }
}
