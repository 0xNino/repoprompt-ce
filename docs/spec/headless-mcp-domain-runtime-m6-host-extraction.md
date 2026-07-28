# Headless MCP domain runtime M6 — host extraction evidence

Date: 2026-07-28

Branch: `feature/headless-runtime-m6-direct-backend`
Base: finalized local `feature/headless-runtime-m5-ai-agent`

## Gate 6A boundary

Gate 6A introduces `MCPDomainHost` in `RepoPromptDomainRuntime` as the protocol-neutral owner of:

- immutable canonical catalog snapshots;
- exact application/window binding resolution;
- registry-generation and connection-generation fencing immediately before invocation;
- authoritative `DomainToolInvocationSecurityContext` installation;
- active invocation ownership, per-connection cancellation, and bounded runtime drain.

The app remains a transport and presentation shell. `ServerNetworkManager` still owns app/window routing, policy filtering, connection admission lanes, resource leases, watchdog selection, progress, tool-card publication, observer callbacks, result formatting, and transport delivery. It now obtains catalog snapshots and exact resolutions from `MCPDomainHost` and enters providers through `MCPDomainHost.invoke`. Connection removal also cancels host-owned invocations.

`MCPService` receives an injected host-bootstrap operation. The production default performs the existing one-time Codex tool-timeout migration before listener startup; tests and later standalone composition can supply a different bootstrap without duplicating lifecycle ownership.

## Compatibility invariants

Gate 6A does not change:

- the default CLI backend or bootstrap Unix socket;
- `MCPInitializeReplayState`, outstanding-request replay, or the JSON-RPC bridge ledger;
- listener/replacement, approval, retry, terminal, kill, or response-delivery contracts;
- tool schemas, policy visibility, wire envelopes, or app/window routing behavior;
- physical app provider composition.

The host does not infer windows, format MCP results, dispatch a second JSON-RPC loop, or access AppKit/MainActor state.

## Bounded drain contract

Host drain cancels all owned invocations and polls actor-owned settlement state only until the configured deadline. It deliberately does not use a structured task-group race, because exiting such a group waits for an uncooperative child and would make the deadline unbounded. A provider that ignores cancellation remains accounted as detached until its original invocation settles; new invocations fail closed once drain begins.

## Focused evidence

- `make dev-test FILTER=MCPDomainHostTests`
  - conductor ticket `8287f6dc-16d9-46bd-8ece-8e784772ee86`
  - 3 tests passed
- `make dev-swift-build PRODUCT=RepoPrompt`
  - conductor ticket `b222dfda-14b4-4b6b-b17f-2f68dd0450df`
  - passed
- `make dev-test FILTER=ToolCatalogSnapshotTests`
  - conductor ticket `788a78f0-3da2-4380-99bc-04e07446d66c`
  - 21 tests passed
- `make dev-test FILTER=MCPProtectedMutationInvocationIntegrationTests`
  - conductor ticket `6ad2e167-505a-47c7-a7f6-3baa1ef0cbe5`
  - 2 tests passed

- `make dev-test FILTER=PersistentMCPResponseDeliveryTests`
  - conductor ticket `85dce091-850d-4826-8c41-3fbd4ae8ea3c`
  - 24 tests passed, including outstanding replay and bounded delivery drain
- `make dev-test FILTER=MCPProxyTerminalRecordTests`
  - conductor ticket `60199ea8-0d14-4f30-8ddf-57859e629a8b`
  - 7 tests passed
- `make dev-test FILTER=DomainInteractionAppSeamTests`
  - conductor ticket `d7ceb0b1-152d-4f28-bec4-28b01d38e9ac`
  - 6 tests passed
- `make dev-test-list`
  - conductor ticket `66b89d8c-c9a3-48f5-bbfb-37b1929a3947`
  - passed
- `python3 Scripts/test_suite_optimizer.py verify-ledger --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv`
  - passed with 3,681 exact methods
- `make dev-lint`
  - conductor ticket `eed9515d-276d-43f9-bee3-4afe0f8bae36`
  - passed
