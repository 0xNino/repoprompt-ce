import Foundation
import MCP
import RepoPromptDomainRuntime

@MainActor
final class MCPPromptContextToolProvider {
    private let dependencies: MCPWindowToolDependencies

    init(runtime _: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.dependencies = dependencies
    }

    func executeDomainRead(
        toolName: String,
        context _: DomainReadContextHandle,
        args: [String: Value]
    ) async throws -> Value {
        switch toolName {
        case MCPWindowToolName.workspaceContext:
            try await executeWorkspaceContext(args: args)
        case MCPWindowToolName.prompt:
            try await executePrompt(args: args)
        default:
            throw MCPError.invalidParams("Unsupported prompt/context read tool: \(toolName)")
        }
    }

    func executeWorkspaceContext(args: [String: Value]) async throws -> Value {
        let op = (args["op"]?.stringValue ?? "snapshot").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if op != "snapshot" {
            var forwarded = args
            forwarded["op"] = .string(op)
            switch op {
            case "export", "list_presets", "select_preset":
                return try await executePrompt(args: forwarded)
            default:
                throw MCPError.invalidParams("Unsupported workspace_context op '\(op)'. Use snapshot, export, list_presets, or select_preset.")
            }
        }
        let includeArr = args["include"]?.arrayValue?.compactMap { $0.stringValue?.lowercased() } ?? ["prompt", "selection", "code", "tokens"]
        let display: FilePathDisplay = ((args["path_display"]?.stringValue ?? "relative").lowercased() == "full") ? .full : .relative
        let overridePreset = try await resolveCopyPresetOverride(args["copy_preset"])
        let metadata = await dependencies.captureRequestMetadata()
        guard await dependencies.drainReadFileAutoSelection(metadata, .mirroredSelectionAndMetrics) == .completed else {
            throw CancellationError()
        }
        let lookupContext = await dependencies.resolveFileToolLookupContext(metadata)
        if includeArr.contains("files") {
            _ = await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngress(rootScope: lookupContext.rootScope)
        }
        let resolvedTabContext = try await dependencies.resolveTabContextSnapshot(metadata, MCPWindowToolName.workspaceContext, .allowLegacyImplicitRouting)
        let dto = try await dependencies.buildTabWorkspaceContext(
            resolvedTabContext.snapshot,
            Set(includeArr),
            display,
            overridePreset,
            resolvedTabContext.usesActiveTabCompatibility
        )
        return try Value(dto)
    }

    func executePrompt(args: [String: Value]) async throws -> Value {
        try await executePromptBody(args: args)
    }

    private func executePromptBody(args: [String: Value]) async throws -> Value {
        let op = (args["op"]?.stringValue ?? "get").lowercased()
        if op == "list_presets" {
            return try Value(ToolResultDTOs.PromptToolEnvelope.forPresetsList(dependencies.buildCopyPresetsListDTO()))
        }
        let metadata = await dependencies.captureRequestMetadata()
        if op == "export" {
            guard await dependencies.drainReadFileAutoSelection(metadata, .mirroredSelectionAndMetrics) == .completed else {
                throw CancellationError()
            }
        }
        let resolvedContext = try await dependencies.resolveTabContextSnapshot(metadata, MCPWindowToolName.prompt, .allowLegacyImplicitRouting)
        if !resolvedContext.usesActiveTabCompatibility {
            return try await executeTabScopedPrompt(op: op, args: args, resolvedContext: resolvedContext)
        }
        switch op {
        case "get":
            return try await activePromptReply(op: op)
        case "set":
            guard let text = args["text"]?.stringValue else { throw MCPError.invalidParams("text required for set") }
            await MainActor.run { dependencies.promptVM.promptText = text }
            return try Value(simplePromptReply(text, op: op))
        case "append":
            guard let text = args["text"]?.stringValue else { throw MCPError.invalidParams("text required for append") }
            let combined = await dependencies.promptVM.promptText + text
            await MainActor.run { dependencies.promptVM.promptText = combined }
            return try Value(simplePromptReply(combined, op: op))
        case "clear":
            await MainActor.run { dependencies.promptVM.promptText = "" }
            return try Value(simplePromptReply("", op: op))
        case "export":
            return try await exportPrompt(args: args, resolvedContext: resolvedContext, tabContext: nil)
        case "select_preset":
            let preset = try await resolveRequiredPreset(args["preset"])
            await MainActor.run { dependencies.promptVM.selectCopyPreset(preset.id) }
            return try Value(ToolResultDTOs.PromptToolEnvelope.forSelectPreset(dependencies.copyPresetDescriptorDTO(preset)))
        default:
            throw MCPError.invalidParams("invalid op: \(op)")
        }
    }

