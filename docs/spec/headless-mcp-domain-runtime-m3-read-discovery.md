# Headless MCP domain runtime — M3 read/discovery evidence

Milestone 3 moves the nine read/discovery tool registrations to one Swift 6, AppKit-free owner in `RepoPromptDomainRuntime`. It is stacked on the M2 workspace/context authority and does not add a standalone stdio host.

## Scope

| Family | Shared registration | App physical backend | Read-derived side effect |
|---|---|---|---|
| `get_code_structure`, `get_file_tree`, `read_file`, `file_search` | `MCPDomainReadToolProvider` / `MCPDomainReadToolDefinitions` | `MCPFileToolProvider` | read/search auto-selection is submitted through `DomainReadSideEffectCoordinator`; selection consumers drain the accepted high-water revision |
| `workspace_context`, `prompt` | same | `MCPPromptContextToolProvider` | selected-context consumers drain; prompt mutation operations remain compatibility passthroughs to the existing app backend and gain no M4 policy |
| `oracle_chat_log`, `history` | same | `MCPOracleToolProvider`, `MCPHistoryToolProvider` | none |
| Git `status`, `diff`, `log`, `show`, `blame` | same | `MCPGitToolProvider` | artifact advertisement is revisioned and awaited |

The app catalog projects `MCPDomainToolDefinition` into the existing `Tool` value at its final registration boundary and retains `MCPWindowToolRuntime` as the freshness/tracing/watchdog execution envelope. The legacy app providers no longer register these nine names. `ToolCatalogSnapshotTests` proves the 24-tool order and every migrated description, annotation, and schema hash are unchanged.

## Context and concurrency contract

Every invocation resolves a `DomainReadContextHandle` from `DomainRoutingCoordinator`. The handle contains runtime and connection generations, `DomainContextIdentity`, workspace/context/routing revisions, and binding kind. It deliberately contains no window identity. A presentation window may participate in compatibility resolution, but the provider and backend receive only the resolved workspace/context authority.

`MCPDomainReadToolProvider` owns common argument validation, pre/post cancellation checks, selection-consumer drains, and backend invocation outside MainActor. The injected backend is the app/headless physical-I/O seam. The current app adapter performs only authority capture/validation on MainActor and reuses the existing filesystem, search, history, prompt-render, Oracle-log, and Git workers; no UI object crosses the shared boundary. A later direct host can inject its physical backend without defining another tool or schema.

`DomainReadSideEffectCoordinator` assigns a monotonic revision per context, serializes effects only within that context, deduplicates exact operation-ID retries, rejects fingerprint collisions, and supports bounded high-water drains. Runtime shutdown cancels outstanding effect tasks and rejects later submissions.

## Parity and evidence

- Frozen catalog parity: `ToolCatalogSnapshotTests/testWindowToolCatalogSignatureMatchesGolden` passes without golden changes.
- Shared owner coverage: `MCPDomainReadToolProviderTests/testDefinitionsCoverM3FamiliesExactlyOnce` and `testProviderUsesDomainHandleAndSharedBackendForEveryFamily`.
- Normalized failure parity: top-level `read_file` and `file_search` invalid parameters are rejected before either app or headless backend; physical backend errors remain unwrapped; cancellation remains `CancellationError`.
- Effect ordering: `DomainReadSideEffectCoordinatorTests` covers monotonic revisions, same-context serialization, exact retry/collision behavior, drain, and shutdown cancellation.
- Contention: `testIndependentReadBackendsDoNotContendOnSideEffectCoordinator` proves two independent reads enter the backend concurrently; the coordinator is not a global read lock.
- App backend coverage: the existing catalog golden plus focused `HistoryMCPToolProviderTests` and the existing read/search/Git owner suites exercise the retained physical implementations.
- Source guards: `Scripts/source_layout_guardrails.sh` requires the M3 owner files and all nine shared definitions, prohibits MainActor/UI imports in `RepoPromptDomainRuntime`, and rejects reintroduced legacy registration markers.

## Explicit exclusions

M3 does not add protected mutation policy, AI sends, Agent or Context Builder execution, provider/process token handoff, a standalone stdio host/backend, credentials/listener work, or M4+ UI cleanup. Existing socket proxy behavior and all unmigrated tool registrations are unchanged.

The headless side of this milestone is the executable shared provider/backend contract, not a new direct process surface. Direct standalone composition remains the planned host milestone.
