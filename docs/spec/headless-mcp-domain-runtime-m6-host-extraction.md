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

## Gate 6B exposure rule

No `--backend headless` surface is introduced by Gate 6A. Gate 6B may be exposed only after one shared non-App physical provider composition supplies the complete canonical tool catalog to both app and standalone hosts. A partial catalog, headless-only replacement providers, or a synthetic window authority is not an acceptable preview.
