# Pearl V2 - Native MCP Server Exposure (`pearl mcp`)

Pearl V2 exposes safe, native macOS automation tools over standard input / standard output (stdio) using the **Model Context Protocol (MCP)** JSON-RPC 2.0 specification (`protocolVersion: 2024-11-05`).

Agents such as **Claude Desktop**, **Claude Code**, **Cursor**, and **Xcode** can connect to `pearl mcp` as an external tool provider while Pearl's kernel-level and in-process policy engines enforce strict security, auditing, and isolation boundaries.

---

## 1. Quick Start & Client Configuration

### Claude Desktop
Add Pearl to your Claude Desktop configuration (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "pearl": {
      "command": "/usr/local/bin/pearl",
      "args": ["mcp"]
    }
  }
}
```

### Claude Code CLI
```bash
claude mcp add pearl -- /usr/local/bin/pearl mcp
```

### Cursor / VS Code
In Cursor Settings -> MCP Servers:
- **Name**: `Pearl`
- **Type**: `stdio`
- **Command**: `pearl mcp`

---

## 2. Supported MCP Methods

The server communicates via newline-delimited JSON-RPC 2.0 messages over `stdin` and `stdout`.

### `initialize`
- **Request**: Standard MCP initialize payload with clientInfo and protocolVersion.
- **Response**:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2024-11-05",
    "capabilities": {
      "tools": {}
    },
    "serverInfo": {
      "name": "Pearl",
      "version": "2.0.0"
    }
  }
}
```

### `notifications/initialized`
- Absorbed silently without response per JSON-RPC 2.0 specifications. Marks the MCP session initialized.

### `ping`
- **Response**: `{"jsonrpc": "2.0", "id": 2, "result": {}}`

### `tools/list`
- Returns full JSON Schema definitions for registered **T0–T2** tools.
- T3+ tools and raw shell interpreters are strictly **NOT** exposed.

### `tools/call`
- Executes tool under Pearl's `PolicyEngine` with untrusted context.
- Returns standard MCP text content response:
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Volume set to 50%."
      }
    ],
    "isError": false
  }
}
```

---

## 3. Exposed Tools (T0–T2 Surface)

| Tool | Tier | Description | Parameters | Reversible |
| :--- | :--- | :--- | :--- | :---: |
| `volume` | T1 | Get or set audio output volume level | `level` (string, optional 0-100) | Yes |
| `battery` | T0 | Get battery percentage and charging state via IOKit | none | No |
| `frontmost_app` | T0 | Get active frontmost application name and bundle ID | none | No |
| `open_app` | T1 | Open or focus an application by name via `NSWorkspace` | `app` (string, required) | Yes |
| `close_app` | T1 | Terminate running application by name | `app` (string, required) | No |
| `screenshot` | T1 | Capture screen to `Pictures/Pearl` | none | Yes |
| `reminder` | T1 | Create or list reminders (Apple Reminders + fallback store) | `action` ("create" \| "list"), `title` (string) | Yes |
| `git_status` | T0 | Check status and branch of git repositories | `path` (string, optional) | No |

---

## 4. Security & Safety Model

1. **Untrusted Client Context**:
   MCP clients are treated as untrusted context callers. Every invocation is tagged `TrustLevel.untrusted`.
2. **NeverTier Defense**:
   Attempts to invoke unexposed or destructive commands (`rm`, `shell_execute`, `git_push_force`, `sudo`, reverse shells, filesystem erasure) are immediately rejected with clean JSON-RPC errors (code `-32001` / `-32002`).
3. **Tamper-Evident Audit Logging**:
   Every MCP tool call (both allowed executions and policy refusals) is recorded in Pearl's SHA-256 hash-chained `audit.log` at `~/Library/Application Support/Pearl/audit.log`.
4. **Network & Storage Isolation**:
   - 0 TCP listeners (network isolation verified via `pearl doctor --security`).
   - Clean shutdown on stdin EOF (`Ctrl+D` / process termination).
   - Zero persistent RAM overhead when client is disconnected.

---

## 5. Verification & Benchmark

Run the full MCP verification suite and latency benchmarks:

```bash
cd Bench
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build --product mcp_bench
.build/debug/mcp_bench
```

Latency measurements over 100 tool calls:
- **p50**: ~0.53 ms
- **p95**: ~30.4 ms
- **p99**: ~30.7 ms

Results are saved to `Bench/results/mcp_bench.csv`.
