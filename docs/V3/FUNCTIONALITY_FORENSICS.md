# Pearl V3.3 — Phase 0 Installed Application Forensics Report

**Inspection Date:** 2026-11-15  
**Target Hardware:** MacBook Neo (Apple Silicon, 8 GB Unified Memory)  
**Operating System:** macOS 27.2.1 (Build `26B131`)  
**Toolchain:** Apple Swift `6.4.2` (`arm64-apple-macosx27.2.0`)  
**Repository Starting Commit:** `566ebb5b81a58f7289f066023958d1154a94dcea` (`main`)

---

## 1. Installed Binary vs. Repository Build Comparison

| Diagnostic Item | Installed / Live System Value | Repository Build (`dist/`) Value | Source-vs-Binary Drift |
| :--- | :--- | :--- | :--- |
| **1. Installed App Location** | `/Applications/Pearl.app` | `/Users/rossonerian/Projects/Pearl/dist/Pearl.app` | Match |
| **2. Bundle Identifier** | `ai.pearl.Pearl` | `ai.pearl.Pearl` | Match |
| **3. `CFBundleShortVersionString`** | `3.2.0` | `3.2.0` | Match |
| **4. `CFBundleVersion`** | `3.2.0` | `3.2.0` | Match |
| **5. Executable Path** | `/Applications/Pearl.app/Contents/MacOS/Pearl` (`5.1M`) | `dist/Pearl.app/Contents/MacOS/Pearl` (`f98088e101ad976de5db12ead8d0f65699d7e8212ba5f2238d5ab04497f89189`) | Exact SHA-256 match |
| **6. Executable Architecture** | `Mach-O 64-bit executable arm64` | `Mach-O 64-bit executable arm64` | Match |
| **7. Running Native Daemon PID** | **None (`Pearl.app` not running)** | — | **Critical runtime gap** (no running socket server) |
| **8. Running Conflicting Executable** | **PID `749`** (`Python 3.9` `/Users/rossonerian/.local/bin/pearl-server`) | Legacy V1/V2 Python HTTP bridge (`TCP 127.0.0.1:49200`) | **Stale daemon conflict** |
| **9. Multiple Pearl Instances / Binaries** | `/Users/rossonerian/.local/bin/pearl*` contains legacy scripts (`pearl-server`, `pearl-hud`, `pearl-guard`, `pearl-ask`, `pearl-telemetry`, etc.) alongside `pearl-cli` | Swift package only builds `Pearl` and `pearl-cli` | **Legacy script co-existence** |
| **10. Older Daemon Active** | **Yes** — `launchctl list` shows `749 0 com.rossonerian.pearl-server` (`~/Library/LaunchAgents/com.rossonerian.pearl-server.plist`, `KeepAlive: true`) listening on `TCP 127.0.0.1:49200` | Architecture requires 0 TCP listeners & single native AppKit daemon | **Architecture violation** |
| **11. Current CLI Executable & Version** | `/Users/rossonerian/.local/bin/pearl` -> `/Users/rossonerian/.local/bin/pearl-cli` (`arm64`, `4.5M`, SHA-256 `103e663812b42e753bd482a4d4731f3decd234f02222a05cb36db4cf286aa423`) | Matches `dist/Pearl.app/Contents/Helpers/pearl-cli` | **No `--help` guard** (`pearl --help` calls IPC `execute`) |
| **12. CLI-to-Daemon Communication** | Fails cleanly with `Error: Pearl daemon is not running (cannot connect to /Users/rossonerian/Library/Application Support/Pearl/pearl.sock)`; socket file absent | Expects active `UnixSocketServer` listening on `pearl.sock` | **CLI unusable without manual app launch** |

---

## 2. Configuration, Providers, Policy & Privacy State

