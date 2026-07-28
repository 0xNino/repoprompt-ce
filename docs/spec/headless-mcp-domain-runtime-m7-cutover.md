# Headless MCP domain runtime M7 — automatic cutover evidence

Date: 2026-07-28

Branch: `feature/headless-runtime-m7-cutover`
Base: finalized M6 head `d3677c3e82d171affe08d35587e0bd9bd4561b0f`

## Final backend contract

`repoprompt-mcp` accepts `--backend app|headless|auto`; MCP stdio defaults to
`auto`. Selection is made exactly once before the first `initialize` read:

- explicit `app` and `headless` never probe;
- `auto` performs one bounded, connect-only probe of the well-known app socket;
- an available app selects the existing proxy/reconnect path;
- an unavailable app selects the M6 direct runtime;
- no initialized process retries or switches backend;
- interactive and exec modes remain app-backed.

The probe verifies a Unix socket node, connects with a 150 ms bound, transmits
no protocol bytes, closes its descriptor, and never examines the private M6
child endpoint.

## Strangler cleanup

- Removed `ServiceRegistry`; app registration is an operation on the
  process-owned `AppDomainRuntimeComposition`.
- Retired the `MCPWindowToolRuntime`, context, dependency, catalog, and group
  compatibility type/files. The retained app-only capabilities are named
  `MCPAppPhysicalCapabilityAdapters`; they are explicit presentation/filesystem
  adapters rather than a generic runtime dependency bag.
- Replaced the mixed app-tool/shared-binding catalog merge with one ordered
  domain-binding projection. App adapters first produce
  `MCPDomainToolBinding`, then the canonical projection is materialized through
  `MCPAppToolBinder`; duplicate names and non-canonical names fail closed.
- Removed protected-mutation milestone staging and the migrated-tool-name
  branching.
- Removed implicit active-tab context resolution and its diagnostics/switches.
  Tool execution now requires an explicit, restored, or exact run-scoped
  binding; app context state is presentation projection only.
- Removed window-participant ownership from `MCPService`. App launch starts the
  process transport, window join/leave only attach presentation, and explicit
  process shutdown owns teardown.
- Removed the six participant-token lifecycle tests and their 15 obsolete
  scenarios. One three-scenario owner test now covers initial process start,
  detach/reattach without transport mutation, and explicit shutdown.
- Extended `headless_runtime_guardrails.sh` to reject retired facades, routing
  fallback switches, migration staging, duplicate headless authorities, UI
  imports, and domain-owned `MainActor`.

## Focused evidence

- Backend selection: conductor ticket
  `c6fd56d3-64b6-438f-9947-c06b7cfe29ba`.
- App catalog parity and canonical projection: ticket
  `7e128736-db52-43f6-9ff6-5c9c49bc9a3a`, 19 tests passed.
- Final tab routing: ticket `d056b382-273a-49fc-84d4-930869f7f1e3`,
  55 tests passed.
- Protected-mutation final policy: ticket
  `4872973d-479f-4de4-97a0-a169fa13c5c5`, passed.
- Selection freshness after fallback retirement: ticket
  `65f1d12c-8275-40a5-a8b7-c047e16f9e73`, 20 tests passed.
- Process-owned catalog/lifecycle: ticket
  `a1422392-0f2e-46a4-b53e-e2093174ecaf`.
- Direct no-app and private-child regression: ticket
  `d1ab19e3-88b2-4498-b806-0d6b8d86ffb7`.
- M0 ownership/duplicate-schema contract: ticket
  `af4141c3-3c67-49c0-ad55-009444b5ed8d`, passed.
- Complete domain-runtime owner suite: ticket
  `dbcc872e-e6c1-4809-8888-fb12ae69fa06`, 102 tests passed.
- Ask-user cancellation synchronization regression: ticket
  `0714d4a9-99ea-463f-834e-6eafd9d738c8`, passed with bounded async
  presentation/cancellation signals rather than scheduler polling.
- Persistent explicit-context connection regression: ticket
  `72c0a678-22c8-403d-b565-fbbfda32a00c`, 21 tests passed.
- Dispatch/catalog diagnostic lifecycle contract: ticket
  `37c94612-cd76-482a-b15a-d50f3ba2d873`, 23 tests passed.
- Worktree explicit-context coverage:
  - selection: `bed88890-848d-4534-ab0c-d50b7b9ca845`;
  - stale-prunable binding: `0e86571b-887a-4045-897f-5dc17c91dbae`;
  - merge: `f6d85d4e-090b-40a5-b6c2-f53918d214c5`.
- Final product compilation:
  - RepoPrompt: `a01104a0-6364-4781-85bb-edcec104b9ee`, passed.
  - repoprompt-mcp: `7a38ce15-ba78-4097-ab80-6ac09d4b7548`, passed.
- Provider package suite: `d197e11a-cc9b-45cd-8c7e-da69e40f84d4`,
  passed.
- Final formatter/lint:
  - format: `77bd54ba-87a4-4424-919c-74955bc26c16`, no changes;
  - lint: `22a4af9c-ad2e-4945-a07d-ebc9997231ca`, passed.
- `Scripts/headless_runtime_guardrails.sh` passed after the final catalog rename.

## Test-ledger reconciliation

The curated ledger preserves metadata for final-policy renames, removes the
active-tab fallback and window-participant scenarios because those production
authorities no longer exist, and adds the four backend-selection tests plus the
process-lifetime replacement. The removed window-participant methods are:

- `testMCPServiceConcurrentColdJoinsAreSingleFlight`
- `testMCPServiceSupersededJoinCannotRemoveSameWindowRejoin`
- `testMCPServiceCancelledJoinRemovesOnlyItsSharedStartClaim`
- `testMCPServiceOverlappingShutdownsFormOneCompleteRestartBarrier`
- `testMCPServiceFailedStartRollsBackParticipantsAndRetryStarts`
- `testMCPServiceFullShutdownRestartFailureLeavesNoPhantomParticipants`

The two active-presentation token tests and the active-tab fallback decision
test are intentionally retired; bound-context freshness and token-accounting
coverage remains.

The final curated-ledger reconciliation passed with 3,755 exact IDs. Its
authoritative list tickets are:

- root: `956bc2d8-1b1d-4f3f-a0b4-2ba728975430`;
- provider: `866d6f72-3605-41ad-808b-956510a58820`.

## Remaining validation gates

- `make dev-codex-schema-check` is locally blocked because installed Codex
  `0.144.1` is below the repository's `0.145.0` schema floor (ticket
  `9d12abdf-40ee-4381-8bf8-f19f6da47326`).
- The root suite was attempted. M7-specific catalog, explicit-context,
  diagnostics, and persistent-connection failures found by that run were
  repaired and their owning suites pass above. A clean full rerun remains
  blocked in this checkout by the already-running visible app owning the
  bootstrap socket, plus an unrelated pre-existing
  `CodexNativeSessionControllerGoalConfigTests` goals-default mismatch. The
  task intentionally does not stop or relaunch that app.
- The complete worktree smoke class similarly reaches its live bootstrap test
  and cannot acquire the app-owned socket. Its non-live M7 owners pass via the
  three focused tickets above; Context Builder export completed before the
  blocked live method.

## Release-validation boundary

Packaging/release validation owns four independent live probes: explicit app,
explicit headless, `auto` with the app available, and `auto` without the app.
This implementation task does not launch, relaunch, stop, or replace the
visible app; orchestrated live evidence remains a release/design-review gate.
