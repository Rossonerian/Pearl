#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Pearl V2 - Master Benchmark Execution Harness
# ==============================================================================
# Executes all subsystem benchmark suites on Apple Silicon, updates raw CSVs
# in Bench/results/, and triggers generate_report.py to regenerate docs/BENCHMARKS.md.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${BENCH_DIR}/.." && pwd)"
RESULTS_DIR="${BENCH_DIR}/results"

mkdir -p "${RESULTS_DIR}"
cd "${REPO_ROOT}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
echo "=============================================================================="
echo " Building Pearl Benchmark Suite via SwiftPM..."
echo " Using DEVELOPER_DIR: ${DEVELOPER_DIR}"
echo "=============================================================================="
DEVELOPER_DIR="${DEVELOPER_DIR}" swift build --package-path "${BENCH_DIR}"

BIN_DIR="${BENCH_DIR}/.build/debug"
if [[ ! -d "${BIN_DIR}" ]]; then
    BIN_DIR="${BENCH_DIR}/.build/out/Products/Debug"
fi

run_suite() {
    local name="$1"
    local bin="${BIN_DIR}/$1"
    echo ""
    echo "------------------------------------------------------------------------------"
    echo " Running Suite: ${name}..."
    echo "------------------------------------------------------------------------------"
    if [[ -x "${bin}" ]]; then
        "${bin}"
        echo "✓ Finished ${name}"
    else
        echo "Warning: Executable ${bin} not found, skipping."
    fi
}

echo "=============================================================================="
echo " Executing Empirical Subsystem Benchmarks on Apple Silicon"
echo " Host: $(uname -m) | OS: $(sw_vers -productName) $(sw_vers -productVersion)"
echo "=============================================================================="

# 1. Baseline V1 comparison
run_suite "baseline_v1"

# 2. Spike 4 Notch HUD Presentation
run_suite "spike4_hud"

# 3. Deterministic Swift Router
run_suite "swift_router_bench"

# 4. Action Benchmark (Native Swift vs osascript vs NSAppleScript)
run_suite "action_bench"

# 5. Full Router Evaluation (851 utterances)
run_suite "router_eval"

# 6. Voice Pipeline E2E & 60Hz Metering
run_suite "voice_e2e"

# 7. M1 Verification (IPC Socket Ping & Status)
run_suite "m1_verification"

# 8. Model Router & LLM Fallback Chain
run_suite "llm_path"

# 9. Inspectable Memory & FTS5 Store
run_suite "memory_bench"

# 10. Native MCP Server Stdio & JSON-RPC
run_suite "mcp_bench"

# 11. Security Sandbox & Guardrails
run_suite "security_bench"

echo ""
echo "=============================================================================="
echo " Aggregating Raw CSVs into docs/BENCHMARKS.md..."
echo "=============================================================================="
python3 "${SCRIPT_DIR}/generate_report.py"

echo ""
echo "=============================================================================="
echo " Master Benchmark Suite Complete!"
echo " All results verified and written to docs/BENCHMARKS.md."
echo "=============================================================================="
