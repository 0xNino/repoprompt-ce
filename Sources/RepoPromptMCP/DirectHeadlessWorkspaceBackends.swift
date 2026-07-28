import CryptoKit
import Foundation
import MCP
import RepoPromptCodeMapCore
import RepoPromptDomainRuntime

private extension DomainSettingValue {
    init(mcpValue: Value) throws {
        switch mcpValue {
        case let .bool(value): self = .bool(value)
        case let .int(value): self = .integer(value)
        case let .double(value): self = .number(value)
        case let .string(value): self = .string(value)
        case .null: self = .null
        default: throw MCPError.invalidParams("setting value must be a boolean, integer, number, string, or null")
        }
    }

    var mcpValue: Value {
        switch self {
        case let .bool(value): .bool(value)
        case let .integer(value): .int(value)
        case let .number(value): .double(value)
        case let .string(value): .string(value)
        case .null: .null
        }
    }
}

actor DirectHeadlessGlobalBackend: DomainGlobalControlBackend {
    private let runtime: MCPDomainRuntime
    private let scopeID: DomainStandaloneScopeID
    private let context: DirectHeadlessDomainContext
    private let settingsStore: DomainDirectSettingsStore

    init(runtime: MCPDomainRuntime, scopeID: DomainStandaloneScopeID, context: DirectHeadlessDomainContext) {
        self.runtime = runtime
        self.scopeID = scopeID
        self.context = context
        settingsStore = DomainDirectSettingsStore(
            persistence: runtime.persistenceCoordinator,
            profileIdentifier: runtime.configuration.profileIdentifier
        )
    }

    func accessSettings(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        await settingsStore.bootstrap()
        let args = try request.mcpArguments()
        let op = args["op"]?.stringValue ?? "list"
        switch op {
        case "list":
            let descriptors = try DomainAppSettingsCatalog.descriptors(in: args["group"]?.stringValue)
            let values = await settingsStore.effectiveValues(for: descriptors)
            let detailed = args["detailed"]?.boolValue == true
            let catalog = descriptors.map { descriptor in
                var item: [String: Value] = [
                    "key": .string(descriptor.key),
                    "group": .string(descriptor.group),
                    "type": .string(descriptor.valueKind.rawValue),
                    "value": values[descriptor.key]?.mcpValue ?? .null,
                    "writable": .bool(true)
                ]
                if descriptor.optionsAvailable { item["options_available"] = .bool(true) }
                if detailed { item["description"] = .string(descriptor.description) }
                return Value.object(item)
            }
            return try .object([
                "settings": .array(catalog),
                "profile": .string(runtime.configuration.profileIdentifier),
                "backend": .string("headless")
            ])
        case "get":
            let selectors = [args["key"] != nil, args["keys"] != nil, args["group"] != nil].count(where: { $0 })
            guard selectors == 1 else { throw MCPError.invalidParams("get requires exactly one of key, keys, or group") }
            if let key = args["key"]?.stringValue {
                return try await .object(["key": .string(key), "value": settingsStore.effectiveValue(for: key).mcpValue])
            }
            let descriptors: [DomainSettingDescriptor] = if let keys = args["keys"]?.arrayValue?.compactMap(\.stringValue) {
                try keys.map { key in
                    guard let descriptor = DomainAppSettingsCatalog.descriptor(for: key) else {
                        throw DomainDirectSettingsError.unknownKey(key)
                    }
                    return descriptor
                }
            } else {
                try DomainAppSettingsCatalog.descriptors(in: args["group"]?.stringValue)
            }
            let values = await settingsStore.effectiveValues(for: descriptors)
            return try .object(["values": .object(values.mapValues(\.mcpValue))])
        case "set":
            guard let key = args["key"]?.stringValue, let value = args["value"] else {
                throw MCPError.invalidParams("set requires key and value")
            }
            let domainValue = try DomainSettingValue(mcpValue: value)
            let revision = try await settingsStore.set(key: key, value: domainValue)
            return try await .object([
                "key": .string(key),
                "value": settingsStore.effectiveValue(for: key).mcpValue,
                "applied": .bool(true),
                "revision": .int(Int(revision))
            ])
        case "options":
            guard let key = args["key"]?.stringValue,
                  let descriptor = DomainAppSettingsCatalog.descriptor(for: key),
                  descriptor.optionsAvailable
            else {
                throw MCPError.invalidParams("options requires a key with options_available=true")
            }
            let limit = max(1, min(args["limit"]?.intValue ?? 200, 200))
            let options = (descriptor.allowedValues ?? []).prefix(limit).map { value in
                Value.object(["value": value.mcpValue])
            }
            return try .object(["key": .string(key), "options": .array(Array(options))])
        default:
            throw MCPError.invalidParams("unknown app_settings op: \(op)")
        }
    }

    func routeContext(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        if args["window_id"] != nil {
            throw MCPError.invalidParams("window_id is unavailable with --backend headless; bind a context_id or working_dirs")
        }
        let op = args["op"]?.stringValue ?? "list"
        switch op {
        case "list":
            return try await workspaceCatalogResult(includeBinding: true)
        case "status":
            let snapshot = try await runtime.standaloneScopeCoordinator.snapshot(scopeID: scopeID)
            return try .object(["binding": bindingValue(snapshot.binding), "backend": .string("headless")])
        case "bind":
            let identity: DomainContextIdentity
            if let raw = args["context_id"]?.stringValue, let contextID = UUID(uuidString: raw) {
                let catalog = await runtime.workspaceStore.snapshot()
                let matches = catalog.workspaces.flatMap(\.contexts).filter {
                    $0.metadata.identity.contextID == contextID
                }
                guard matches.count == 1, let match = matches.first else {
                    throw MCPError.invalidParams("context_id is unknown or ambiguous")
                }
                identity = match.metadata.identity
            } else if let workingDirs = Self.workingDirectories(from: args["working_dirs"]) {
                let requested = Set(workingDirs.map {
                    URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
                })
                let catalog = await runtime.workspaceStore.snapshot()
                let candidates = catalog.workspaces.filter { workspace in
                    let roots = Set(workspace.document.metadata.repoPaths.map {
                        URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
                    })
                    return roots == requested || roots.isSuperset(of: requested)
                }
                guard candidates.count == 1, let workspace = candidates.first else {
                    throw MCPError.invalidParams("working_dirs did not resolve one existing workspace; direct creation is not implicit")
                }
                let activeID = workspace.document.metadata.activeContextID
                guard let chosen = workspace.contexts.first(where: { $0.metadata.identity.contextID == activeID })
                    ?? (workspace.contexts.count == 1 ? workspace.contexts.first : nil)
                else {
                    throw MCPError.invalidParams("workspace does not have one unambiguous context")
                }
                identity = chosen.metadata.identity
            } else {
                throw MCPError.invalidParams("headless bind requires context_id or working_dirs")
            }
            let snapshot = try await runtime.standaloneScopeCoordinator.bind(scopeID: scopeID, context: identity)
            return try .object(["binding": bindingValue(snapshot.binding), "backend": .string("headless")])
        default:
            throw MCPError.invalidParams("unknown bind_context op: \(op)")
        }
    }

    func manageWorkspaceLifecycle(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        if args["window_id"] != nil || args["open_in_new_window"]?.boolValue == true {
            throw MCPError.invalidParams("window selectors and new-window presentation are unavailable with --backend headless")
        }
        let action = args["action"]?.stringValue ?? "list"
        switch action {
        case "list":
            return try await workspaceCatalogResult(includeBinding: false)
        case "switch":
            guard let selector = args["workspace"]?.stringValue else {
                throw MCPError.invalidParams("switch requires workspace")
            }
            let catalog = await runtime.workspaceStore.snapshot()
            let matches = catalog.workspaces.filter {
                $0.document.workspaceID.uuidString == selector
                    || $0.document.metadata.name.localizedCaseInsensitiveCompare(selector) == .orderedSame
            }
            guard matches.count == 1, let workspace = matches.first else {
                throw MCPError.invalidParams("workspace is unknown or ambiguous")
            }
            let activeID = workspace.document.metadata.activeContextID
            guard let chosen = workspace.contexts.first(where: { $0.metadata.identity.contextID == activeID })
                ?? workspace.contexts.first
            else {
                throw MCPError.invalidParams("workspace has no contexts")
            }
            let snapshot = try await runtime.standaloneScopeCoordinator.bind(
                scopeID: scopeID,
                context: chosen.metadata.identity
            )
            return try .object([
                "workspace_id": .string(workspace.document.workspaceID.uuidString),
                "context_id": .string(chosen.metadata.identity.contextID.uuidString),
                "binding": bindingValue(snapshot.binding)
            ])
        case "list_tabs":
            return try await workspaceCatalogResult(includeBinding: true)
        case "select_tab":
            guard let raw = args["tab"]?.stringValue, let contextID = UUID(uuidString: raw) else {
                throw MCPError.invalidParams("headless select_tab requires a canonical tab UUID")
            }
            let forwarded = try DomainPhysicalToolRequest(
                argumentsJSON: JSONEncoder().encode(["op": Value.string("bind"), "context_id": .string(contextID.uuidString)]),
                securityContext: request.securityContext
            )
            return try await routeContext(forwarded)
        case "create", "hide", "unhide", "delete", "add_folder", "remove_folder", "create_tab", "close_tab":
            return try await mutateWorkspaceLifecycle(action: action, args: args, request: request)
        default:
            throw MCPError.invalidParams("unknown manage_workspaces action: \(action)")
        }
    }

    private func mutateWorkspaceLifecycle(
        action: String,
        args: [String: Value],
        request: DomainPhysicalToolRequest
    ) async throws -> DomainPhysicalToolResult {
        let operationID = request.securityContext?.invocationID ?? UUID()
        if action == "create" {
            guard let name = args["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                throw MCPError.invalidParams("create requires a non-empty name")
            }
            let roots: [String] = if let rawPath = args["folder_path"]?.stringValue {
                try [validatedDirectory(rawPath).path]
            } else {
                []
            }
            let catalog = await runtime.workspaceStore.snapshot()
            let workspaceID = UUID()
            let contextID = UUID()
            let object: [String: Any] = [
                "id": workspaceID.uuidString,
                "schemaVersion": 1,
                "name": name,
                "repoPaths": roots,
                "isSystemWorkspace": false,
                "isHiddenInMenus": false,
                "activeComposeTabID": contextID.uuidString,
                "composeTabs": [[
                    "id": contextID.uuidString,
                    "name": "Prompt 1",
                    "prompt": "",
                    "selectedPaths": []
                ]]
            ]
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let fileURL = runtime.configuration.workspaceStorageDirectory
                .appendingPathComponent("\(workspaceID.uuidString).json", isDirectory: false)
            let document = try DomainWorkspaceDocument.decode(documentBytes: bytes, fileURL: fileURL)
            try await MCPDomainMutationCommitContext.willCommit()
            let outcome = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedCatalogRevision: catalog.catalogRevision,
                origin: .standalone,
                command: .createWorkspace(document)
            ))
            try requireApplied(outcome)
            var result: [String: Value] = [
                "workspace_id": .string(workspaceID.uuidString),
                "context_id": .string(contextID.uuidString),
                "name": .string(name),
                "catalog_revision": .int(Int(outcome.catalogRevision))
            ]
            if args["switch_to_created"]?.boolValue == true {
                let binding = try await runtime.standaloneScopeCoordinator.bind(
                    scopeID: scopeID,
                    context: DomainContextIdentity(workspaceID: workspaceID, contextID: contextID)
                )
                result["binding"] = bindingValue(binding.binding)
            }
            return try .object(result)
        }

        let catalog = await runtime.workspaceStore.snapshot()
        let workspace: DomainWorkspaceSnapshot
        if let selector = args["workspace"]?.stringValue {
            workspace = try resolveWorkspace(selector, in: catalog, includeHidden: args["include_hidden"]?.boolValue == true)
        } else {
            let current = try await context.snapshot(for: request)
            workspace = current.workspace
        }

        if action == "delete" {
            try await MCPDomainMutationCommitContext.willCommit()
            let outcome = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedCatalogRevision: catalog.catalogRevision,
                expectedWorkspaceRevision: workspace.revisions.workingRevision,
                origin: .standalone,
                command: .deleteWorkspace(workspaceID: workspace.document.workspaceID)
            ))
            try requireApplied(outcome)
            if let scope = try? await runtime.standaloneScopeCoordinator.snapshot(scopeID: scopeID),
               bindingContext(scope.binding)?.workspaceID == workspace.document.workspaceID
            {
                _ = try? await runtime.standaloneScopeCoordinator.unbind(scopeID: scopeID)
            }
            return try .object([
                "workspace_id": .string(workspace.document.workspaceID.uuidString),
                "deleted": .bool(true),
                "catalog_revision": .int(Int(outcome.catalogRevision))
            ])
        }

        guard var object = try JSONSerialization.jsonObject(with: workspace.document.documentBytes) as? [String: Any] else {
            throw DirectHeadlessDomainContext.Error.invalidWorkspaceDocument
        }
        var selectedContextID: UUID?
        switch action {
        case "hide", "unhide":
            object["isHiddenInMenus"] = action == "hide"
        case "add_folder", "remove_folder":
            guard let rawPath = args["folder_path"]?.stringValue else {
                throw MCPError.invalidParams("\(action) requires folder_path")
            }
            let path = try validatedDirectory(rawPath).path
            var roots = object["repoPaths"] as? [String] ?? []
            if action == "add_folder" {
                if !roots.contains(path) { roots.append(path) }
            } else {
                roots.removeAll { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path == path }
            }
            object["repoPaths"] = roots
        case "create_tab":
            var tabs = object["composeTabs"] as? [[String: Any]] ?? []
            let newID = UUID()
            let mode = args["mode"]?.stringValue ?? "blank"
            var tab: [String: Any]
            if mode == "fork" {
                guard let source = resolveContext(args["source_tab"]?.stringValue, in: tabs) else {
                    throw MCPError.invalidParams("create_tab mode=fork requires an unambiguous source_tab")
                }
                tab = source
            } else if mode == "blank" {
                tab = ["prompt": "", "selectedPaths": []]
            } else {
                throw MCPError.invalidParams("create_tab mode must be blank or fork")
            }
            tab["id"] = newID.uuidString
            tab["name"] = args["name"]?.stringValue ?? "Prompt \(tabs.count + 1)"
            tabs.append(tab)
            object["composeTabs"] = tabs
            if args["bind"]?.boolValue != false {
                selectedContextID = newID
                object["activeComposeTabID"] = newID.uuidString
            }
        case "close_tab":
            guard var tabs = object["composeTabs"] as? [[String: Any]], tabs.count > 1,
                  let target = resolveContext(args["tab"]?.stringValue, in: tabs),
                  let rawID = target["id"] as? String,
                  let targetID = UUID(uuidString: rawID)
            else {
                throw MCPError.invalidParams("close_tab requires an existing tab and refuses to close the last tab")
            }
            let activeID = (object["activeComposeTabID"] as? String).flatMap(UUID.init(uuidString:))
            if activeID == targetID, args["allow_active"]?.boolValue != true {
                throw MCPError.invalidRequest("close_tab refuses to close the active tab unless allow_active=true")
            }
            tabs.removeAll { ($0["id"] as? String) == rawID }
            object["composeTabs"] = tabs
            if activeID == targetID, let replacement = tabs.first?["id"] as? String {
                object["activeComposeTabID"] = replacement
                selectedContextID = UUID(uuidString: replacement)
            }
        default:
            throw MCPError.invalidParams("unsupported workspace mutation: \(action)")
        }

        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let replacement = try DomainWorkspaceDocument.decode(
            documentBytes: bytes,
            fileURL: workspace.document.fileURL
        )
        try await MCPDomainMutationCommitContext.willCommit()
        let outcome = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: operationID,
            expectedCatalogRevision: catalog.catalogRevision,
            expectedWorkspaceRevision: workspace.revisions.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(replacement)
        ))
        try requireApplied(outcome)
        var result: [String: Value] = [
            "workspace_id": .string(workspace.document.workspaceID.uuidString),
            "action": .string(action),
            "workspace_revision": .int(Int(outcome.after?.workingRevision ?? workspace.revisions.workingRevision))
        ]
        if let selectedContextID {
            let binding = try await runtime.standaloneScopeCoordinator.bind(
                scopeID: scopeID,
                context: DomainContextIdentity(
                    workspaceID: workspace.document.workspaceID,
                    contextID: selectedContextID
                )
            )
            result["context_id"] = .string(selectedContextID.uuidString)
            result["binding"] = bindingValue(binding.binding)
        }
        return try .object(result)
    }

    private func resolveWorkspace(
        _ selector: String,
        in catalog: DomainWorkspaceCatalogSnapshot,
        includeHidden: Bool
    ) throws -> DomainWorkspaceSnapshot {
        let matches = catalog.workspaces.filter { workspace in
            let explicitID = workspace.document.workspaceID.uuidString == selector
            let nameMatch = workspace.document.metadata.name.localizedCaseInsensitiveCompare(selector) == .orderedSame
            return explicitID || (nameMatch && (includeHidden || !workspace.document.metadata.isHiddenInMenus))
        }
        guard matches.count == 1, let match = matches.first else {
            throw MCPError.invalidParams("workspace is unknown or ambiguous")
        }
        return match
    }

    private func resolveContext(_ selector: String?, in tabs: [[String: Any]]) -> [String: Any]? {
        guard let selector else { return tabs.count == 1 ? tabs.first : nil }
        let matches = tabs.filter {
            ($0["id"] as? String) == selector
                || (($0["name"] as? String)?.localizedCaseInsensitiveCompare(selector) == .orderedSame)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func validatedDirectory(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw MCPError.invalidParams("folder_path must be an existing absolute directory")
        }
        return url
    }

    private func requireApplied(_ outcome: DomainCommandOutcome) throws {
        guard outcome.disposition == .applied
            || outcome.disposition == .unchanged
            || outcome.disposition == .deduplicated
        else {
            throw DirectHeadlessDomainContext.Error.stateConflict(
                outcome.diagnostic ?? outcome.errorCode?.rawValue ?? outcome.disposition.rawValue
            )
        }
    }

    private func workspaceCatalogResult(includeBinding: Bool) async throws -> DomainPhysicalToolResult {
        let catalog = await runtime.workspaceStore.snapshot()
        let workspaces = catalog.workspaces.map { workspace in
            Value.object([
                "workspace_id": .string(workspace.document.workspaceID.uuidString),
                "name": .string(workspace.document.metadata.name),
                "repo_paths": .array(workspace.document.metadata.repoPaths.map(Value.string)),
                "hidden": .bool(workspace.document.metadata.isHiddenInMenus),
                "contexts": .array(workspace.contexts.map { context in
                    .object([
                        "context_id": .string(context.metadata.identity.contextID.uuidString),
                        "name": .string(context.metadata.name)
                    ])
                })
            ])
        }
        var result: [String: Value] = [
            "backend": .string("headless"),
            "workspaces": .array(workspaces),
            "catalog_revision": .int(Int(catalog.catalogRevision))
        ]
        if includeBinding,
           let scope = try? await runtime.standaloneScopeCoordinator.snapshot(scopeID: scopeID)
        {
            result["binding"] = bindingValue(scope.binding)
        }
        return try .object(result)
    }

    private nonisolated static func workingDirectories(from value: Value?) -> [String]? {
        guard let value else { return nil }
        if let string = value.stringValue {
            return string.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if let array = value.arrayValue {
            let strings = array.compactMap(\.stringValue)
            return strings.count == array.count ? strings : nil
        }
        return nil
    }

    private func bindingContext(_ binding: DomainBinding) -> DomainContextIdentity? {
        switch binding {
        case let .context(identity, _), let .runScoped(_, identity): identity
        case .unbound, .appPresentationWindow: nil
        }
    }

    private func bindingValue(_ binding: DomainBinding) -> Value {
        switch binding {
        case .unbound:
            .object(["kind": .string("unbound")])
        case let .context(identity, explicit):
            .object([
                "kind": .string("context"),
                "workspace_id": .string(identity.workspaceID.uuidString),
                "context_id": .string(identity.contextID.uuidString),
                "explicit": .bool(explicit)
            ])
        case let .runScoped(runID, identity):
            .object([
                "kind": .string("run_scoped"),
                "run_id": .string(runID.uuidString),
                "workspace_id": .string(identity.workspaceID.uuidString),
                "context_id": .string(identity.contextID.uuidString)
            ])
        case .appPresentationWindow:
            .object(["kind": .string("invalid_app_presentation")])
        }
    }
}

actor DirectHeadlessWorkspaceBackend: DomainWorkspaceCapabilityBackend {
    private let context: DirectHeadlessDomainContext

    init(context: DirectHeadlessDomainContext) {
        self.context = context
    }

    func mutateSelection(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        let snapshot = try await context.snapshot(for: request)
        let op = args["op"]?.stringValue ?? "get"
        var paths = snapshot.selection
        let requested = args["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        switch op {
        case "get", "preview":
            break
        case "clear":
            paths = []
        case "set":
            paths = requested
        case "add":
            for path in requested where !paths.contains(path) {
                paths.append(path)
            }
        case "remove":
            let removed = Set(requested)
            paths.removeAll { removed.contains($0) }
        case "promote", "demote":
            break
        default:
            throw MCPError.invalidParams("unknown manage_selection op: \(op)")
        }
        if paths != snapshot.selection {
            _ = try await context.mutate(request: request, mutation: .setSelection(paths))
        }
        return try .object([
            "selection": .array(paths.map(Value.string)),
            "count": .int(paths.count),
            "operation": .string(op)
        ])
    }

    func inspectCodeStructure(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await context.snapshot(for: request)
        let requested = args["paths"]?.arrayValue?.compactMap(\.stringValue) ?? snapshot.selection
        let candidates: [URL] = if requested.isEmpty {
            Self.files(under: snapshot.roots).filter {
                CodeMapSyntaxEngine.supportsCodeMap(fileExtension: $0.pathExtension)
            }
        } else {
            try requested.prefix(256).flatMap { raw -> [URL] in
                let resolved = try context.resolvePath(raw, roots: snapshot.roots)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return Self.files(under: [resolved])
                }
                return [resolved]
            }
        }
        let limited = Array(candidates.filter {
            CodeMapSyntaxEngine.supportsCodeMap(fileExtension: $0.pathExtension)
        }.prefix(256))
        let files = try await Self.runBlocking {
            try limited.map(Self.codeMapResult)
        }
        return try .object([
            "files": .array(files),
            "updates_pending": .bool(false),
            "backend": .string("headless")
        ])
    }

    func renderFileTree(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await context.snapshot(for: request)
        if args["type"]?.stringValue == "roots" {
            return try .mcp(.string(snapshot.roots.map(\.path).joined(separator: "\n")))
        }
        let maxDepth = max(0, min(args["max_depth"]?.intValue ?? 6, 32))
        let roots: [URL] = if let path = args["path"]?.stringValue {
            try [context.resolvePath(path, roots: snapshot.roots)]
        } else {
            snapshot.roots
        }
        let lines = roots.flatMap { root in Self.treeLines(root: root, maxDepth: maxDepth) }
        return try .mcp(.string(lines.joined(separator: "\n")))
    }

    func readFile(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await context.snapshot(for: request)
        guard let rawPath = args["path"]?.stringValue else { throw MCPError.invalidParams("missing path") }
        let url = try context.resolvePath(rawPath, roots: snapshot.roots)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
        let start = args["start_line"]?.intValue
        let limit = args["limit"]?.intValue
        let selected: ArraySlice<String>
        if let start, start < 0 {
            selected = lines.suffix(min(lines.count, abs(start)))
        } else if let start {
            let index = max(0, start - 1)
            guard index < lines.count else { return try .mcp(.string("")) }
            selected = lines[index ..< min(lines.count, index + max(0, limit ?? lines.count))]
        } else {
            selected = lines[...]
        }
        return try .mcp(.string(selected.joined(separator: "\n")))
    }

    func searchFiles(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await context.snapshot(for: request)
        guard let pattern = args["pattern"]?.stringValue, !pattern.isEmpty else {
            throw MCPError.invalidParams("pattern cannot be empty")
        }
        let maxResults = max(1, min(args["max_results"]?.intValue ?? 50, 1000))
        let regexEnabled = args["regex"]?.boolValue ?? Self.looksLikeRegex(pattern)
        let regex = regexEnabled ? try NSRegularExpression(pattern: pattern) : nil
        let mode = args["mode"]?.stringValue ?? "auto"
        var results: [Value] = []
        for file in Self.files(under: snapshot.roots) {
            if results.count >= maxResults { break }
            let relative = Self.relativePath(file, roots: snapshot.roots)
            let pathMatch = Self.matches(pattern, value: relative, regex: regex)
            if mode == "path" || (mode == "auto" && pattern.contains("*")) {
                if pathMatch { results.append(.object(["path": .string(relative)])) }
                continue
            }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                if Self.matches(pattern, value: line, regex: regex) {
                    results.append(.object([
                        "path": .string(relative),
                        "line": .int(index + 1),
                        "text": .string(line)
                    ]))
                    if results.count >= maxResults { break }
                }
            }
        }
        if args["count_only"]?.boolValue == true {
            return try .object(["count": .int(results.count)])
        }
        return try .object(["matches": .array(results), "count": .int(results.count)])
    }

    func renderWorkspaceContext(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await context.snapshot(for: request)
        let op = args["op"]?.stringValue ?? "snapshot"
        switch op {
        case "snapshot":
            return try .object([
                "prompt": .string(snapshot.prompt),
                "selection": .array(snapshot.selection.map(Value.string)),
                "roots": .array(snapshot.roots.map { .string($0.path) }),
                "workspace_id": .string(snapshot.identity.workspaceID.uuidString),
                "context_id": .string(snapshot.identity.contextID.uuidString)
            ])
        case "export":
            guard let path = args["path"]?.stringValue else { throw MCPError.invalidParams("export requires path") }
            let destination = try context.resolvePath(path, roots: snapshot.roots, allowMissingLeaf: true)
            try await admitExport(destination, roots: snapshot.roots)
            let content = "Prompt:\n\(snapshot.prompt)\n\nSelection:\n\(snapshot.selection.joined(separator: "\n"))\n"
            try content.write(to: destination, atomically: true, encoding: .utf8)
            return try .object(["path": .string(destination.path), "exported": .bool(true)])
        case "list_presets":
            return try .object(["presets": .array([])])
        case "select_preset":
            throw MCPError.invalidRequest("copy presets are unavailable without an extracted preset backend")
        default:
            throw MCPError.invalidParams("unknown workspace_context op: \(op)")
        }
    }

    func accessPrompt(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await context.snapshot(for: request)
        let op = args["op"]?.stringValue ?? "get"
        switch op {
        case "get":
            return try .object(["prompt": .string(snapshot.prompt)])
        case "set", "append", "clear":
            let prompt: String = switch op {
            case "set": args["text"]?.stringValue ?? ""
            case "append": snapshot.prompt + (args["text"]?.stringValue ?? "")
            default: ""
            }
            let physical = DomainPhysicalToolRequest(
                argumentsJSON: request.request.argumentsJSON,
                securityContext: request.request.securityContext
            )
            let updated = try await context.mutate(request: physical, mutation: .setPrompt(prompt))
            return try .object(["prompt": .string(updated.prompt), "operation": .string(op)])
        case "export":
            guard let path = args["path"]?.stringValue else { throw MCPError.invalidParams("export requires path") }
            let destination = try context.resolvePath(path, roots: snapshot.roots, allowMissingLeaf: true)
            try await admitExport(destination, roots: snapshot.roots)
            try snapshot.prompt.write(to: destination, atomically: true, encoding: .utf8)
            return try .object(["path": .string(destination.path), "exported": .bool(true)])
        case "list_presets":
            return try .object(["presets": .array([])])
        case "select_preset":
            throw MCPError.invalidRequest("select_preset is unavailable without an extracted preset backend")
        default:
            throw MCPError.invalidParams("unknown prompt op: \(op)")
        }
    }

    private func admitExport(_ destination: URL, roots: [URL]) async throws {
        let mappings = roots.map {
            DomainMutationPhysicalRootMapping(canonicalRoot: $0.path, physicalRoot: $0.path)
        }
        try await MCPDomainMutationCommitContext.admitPhysicalTargets(
            [destination.path],
            rootMappings: mappings
        )
        try await MCPDomainMutationCommitContext.willCommit()
    }

    private nonisolated static func codeMapResult(_ url: URL) throws -> Value {
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            return .object([
                "path": .string(url.path),
                "diagnostic": .string("undecodable_source")
            ])
        }
        guard let language = CodeMapSyntaxEngine.shared.language(forFileExtension: url.pathExtension) else {
            return .object([
                "path": .string(url.path),
                "diagnostic": .string("unsupported_language")
            ])
        }
        let snapshot = CodeMapCoreSourceSnapshot(
            rawByteCount: data.count,
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(SHA256.hash(data: data))),
            decoderPolicy: .workspaceAutomaticV1,
            decodeResult: .decoded(CodeMapDecodedSource(text: content, detectedEncodingRawValue: String.Encoding.utf8.rawValue))
        )
        let outcome = try CodeMapSyntaxArtifactBuilder.build(source: snapshot, language: language)
        switch outcome {
        case let .ready(artifact):
            return .object([
                "path": .string(url.path),
                "language": .string(language.rawValue),
                "signatures": .string(artifact.apiDescription)
            ])
        case .readyNoSymbols:
            return .object([
                "path": .string(url.path),
                "language": .string(language.rawValue),
                "signatures": .string(""),
                "diagnostic": .string("no_symbols")
            ])
        case .oversize:
            return .object(["path": .string(url.path), "diagnostic": .string("source_oversize")])
        case .parseFailed:
            return .object(["path": .string(url.path), "diagnostic": .string("parse_failed")])
        case .decodeFailed:
            return .object(["path": .string(url.path), "diagnostic": .string("decode_failed")])
        }
    }

    private nonisolated static func runBlocking<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let value = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try operation() })
            }
        }
        try Task.checkCancellation()
        return value
    }

    private nonisolated static func files(under roots: [URL]) -> [URL] {
        roots.flatMap { root -> [URL] in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            return enumerator.compactMap { item -> URL? in
                guard let url = item as? URL,
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { return nil }
                return url
            }
        }
    }

    private nonisolated static func treeLines(root: URL, maxDepth: Int) -> [String] {
        var lines = [root.lastPathComponent + "/"]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return lines }
        for case let url as URL in enumerator {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let depth = relative.split(separator: "/").count
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            lines.append(String(repeating: "  ", count: depth) + url.lastPathComponent + (isDirectory ? "/" : ""))
        }
        return lines
    }

    private nonisolated static func relativePath(_ url: URL, roots: [URL]) -> String {
        for root in roots where url.path.hasPrefix(root.path + "/") {
            return String(url.path.dropFirst(root.path.count + 1))
        }
        return url.path
    }

    private nonisolated static func matches(_ pattern: String, value: String, regex: NSRegularExpression?) -> Bool {
        if let regex {
            return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        if pattern.contains("*") {
            let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
            return (try? NSRegularExpression(pattern: "^\(escaped)$"))?
                .firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        return value.localizedCaseInsensitiveContains(pattern)
    }

    private nonisolated static func looksLikeRegex(_ pattern: String) -> Bool {
        pattern.range(of: #"[\[\](){}|+?^$\\]"#, options: .regularExpression) != nil
    }
}