| Area | Observed State | Issue Identified |
| :--- | :--- | :--- |
| **13. Application Support Configuration** | `~/Library/Application Support/Pearl/config.json` has `"version": "2.0.0"`, `mlxEnabled: false`, `pccEnabled: false`, `allowedFolders: ["~/Documents", "~/Downloads", "~/Desktop", "~/Projects"]`, `fastModelID: "claude-haiku-5-5"`, `escalationModelID: "claude-sonnet-5-5"`. | Version field stale (`2.0.0` vs `3.2.0`); no migration on load; no `launchAtLogin` setting. |
| **14–15. Active Tool Catalog vs Registered Tools** | Core registers 4 task tools (`list_tasks`, `create_task`, `complete_task`, `delete_task`). `PearlToolsRegistry.allTools()` supplies 43 tools (`battery`, `volume`, `get_display_info`, `display_context`, `open_app`, `close_app`, `frontmost_app`, `screenshot`, `trash_screenshots`, `git`, `git_status`, `reminder`, `list_calendar_events`, `check_calendar_availability`, `create_calendar_event`, `delete_calendar_event`, `calendar`, `read_clipboard`, `write_clipboard`, `clipboard`, `post_notification`, `notification`, `undo`, `search_files`, `read_file_safe`, `copy_file`, `move_file`, `list_windows`, `manage_window`, `list_shortcuts`, `run_shortcut`, `list_browser_tabs`, `open_url`, `read_active_tab`, `propose_skill`, `use_recipe`, `search_skill_catalog`, `subbot_run`, `subbot_workflow`, `vault_list`, `vault_read`, `vault_write`, `vault_search`, `write_output_file`, `create_mail_draft`, `send_mail`, `read_screen_text`). | `PearlToolsRegistry.registerAll(into:catalog:)` ignores non-shared `registry` arguments; `MCPServer` maintains a duplicate `schema(for:tool:)` switch and separate `registerDefaultTools`; no `pearl tools list\|inspect\|doctor` runtime inspection exists. |
| **16. Model Provider Availability** | `SystemLanguageModel.default.availability` is **`available`** (macOS 27.2.1); `MLXProvider` disabled (`mlxEnabled: false`); `FrontierProvider` lacks any API key in macOS Keychain (`ai.pearl` / `anthropic`) or shell env. | **Crucial**: `AppleFMProvider.intentInstructions` hardcodes only 12 legacy actions (`volume\|battery\|open_app\|close_app\|screenshot\|trash_screenshots\|reminder\|undo\|list_tasks\|create_task\|complete_task\|delete_task\|unknown`) with a single `"parameter"` string! `FrontierProvider` sends zero `tools` definitions and never parses `tool_use` blocks (`toolCalls: []`). |
| **17. Current Policy Configuration** | `~/Library/Application Support/Pearl/policy.json` (`version: "2.0.0"`) declares NeverTier, TaintTracker, Seatbelt. `PolicyEngine.evaluate()` skips `ToolMetadata.requiresConfirmation` when trusted and `tier < .t4ExternalSideEffects`; `ModelToolExecutor` blocks all `tier > .t2ReadPersonal` tools on local models (`move_file`, `close_app`, `write_output_file`, `run_shortcut`). | Confirmation and tier policies are split inconsistently between `PolicyEngine`, `ModelToolExecutor`, and individual tool execute blocks. |
| **18. Filesystem Permissions** | `~/Desktop` (`0700`), `~/Documents` (`0700`), `~/Downloads` (`0700`), `~/Projects` (`0755`). Signed ad-hoc with entitlements: `com.apple.security.automation.apple-events`, `com.apple.security.device.audio-input`, `com.apple.security.files.user-selected.read-write` (non-sandboxed). | `FolderAllowlistValidator` uses naive `URL.resolvingSymlinksInPath()` without ancestral resolution for uncreated leaf paths or `cwd`-independent relative normalization; no security-scoped bookmarks or `NSOpenPanel` Settings UI exist. |
| **19. macOS Privacy (TCC) Permissions** | `TCC.db` protected by SIP (unreadable directly without Full Disk Access). Runtime app requests Microphone/Speech on launch; Reminders/Calendar use EventKit authorization checks. | No runtime diagnostic exposes live TCC authorization status per capability cleanly. |
| **20. Application Logs & Audit Integrity** | `~/.pearl/pearl-server.log` active for legacy Python server; `~/Library/Application Support/Pearl/audit.log` (`425 KB`, through `seq: 1414`) contains **synthetic unit-test pollution** (`tool_1..tool_7`, `KillSwitch`, `sudo rm -rf /`, `modify_stuff` on `2026-11-14T13:38:45Z`). | `AuditLogger`, `SpendCapTracker`, `TaskStore`, `JobStore`, `ApprovalQueue`, `ReminderTool`, and `CalendarLocalStore` default to live `~/Library/Application Support/Pearl/` during `swift test`, polluting user state. |

---

## 3. Missing Capabilities & Architectural Bugs

### Missing Core Tools
- `create_directory` — **missing** (no folder creation capability anywhere in `Sources/PearlTools/`).
- `list_directory` — **missing** (cannot list directories or filter files/folders).
- `rename_file` — **missing**.
- `trash_file` — **missing** (`TrashFileTool.swift` only contains `TrashScreenshotsTool`).
- `reminder` `complete` action — **missing** (`ReminderTool.swift` only handles `list` and `create`).

