# Headless MCP domain runtime — M0 contract freeze

Date: 2026-07-26

Base: `main` at `664252ebc85e`
Machine-readable authority: `Scripts/Fixtures/headless_mcp_domain_runtime_m0_contract.json`

## Scope

This is Milestone 0 of the eight-PR headless runtime plan. It records current authorities, closes bounded evidence questions, and establishes drift guards. It deliberately does **not** add a runtime target, move providers, define a production `DomainRunLaunchToken`, change persistence, or launch a child process.

The normalized catalog fixture contains all 27 public tools and all 98 top-level canonical actions. Its sanitized success/error observations apply independently to each action:

- success: a schema-valid request has the `typed_tool_result` outcome class;
- error: a missing discriminator or action-specific required field has the `invalid_params` class before mutation.

These are normalized outcome fixtures, not an exact JSON-RPC wire-envelope claim.

`ToolCatalogSnapshotTests` remains the detailed description/schema-hash golden for the 24 window tools. The M0 manifest adds the three global tools, action coverage, policy normalization, and dependency accounting rather than creating a second schema-hash authority.

## Canonical inventories

### Tool policy and parity ledger

Capability names below are from `MCPToolCapabilities`; `none` is intentional for tools currently outside capability mapping. Owner is the current app-side authority. “Headless” is the frozen expectation for the later family migration, not an M0 implementation claim.

| Tool | Capability | Admission / execution | Current owner | Schema/action fixture | Denied/cancel/lifecycle contract | App / headless expectation |
|---|---|---|---|---|---|---|
| `app_settings` | app_settings | exclusive / bounded | `AppSettingsMCPService` | manifest + service schema | invalid params; connection cancellation | app authoritative / exact later parity |
| `bind_context` | routing_advanced | exclusive / workspace lifecycle | `WindowRoutingService` | manifest + service schema | invalid context; bind lifecycle | app authoritative / exact later parity |
| `manage_workspaces` | routing_advanced | exclusive / workspace lifecycle | `WindowRoutingService` | manifest + service schema | approval/invalid target; workspace lifecycle | app authoritative / exact later parity |
| `manage_selection` | context_mutate | exclusive / bounded | `MCPSelectionToolProvider` | manifest + catalog golden | artifact fence/invalid params; request cancellation | app authoritative / exact later parity |
| `file_actions` | file_management | exclusive / bounded | `MCPFileToolProvider` | manifest + catalog golden | mutation/approval errors; request cancellation | app authoritative / exact later parity |
| `get_code_structure` | structural_explore | small_read / bounded | `MCPFileToolProvider` | manifest + catalog golden | lookup/invalid params; bounded cleanup | app authoritative / exact later parity |
| `get_file_tree` | structural_explore | small_read / bounded | `MCPFileToolProvider` | manifest + catalog golden | lookup/invalid params; bounded cleanup | app authoritative / exact later parity |
| `read_file` | none | small_read / bounded | `MCPFileToolProvider` | manifest + catalog golden | authorization/lookup; bounded cleanup | app authoritative / exact later parity |
| `file_search` | none | file_search / long synchronous | `MCPFileToolProvider` | manifest + catalog golden | lookup/overload; cooperative cancellation | app authoritative / exact later parity |
| `workspace_context` | context_render | exclusive / bounded | `MCPPromptContextToolProvider` | manifest + catalog golden | export/selector errors; request cancellation | app authoritative / exact later parity |
| `prompt` | context_mutate | exclusive / bounded | `MCPPromptContextToolProvider` | manifest + catalog golden | export/selector errors; request cancellation | app authoritative / exact later parity |
| `apply_edits` | file_content_edit | exclusive / interactive | `MCPApplyEditsToolProvider` | manifest + catalog golden | approval/rebase/invalid mode; interactive lifecycle | app authoritative / exact later parity |
| `oracle_utils` | conversation_helper | control / long synchronous | `MCPOracleToolProvider` | manifest + catalog golden | chat/model errors; cooperative cancellation | app authoritative / exact later parity |
| `ask_oracle` | agent_conversation_send | control / long synchronous | `MCPOracleToolProvider` | manifest + catalog golden | policy/provider errors; cooperative cancellation | app authoritative / exact later parity |
| `oracle_send` | conversation_send | control / long synchronous | `MCPOracleToolProvider` | manifest + catalog golden | policy/provider errors; cooperative cancellation | app authoritative / exact later parity |
| `oracle_chat_log` | conversation_log | small_read / long synchronous | `MCPOracleToolProvider` | manifest + catalog golden | chat/invalid params; cooperative cancellation | app authoritative / exact later parity |
| `git` | git_read | git_read / workspace lifecycle | `MCPGitToolProvider` | manifest + catalog golden | repo/operation errors; process cleanup | app authoritative / exact later parity |
| `manage_worktree` | worktree_manage | exclusive / workspace lifecycle | `MCPGitToolProvider` | manifest + catalog golden | preview/approval/conflict; merge lifecycle | app authoritative / exact later parity |
| `context_builder` | discovery | control / long synchronous | `MCPContextBuilderToolProvider` | manifest + catalog golden | policy/provider errors; cooperative cancellation | app authoritative / exact later parity |
| `ask_user` | user_interaction | control / interactive | `MCPAskUserToolProvider` | manifest + catalog golden | denied/timeout/cancel; interactive lifecycle | app authoritative / exact later parity |
| `agent_explore` | agent_explore_control | control / lifecycle managed | `MCPAgentControlToolProvider` | manifest + catalog golden | policy/provider errors; session lifecycle | app authoritative / exact later parity |
| `agent_run` | agent_external_control | control / lifecycle managed | `MCPAgentControlToolProvider` | manifest + catalog golden | policy/provider errors; session lifecycle | app authoritative / exact later parity |
| `agent_manage` | agent_external_control | control / bounded | `MCPAgentControlToolProvider` | manifest + catalog golden | ownership/invalid session; bounded cleanup | app authoritative / exact later parity |
| `share_thoughts` | agent_reasoning_control | control / bounded | `MCPAgentSessionControlToolProvider` | manifest + catalog golden | policy/identity errors; request cancellation | app authoritative / exact later parity |
| `set_status` | agent_session_control | control / bounded | `MCPAgentSessionControlToolProvider` | manifest + catalog golden | policy/identity errors; request cancellation | app authoritative / exact later parity |
| `wait_for_next_user_instruction` | agent_reasoning_control | control / interactive | `MCPAgentSessionControlToolProvider` | manifest + catalog golden | terminal/cancel; interactive lifecycle | app authoritative / exact later parity |
| `history` | none | control / bounded | `HistoryMCPToolService` | manifest + catalog golden | scan budget/invalid params; request cancellation | app authoritative / exact later parity |

