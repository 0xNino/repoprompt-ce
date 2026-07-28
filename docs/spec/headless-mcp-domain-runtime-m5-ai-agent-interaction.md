# Headless MCP domain runtime — M5 AI, Agent, Context Builder, and interaction

Milestone 5 is PR 6/8, stacked on finalized M4B (`feature/headless-runtime-m4-protected-mutations`). It moves long-running AI/Agent lifecycle authority into `RepoPromptDomainRuntime` while retaining the existing app providers as injected physical and presentation adapters. It does not add a direct stdio host or a real private child listener.

The machine-readable gate is frozen in `Scripts/Fixtures/headless_mcp_domain_runtime_m5_contract.json`.

## Authority and compatibility ledger

| Concern | M5 authority | Compatibility boundary |
|---|---|---|
| Agent sessions | `DomainAgentRunSessionStore` and neutral `DomainAgentRun*` DTOs | `AgentRunSessionStore` and `AgentRunMCPSnapshot` are app compatibility adapters; view models project/provider-drive state but do not own session lifecycle |
| Oracle, Context Builder, Agent, and session-control invocation | `MCPDomainLongRunningToolProvider` wraps the canonical binding once | existing physical app providers retain public schemas, result envelopes, transcript/history behavior, and process implementation |
| interaction | `DomainInteractionBroker` | negotiated elicitation is preferred, app UI is a presentation adapter, and absent providers return immediately unavailable |
| child launch handoff | `DomainPrivateChildLaunchHarness`, `DomainChildLaunchCarrier`, and the M2 `DomainRunLaunchToken` issuer | the injected harness proves the carrier and single-use token seam; the real listener/endpoint is M6B |
| credentials | `DomainCredentialEnvelopeStore` | M0 packaged-child Keychain evidence remains unresolved, so only parent-owned minimum-scope, memory-only, single-use envelopes are permitted |
| cost/process approval | M4 `DomainMutationPolicyStore` with `ai_cost` and `external_process` actions | verified app proxy remains compatible; headless/run-scoped calls require an explicit grant and revalidate before backend entry |
| observability | `DomainActivityCenter` | app UI may project snapshots; activity sequence and terminal settlement are runtime-owned |
| registration | `ServiceRegistry` composes long-running then protected wrappers | no second registration or schema implementation is introduced |

## Session lifecycle and recovery

Registrations carry runtime ID, runtime lifecycle generation, session ID, and registration generation. Turn epochs additionally carry activation ID, monotonic ordinal, continuity generation, and transition kind. Terminal publication requires an exact epoch plus commit ID: the same commit is idempotent, a different commit fails closed, and a stale epoch cannot replace the current epoch.

Parked waits own cancellable continuations and bounded timeout tasks. Replacement, TTL expiry, cleanup, caller cancellation, and runtime shutdown settle each exact waiter. Shutdown requests provider cancellation without structurally awaiting an uncooperative handler past the deadline; unfinished sessions persist as interrupted metadata.

Durable data is resumability metadata, never a claim that a process is alive. Bootstrap maps every nonterminal prior-runtime record to dormant. An explicit resume claim creates a new registration fenced to the current runtime and continues only the durable ordinal/continuity counters. Transient executions are never reconstructed.

## Interaction settlement

The broker selects one provider in this order:

1. negotiated MCP elicitation when installed and available;
2. app UI when the physical adapter reports availability;
3. immediate unavailable.

Each request has an internal generation. Response, timeout, caller cancellation, provider failure, and runtime shutdown race through one settlement path. The winning path removes the pending record, cancels timeout/provider work as applicable, dismisses presentation when needed, and resumes the continuation once. Later provider responses are ignored and counted.

## Child launch and credential fallback

`DomainPrivateChildLaunchHarness` accepts an injected endpoint descriptor and launch-token issuer. It emits only the frozen environment carrier:

- `REPOPROMPT_MCP_PRIVATE_ENDPOINT`
- `REPOPROMPT_MCP_LAUNCH_TOKEN`
- `REPOPROMPT_MCP_CREDENTIAL_ENVELOPE` when a credential is required

The credential environment value is an opaque envelope identifier, not a secret. Secret bytes stay in a parent-owned actor, are bound to runtime generation plus provider/run/principal/purpose scope, expire, redeem once, are never encoded to disk, render only a redacted description, and are zeroed on consume, revoke, expiry, or shutdown. This is the mandatory fallback prescribed by M0 until packaged child Keychain access is empirically proven.

No listener is opened and no child is connected in M5. The real identity-fenced private endpoint and direct child redemption protocol remain M6B.

## Long-running invocation and activity

The shared provider covers:

`oracle_utils`, `ask_oracle`, `oracle_send`, `context_builder`, `ask_user`, `agent_explore`, `agent_run`, `agent_manage`, `share_thoughts`, `set_status`, and `wait_for_next_user_instruction`.

AI sends and Agent operations that may invoke a model or process require explicit `ai_cost` and/or `external_process` authorization. The immutable authorization snapshot is revalidated immediately before physical execution. The provider installs any injected child carrier in a task-local value only for that backend call.

Every migrated call publishes a runtime activity. Publication sequence is monotonic. Active states cannot overwrite terminal state; terminal commit is exactly once; shutdown converts remaining active activities to cancelled. `DomainRuntimeSnapshot` reports the activity high-water sequence and active/recent-terminal counts.

## Gate evidence

The focused evidence belongs to:

- `DomainAgentRunSessionStoreTests`
- `DomainInteractionBrokerTests`
- `DomainCredentialAndChildLaunchTests`
- `DomainActivityAndLongRunningProviderTests`
- existing `AgentRunSessionStoreRegistrationTests` and `AgentModeMCPWaitEpochTests`
- existing Agent run/manage/wait suites
- existing Oracle, Context Builder, ask-user, and catalog parity suites
- both product builds, provider-package tests, lint, authoritative test list/ledger, and source-layout guardrails

## Explicit exclusions

M5 does not extract the MCP host, add direct stdio, open a private child listener, change proxy routing, change the frozen 27-tool catalog, automatically select a backend, delete app adapters, or perform M7 cleanup.
