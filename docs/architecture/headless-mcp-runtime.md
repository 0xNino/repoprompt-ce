# Headless MCP domain runtime

Milestone 6 adds an explicit preview backend for the RepoPrompt CE MCP executable:

```bash
repoprompt-mcp --backend headless
```

The default remains `--backend app`. Automatic backend selection is intentionally deferred.
Interactive and exec CLI modes remain app-backed and reject `--backend headless`.

## Ownership

`RepoPromptDomainRuntime` owns the protocol-neutral MCP host and the canonical 27-tool catalog.
It owns connection generations, invocation admission, policy/resource lanes, progress,
watchdogs, settlement, terminal fencing, response-delivery accounting, and bounded drain. The
app's `ServerNetworkManager`, `ServerController`, and `MCPService` remain transport,
presentation, proxy, reconnect, replay, listener, and approval shells.

Canonical schemas are Swift definitions in `MCPDomainCanonicalToolDefinitions`. Both app and
direct registration consume those definitions; there is no generated resource manifest or
live-window recorder. Standalone composition uses a `.standalone` registration scope and never
creates a synthetic window. `bind_context` is global in headless mode and accepts domain
`context_id` or working-directory selectors; window selectors fail closed.

Capability backends are `Foundation`/`Sendable` protocols named for physical operations. The
standalone installer reuses `MCPDomainReadToolProvider` for migrated reads and applies both the
long-running and protected-mutation decorators to every canonical binding. File edits use the
shared production apply-edits engine, including operation-ID correlation, revision validation,
path fencing, approval, and retry classification. Runtime state, mutation policy/journal,
workspace documents, Agent sessions, and worktree bindings use the isolated profile's
`DomainPersistenceCoordinator` storage.

## Direct transport and child calls

Direct mode installs one MCP SDK `Server` over `MCPStdioServerTransport`; it does not add a
second JSON-RPC dispatcher. The transport records one accepted-request/delivered-response hop
and distinguishes stdin EOF, truncated EOF, read/poll failure, PPID replacement, broken pipe,
write failure, and cancellation. Terminal paths enter bounded host drain before runtime
shutdown.

Long-running Agent and Context Builder providers receive an explicit run-scoped carrier. The
carrier contains a private Unix endpoint, single-use launch token, verified principal/provider
identity, and run ID. The endpoint directory is owner-only, the socket is identity-fenced, and
token redemption checks runtime generation, peer PID, expiry, scope, and replay before
registering a child connection. Nested MCP calls therefore return to the owning direct runtime
rather than proxying through the app.

## Profiles and security defaults

`REPOPROMPT_MCP_HEADLESS_PROFILE` selects a sanitized profile. The default storage root is:

```text
~/Library/Application Support/RepoPrompt CE/Headless/<profile>/
```

`REPOPROMPT_MCP_HEADLESS_PROFILE_DIR` is available for isolated tests and automation.
Protected mutations default to deny until the profile policy authorizes the verified principal;
long-running provider costs remain decorated and auditable. Direct mode has no AppKit, SwiftUI,
window, view-model, live-app, or UI-presentation dependency.

## Validation owners

- Domain host tests own admission/drain/generation/watchdog/delivery invariants.
- Canonical catalog tests own all 27 fingerprints and headless `bind_context` semantics.
- Standalone composition tests construct the real runtime without app composition and resolve
  every canonical tool.
- Direct process tests launch the built executable with no app, exercise the advertised policy
  surface, verify denied mutations do not execute, and validate EOF drain.
- Stdio and private-endpoint tests own terminal provenance, bounded broken-pipe behavior,
  half-close response drain, identity fencing, token redemption, replay, expiry, and foreign
  runtime rejection.
- `Scripts/headless_runtime_guardrails.sh` rejects duplicate schema/backend authorities and app
  dependencies in the domain runtime.
