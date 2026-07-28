#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

runtime_sources="Sources/RepoPromptDomainRuntime"
direct_sources="Sources/RepoPromptMCP"

if grep -R -n -E '^[[:space:]]*import[[:space:]]+(AppKit|SwiftUI)([[:space:]]|$)' "$runtime_sources"; then
  echo "error: RepoPromptDomainRuntime must remain independent of AppKit and SwiftUI" >&2
  exit 1
fi

for forbidden in \
  MCPFoundationStandaloneBackend \
  MCPDomainCanonicalToolManifest \
  RECORD_MCP_WINDOW_TOOL_CATALOG \
  MCPServerViewModel; do
  if grep -R -n --include='*.swift' --include='*.json' "$forbidden" "$runtime_sources" "$direct_sources"; then
    echo "error: forbidden duplicate or app-owned headless authority: $forbidden" >&2
    exit 1
  fi
done

canonical_file="$runtime_sources/MCPDomainCanonicalToolDefinitions.swift"
if [[ ! -f "$canonical_file" ]]; then
  echo "error: missing canonical Swift tool definitions" >&2
  exit 1
fi

if find "$runtime_sources" "$direct_sources" -type f \( -iname '*tool*manifest*.json' -o -iname '*schema*manifest*.json' \) -print -quit | grep -q .; then
  echo "error: headless canonical schemas must not be copied into a resource manifest" >&2
  exit 1
fi

if ! grep -q 'MCPStdioServerTransport' "$direct_sources/DirectHeadlessMCPService.swift"; then
  echo "error: headless backend must use its terminal-aware bounded stdio transport" >&2
  exit 1
fi

if grep -E -q '(^|[^[:alnum:]_])StdioTransport\(' "$direct_sources/DirectHeadlessMCPService.swift"; then
  echo "error: headless backend must not install the SDK stdio dispatcher" >&2
  exit 1
fi

if ! grep -q 'MCPDomainReadToolProvider' "$runtime_sources/MCPDomainStandaloneCapabilityProvider.swift"; then
  echo "error: standalone composition must reuse the canonical migrated read provider" >&2
  exit 1
fi

if ! grep -q 'protectedMutationProvider.protectedBinding' "$runtime_sources/MCPDomainStandaloneCapabilityProvider.swift" \
  || ! grep -q 'longRunningToolProvider.wrapping' "$runtime_sources/MCPDomainStandaloneCapabilityProvider.swift"; then
  echo "error: standalone bindings must install both security decorators" >&2
  exit 1
fi

echo "Headless runtime guardrails passed."