    private func executeTabScopedPrompt(op: String, args: [String: Value], resolvedContext: MCPServerViewModel.ResolvedTabContextSnapshot) async throws -> Value {
        let tabContext = resolvedContext.snapshot
        switch op {
        case "get":
            let context = try await dependencies.requireCurrentTabContext(MCPWindowToolName.prompt)
            return try Value(simplePromptReply(context.promptText, op: op))
        case "set":
            guard let text = args["text"]?.stringValue else { throw MCPError.invalidParams("text required for set") }
            try await dependencies.updateCurrentTabContext(MCPWindowToolName.prompt) { $0.promptText = text }
            let context = try await dependencies.requireCurrentTabContext(MCPWindowToolName.prompt)
            return try Value(simplePromptReply(context.promptText, op: op))
        case "append":
            guard let text = args["text"]?.stringValue else { throw MCPError.invalidParams("text required for append") }
            try await dependencies.updateCurrentTabContext(MCPWindowToolName.prompt) { $0.promptText += text }
            let context = try await dependencies.requireCurrentTabContext(MCPWindowToolName.prompt)
            return try Value(simplePromptReply(context.promptText, op: op))
        case "clear":
            try await dependencies.updateCurrentTabContext(MCPWindowToolName.prompt) { $0.promptText = "" }
            return try Value(simplePromptReply("", op: op))
        case "export":
            return try await exportPrompt(args: args, resolvedContext: resolvedContext, tabContext: tabContext)
        case "list_presets":
            return try Value(ToolResultDTOs.PromptToolEnvelope.forPresetsList(dependencies.buildCopyPresetsListDTO()))
        case "select_preset":
            guard tabContext.explicitlyBound, tabContext.runID == nil else {
                throw MCPError.invalidParams("select_preset requires an explicitly bound tab (bind_context or _tabID). It is disabled for run-based bindings; use copy_preset override in workspace_context or export instead.")
            }
            let preset = try await resolveRequiredPreset(args["preset"])
            await MainActor.run { dependencies.promptVM.selectCopyPreset(preset.id) }
            return try Value(ToolResultDTOs.PromptToolEnvelope.forSelectPreset(dependencies.copyPresetDescriptorDTO(preset)))
        default:
            throw MCPError.invalidParams("Unsupported op '\(op)' for prompt when tab context is active")
        }
    }

    private func simplePromptReply(_ text: String, op: String) -> ToolResultDTOs.PromptToolEnvelope {
        let lines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        return .forPrompt(ToolResultDTOs.PromptReply(prompt: text, lines: lines, copyPresetName: nil, chatPresetName: nil, chatMode: nil, includesFiles: nil, includesFileTree: nil, includesCodemaps: nil, includesGitDiff: nil, includesUserPrompt: nil, includesMetaPrompts: nil, includesStoredPrompts: nil, fileTreeMode: nil, codeMapUsage: nil, gitInclusion: nil, effectiveTokens: nil, fullFilesTokens: nil, codeMapFileCount: nil, codeMapTokens: nil, codeMapFiles: nil), op: op)
    }

