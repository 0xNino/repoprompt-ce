import Foundation
@testable import RepoPromptApp
import XCTest

final class IdentityTransitionDiagnosticsTests: XCTestCase {
    func testDefaultsMigrationCopiesLegacyDomainWithoutOverwritingSuccessorValues() {
        let names = DefaultsDomainNames()
        let defaults = UserDefaults.standard
        defer { names.remove(from: defaults) }

        defaults.setPersistentDomain(
            [
                UpdateChannel.userDefaultsKey: UpdateChannel.tip.rawValue,
                "NSWindow Frame Main": "legacy-frame",
                "legacy-only": "legacy-value"
            ],
            forName: names.legacy
        )
        defaults.setPersistentDomain(
            [
                "NSWindow Frame Main": "successor-frame",
                "successor-only": "successor-value"
            ],
            forName: names.successor
        )

        let report = BundleIdentityDefaultsMigration.migrateIfNeeded(
            bundleIdentifier: RuntimeCodeSigningPolicy.successorDeveloperIDBundleIdentifier,
            defaults: defaults,
            legacyDomainName: names.legacy,
            successorDomainName: names.successor
        )

        XCTAssertEqual(report.outcome, .migrated)
        XCTAssertEqual(report.copiedKeyCount, 2)
        XCTAssertEqual(report.preservedKeyCount, 2)
        let migrated = defaults.persistentDomain(forName: names.successor)
        XCTAssertEqual(migrated?[UpdateChannel.userDefaultsKey] as? String, UpdateChannel.tip.rawValue)
        XCTAssertEqual(migrated?["NSWindow Frame Main"] as? String, "successor-frame")
        XCTAssertEqual(migrated?["legacy-only"] as? String, "legacy-value")
        XCTAssertEqual(migrated?["successor-only"] as? String, "successor-value")
        XCTAssertEqual(
            migrated?[BundleIdentityDefaultsMigration.completionMarker] as? Bool,
            true
        )
    }

    func testDefaultsMigrationIsSuccessorOnlyAndIdempotent() {
        let names = DefaultsDomainNames()
        let defaults = UserDefaults.standard
        defer { names.remove(from: defaults) }
        defaults.setPersistentDomain(["legacy-only": 1], forName: names.legacy)

        let skipped = BundleIdentityDefaultsMigration.migrateIfNeeded(
            bundleIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
            defaults: defaults,
            legacyDomainName: names.legacy,
            successorDomainName: names.successor
        )
        XCTAssertEqual(skipped.outcome, .skipped)
        XCTAssertNil(defaults.persistentDomain(forName: names.successor))

        let first = BundleIdentityDefaultsMigration.migrateIfNeeded(
            bundleIdentifier: RuntimeCodeSigningPolicy.successorDeveloperIDBundleIdentifier,
            defaults: defaults,
            legacyDomainName: names.legacy,
            successorDomainName: names.successor
        )
        XCTAssertEqual(first.outcome, .migrated)

        defaults.setPersistentDomain(["legacy-only": 2, "late-key": true], forName: names.legacy)
        let second = BundleIdentityDefaultsMigration.migrateIfNeeded(
            bundleIdentifier: RuntimeCodeSigningPolicy.successorDeveloperIDBundleIdentifier,
            defaults: defaults,
            legacyDomainName: names.legacy,
            successorDomainName: names.successor
        )
        XCTAssertEqual(second.outcome, .alreadyCompleted)
        let migrated = defaults.persistentDomain(forName: names.successor)
        XCTAssertEqual(migrated?["legacy-only"] as? Int, 1)
        XCTAssertNil(migrated?["late-key"])
    }

    func testDiagnosticLedgerIsBoundedPrivateAndContainsOnlyStructuredFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("identity-transition-v1.json")
        let recorder = IdentityTransitionDiagnostics(
            fileURL: fileURL,
            maximumEventCount: 3,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        for index in 0 ..< 5 {
            recorder.record(
                IdentityTransitionDiagnosticEvent(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                    subsystem: .secureStorage,
                    stage: "stage-\(index)",
                    outcome: .succeeded,
                    bundleIdentifier: RuntimeCodeSigningPolicy.successorDeveloperIDBundleIdentifier,
                    displayVersion: "1.2.3",
                    buildVersion: "123",
                    migrationPhase: "disabled",
                    secureStorageDomain: "successor-official",
                    updateChannel: UpdateChannel.tip.rawValue,
                    targetDisplayVersion: nil,
                    targetBuildVersion: nil,
                    recordStateCounts: ["verified": 2],
                    errorClass: nil
                )
            )
        }

        XCTAssertEqual(recorder.readEvents().map(\.stage), ["stage-2", "stage-3", "stage-4"])
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let encoded = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(encoded.contains("account"))
        XCTAssertFalse(encoded.contains("attemptIdentifier"))
        XCTAssertFalse(encoded.contains("fileURL"))
        XCTAssertFalse(encoded.contains("rawError"))
    }
}

private struct DefaultsDomainNames {
    let legacy = "identity-transition-tests.legacy.\(UUID().uuidString)"
    let successor = "identity-transition-tests.successor.\(UUID().uuidString)"

    func remove(from defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: legacy)
        defaults.removePersistentDomain(forName: successor)
    }
}
