import Foundation
@testable import RepoPromptMCP
import XCTest

final class DirectHeadlessRuntimeConfigurationTests: XCTestCase {
    func testDefaultProfileUsesCanonicalAppStorageAndNeverFallsBackToCWD() throws {
        let home = temporaryDirectory("home")
        let cwd = temporaryDirectory("cwd")
        let temporary = temporaryDirectory("tmp")
        let locations = try DirectHeadlessRuntimeLocationResolver.resolve(
            environment: [:],
            currentDirectory: cwd,
            homeDirectory: home,
            temporaryDirectory: temporary,
            customWorkspaceStoragePath: nil
        )

        let canonicalRoot = home.appendingPathComponent(
            "Library/Application Support/RepoPrompt CE",
            isDirectory: true
        )
        XCTAssertEqual(locations.profileIdentifier, "default")
        XCTAssertEqual(locations.storageDirectory, canonicalRoot)
        XCTAssertEqual(
            locations.workspaceStorageDirectory,
            canonicalRoot.appendingPathComponent("Workspaces", isDirectory: true)
        )
        XCTAssertEqual(locations.workingDirectories, [])
        XCTAssertFalse(locations.storageDirectory.path.contains("/Headless/"))
        XCTAssertFalse(locations.mayBootstrapIsolatedWorkspace)
    }

    func testDefaultProfileUsesCanonicalCustomWorkspaceStorage() throws {
        let home = temporaryDirectory("home")
        let custom = temporaryDirectory("custom-workspaces")
        let locations = try DirectHeadlessRuntimeLocationResolver.resolve(
            environment: [:],
            currentDirectory: home,
            homeDirectory: home,
            customWorkspaceStoragePath: custom.path
        )

        XCTAssertEqual(
            locations.workspaceStorageDirectory,
            custom.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    func testExplicitProfileDirectoryAndRootsAreIntentionalIsolation() throws {
        let profile = temporaryDirectory("profile")
        let root = temporaryDirectory("root")
        let locations = try DirectHeadlessRuntimeLocationResolver.resolve(
            environment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "test-profile",
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": root.path
            ],
            currentDirectory: profile,
            homeDirectory: profile
        )

        XCTAssertEqual(locations.profileIdentifier, "test-profile")
        XCTAssertEqual(locations.storageDirectory, profile.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(locations.workingDirectories, [root.standardizedFileURL.resolvingSymlinksInPath()])
        XCTAssertTrue(locations.usesExplicitProfileDirectory)
        XCTAssertTrue(locations.mayBootstrapIsolatedWorkspace)
    }

    func testNonDefaultProfileRequiresExplicitDirectory() throws {
        XCTAssertThrowsError(try DirectHeadlessRuntimeLocationResolver.resolve(
            environment: ["REPOPROMPT_MCP_HEADLESS_PROFILE": "other"],
            currentDirectory: FileManager.default.temporaryDirectory,
            customWorkspaceStoragePath: nil
        )) { error in
            XCTAssertEqual(
                error as? DirectHeadlessRuntimeLocationError,
                .profileDirectoryRequired("other")
            )
        }
    }

    func testDuplicateOrEmptyExplicitRootsFailClosed() throws {
        let root = temporaryDirectory("root")
        for value in ["\(root.path):\(root.path)", ""] {
            XCTAssertThrowsError(try DirectHeadlessRuntimeLocationResolver.resolve(
                environment: ["REPOPROMPT_MCP_WORKING_DIRS": value],
                currentDirectory: root,
                homeDirectory: root,
                customWorkspaceStoragePath: nil
            ), "value=\(value)")
        }
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-headless-locations-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