- `make dev-swift-build PRODUCT=repoprompt-mcp`
  - conductor ticket `ceefa81f-a16f-4946-96f0-67584a4324d9`
  - passed
- `make dev-provider-test`
  - conductor ticket `d06ecb69-2f0f-4b7c-8f9a-b1ba76af0624`
  - passed
- `make guardrails`
  - source layout, contributor allowlist, legal inventory, and pinned Codex guardrails reported success
- `make dev-codex-schema-check`
  - conductor ticket `3abc1d06-8c1e-4e37-aa94-be031daf4e51`
  - environment blocked: installed Codex CLI `0.144.1` is below the repository floor `0.145.0`; no schema comparison ran

## Gate 6A corrective review closure

The review follow-up closes the host lifecycle blocker and shipping-lifecycle highs without changing proxy wire behavior:

- invocation validation may suspend, but the final lifecycle check and active-invocation insertion are now one actor-isolated, suspension-free admission step; `beginDrain` therefore cannot miss a late untracked invocation;
- drain observes caller cancellation explicitly, returns a distinct `callerCancelled` result, and never catches cancellation only to re-enter a hot polling loop;
- the host-created provider task is an explicitly owned operation: it is inserted before the actor yields, indexed by invocation and connection, cancelled by caller/connection/drain, and retained in detached accounting until terminal settlement;
- the shipping `AppDelegate` termination barrier now awaits `MCPDomainRuntime.shutdown()` after agent-session and MCP-server teardown;
- domain-host queue and execution timings flow through `DomainRuntimeMetricsSink` into the `EditFlow.MCPToolCall.DomainHost.QueueWait` and `EditFlow.MCPToolCall.DomainHost.Execution` stages with tool, outcome, and microsecond dimensions.

Corrective focused evidence:

- `make dev-test FILTER=MCPDomainHostTests`
  - conductor ticket `8affc9cf-5c22-48cc-b29d-c23378389ffb`
  - 5 tests passed, including the suspended-admission/drain race and cancelled-drain bounded-return regression
- `make dev-test FILTER=ToolCatalogSnapshotTests`
  - conductor ticket `381db41b-4029-4060-affd-d826ad253aba`
  - 22 tests passed, including the shipping termination shutdown seam
- `make dev-test FILTER=ServerControllerAdmissionTests`
  - conductor ticket `9cebdb0b-675a-464e-885b-b006476902e4`
  - 3 tests passed
- `make dev-test FILTER=MCPAgentPolicyAdmissionRaceTests`
  - conductor ticket `c536780d-7e92-4b11-8474-089ae0cc69d5`
  - 39 tests passed
- `make dev-test FILTER=MCPToolExecutionWatchdogIntegrationTests`
  - conductor ticket `9cfce974-0fa2-428e-a965-ae2e0ddca2c3`
  - 22 tests passed
- `make dev-test FILTER=BootstrapSocketOwnershipTests`
  - conductor ticket `7ed688fb-acaf-4c1a-bacf-e022d1ee1190`
  - 7 tests passed
- `make dev-test FILTER=MCPSocketDescriptorHardeningTests`
  - conductor ticket `2c35144b-ff3e-4948-86ff-5996db32a06b`
  - 30 tests passed, including listener replacement and kill/stop lifecycle fencing
- `make dev-test FILTER=UnixSocketMCPTerminalCleanupTests`
  - conductor ticket `48fa9b3f-8eb7-4df9-8f38-991d0bfa8afb`
  - 13 tests passed
- `make dev-test FILTER=PersistentMCPResponseDeliveryTests`
  - conductor ticket `eb362895-f49b-4916-b048-c620c4779a20`
  - 24 tests passed
- `make dev-test-list`
  - conductor ticket `7d68ad28-828e-4bcd-840f-cc51bf6c4384`
  - passed
- `python3 Scripts/test_suite_optimizer.py verify-ledger --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv`
  - passed with 3,684 exact methods; root/provider list tickets `75a31b9a-c4e6-4eba-b8d1-1441d34db65d` and `7bf553be-656b-4e0a-a4ff-36bc5fea0db3`
