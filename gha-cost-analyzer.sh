#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# gha-cost-analyzer/gha-cost-analyzer.sh
#
# fetch.sh → analyze.sql を一括実行するラッパー。
#
# Usage:
#   ./gha-cost-analyzer.sh --repos-file repos.txt
#   ./gha-cost-analyzer.sh --repos-file repos.txt --date 2025-01-06
#   ./gha-cost-analyzer.sh --repos-file repos.txt --from 2025-01-01 --to 2025-01-31
#   ./gha-cost-analyzer.sh myorg/repo1 myorg/repo2
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Extract --outdir from arguments for DuckDB
OUTDIR="./output"
ARGS=("$@")
for (( i=0; i<${#ARGS[@]}; i++ )); do
  if [[ "${ARGS[$i]}" == "--outdir" ]] && (( i+1 < ${#ARGS[@]} )); then
    OUTDIR="${ARGS[$((i+1))]}"
    break
  fi
done

echo "============================================"
echo "  gha-cost-analyzer"
echo "============================================"
echo ""

# --- Step 1: Fetch ---
echo ">>> Step 1/2: Fetching job data from GitHub API ..."
echo ""
bash "${SCRIPT_DIR}/fetch.sh" "$@"

echo ""
echo ">>> Step 2/2: Analyzing with DuckDB ..."
echo ""

# --- Step 2: Analyze ---
if ! command -v duckdb &>/dev/null; then
  echo "[WARN] duckdb not found. Install it to run analysis:"
  echo "  brew install duckdb        # macOS"
  echo "  pip install duckdb-cli     # pip"
  echo ""
  echo "Or run manually:"
  echo "  duckdb -cmd \"SET VARIABLE outdir = '${OUTDIR}';\" < ${SCRIPT_DIR}/analyze.sql"
  exit 0
fi

cd "${SCRIPT_DIR}"
duckdb -cmd "SET VARIABLE outdir = '${OUTDIR}';" < analyze.sql

echo ""
echo "============================================"
echo "  Results:"
echo "    ${OUTDIR}/*/jobs_all.csv     生データ（日付別）"
echo "============================================"