The normalized advertisement fixtures freeze Discover, generic Agent Mode, and native-provider Agent Mode capability sets. Admission and execution partitions are exhaustive and fail closed: every catalog tool appears exactly once in each partition.

### Dependency and MainActor boundary

`MCPWindowToolDependencies` is the constructor-time seam. The manifest freezes all 84 stored fields; the guard test extracts those names from source and rejects additions, removals, or silent renames. This is an inventory, not approval to carry the entire app graph into the future runtime.

Current `@MainActor` owners are `MCPWindowToolCatalogService`, `MCPWindowToolRuntime`, `ServiceRegistry`, `WindowSettingsManager`, `GlobalSettingsStore`, `WorkspaceApprovalManager`, and `AgentExternalMCPRunStarter`. `MCPBootstrapLease`, `MCPReplayState`, and `BootstrapSocketMCPTransport` are actors rather than MainActor owners. The joined EditFlowPerf request timeline freezes `MainActorScheduled → MainActorEntered → MainActorExited`, provider execution, persistence, and response delivery as separately observable boundaries.

### Approval

`WorkspaceApprovalManager` currently owns `create_workspace`, `delete_workspace`, `add_folder`, and `remove_folder`. Terminal results are approved (including always-allow), denied, and timeout. Cancellation settles as denied exactly once, guarded by `WorkspaceApprovalCancellationTests`.

## Closed evidence gates

### Pinned SDK stdio

`Package.swift` pins `repoprompt/swift-sdk` at `85dec2fc7a27252bc33dc7728be6af6b3bd398c0`. Inspection of that revision's `StdioTransport` found:

1. clean EOF finishes the message stream normally;
2. a read error is logged and then also finishes the stream normally;
3. incomplete trailing frame data is discarded at EOF;
4. therefore the server observes `connectionClosed` for all three and receives no terminal provenance.

This gate is closed by a negative assessment: keep the pin, but M6B must use a bounded RepoPromptMCP-owned stdio adapter if it needs the app-owned clean-EOF/truncation/read-error distinction. No SDK fork is required by M0. Existing socket-reader and bridge-ledger tests are the fallback behavior reference.

The same SDK revision exposes `elicitation/create` with accept, decline, and cancel actions. That is recorded as **SDK-supported, client-negotiated**, never assumed.