- `make dev-swift-build PRODUCT=RepoPrompt`
  - conductor ticket `c23f9540-6487-4034-83c8-f05f3c76777c`
  - passed
- `make dev-swift-build PRODUCT=repoprompt-mcp`
  - conductor ticket `3c82ba54-e85a-4a64-938c-3c80bdfb37b9`
  - passed
- `make dev-provider-test`
  - conductor ticket `3b8f01dc-4cf9-464f-84f6-49fdec227a84`
  - passed
- `make dev-lint`
  - conductor ticket `0b7a4f7d-a035-4762-9eab-42e417fe7ca1`
  - passed
- `make guardrails`
  - passed
- `make dev-codex-schema-check`
  - conductor ticket `3c6a91b0-05b4-4882-ba2f-7c91006d8c37`
  - environment blocked before comparison: installed Codex CLI `0.144.1` is below the required `0.145.0` floor

## Gate 6A protocol-neutral policy and resource admission ownership

The A3 extraction moves canonical `tools/list` filtering, two-stage `tools/call` policy decisions, admission classification, admission-limit constants, and keyed application/window resource admission into `RepoPromptDomainRuntime`:

- `MCPDomainHost.advertisedCatalog` owns disabled, restricted, explicit-grant, and role visibility ordering over one registry snapshot;
- `evaluateEarlyCallPolicy` and `evaluatePreAdmissionCallPolicy` preserve the existing early grant-denial versus later restricted/role/admission-class ordering, while `ServerNetworkManager` maps typed outcomes to the existing byte-identical user errors;
- `MCPDomainToolResourceAdmissionController` is the physical cancellation-safe FIFO lease authority, including repository resource identity for standalone composition;
- the host owns the mutation and small-read controllers; the app keeps only routing-to-resource selection, timing evidence, and the intentional explicit release boundary before formatter/observer tails;
- the app compatibility controller name is now only a typealias used by the existing focused tests.

Evidence:

- `make dev-test FILTER=MCPDomainHostTests` — ticket `f81f5c8f-d964-4c50-b9e9-12d66d05c3e2`, 6 passed
- `make dev-test FILTER=MCPToolAdmissionPolicyTests` — ticket `5a5875b5-de96-4e75-a946-ab201f104fff`, passed
- `make dev-test FILTER=ToolCatalogSnapshotTests` — ticket `1aadf74a-4648-4948-8554-929d60afbd9e`, 22 passed
- `make dev-test FILTER=MCPAgentPolicyAdmissionRaceTests` — ticket `95bf4a7c-349c-4fd1-8703-45cb872e39f1`, 39 passed
- `make dev-test FILTER=MCPToolExecutionWatchdogIntegrationTests` — ticket `f675276f-eff8-4b95-9bc9-2c3d5b930d52`, 22 passed, including resource release timing
- `make dev-test FILTER=PersistentMCPResponseDeliveryTests` — ticket `04f7c112-e618-452e-9aa3-e2292451716b`, 24 passed
- `make dev-test FILTER=MCPProxyTerminalRecordTests` — ticket `1be5980a-9584-40ba-9992-edc36db01488`, 7 passed
- `make dev-swift-build PRODUCT=RepoPrompt` — ticket `94134db9-89f1-42b3-b5d2-c49894abe761`, passed
- `make dev-swift-build PRODUCT=repoprompt-mcp` — ticket `b2d3146e-d3be-4dd5-b26a-0f182348ea09`, passed
- `make dev-lint` — ticket `ad6078a8-bb3c-48ed-ade8-ab6750c0c07f`, passed
- ledger verification — 3,685 exact methods; root/provider list tickets `b83c1f34-6f5f-4f2a-9c6d-cd76436cac73` and `bbdd4de0-e74d-4c45-ab45-1783ffb04057`

## Gate 6B exposure rule

No `--backend headless` surface is introduced by Gate 6A. Gate 6B may be exposed only after one shared non-App physical provider composition supplies the complete canonical tool catalog to both app and standalone hosts. A partial catalog, headless-only replacement providers, or a synthetic window authority is not an acceptable preview.
