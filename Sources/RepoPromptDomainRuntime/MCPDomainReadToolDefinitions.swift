import Foundation
import MCP

package enum MCPDomainReadToolDefinitions {
    package static let migratedToolNames: [String] = [
        "get_code_structure",
        "get_file_tree",
        "read_file",
        "file_search",
        "workspace_context",
        "prompt",
        "oracle_chat_log",
        "git",
        "history"
    ]

    package static let definitions: [MCPDomainToolDefinition] = [
        codeStructure,
        fileTree,
        readFile,
        fileSearch,
        workspaceContext,
        prompt,
        oracleChatLog,
        git,
        history
    ]

    package static func definition(named name: String) -> MCPDomainToolDefinition? {
        definitions.first { $0.name == name }
    }

    private static let readOnly = MCPDomainToolAnnotations(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )
    private static let ephemeral = MCPDomainToolAnnotations(
        readOnlyHint: false,
        destructiveHint: false,
        openWorldHint: false
    )

    private static let codeStructure = MCPDomainToolDefinition(
        name: "get_code_structure",
        description: """
        Return root-local committed code structure for explicit paths or the current selection.

        - `paths`: Optional file/directory seeds; omit to use the authoritative current selection.
        - `expand`: Optional `uses`, `used_by`, or `both`; omit for seeds only.
        - `depth`: Relationship depth 1...4 (default 1; meaningful only with `expand`).
        - `signatures`: Include codemap signature text (default true). False performs no artifact demands.
        - `size`: Output size `small`, `medium` (default), or `large`.

        Inspect per-root results in mixed workspaces. `updates_pending` graph data is usable.
        When `truncated` is present, rerun the same call with the next larger `size`.
        Seeds render before related files, so small outputs preserve the graph and degrade signature text gracefully.

        Examples:
        - Signatures for a folder: {"paths":["Sources/Auth/"]}
        - Who uses a file with large output: {"paths":["Sources/Auth/SessionStore.swift"],"expand":"used_by","size":"large"}
        - Cheap graph-only sweep: {"expand":"both","depth":2,"signatures":false,"size":"small"}
        """,
        inputSchema: object([
            "paths": array("Optional one to 256 file or directory paths; omit for current selection", items: string("File or directory path")),
            "expand": string("Relationships from each seed's perspective", enum: ["uses", "used_by", "both"]),
            "depth": integer("Relationship depth 1...4 (default 1)"),
            "signatures": boolean("Include codemap signature text (default true)"),
            "size": string("Output size (default medium)", enum: ["small", "medium", "large"])
        ], additionalProperties: false),
        annotations: readOnly
    )

    private static let fileTree = MCPDomainToolDefinition(
        name: "get_file_tree",
        description: """
        Generate ASCII directory tree of the project.

        **Types**:
        - `files` (default): Directory tree with files
        - `roots`: List loaded root folders only

        **Modes** (for type="files"):
        - `auto` (default): Full tree, auto-trims depth if too large (~10k token target)
        - `full`: Complete tree (can be very large)
        - `folders`: Directories only, no files
        - `selected`: Only selected files and their parent directories

        **Options**:
        - `path`: Start from specific folder (modes/max_depth apply from there)
        - `max_depth`: Limit depth (root=0, immediate children=1, etc.)

        **Markers**: `*` = selected file, `+` = has codemap

        **Worktree scope**: When an agent session is bound to a Git worktree, displayed paths may remain logical/canonical while filesystem reads use the bound worktree. Responses include `worktree_scope` when this remapping is active.

        **Examples**:
        - Auto tree: `{}`
        - Folders only: `{"mode":"folders"}`
        - Subtree: `{"path":"src/components","max_depth":2}`
        - Selected files: `{"mode":"selected"}`
        """,
        inputSchema: object([
            "type": string("Tree type to generate (default: 'files')", enum: ["files", "roots"]),
            "mode": string("Filter mode (for 'files' type only, default: 'auto')", enum: ["auto", "full", "folders", "selected"]),
            "max_depth": integer("Maximum depth (root = 0)"),
            "path": string("Optional starting folder (absolute or relative) when type='files'. When provided, the tree is generated from this folder and 'mode' and 'max_depth' apply from that subtree.")
        ]),
        annotations: readOnly
    )

    private static let readFile = MCPDomainToolDefinition(
        name: "read_file",
        description: """
        Read file contents with optional line range.

        **Parameters**:
        - `path`: File path (required)
        - `start_line`: 1-based line number, or negative for tail behavior
        - `limit`: Number of lines (only with positive start_line)

        **Behaviors**:
        - No params: Entire file
        - `start_line=10`: From line 10 to end
        - `start_line=10, limit=20`: Lines 10-29
        - `start_line=-10`: Last 10 lines (like `tail -10`)

        **Worktree scope**: When an agent session is bound to a Git worktree, displayed paths may remain logical/canonical while filesystem reads use the bound worktree. Responses include `worktree_scope` when this remapping is active.

        **Examples**:
        - Full file: `{"path":"src/main.swift"}`
        - Lines 50-100: `{"path":"file.swift","start_line":50,"limit":51}`
        - Last 20 lines: `{"path":"file.swift","start_line":-20}`
        """,
        inputSchema: object([
            "path": string("File path"),
            "start_line": integer("Line to start from (1-based) or negative for tail behavior (-N reads last N lines)"),
            "limit": integer("Number of lines to read")
        ], required: ["path"]),
        annotations: readOnly
    )

    private static let fileSearch = MCPDomainToolDefinition(
        name: "file_search",
        description: """
        Search files by path pattern and/or content.

        **Modes**:
        - `auto` (default): Detects path vs content search from pattern
        - `path`: Match file paths only (glob-style with regex=false, full regex otherwise)
        - `content`: Search inside file contents
        - `both`: Search paths and contents

        **Matching** (regex auto-detected by default):
        - Regex mode: Full regex support (groups, lookarounds, anchors)
        - Literal mode (regex=false): Special chars matched literally, `*`/`?` wildcards for paths
        - Tip: Set `regex=false` to force literal substring matching

        **Key options**:
        - `pattern`: Search term (required)
        - `max_results`: Result limit (default: 50)
        - `context_lines`: Lines before/after matches (alias: `-C`)
        - `whole_word`: Match whole words only
        - `count_only`: Return counts only, no content
        - `filter.extensions`: Limit to extensions (e.g., [".swift"])
        - `filter.paths`: Limit to paths/folders (can also be a loaded root name like 'RepoPrompt')
        - `filter.exclude`: Skip matching patterns

        **Worktree scope**: When an agent session is bound to a Git worktree, displayed paths may remain logical/canonical while filesystem searches use the bound worktree. Responses include `worktree_scope` when this remapping is active.

        **Examples**:
        - Literal: `{"pattern":"frame(minWidth:","regex":false}`
        - Regex OR: `{"pattern":"performSearch|searchUsers"}`
        - Find files: `{"pattern":"*.swift","mode":"path","regex":false}`
        - With context: `{"pattern":"TODO","context_lines":2}`
        - Scoped: `{"pattern":"auth","filter":{"paths":["src/auth/"]}}`

        Response capped at ~50k chars; excess results omitted (count reported).
        """,
        inputSchema: object([
            "pattern": string("Search pattern"),
            "mode": string("Search scope: auto-detects if not specified", enum: ["auto", "path", "content", "both"]),
            "regex": boolean("Use regex matching (default: auto based on pattern)"),
            "filter": objectProperty("File filtering options (alias: use 'path' string parameter for single-file search)", properties: [
                "extensions": array("Only search files with these extensions", items: string("File extension like '.js' or '.swift'")),
                "exclude": array("Skip files/paths matching these patterns", items: string("Pattern like 'node_modules' or '*.log'")),
                "paths": array("Limit search to specific file or folder paths, or a loaded root name", items: string("Absolute path, relative path, or loaded root name (e.g., 'RepoPrompt')"))
            ]),
            "path": string("Alias for filter.paths with a single file or folder path"),
            "max_results": integer("Maximum total results (default: 50)"),
            "count_only": boolean("Return only match count"),
            "context_lines": integer("Lines of context before/after matches (alias: -C)"),
            "whole_word": boolean("Match whole words only")
        ], required: ["pattern"]),
        annotations: readOnly
    )

    private static let workspaceContext = MCPDomainToolDefinition(
        name: "workspace_context",
        description: """
        Canonical workspace context render/export tool.

        Default behavior returns a snapshot of prompt, selection, code structure, and tokens.
        Use `op` for render/export helpers, or omit it for the default snapshot.

        **Default includes**: `["prompt","selection","code","tokens"]`

        **Available includes**:
        - `prompt`: Current prompt text
        - `selection`: Selected files summary
        - `code`: Code structure (codemaps) for selection
        - `files`: Full file contents
        - `tree`: File tree of selected files
        - `tokens`: Token breakdown by component

        **Operations**:
        - `snapshot` (default) — build/render the current workspace context snapshot
        - `export` — write the rendered export to disk
        - `list_presets` — list copy presets
        - `select_preset` — select the active copy preset for the bound tab

        **Options**:
        - `include`: Array of sections to include for snapshot rendering
        - `path_display`: "relative" | "full"
        - `copy_preset`: Override copy preset for token calculation / export rendering

        **Worktree scope**: When an agent session is bound to a Git worktree, displayed paths may remain logical/canonical while filesystem reads/searches use the bound worktree. Responses include `worktree_scope` when this remapping is active.

        **Examples**:
        - Default snapshot: `{}`
        - With file contents: `{"include":["prompt","selection","files"]}`
        - Export: `{"op":"export","path":"context.txt"}`
        - Preset override: `{"copy_preset":"Plan"}`

        Related: manage_selection, get_file_tree, ask_oracle
        """,
        inputSchema: object([
            "op": string("Operation (default: 'snapshot')", enum: ["snapshot", "export", "list_presets", "select_preset"]),
            "include": array("What to include (defaults to prompt, selection, code, tokens)", items: string(nil, enum: ["prompt", "selection", "code", "files", "tree", "tokens"])),
            "path_display": string("Path display for blocks", enum: ["full", "relative"]),
            "path": string("File path for export operation"),
            "preset": string("Preset UUID, kind, or name"),
            "copy_preset": string("Preset UUID, kind, or name")
        ]),
        annotations: readOnly
    )

    private static let prompt = MCPDomainToolDefinition(
        name: "prompt",
        description: """
        Get or modify the shared prompt (instructions/notes).

        **Operations**: get | set | append | clear | export | list_presets | select_preset

        **Parameters by op**:
        - `set`/`append`: `text` (required)
        - `export`: `path` (required), `copy_preset` (optional override)
        - `select_preset`: `preset` (required) - UUID, kind, or name

        **Notes**:
        - `select_preset` requires an explicitly bound tab context (not available during discovery runs)
        - `export` writes clipboard content to file so it can be copy/pasted into ChatGPT (or another AI) for a second opinion; use `copy_preset` to override format
        - `list_presets` returns all available copy presets with configurations

        **Examples**:
        - Get: `{"op":"get"}`
        - Set: `{"op":"set","text":"Focus on error handling"}`
        - Export: `{"op":"export","path":"context.txt"}`
        - List presets: `{"op":"list_presets"}`
        - Select preset: `{"op":"select_preset","preset":"Plan"}`

        Related: workspace_context, manage_selection, ask_oracle
        """,
        inputSchema: object([
            "op": string("Operation (default: 'get')", enum: ["get", "set", "append", "clear", "export", "list_presets", "select_preset"]),
            "text": string("Text for set/append"),
            "path": string("File path (required for export)"),
            "preset": string("Preset UUID, kind, or name"),
            "copy_preset": string("Preset UUID, kind, or name")
        ]),
        annotations: ephemeral
    )

    private static let oracleChatLog = MCPDomainToolDefinition(
        name: "oracle_chat_log",
        description: """
        Read recent Oracle conversation messages to recover context during agent mode.

        Returns the tail of an Oracle chat as lightweight `{ role, text }` objects. Available only during agent mode runs.

        **Parameters**:
        - `chat_id` (optional): Target a specific Oracle chat (short ID or UUID). Omit to read the most recent one.
        - `limit` (optional): Number of messages to return (default: 8, range: 1–50)
        - `include_user` (optional): Include your own messages in output (default: false)
        """,
        inputSchema: object([
            "chat_id": string("Chat ID (short ID or UUID) to read"),
            "limit": integer("Max number of messages to return (default: 8, min: 1, max: 50)"),
            "include_user": boolean("Include user messages in output (default: false)")
        ]),
        annotations: readOnly
    )

    private static let git = MCPDomainToolDefinition(
        name: "git",
        description: """
        Safe, read-only git operations.

        **Operations**: status | diff | log | show | blame

        **Compare specs** (for diff/show):
        | Spec | Meaning |
        |------|--------|
        | `uncommitted` | Working dir vs HEAD (default) |
        | `staged` | Staged changes vs HEAD |
        | `unstaged` | Working dir vs staged |
        | `back:N` | HEAD~N..HEAD |
        | `mergebase:X` | Working dir vs merge-base with X |
        | `main` | Working dir vs merge-base with trunk branch (auto-detected) |
        | `uncommitted:main` | Uncommitted vs merge-base with trunk branch |
        | `staged:main` | Staged vs merge-base with trunk branch |
        | `trunk` | Alias for `main` |
        | `last` | vs CURRENT snapshot |
        | `<snapshot_id>` | vs specific snapshot |
        | `<revspec>` | Any git revspec |

        **Detail levels** (for diff/show):
        - `summary` (default): Totals only
        - `files`: File list with stats
        - `patches`: Patch hunks, truncated for safety (~300 lines)
        - `full`: Patch hunks, untruncated (may be large)

        **Publishing artifacts** (`artifacts=true`):
        Writes snapshot files to disk for persistent reference. **Required for ask_oracle review mode** to include git diff context.
        - Creates MAP.txt, files.tsv, and optional patches
        - Primary review artifacts are auto-selected into context when possible
        - `mode`: "quick" | "standard" | "deep" (default: "standard")
        - `scope`: "all" | "selected" — filter to selected files only

        **Repo targeting**:
        - Generic calls default to the first loaded root's repo; nested Agent Context Builder runs default to their frozen selected repository target
        - `repo_root`: Target specific repo (path or name)
        - `repo_roots`: Array for multi-repo operations (status, diff)
        - Tree specifiers: append `@wt` (explicit worktree), `@main` (main checkout), or `@main:<branch>` to target a worktree by branch (local branch name)

        **Safety**: --no-ext-diff, --no-textconv, --color=never, GIT_TERMINAL_PROMPT=0

        **Examples**:
        - Status: `{"op":"status"}`
        - Main checkout status: `{"op":"status","repo_root":"@main"}`
        - Worktree by branch: `{"op":"status","repo_root":"@main:main"}`
        - Diff vs trunk: `{"op":"diff","compare":"main"}`
        - Quick diff: `{"op":"diff","detail":"files"}`
        - Inline patches: `{"op":"diff","detail":"patches"}`
        - Full untruncated diff: `{"op":"diff","detail":"full"}`
        - Publish for review: `{"op":"diff","artifacts":true,"scope":"selected"}`
        - Recent commits: `{"op":"log","count":5}`

        Note: log/show/blame run on primary repo only with multi-root.
        """,
        inputSchema: object([
            "op": string("Operation", enum: ["status", "diff", "log", "show", "blame"]),
            "repo_root": string("Repository root path inside a loaded root, or loaded root name. Generic calls default to the first loaded root; nested Agent Context Builder runs use the frozen selected repository target. Supports @wt, @main, or @main:<branch> to target a worktree by branch (local branch name)."),
            "repo_roots": array("Multiple repository root paths inside loaded roots, or root names (for multi-root operations). Supports @wt, @main, or @main:<branch> suffixes.", items: string()),
            "repo_key": string("Repository key (optional alternative to repo_root)"),
            "compare": string("Compare spec for diff/show (supports main/trunk aliases)"),
            "detail": string("Detail level for diff/show", enum: ["summary", "files", "patches", "full"]),
            "mode": string("Artifact mode for diff", enum: ["quick", "standard", "deep"]),
            "scope": string("Diff scope", enum: ["all", "selected"]),
            "path": string("Single pathspec"),
            "paths": array("Multiple pathspecs", items: string()),
            "context_lines": integer("Diff context lines"),
            "detect_renames": boolean("Enable rename detection"),
            "artifacts": boolean("Write snapshot artifacts (diff only); primary review artifacts are auto-selected into context when possible"),
            "inline": objectProperty(nil, properties: [
                "map": boolean("Include MAP excerpt"),
                "mode": string("Inline mode", enum: ["brief", "full"]),
                "max_lines": integer("Max MAP lines")
            ], required: []),
            "ref": string("Ref for show operation"),
            "count": integer("Number of commits for log"),
            "lines": string("Line range for blame (e.g., \"45-60\")")
        ], required: ["op"]),
        annotations: readOnly
    )

    private static let history = MCPDomainToolDefinition(
        name: "history",
        description: """
        Query past Agent Mode session transcripts across all workspaces. All operations are read-only.

        **Operations**: list_sessions | search | time | get_session

        - `list_sessions`: Session inventory with content-aware filters (workspace, agent kind, model, files touched, date range). Returns session metadata including duration, turn count, and files touched.
        - `search`: Full-text search across session transcripts and summaries. Matches against both live activity text and compacted turn summaries. Returns snippets with ~200 chars of context around each match.
        - `get_session`: Read a bounded, noise-reduced window around a known session turn. Use `search` first, then call `get_session` with `session_id`, `around_turn`, `context_turns: 0`, and a modest `max_chars` for a single search hit; whole-session dumps are intentionally unsupported.
        - `time`: Aggregate time-in-session analytics. Groups by day, week, month, session, or workspace. Active duration uses the settings-backed default idle threshold (currently 10 minutes) unless `idle_threshold_minutes` is provided.

        **Scope**: Window routing does not imply workspace scope; history scans all saved workspaces by default. Use `workspace` to filter by saved name, UUID, or `Workspace-*` storage directory. Stale indexes are skipped and reported in `skipped_workspaces`.

        **Truncation**: `truncated` means `limit` capped returned results; `scan_truncated` means `max_sessions_scanned` or a cooperative workspace/index/byte/turn/elapsed budget capped work. `scan_diagnostics` identifies budget limits with typed counters and `retryable`; narrow `workspace`, `session_id`, or date scope before retrying.
        **Caching**: The cross-workspace session inventory is cached for ~90 seconds for query-loop performance. A session saved within that window may not appear in `list_sessions`/`search`/`time` until the cache expires. `get_session` first resolves the exact session filename without a full inventory scan, then retains one cache-bypassed fresh-scan fallback for just-saved sessions; transcript content is signature-checked and cache-invalidated when the session file changes.
        """,
        inputSchema: object([
            "op": string("Operation.", enum: ["list_sessions", "search", "time", "get_session"]),
            "workspace": string("Limit to saved workspace name, UUID, or Workspace-* storage directory."),
            "agent_kind": string("[list_sessions] Agent kind filter (e.g. claudeCodeGLM, codexExec, acp)."),
            "model": string("[list_sessions] Model substring match."),
            "touched_file": string("[list_sessions] Filter sessions that edited or read this file path."),
            "date_from": string("ISO 8601 lower date bound (e.g. 2026-01-01T00:00:00Z)."),
            "date_to": string("ISO 8601 upper date bound."),
            "sort": string("[list_sessions] Sort order: last_activity (default), duration, turn_count.", enum: ["last_activity", "duration", "turn_count"]),
            "limit": integer("Max returned results. list_sessions default 30, search default 20, max 100."),
            "idle_threshold_minutes": integer("[list_sessions, time] Idle gap threshold in minutes for active duration. Omitted uses the app setting/default (currently 10). Range 0...1440."),
            "max_sessions_scanned": integer("[list_sessions, search, time] Max sessions hydrated/scanned before scan_truncated. Default 200, cap 1000. Independent cooperative inventory/turn/elapsed budgets may also truncate and are reported in scan_diagnostics."),
            "include_turn_request_text": boolean("[search] Verbose opt-in: include clipped matched-turn user request text. Default false to keep output compact."),
            "query": string("[search] Search term (required for search). Case-insensitive substring match."),
            "session_id": string("[search, time, get_session] Limit to a specific session UUID."),
            "around_turn": integer("[get_session] Turn index to inspect, usually copied from a search result. Returns a small window around this turn."),
            "context_turns": integer("[get_session] Number of turns before/after around_turn. Use 0 for the cheapest target-turn-only follow-up to a search result. Default 1, max 5."),
            "turn_start": integer("[get_session] Inclusive start turn for a bounded range. Requires no around_turn. Max returned span is 20 turns."),
            "turn_end": integer("[get_session] Inclusive end turn for a bounded range. Max returned span is 20 turns."),
            "roles": array("[get_session] Included roles. Default: user, assistant, errors, summaries. Tool calls are summarized per turn; include role `tool` only when individual tool entries are needed.", items: string("[get_session] Role to include", enum: ["user", "assistant", "tool", "error", "summary", "system", "thinking"])),
            "max_chars": integer("[get_session] Hard cap on returned text. Default 6000, max 20000."),
            "source": string("[search] Where to search: activities, summaries, or all (default all).", enum: ["activities", "summaries", "all"]),
            "group_by": string("[time] Grouping dimension (required for time).", enum: ["day", "week", "month", "session", "workspace"]),
            "include_details": boolean("[time] Verbose opt-in: include per-session breakdowns in each group. Default false.")
        ], required: ["op"], description: """
        Provide `op` plus operation-specific fields.

        **list_sessions**: workspace?, agent_kind?, model?, touched_file?, date_from?, date_to?, sort?, limit?, idle_threshold_minutes?, max_sessions_scanned?
        **search**: query (required), workspace?, session_id?, source?, date_from?, date_to?, limit?, max_sessions_scanned?, include_turn_request_text?
        **get_session**: session_id (required), around_turn? + context_turns?, or turn_start? + turn_end?, roles?, max_chars?
        **time**: group_by (required), workspace?, session_id?, date_from?, date_to?, limit?, include_details?, idle_threshold_minutes?, max_sessions_scanned?
        """),
        annotations: readOnly
    )

    private static func object(
        _ properties: [String: Value],
        required: [String] = [],
        additionalProperties: Bool? = nil,
        description: String? = nil
    ) -> Value {
        var value: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(Value.string))
        ]
        if let additionalProperties { value["additionalProperties"] = .bool(additionalProperties) }
        if let description { value["description"] = .string(description) }
        return .object(value)
    }

    private static func objectProperty(
        _ description: String?,
        properties: [String: Value],
        required: [String]? = nil
    ) -> Value {
        var value: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if let required { value["required"] = .array(required.map(Value.string)) }
        if let description { value["description"] = .string(description) }
        return .object(value)
    }

    private static func string(_ description: String? = nil, enum values: [String]? = nil) -> Value {
        property(type: "string", description: description, enum: values)
    }

    private static func integer(_ description: String? = nil) -> Value {
        property(type: "integer", description: description)
    }

    private static func boolean(_ description: String? = nil) -> Value {
        property(type: "boolean", description: description)
    }

    private static func array(_ description: String?, items: Value) -> Value {
        var value: [String: Value] = ["type": .string("array"), "items": items]
        if let description { value["description"] = .string(description) }
        return .object(value)
    }

    private static func property(
        type: String,
        description: String?,
        enum values: [String]? = nil
    ) -> Value {
        var value: [String: Value] = ["type": .string(type)]
        if let description { value["description"] = .string(description) }
        if let values { value["enum"] = .array(values.map(Value.string)) }
        return .object(value)
    }
}
