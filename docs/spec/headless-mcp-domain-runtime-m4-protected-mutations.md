# Headless MCP domain runtime — M4 protected mutations

Milestone 4 is PR 5/8, stacked on M3 (`feature/headless-runtime-m3-read-discovery`, PR #657). It migrates protected mutation admission into `RepoPromptDomainRuntime` without adding a direct standalone host, AI/Agent execution, credential transport, or M7 cleanup.

## Gate 4A — selection, prompt, routing, and workspace mutations

Gate 4A protects the mutation actions of `manage_selection`, `prompt`, `workspace_context`, `bind_context`, and `manage_workspaces`. Read actions on mixed tools retain their M3 behavior. `file_actions`, `apply_edits`, and `manage_worktree` remain explicitly outside the gate until 4B.

### Authority and parity ledger

| Concern | M4 authority | Compatibility boundary |
|---|---|---|
| mutation classification | `MCPDomainProtectedMutationToolProvider` | existing public names, input schemas, annotations, and physical app providers are unchanged |
| invocation identity | immutable `DomainToolInvocationSecurityContext` installed by `MCPConnectionManager` | app proxy transport and run-scoped tool advertisement remain unchanged |
| persistent headless grants | `DomainMutationPolicyStore`, schema version 1, CAS-written `Settings/protected-mutations.json` | verified app-proxy principals retain the app approval/policy behavior |
| approval ordering and settlement | `DomainMutationApprovalBroker` | `WorkspaceApprovalManager` is an AppKit presenter and legacy policy façade |
| policy administration | `repoprompt-mcp policy list|grant|revoke` | mutations require stdin and stderr TTYs plus an immediate `yes` confirmation |
| construction | `ServiceRegistry` wraps every registered binding exactly once | app providers remain physical backends; no second mutation registration exists |

The runtime starts in an explicit construction stage. The 4A commit selected `m4A`; after its focused gate passed, the 4B commit switches production app composition to `m4B`. The configuration default remains `m3Compatibility` for explicit compatibility fixtures. This prevents both partial activation and dual executable mutation paths.

### Security ledger

- Missing, display-name-only, or runtime-generation-mismatched principals default-deny before the physical backend.
- Verified app-proxy principals preserve current app behavior.
- Run-scoped verified principals require the tool in their immutable ephemeral grant, or a non-expired, non-revoked persistent grant matching `tool.action`, principal, optional provider/workspace, and canonical roots.
- Authorization is revalidated and cancellation is checked immediately before backend execution.
- Persistent grant changes are TTY-administrator-only and compare-and-swap against the durable document.
- Corrupt, future-version, wrong-profile, or externally-conflicted policy enters degraded read-only mode.
- Approval requests have one FIFO active presenter, bounded deadlines, cancellation settlement, presenter-loss settlement, default-deny terminal mapping, and ignored late responses.

### MainActor ledger

`DomainMutationPolicyStore`, `DomainMutationApprovalBroker`, and `MCPDomainProtectedMutationToolProvider` are domain-runtime concurrency authorities and do not depend on AppKit or `@MainActor`. `WorkspaceApprovalManager` remains `@MainActor` only as the compatibility presenter/policy façade. Physical selection, prompt, routing, and workspace backends retain their existing app isolation; the new security decision executes before entering them.

### Gate 4A focused evidence

| Validation | Result |
|---|---|
| `make dev-test FILTER=DomainProtectedMutationSecurityTests` | passed after staged grant-selection review fix, ticket `c50dfe50-9f60-4d01-844a-c80552353fdf` |
| `make dev-test FILTER=DomainMutationApprovalBrokerTests` | passed, ticket `dd9ca20d-ec78-4e20-83e1-814259360be7` |
| `make dev-test FILTER=WorkspaceApprovalCancellationTests` | passed, ticket `16eae60b-696f-4cfb-b2b6-0c0d612d1de8` |
| `make dev-test FILTER=HeadlessMCPDomainRuntimeM0ContractTests` | passed, ticket `06983bcc-1bb0-406f-ac10-737344cc194c` |
| `make dev-test-list` | passed, ticket `04183487-83e2-4b17-a83a-54cf7eb31cea` |
| `test_suite_optimizer.py verify-ledger` | passed; 3,634 exact root/provider IDs reconciled |
| `make dev-swift-build PRODUCT=RepoPrompt` | passed, ticket `893688a2-cb77-441e-abe3-28549f715a87` |
| `make dev-swift-build PRODUCT=repoprompt-mcp` | passed, ticket `710c0e01-3ac0-419d-a1d8-cc3ae1822a79` |
| `make dev-lint` | passed, ticket `c182fb45-f0b0-4ce2-af2d-6ee532cbdabf` |
| `make xcode-generator-test` | passed, 24 tests |
| `make guardrails` | passed |

## Gate 4B — filesystem, apply-edits, and worktree mutations

Gate 4B activates `file_actions`, `apply_edits`, and mutating `manage_worktree` actions through the same `MCPDomainProtectedMutationToolProvider`; the physical app providers remain the single execution backends.

### Security and settlement ledger

| Concern | M4 authority | Commit boundary |
|---|---|---|
| root scope | immutable workspace roots/revision captured from `DomainRoutingCoordinator` | requested paths resolve within an authoritative canonical root at admission |
| symlink/TOCTOU fence | `DomainMutationPathFence` | root device/inode and resolved requested path are revalidated immediately before physical mutation |
| durable replay | `DomainMutationJournal`, schema version 1, CAS-written `Settings/protected-mutation-journal.json` | stable `operation_id` + deterministic request/scope fingerprint elects one writer and replays the exact result |
| file actions | existing `MCPServerViewModel.performFileAction` backend | hook follows freshness/argument validation and precedes create/trash/move I/O |
| apply edits | existing `WorkspaceFileEditHost` backend | hook follows path/edit/approval resolution and precedes overwrite/create I/O |
| worktrees | existing worktree provider and `VCSService` backends | hook follows selector, confirmation, or routed approval and precedes settings/Git/session mutation |

Relative file paths remain compatible when exactly one authoritative root is bound; ambiguous multi-root relative writes fail closed. Verified app-proxy external worktree creation retains its explicit `allow_external_path` behavior while headless grants remain root-scoped.

Cancellation before the commit hook records `cancelledBeforeCommit` and permits the same stable operation to retry. Once the hook atomically moves the record to `committing`, cancellation or reply loss produces a partial-success diagnostic and durable `indeterminateAfterCommit`; restart refuses automatic reexecution. Applied records contain the encoded exact MCP result. Collision, active-owner, corrupt/future journal, CAS exhaustion, and interrupted commit all default-deny.

### MainActor ledger

`DomainMutationJournal`, `DomainMutationPathFence`, and the protected provider are AppKit-free domain authorities. Existing physical file/edit/worktree providers retain their current actor isolation. The task-local commit controller crosses into those providers only to revalidate policy/path authority and CAS the durable journal at their physical commit point.

### Gate 4B focused evidence

| Validation | Result |
|---|---|
| `make dev-test FILTER=DomainProtectedMutationJournalTests` | passed 5 adversarial fixtures after final fence/fingerprint strengthening, ticket `f6363730-c0dc-4afb-95bd-7c3272a3a7a6` |
| `make dev-test FILTER=HeadlessMCPDomainRuntimeM0ContractTests` | passed 3 contract/ledger tests, ticket `673437d2-8b07-4232-8401-6b8539f78d71` |
| `make dev-test FILTER=MCPFileActionPartialSuccessTests` | passed 3 app compatibility tests, ticket `b0a09b71-6642-4f4f-aa46-8de8366ec534` |
| focused apply-edits materialization test | passed, ticket `2d6777dc-140f-4689-843a-cc0738ede99d` |
| `make dev-test FILTER=ManageWorktreeToolServiceTests` | passed 2 provider tests, ticket `4ee23570-2a76-41f3-96ab-3b2e3bd58db5` |
| `make dev-test FILTER=ToolCatalogSnapshotTests` | passed 20 frozen catalog tests, ticket `0f8a0c6e-3538-44af-a753-b118f43348ae` |
| `make dev-test-list` + `verify-ledger` | passed; 3,639 exact root/provider IDs reconciled, list ticket `d2f504c5-cc1e-4263-8fca-b6b5ea8141de` |
| `make dev-swift-build PRODUCT=RepoPrompt` | passed, ticket `8f581c71-6a21-4866-99da-229a4a5d3b0c` |
| `make dev-swift-build PRODUCT=repoprompt-mcp` | passed, ticket `1c59725c-f484-429a-be78-0d318cff6f34` |
| `make dev-lint` | passed, ticket `fbb8c35f-99aa-485f-8c64-efe17d73ea8b` |
| `make guardrails` | passed |


## Explicit exclusions

M4 does not migrate AI/Agent/Context Builder execution (M5), add a direct host/backend or credential transport (M6), remove the app proxy/physical adapters (M7), launch/relaunch the visible app, or change the frozen 27-tool public catalog.
