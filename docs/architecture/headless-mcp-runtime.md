# Headless MCP domain runtime

The RepoPrompt CE MCP executable supports three session backends:

```bash
repoprompt-mcp --backend app
repoprompt-mcp --backend headless
repoprompt-mcp --backend auto
```

`auto` is the default for MCP stdio mode. It performs one bounded connect-only probe of the
well-known app bootstrap socket before reading initialize, then fixes the selected backend for
the lifetime of the process. It never probes private headless child endpoints and never
switches an initialized session. `app` preserves proxy reconnect/replay behavior; `headless`
composes the direct runtime. Interactive and exec modes remain app-backed and reject
`--backend headless`.

## Ownership

`RepoPromptDomainRuntime` owns the protocol-neutral MCP host and canonical 27-tool catalog. It
owns connection generations, invocation admission, policy/resource lanes, progress, watchdogs,
settlement, terminal fencing, response-delivery accounting, and bounded drain. The app's
`ServerNetworkManager`, `ServerController`, and `MCPService` are transport, presentation,
proxy, reconnect, replay, listener, and approval adapters.

App transport lifetime is process-owned from launch through termination. Opening or closing
the last window does not start or stop MCP. Window and active-context information retained by
the app is presentation affinity only; the domain routing coordinator remains authoritative.
Tool dispatch never infers a domain context from the mutable active tab: clients bind a
`context_id`, provide an explicit context hint, or use an exact run-scoped binding.

Canonical schemas are Swift definitions in `MCPDomainCanonicalToolDefinitions`. Both app and
direct registration consume those definitions through `MCPDomainToolRegistry`; there is no
legacy service registry, generated resource manifest, live-window recorder, or mixed catalog
authority. Standalone composition uses a `.standalone` registration scope and never creates a
synthetic window. `bind_context` is global in headless mode and accepts domain `context_id` or
working-directory selectors; window selectors fail closed.

Capability backends are `Foundation`/`Sendable` protocols named for physical operations. The
standalone installer reuses `MCPDomainReadToolProvider` and applies both long-running and
protected-mutation decorators to every canonical binding. There is one final protected-mutation
policy; milestone construction flags are not part of runtime configuration. File edits use the
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

- Backend-selection tests own explicit selection, one-shot auto probing, unavailable-app
  fallback, and the no-protocol-bytes probe contract.
- Domain host tests own admission/drain/generation/watchdog/delivery invariants.
- Canonical catalog tests own all 27 fingerprints and headless `bind_context` semantics.
- Standalone composition tests construct the real runtime without app composition and resolve
  every canonical tool.
- Direct process tests launch the built executable with no app, exercise the advertised policy
  surface, verify denied mutations do not execute, and validate EOF drain.
- Stdio and private-endpoint tests own terminal provenance, bounded broken-pipe behavior,
  half-close response drain, identity fencing, token redemption, replay, expiry, and foreign
  runtime rejection.
- `Scripts/headless_runtime_guardrails.sh` rejects duplicate schema/backend authorities,
  milestone migration switches, retired registry/window-tool compatibility types, and
  MainActor/UI dependencies in the domain runtime.