    private func activePromptReply(op: String) async throws -> Value {
        let prompt = await dependencies.promptVM.promptText
        let lines = prompt.isEmpty ? 0 : prompt.components(separatedBy: "\n").count
        let copyPreset = await dependencies.promptVM.currentCopyPreset()
        let chatPreset = await dependencies.promptVM.currentChatPreset()
        let resolved = await dependencies.promptVM.resolvePromptContext()
        let effectiveTokens = await dependencies.promptVM.calculateTokensForChatContext()
        let fullFilesTokens = await dependencies.promptVM.tokenCountingViewModel.totalTokenCountFilesOnly
        let includesCodemaps = resolved.codeMapUsage != .none
        let includesGitDiff = resolved.gitInclusion != .none
        let hasStoredPrompts = resolved.storedPromptIds?.isEmpty == false
        let codeMapFileCount = includesCodemaps ? await dependencies.promptVM.codeMapFileCount : nil
        let codeMapTokens = includesCodemaps ? await dependencies.promptVM.codeMapTokenCount : nil
        let codeMapFiles: [String]? = try await {
            guard includesCodemaps else { return nil }
            let collections = try await dependencies.selectionCollectionsForCurrentTabContext()
            let roots = await dependencies.promptVM.workspaceFileContextStore.rootRefs(scope: .allLoaded)
            let display = dependencies.promptVM.filePathDisplayOption
            return collections.codemap.map { entry in
                if display == .full {
                    return entry.file.fullPath
                }
                guard let root = roots.first(where: { $0.id == entry.file.rootID }) else { return entry.file.relativePath }
                return ClientPathFormatter.displayPath(root: root, relativePath: entry.file.standardizedRelativePath, visibleRoots: roots)
            }
        }()
        let envelope = ToolResultDTOs.PromptToolEnvelope.forPrompt(ToolResultDTOs.PromptReply(
            prompt: prompt,
            lines: lines,
            copyPresetName: copyPreset.name,
            chatPresetName: chatPreset.name,
            chatMode: chatPreset.mode.rawValue,
            includesFiles: resolved.includeFiles,
            includesFileTree: resolved.rendersFileTree,
            includesCodemaps: includesCodemaps,
            includesGitDiff: includesGitDiff,
            includesUserPrompt: resolved.includeUserPrompt,
            includesMetaPrompts: resolved.includeMetaPrompts,
            includesStoredPrompts: hasStoredPrompts,
            fileTreeMode: resolved.effectiveFileTreeMode.rawValue,
            codeMapUsage: resolved.codeMapUsage.rawValue,
            gitInclusion: resolved.gitInclusion.rawValue,
            effectiveTokens: effectiveTokens,
            fullFilesTokens: fullFilesTokens,
            codeMapFileCount: codeMapFileCount,
            codeMapTokens: codeMapTokens,
            codeMapFiles: codeMapFiles
        ), op: op)
        return try Value(envelope)
    }

    private func exportPrompt(args: [String: Value], resolvedContext: MCPServerViewModel.ResolvedTabContextSnapshot, tabContext: MCPServerViewModel.TabScopedContext?) async throws -> Value {
        guard let rawPath = args["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            throw MCPError.invalidParams("path required for export")
        }
        let overridePreset = try await resolveCopyPresetOverride(args["copy_preset"])
        let activePreset = await MainActor.run { dependencies.promptVM.currentCopyPreset() }
        let effectivePreset = overridePreset ?? activePreset
        let cfg = await MainActor.run { dependencies.promptVM.resolvePromptContext(effectivePreset, custom: dependencies.promptVM.workingCopyCustomizations) }
        let text = if let tabContext {
            await dependencies.buildTabClipboardContent(cfg, tabContext)
        } else {
            await dependencies.promptVM.buildClipboard(for: cfg)
        }
        let pathDisplay = await MainActor.run { dependencies.promptVM.filePathDisplayOption }
        let rootRefs = await dependencies.promptVM.workspaceFileContextStore.rootRefs(scope: .allLoaded)
        let effectiveContext = tabContext.map { MCPServerViewModel.ResolvedTabContextSnapshot(snapshot: $0, usesActiveTabCompatibility: false) } ?? resolvedContext
        let files = try await dependencies.buildExportSelectedFileInfos(effectiveContext, cfg, tabContext?.selection, pathDisplay)
        let resolvedPath = try await dependencies.writePromptExportFile(rawPath, text)
        _ = await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngressForExplicitRequest(
            userPath: resolvedPath,
            fallbackScope: .allLoaded
        )
        let exportPath = pathDisplay == .full ? resolvedPath : MCPWindowWorkspaceToolHelpers.prefixedRelativePath(forPath: resolvedPath, rootRefs: rootRefs)
        let envelope = ToolResultDTOs.PromptToolEnvelope.forExport(ToolResultDTOs.PromptExportReply(path: exportPath, tokens: TokenCalculationService.estimateTokens(for: text), bytes: text.lengthOfBytes(using: .utf8), files: files, copyPreset: dependencies.copyPresetDescriptorDTO(effectivePreset)))
        return try Value(envelope)
    }

    private func resolveCopyPresetOverride(_ value: Value?) async throws -> CopyPreset? {
        guard let selector = dependencies.parseCopyPresetSelector(value) else { return nil }
        guard let preset = dependencies.resolveCopyPreset(selector) else { throw MCPError.invalidParams("copy_preset not found") }
        return preset
    }

    private func resolveRequiredPreset(_ value: Value?) async throws -> CopyPreset {
        guard let selector = dependencies.parseCopyPresetSelector(value) else {
            throw MCPError.invalidParams("preset parameter required for select_preset (UUID, kind, or name)")
        }
        guard let preset = dependencies.resolveCopyPreset(selector) else { throw MCPError.invalidParams("preset not found") }
        return preset
    }
}
