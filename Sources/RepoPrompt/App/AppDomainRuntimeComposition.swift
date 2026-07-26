import Foundation
import RepoPromptDomainRuntime

/// App-process composition for the M1 domain runtime and live catalog registry.
/// Workspace/context/provider authority remains app-owned until later milestones.
final class AppDomainRuntimeComposition: Sendable {
    static let shared = AppDomainRuntimeComposition()

    let runtime: MCPDomainRuntime

    private init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let root = applicationSupport.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        runtime = MCPDomainRuntime(
            configuration: DomainRuntimeConfiguration(
                mode: .app,
                profileIdentifier: "default",
                storageDirectory: root,
                eventDirectory: root.appendingPathComponent("Events", isDirectory: true),
                temporaryDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("RepoPrompt CE", isDirectory: true)
            )
        )
    }
}