### Pipeline & Execution Defects
1. **No Daemon Running + CLI Auto-Failure**: `Pearl.app` is inactive; `pearl status` and `pearl "create folder Pearl on Desktop"` fail immediately on `connect()` to `pearl.sock`. Even `pearl --help` falls into `default:` and attempts to execute `"--help"` as a natural-language query over IPC.
2. **Deterministic Router Gap**: `DeterministicRouter` has 0 filesystem grammar rules (`create folder`, `list folders`, `find files`, `rename`, `move`, `copy`, `trash`, `undo`).
3. **Model Tool Selection Dead-End**: `AppleFMProvider` only knows 12 single-parameter actions, so `"Create a folder called Pearl on my Desktop"` returns `unknown` and drops to plain conversational chat—either refusing or hallucinating completion without executing a filesystem operation. `FrontierProvider` omits Anthropic `tools` entirely.
4. **Registration Divergence**: `PearlToolsRegistry.registerAll(into:catalog:)` drops custom `registry` arguments; `AppDelegate`, `CentralToolCatalog`, and `MCPServer` each separately register task/default subsets; `MCPServer` duplicates schemas in a hand-maintained `switch`.
5. **`PlanExecutor` Resume Bug**: In `PlanExecutor.runLoopCore`, resuming a `.pausedForApproval` step checks `matchingApproval.status == .approved` and marks `step.status = .completed` with `"Approved and executed via ApprovalQueue"` without propagating real execution success/failure or arguments when `ApprovalQueue.approve(id:)` ran separately.
6. **`FolderAllowlistValidator` Path Gaps**: Uncreated nested paths inside a symlinked ancestor or bare relative folder names evaluated inside a `.app` bundle (where `cwd` is `/`) do not robustly canonicalize ancestors prior to allowlist comparison.
7. **Confirmation UX Disconnection**: `pearl-cli` (`case "execute"`) lacks `--confirm` and interactive confirmation handling; `HUDView` displays raw text without guaranteed structured confirmation metadata (`requiresConfirmation`, `pendingToolName`, `pendingArguments`).

---

## 4. Exact Reproduction of Failure

**Scenario:** User requests `"Create a folder called Pearl on my Desktop"` on MacBook Neo (`v3.2.0`, `566ebb5`).

1. **Via CLI (`pearl "Create a folder called Pearl on my Desktop"`)**:
   - Observed output: `Error: Pearl daemon is not running (cannot connect to /Users/rossonerian/Library/Application Support/Pearl/pearl.sock)` (exit code `1`).
2. **Even when `Pearl.app` (`v3.2.0`) is launched manually**:
   - `AssistantPipeline` passes input to `DeterministicRouter.resolve(utterance:)` -> **returns `nil`** (no filesystem rules).
   - Falls through to `FallbackChain` -> `AppleFMProvider.generate()` -> `intentInstructions` restricts output to 12 hardcoded tools (no `create_directory` or any filesystem tool) -> returns `{"action": "unknown", "parameter": ""}`.
   - Falls through to conversational `LanguageModelSession` (or `Offline Fallback` explanation listing only volume/battery/apps/reminders/tasks/screenshots/git) -> **zero directories created on `~/Desktop`**.

---

## 5. V3.3 Recovery Targets

1. Implement `FilesystemPermissionManager` + `CreateDirectoryTool` (`create_directory`), `ListDirectoryTool` (`list_directory`), `RenameFileTool` (`rename_file`), `TrashFileTool` (`trash_file`), and `ReminderTool` (`complete`), plus Settings `"Folders & Permissions"` UI using `NSOpenPanel` and security-scoped bookmarks.
2. Unify tool registration (`CentralToolCatalog` <-> `ToolRegistry` <-> `PearlToolsRegistry` <-> `MCPServer`) and add live runtime `pearl tools list|inspect|doctor` diagnostics + `--help` + `--confirm`.
3. Add deterministic filesystem grammar with multi-folder `PlanExecutor` plans, ambiguity clarifications (`Where should I create it: Desktop, Documents, Downloads or Projects?`), and negation/false-positive guards.
4. Upgrade `AppleFMProvider` & `FrontierProvider` to consume dynamic catalog tool schemas and multi-step tool calls, and fix `PolicyEngine`, `ModelToolExecutor`, and `PlanExecutor` approval resume correctness.
5. Isolate all tests from `~/Library/Application Support/Pearl/`, pass all 20 mandatory real-disk tests and native macOS checks, remove `com.rossonerian.pearl-server` conflict, verify `Pearl.app` v3.3.0 resource/security gates on MacBook Neo, and update docs.