### Packaged CLI credentials

`Scripts/package_app.sh` places `repoprompt-mcp` in `RepoPrompt.app/Contents/MacOS` and signs it before the outer app. No Keychain or security command was run for M0. The preserved `item0_measurement_record.json` explicitly says authorization-UI behavior is unmeasured and `startup_scan_approved` is false.

No empirical credential-access result exists: the measurement is classified `not_run_approval_required`, not as an observed Keychain rejection. The design gate is fail-closed, while the empirical gate remains explicitly unresolved:

- direct packaged-child Keychain access is **not proven and prohibited as an architectural assumption**;
- the prescribed fallback is parent-owned secure storage plus a minimum-scope, in-memory credential handoff;
- debug alternate-in-memory storage is explicitly nonpersistent;
- the 23-account secure-storage catalog remains parent-owned and secrets/account identifiers are not copied into this evidence.

### Persistence and save semantics

The manifest classifies durable files, in-memory window overlays, runtime-policy UserDefaults, presentation defaults, and secure storage. It also exhaustively classifies every `WorkspaceSaveSource`:

- automatic poll: `pollTimer`, `pollAndSaveState`, `pollAndSaveStateAsync`;
- lifecycle: `workspaceSwitchSaveState`, `mcpTabContextEndOfRun`;
- debounced automatic: `workspaceFilesDebouncedSelectionSave`;
- explicit save API: `saveWorkspaceAsync`;
- mutation write-through: workspace/root/preset/prompt/normalization mutations listed in the fixture;
- legacy unattributed: `directUnknown`;
- DEBUG-only: `debugWorkspaceSelectionFixtureApply`.

`GlobalSettingsStore` is file-backed at `~/Library/Application Support/RepoPrompt CE/Settings/globalSettings.json`. `WindowSettingsManager` is an in-memory overlay that writes only on explicit commit or opt-in auto-persist. Approval, tool availability, apply-edits policy, and host admission UserDefaults are runtime-policy migration candidates, not presentation preferences. Working-journal rows freeze the later M2/M4 migration accounting without implementing it.

### EditFlowPerf representative baseline

`headless-mcp-domain-runtime-m0-editflowperf-baseline.json` records the current checkout as a representative large workspace (2,341 tracked files; 1,654 source/test/script files; 42,426,964 bytes) and freezes observed queue, MainActor, execution, durability, and response event contracts. It also preserves the historical observed work-count blob `f2c2693e7956c561dced51fc51fa165676a7efbc`.

This is intentionally not a live latency claim. The task prohibited visible app lifecycle actions, so a live MCP round trip is recorded as blocked-not-run with the exact fallback: use a separately authorized, already-running CE debug app and `make dev-smoke`; never infer that result from XCTest timing.

### Private child endpoint and launch token

Current `MCPBootstrapLeaseSpec` has 14 frozen fields in the manifest. The future private endpoint contract is:

- per-runtime random Unix-domain socket, never the well-known app socket;
- private directory mode `0700`, socket mode `0600`;
- identity fenced by runtime ID, generation, and owner PID;
- listener descriptors never inherited by children;
- endpoint passed explicitly as `REPOPROMPT_MCP_PRIVATE_ENDPOINT` through a host-created launch-scoped environment boundary;
- one expected child/descendant admission, lasting only through terminal settlement;
- identity-fenced idempotent cleanup; admission failure revokes endpoint and token fail closed.

The future `DomainRunLaunchToken` child material is one opaque random capability; it does not expose or select policy. A host-only record binds its digest to runtime generation, child/descendant, context, principal, provider, purpose, and tool policy. The capability is single-use, short-lived, memory-only, never logged/persisted, and revoked on idempotent terminal cleanup. Its explicit child carrier is `REPOPROMPT_MCP_LAUNCH_TOKEN`. Codex, Claude, OpenCode, and Cursor launch paths already have environment/config carriers; M0 adds no launch wiring.

The guard test confirms that neither a production `DomainRunLaunchToken` type nor a headless runtime target exists in M0.

## M0 gate result

All bounded M0 design questions have an observed result or an explicit fail-closed fallback. Live end-to-end EditFlowPerf latency is intentionally not sampled because app lifecycle actions were prohibited, and its later measurement recipe is frozen. Direct child Keychain behavior remains the one empirical unresolved gate because the preserved procedure requires separate approval; until that measurement occurs, direct access is excluded and the parent-owned credential fallback is mandatory. Later milestones must update the parity ledger and migration rows deliberately as families move.
