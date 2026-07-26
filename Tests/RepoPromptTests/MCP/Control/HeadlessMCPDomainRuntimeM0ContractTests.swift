import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class HeadlessMCPDomainRuntimeM0ContractTests: XCTestCase {
    func testCanonicalCatalogActionsPoliciesAndDependenciesMatchFrozenManifest() async throws {
        let manifest = try loadJSONObject("Scripts/Fixtures/headless_mcp_domain_runtime_m0_contract.json")
        let catalog = try dictionary(manifest, key: "catalog")
        let globals = try strings(catalog, key: "global_tools")
        let windows = try strings(catalog, key: "window_tools")
        let allTools = globals + windows

        XCTAssertEqual(globals, MCPGlobalToolName.orderedToolNames)
        XCTAssertEqual(windows, MCPWindowToolGroup.orderedToolNames)
        XCTAssertEqual(allTools.count, 27)
        XCTAssertEqual(Set(allTools).count, allTools.count)

        let actionFixtures = try stringArrays(catalog, key: "actions")
        XCTAssertEqual(Set(actionFixtures.keys), Set(allTools))
        XCTAssertTrue(actionFixtures.values.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(actionFixtures.values.reduce(0) { $0 + $1.count }, try integer(catalog, key: "canonical_action_count"))
        let normalizedFixture = try dictionary(catalog, key: "action_fixture_contract")
        let successFixture = try dictionary(normalizedFixture, key: "success_fixture")
        let errorFixture = try dictionary(normalizedFixture, key: "error_fixture")
        XCTAssertEqual(try string(successFixture, key: "result_class"), "typed_tool_result")
        XCTAssertEqual(try string(errorFixture, key: "error_code"), "invalid_params")
        XCTAssertEqual(errorFixture["mutation_started"] as? Bool, false)
        XCTAssertEqual(normalizedFixture["wire_envelope_claim"] as? Bool, false)

        let window = makeWindowWithoutAutoStart()
        addTeardownBlock { @MainActor in
            window.beginClose()
            await window.tearDown()
        }
        let liveTools = await window.mcpServer.windowMCPTools
        XCTAssertEqual(liveTools.map(\.name), windows)
        for tool in liveTools {
            let expected = try XCTUnwrap(actionFixtures[tool.name], tool.name)
            if expected == ["call"] {
                continue
            }
            let properties = try schemaProperties(for: tool)
            if tool.name == MCPWindowToolName.applyEdits {
                XCTAssertNotNil(properties["rewrite"])
                XCTAssertNotNil(properties["search"])
                XCTAssertNotNil(properties["edits"])
                XCTAssertEqual(expected, ["rewrite", "single_replace", "multiple_edits"])
                continue
            }
            let discriminator = properties["op"] ?? properties["action"]
            let object = try XCTUnwrap(discriminator?.objectValue, tool.name)
            let actual = try XCTUnwrap(object["enum"]?.arrayValue?.compactMap(\.stringValue), tool.name)
            XCTAssertEqual(actual, expected, tool.name)
        }

        let appSettings = try source("Sources/RepoPrompt/Infrastructure/MCP/AppSettingsMCPService.swift")
        let routing = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowRoutingService.swift")
        XCTAssertEqual(
            try enumValues(in: appSettings, after: "static let toolName = MCPGlobalToolName.appSettings", key: "op"),
            actionFixtures[MCPGlobalToolName.appSettings]
        )
        XCTAssertEqual(
            try enumValues(in: routing, after: "name: MCPGlobalToolName.bindContext", key: "op"),
            actionFixtures[MCPGlobalToolName.bindContext]
        )
        XCTAssertEqual(
            try enumValues(in: routing, after: "name: MCPGlobalToolName.manageWorkspaces", key: "action"),
            actionFixtures[MCPGlobalToolName.manageWorkspaces]
        )

        let policy = try dictionary(manifest, key: "policy")
        let admissionFixture = try stringArrays(policy, key: "admission")
        let actualAdmission = Dictionary(grouping: MCPToolAdmissionPolicy.classifications.keys) {
            MCPToolAdmissionPolicy.classifications[$0]!.rawValue
        }
        XCTAssertEqual(actualAdmission.mapValues(Set.init), admissionFixture.mapValues(Set.init))

        let executionFixture = try stringArrays(policy, key: "execution")
        let actualExecution = Dictionary(grouping: allTools) { toolName in
            switch MCPToolExecutionContractCatalog.contract(for: toolName)!.kind {
            case .bounded: "bounded"
            case .longSynchronousCancellable: "long_synchronous"
            case .lifecycleManagedCancellable: "lifecycle_managed"
            case .interactiveCancellable: "interactive"
            case .workspaceLifecycleCancellable: "workspace_lifecycle"
            }
        }
        XCTAssertEqual(actualExecution.mapValues(Set.init), executionFixture.mapValues(Set.init))

        let profiles = try stringArrays(policy, key: "advertisement_profiles")
        XCTAssertEqual(
            Set(DiscoverMCPToolPolicy.restrictedCapabilities.map(\.externalName)),
            try Set(XCTUnwrap(profiles["discover_restricted_capabilities"]))
        )
        XCTAssertEqual(
            Set(DiscoverMCPToolPolicy.grantedCapabilities.map(\.externalName)),
            try Set(XCTUnwrap(profiles["discover_granted_capabilities"]))
        )
        XCTAssertEqual(
            Set(AgentModeMCPToolPolicy.restrictedCapabilities.map(\.externalName)),
            try Set(XCTUnwrap(profiles["agent_mode_restricted_capabilities"]))
        )
        XCTAssertEqual(
            Set(AgentModeMCPToolPolicy.grantedCapabilities.map(\.externalName)),
            try Set(XCTUnwrap(profiles["agent_mode_generic_granted_capabilities"]))
        )
        XCTAssertEqual(
            Set(AgentModeMCPToolPolicy.codexNativeGrantedCapabilities.map(\.externalName)),
            try Set(XCTUnwrap(profiles["agent_mode_native_granted_capabilities"]))
        )
        XCTAssertEqual(
            Set(MCPPolicyGatedTools.gatedCapabilities.map(\.externalName)),
            try Set(XCTUnwrap(profiles["policy_gated_capabilities"]))
        )

        let dependencies = try dictionary(manifest, key: "dependencies")
        let expectedDependencies = try strings(dependencies, key: "stored_dependencies")
        let sourceDependencies = try storedPropertyNames(
            in: source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPWindowToolDependencies.swift"),
            startingAt: "    let executeOracleUtils:"
        )
        XCTAssertEqual(sourceDependencies, expectedDependencies)
        XCTAssertEqual(expectedDependencies.count, try integer(dependencies, key: "stored_dependency_count"))
    }

    func testSDKCredentialAndPrivateChildContractsAreFailClosedEvidence() throws {
        let manifest = try loadJSONObject("Scripts/Fixtures/headless_mcp_domain_runtime_m0_contract.json")
        let package = try source("Package.swift")
        let sdk = try dictionary(manifest, key: "sdk_stdio")
        let revision = try string(sdk, key: "revision")
        XCTAssertTrue(package.contains("swift-sdk.git\", revision: \"\(revision)\""))
        let sourceEvidence = try dictionary(sdk, key: "source_evidence")
        XCTAssertEqual(try string(sourceEvidence, key: "assessment_kind"), "pinned_dependency_source_inspection")
        let sdkTransport = try sdkCheckoutSource(string(sourceEvidence, key: "transport"))
        XCTAssertTrue(sdkTransport.contains("if bytesRead == 0"))
        XCTAssertTrue(sdkTransport.contains("logger.error(\"Read error occurred\""))
        XCTAssertTrue(sdkTransport.contains("messageContinuation.finish()"))
        XCTAssertTrue(sdkTransport.contains("var pendingData = Data()"))
        let sdkServer = try sdkCheckoutSource(string(sourceEvidence, key: "server"))
        XCTAssertTrue(sdkServer.contains("for try await data in stream"))
        XCTAssertTrue(sdkServer.contains("closeConnectionAfterTerminalEvent(throwing: MCPError.connectionClosed)"))
        let assessment = try dictionary(sdk, key: "observed_terminal_assessment")
        XCTAssertEqual(try string(assessment, key: "host_visible_error"), "none; all three collapse to connectionClosed")
        XCTAssertTrue(try string(assessment, key: "decision").contains("RepoPromptMCP-owned stdio transport adapter"))
        let elicitation = try dictionary(sdk, key: "elicitation")
        XCTAssertEqual(try string(elicitation, key: "method"), "elicitation/create")
        XCTAssertEqual(try strings(elicitation, key: "actions"), ["accept", "decline", "cancel"])
        XCTAssertTrue(try string(elicitation, key: "classification").contains("client-negotiated"))

        let credential = try dictionary(manifest, key: "credential_gate")
        let measurement = try loadJSONObject("Scripts/Fixtures/item0_measurement_record.json")
        let keychain = try dictionary(measurement, key: "keychain_access_measurement")
        XCTAssertEqual(try string(credential, key: "direct_keychain_measurement"), "not_run_approval_required")
        XCTAssertEqual(try string(credential, key: "evidence_kind"), "policy_decision_not_empirical_measurement")
        XCTAssertEqual(try string(keychain, key: "status"), "incomplete")
        XCTAssertEqual(keychain["startup_scan_approved"] as? Bool, false)
        XCTAssertTrue(try string(credential, key: "prescribed_fallback").contains("Parent-owned secure storage"))
        XCTAssertEqual(SecureStorageAccountCatalog.allAccounts.count, try integer(credential, key: "secure_account_catalog_count"))

        let packageScript = try source("Scripts/package_app.sh")
        let cliCopy = "cp \"$BUILD_DIR/$exe\" \"$APP_BUNDLE/Contents/MacOS/$exe\""
        let cliSign = "sign_path \"$APP_BUNDLE/Contents/MacOS/repoprompt-mcp\""
        let appSign = "sign_path \"$APP_BUNDLE/Contents/MacOS/$APP_NAME\""
        XCTAssertTrue(packageScript.contains(cliCopy))
        XCTAssertLessThan(
            try XCTUnwrap(packageScript.range(of: cliSign)?.lowerBound),
            try XCTUnwrap(packageScript.range(of: appSign)?.lowerBound)
        )

        let child = try dictionary(manifest, key: "child_launch")
        let currentLeaseFields = try strings(child, key: "current_lease_fields")
        let leaseSource = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPBootstrapLease.swift")
        XCTAssertEqual(
            try storedPropertyNames(in: leaseSource, startingAt: "struct MCPBootstrapLeaseSpec", endingAt: "enum MCPBootstrapReadinessError"),
            currentLeaseFields
        )
        let endpoint = try dictionary(child, key: "private_endpoint_contract")
        XCTAssertEqual(try string(endpoint, key: "directory_mode"), "0700")
        XCTAssertEqual(try string(endpoint, key: "socket_mode"), "0600")
        XCTAssertEqual(try string(endpoint, key: "descriptor_inheritance"), "prohibited")
        XCTAssertEqual(try string(endpoint, key: "admission"), "single_use_expected_child_or_descendant")
        XCTAssertEqual(try string(endpoint, key: "cleanup"), "identity_fenced_idempotent_settlement")
        let token = try dictionary(child, key: "domain_run_launch_token_contract")
        XCTAssertEqual(try string(token, key: "status"), "frozen_contract_only_not_implemented")
        XCTAssertEqual(try strings(token, key: "child_material"), ["opaque_random_capability"])
        XCTAssertEqual(try string(token, key: "policy_selection_authority"), "host_only")
        XCTAssertTrue(try strings(token, key: "host_record_bindings").contains("restricted_tools"))
        XCTAssertTrue(try Set(strings(token, key: "rules")).isSuperset(of: ["single_use", "memory_only", "never_logged", "never_persisted"]))

        let packageManifest = try source("Package.swift")
        XCTAssertFalse(packageManifest.contains("HeadlessMCPDomainRuntime"))
        XCTAssertFalse(packageManifest.contains("RepoPromptDomainRuntime"))
        let productionSwift = try allSwiftSource()
        XCTAssertFalse(productionSwift.contains("DomainRunLaunchToken"))
    }

    func testPersistenceApprovalMainActorAndPerformanceInventoriesRemainComplete() throws {
        let manifest = try loadJSONObject("Scripts/Fixtures/headless_mcp_domain_runtime_m0_contract.json")
        let persistence = try dictionary(manifest, key: "persistence")
        let classifications = try stringArrays(persistence, key: "save_source_classification")
        let classifiedSources = classifications.keys.sorted().flatMap { classifications[$0]! }
        let saveSource = try source("Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceSaveDiagnostics.swift")
        let expression = try NSRegularExpression(pattern: #"WorkspaceSaveSource\("([^"]+)"\)"#)
        let range = NSRange(saveSource.startIndex..., in: saveSource)
        let actualSources = expression.matches(in: saveSource, range: range).compactMap { match -> String? in
            guard let valueRange = Range(match.range(at: 1), in: saveSource) else { return nil }
            return String(saveSource[valueRange])
        }
        XCTAssertEqual(Set(classifiedSources), Set(actualSources))
        XCTAssertEqual(classifiedSources.count, actualSources.count)

        let journal = try dictionaries(persistence, key: "working_journal_migration_rows")
        XCTAssertEqual(Set(journal.compactMap { $0["migration_milestone"] as? String }), ["M2", "M4", "never_to_child_disk"])
        XCTAssertTrue(journal.allSatisfy { $0["state"] != nil && $0["current_authority"] != nil })

        let approval = try dictionary(manifest, key: "approval")
        XCTAssertEqual(
            WorkspaceApprovalOperation.allCases.map(\.rawValue),
            try strings(approval, key: "workspace_operations")
        )
        XCTAssertEqual(try string(approval, key: "cancellation_result"), "denied")
        let approvalManager = try source("Sources/RepoPrompt/Infrastructure/MCP/WorkspaceApproval/WorkspaceApprovalManager.swift")
        XCTAssertTrue(approvalManager.contains("continuation.resume(returning: .denied)"))

        let actorInventory = try dictionary(manifest, key: "main_actor")
        let actorSources = [
            "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPWindowToolCatalogService.swift",
            "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPWindowToolRuntime.swift",
            "Sources/RepoPrompt/Infrastructure/MCP/ServiceRegistry.swift",
            "Sources/RepoPrompt/Features/Settings/Models/WindowSettingsManager.swift",
            "Sources/RepoPrompt/Features/Settings/Models/GlobalSettingsManager.swift",
            "Sources/RepoPrompt/Infrastructure/MCP/WorkspaceApproval/WorkspaceApprovalManager.swift",
            "Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentExternalMCPRunStarter.swift"
        ]
        XCTAssertEqual(actorSources.count, try strings(actorInventory, key: "owners").count)
        for path in actorSources {
            XCTAssertTrue(try source(path).contains("@MainActor"), path)
        }

        let baseline = try loadJSONObject("docs/spec/headless-mcp-domain-runtime-m0-editflowperf-baseline.json")
        let constraints = try dictionary(baseline, key: "capture_constraints")
        XCTAssertEqual(try string(constraints, key: "live_mcp_round_trip_status"), "blocked_not_run")
        XCTAssertTrue(try string(constraints, key: "fallback").contains("already-running CE debug app"))
        let stages = try dictionaries(baseline, key: "observed_stage_baseline")
        XCTAssertEqual(Set(stages.compactMap { $0["stage"] as? String }), ["queue", "main_actor", "execution", "persistence", "response"])
        XCTAssertTrue(stages.allSatisfy { $0["evidence"] != nil && $0["observations"] != nil })
        let checkout = try dictionary(baseline, key: "checkout_baseline")
        XCTAssertEqual(try string(checkout, key: "classification"), "representative_large_workspace")
        XCTAssertGreaterThan(try integer(checkout, key: "tracked_files"), 2000)
    }

    private func loadJSONObject(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: RepoRoot.url().appendingPathComponent(relativePath))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], relativePath)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: RepoRoot.url().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func sdkCheckoutSource(_ relativePath: String) throws -> String {
        let checkout = try RepoRoot.url()
            .appendingPathComponent(".build/checkouts/swift-sdk", isDirectory: true)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: checkout, encoding: .utf8)
    }

    private func dictionary(_ object: [String: Any], key: String) throws -> [String: Any] {
        try XCTUnwrap(object[key] as? [String: Any], key)
    }

    private func dictionaries(_ object: [String: Any], key: String) throws -> [[String: Any]] {
        try XCTUnwrap(object[key] as? [[String: Any]], key)
    }

    private func string(_ object: [String: Any], key: String) throws -> String {
        try XCTUnwrap(object[key] as? String, key)
    }

    private func strings(_ object: [String: Any], key: String) throws -> [String] {
        try XCTUnwrap(object[key] as? [String], key)
    }

    private func stringArrays(_ object: [String: Any], key: String) throws -> [String: [String]] {
        try XCTUnwrap(object[key] as? [String: [String]], key)
    }

    private func integer(_ object: [String: Any], key: String) throws -> Int {
        try XCTUnwrap((object[key] as? NSNumber)?.intValue, key)
    }

    private func schemaProperties(for tool: RepoPromptApp.Tool) throws -> [String: Value] {
        let schema = try XCTUnwrap(Value(tool.inputSchema).objectValue, tool.name)
        return try XCTUnwrap(schema["properties"]?.objectValue, tool.name)
    }

    private func enumValues(in source: String, after anchor: String, key: String) throws -> [String] {
        let anchorRange = try XCTUnwrap(source.range(of: anchor), anchor)
        let tail = source[anchorRange.lowerBound...]
        let keyRange = try XCTUnwrap(tail.range(of: "\"\(key)\""), key)
        let keyedTail = tail[keyRange.lowerBound...]
        let enumRange = try XCTUnwrap(keyedTail.range(of: "enum: ["), key)
        let valuesTail = keyedTail[enumRange.upperBound...]
        let close = try XCTUnwrap(valuesTail.firstIndex(of: "]"), key)
        let values = String(valuesTail[..<close])
        let expression = try NSRegularExpression(pattern: #""([^"]+)""#)
        let matches = expression.matches(in: values, range: NSRange(values.startIndex..., in: values))
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: values) else { return nil }
            return String(values[range])
        }
    }

    private func storedPropertyNames(
        in source: String,
        startingAt start: String,
        endingAt end: String? = nil
    ) throws -> [String] {
        let startRange = try XCTUnwrap(source.range(of: start), start)
        let tail = source[startRange.lowerBound...]
        let bounded: Substring = if let end, let endRange = tail.range(of: end) {
            tail[..<endRange.lowerBound]
        } else {
            tail
        }
        let text = String(bounded)
        let expression = try NSRegularExpression(pattern: #"(?m)^\s+let\s+([A-Za-z][A-Za-z0-9]*):"#)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private func allSwiftSource() throws -> String {
        let sources = try RepoRoot.url().appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var content = ""
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            content += try String(contentsOf: url, encoding: .utf8)
        }
        return content
    }

    private func makeWindowWithoutAutoStart() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }
}
