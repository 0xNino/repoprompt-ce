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

The runtime starts in an explicit construction stage. Production app composition selects `m4A`; the default remains `m3Compatibility`, and 4B families are not protected until the later gate changes construction to `m4B`. This prevents both partial activation and dual executable mutation paths.

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

Not active in the 4A commit. Gate 4B must extend the same provider/policy path to `file_actions`, `apply_edits`, and `manage_worktree`, then add admission and precommit root/symlink fences, durable operation-ID deduplication, CAS, cancellation-before-commit, postcommit partial success, and interruption/N-writer evidence before switching construction to `m4B`.

## Explicit exclusions

M4 does not migrate AI/Agent/Context Builder execution (M5), add a direct host/backend or credential transport (M6), remove the app proxy/physical adapters (M7), launch/relaunch the visible app, or change the frozen 27-tool public catalog.
