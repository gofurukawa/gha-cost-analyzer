#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# gha-cost-analyzer/fetch.sh
#
# GitHub Actions のジョブ実行履歴を複数リポジトリから並行取得し、CSV に出力する。
#
# Usage:
#   ./fetch.sh [OPTIONS] <owner/repo> [<owner/repo> ...]
#   ./fetch.sh [OPTIONS] --repos-file repos.txt
#
# Options:
#   --date YYYY-MM-DD   指定日1日分を取得 (UTC, default: 本日)
#   --from YYYY-MM-DD   期間の開始日 (--to と併用, UTC)
#   --to   YYYY-MM-DD   期間の終了日 (--from と併用, UTC)
#   --parallel N         並行実行数 (default: 4)
#   --outdir DIR         出力ベースディレクトリ (default: ./output)
#   --repos-file FILE    リポジトリ一覧ファイル (1行1リポジトリ)
#   --status STATUS      completed / success / failure (default: completed)
#   --help               ヘルプ表示
#
# Requirements:
#   - gh (GitHub CLI, authenticated)
#   - jq
#
# Output:
#   <outdir>/<date>/jobs_<owner>_<repo>.csv   ... リポジトリごとの生データ
#   <outdir>/<date>/jobs_all.csv              ... 全リポジトリ結合
#   ※ <date> は YYYY-MM-DD または YYYY-MM-DD_YYYY-MM-DD
# =============================================================================

# --- Defaults ---
DATE_SINGLE=""      # YYYY-MM-DD (--date 用)
DATE_FROM=""        # YYYY-MM-DD (--from 用)
DATE_TO=""          # YYYY-MM-DD (--to 用)
PARALLEL=4
OUTDIR="./output"
REPOS_FILE=""
STATUS="completed"
REPOS=()

# --- Color helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Usage ---
usage() {
  sed -n '/^# Usage:/,/^# Output:/p' "$0" | sed 's/^# \?//'
  exit 0
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)       DATE_SINGLE="$2"; shift 2 ;;
    --from)       DATE_FROM="$2";  shift 2 ;;
    --to)         DATE_TO="$2";    shift 2 ;;
    --parallel)   PARALLEL="$2";   shift 2 ;;
    --outdir)     OUTDIR="$2";     shift 2 ;;
    --repos-file) REPOS_FILE="$2"; shift 2 ;;
    --status)     STATUS="$2";     shift 2 ;;
    --help|-h)    usage ;;
    -*)           log_error "Unknown option: $1"; exit 1 ;;
    *)            REPOS+=("$1");   shift ;;
  esac
done

# --- Validate date options ---
validate_date() {
  local d="$1" label="$2"
  if [[ ! "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    log_error "$label must be YYYY-MM-DD format, got: $d"
    exit 1
  fi
  if ! date -u -d "$d" +%Y-%m-%d &>/dev/null 2>&1 && \
     ! date -u -j -f "%Y-%m-%d" "$d" +%Y-%m-%d &>/dev/null 2>&1; then
    log_error "$label is not a valid date: $d"
    exit 1
  fi
}

if [[ -n "$DATE_SINGLE" && ( -n "$DATE_FROM" || -n "$DATE_TO" ) ]]; then
  log_error "--date cannot be used with --from/--to"
  exit 1
fi

if [[ -n "$DATE_FROM" && -z "$DATE_TO" ]] || [[ -z "$DATE_FROM" && -n "$DATE_TO" ]]; then
  log_error "--from and --to must be used together"
  exit 1
fi

[[ -n "$DATE_SINGLE" ]] && validate_date "$DATE_SINGLE" "--date"
[[ -n "$DATE_FROM" ]]   && validate_date "$DATE_FROM" "--from"
[[ -n "$DATE_TO" ]]     && validate_date "$DATE_TO" "--to"

if [[ -n "$DATE_FROM" && -n "$DATE_TO" ]] && [[ "$DATE_FROM" > "$DATE_TO" ]]; then
  log_error "--from ($DATE_FROM) must be on or before --to ($DATE_TO)"
  exit 1
fi

# Default: today (UTC)
if [[ -z "$DATE_SINGLE" && -z "$DATE_FROM" ]]; then
  DATE_SINGLE=$(date -u +%Y-%m-%d)
fi

# --- Load repos from file if specified ---
if [[ -n "$REPOS_FILE" ]]; then
  if [[ ! -f "$REPOS_FILE" ]]; then
    log_error "Repos file not found: $REPOS_FILE"
    exit 1
  fi
  while IFS= read -r line; do
    line="${line%%#*}"        # strip comments
    line="${line// /}"        # strip spaces
    [[ -n "$line" ]] && REPOS+=("$line")
  done < "$REPOS_FILE"
fi

if [[ ${#REPOS[@]} -eq 0 ]]; then
  log_error "No repositories specified."
  echo "Usage: $0 [OPTIONS] <owner/repo> [<owner/repo> ...]" >&2
  echo "       $0 [OPTIONS] --repos-file repos.txt" >&2
  exit 1
fi

# --- Prerequisite check ---
for cmd in gh jq; do
  if ! command -v "$cmd" &>/dev/null; then
    log_error "'$cmd' is required but not found."
    exit 1
  fi
done

# gh auth check
if ! gh auth status &>/dev/null 2>&1; then
  log_error "gh is not authenticated. Run 'gh auth login' first."
  exit 1
fi

# --- Prepare dates and output subdirectory ---
next_day() {
  date -u -d "$1 + 1 day" +%Y-%m-%d 2>/dev/null \
    || date -u -j -f "%Y-%m-%d" -v+1d "$1" +%Y-%m-%d
}

if [[ -n "$DATE_SINGLE" ]]; then
  # --date mode (or default today)
  SINCE_DATE="${DATE_SINGLE}T00:00:00Z"
  UNTIL_DATE="$(next_day "$DATE_SINGLE")T00:00:00Z"
  DATE_LABEL="$DATE_SINGLE (UTC)"
  DATE_DIR_SUFFIX="$DATE_SINGLE"
else
  # --from / --to mode
  SINCE_DATE="${DATE_FROM}T00:00:00Z"
  UNTIL_DATE="$(next_day "$DATE_TO")T00:00:00Z"
  if [[ "$DATE_FROM" == "$DATE_TO" ]]; then
    DATE_LABEL="$DATE_FROM (UTC)"
    DATE_DIR_SUFFIX="$DATE_FROM"
  else
    DATE_LABEL="${DATE_FROM} to ${DATE_TO} (UTC)"
    DATE_DIR_SUFFIX="${DATE_FROM}_${DATE_TO}"
  fi
fi

OUTDIR="${OUTDIR}/${DATE_DIR_SUFFIX}"
mkdir -p "$OUTDIR"

CSV_HEADER="repo,workflow_name,workflow_file,run_id,run_number,event,branch,run_started_at,job_id,job_name,runner_label,runner_os,runner_group,status,conclusion,job_started_at,job_completed_at,duration_sec"

log_info "Settings:"
log_info "  Repos:    ${REPOS[*]}"
log_info "  Period:   $DATE_LABEL"
log_info "  Parallel: $PARALLEL"
log_info "  Status:   $STATUS"
log_info "  Output:   $OUTDIR"
echo ""

# =============================================================================
# fetch_repo: 1リポジトリ分のデータを取得して CSV 出力
# =============================================================================
fetch_repo() {
  local repo="$1"
  local since="$2"
  local until="$3"
  local status="$4"
  local outdir="$5"

  local safe_name="${repo//\//_}"
  local csv_file="${outdir}/jobs_${safe_name}.csv"
  local tmp_runs
  tmp_runs=$(mktemp)
  local tmp_jobs
  tmp_jobs=$(mktemp)

  trap "rm -f '$tmp_runs' '$tmp_jobs'" RETURN

  log_info "[$repo] Fetching workflow runs (${since}..${until}) ..."

  # --- Step 1: Get workflow runs ---
  gh api --paginate \
    "/repos/${repo}/actions/runs?status=${status}&created=${since}..${until}&per_page=100" \
    --jq '.workflow_runs[] | {
      run_id: .id,
      run_number: .run_number,
      workflow_name: .name,
      workflow_file: (.path // "" | split("/") | last),
      event: .event,
      branch: .head_branch,
      run_started_at: .run_started_at
    }' > "$tmp_runs" 2>/dev/null || true

  local run_count
  run_count=$(wc -l < "$tmp_runs" | tr -d ' ')
  if [[ "$run_count" -eq 0 ]]; then
    log_warn "[$repo] No workflow runs found."
    return
  fi
  log_info "[$repo] Found $run_count runs. Fetching jobs ..."

  # --- Step 2: Get jobs for each run ---
  local processed=0
  local run_ids
  run_ids=$(jq -r '.run_id' "$tmp_runs" | sort -u)

  for run_id in $run_ids; do
    # run metadata
    local run_meta
    run_meta=$(jq -c "select(.run_id == ${run_id})" "$tmp_runs" | head -1)

    gh api --paginate \
      "/repos/${repo}/actions/runs/${run_id}/jobs?per_page=100" \
      --jq '.jobs[] | {
        job_id: .id,
        job_name: .name,
        runner_label: (.labels // [] | join(";")),
        runner_os: (.labels // [] | map(select(
          test("ubuntu|windows|macos|linux"; "i")
        )) | first // "unknown"),
        runner_group: (.runner_group_name // ""),
        status: .status,
        conclusion: .conclusion,
        job_started_at: .started_at,
        job_completed_at: .completed_at
      }' 2>/dev/null | while IFS= read -r job; do
        # Merge run metadata + job data → CSV row
        echo "$run_meta" "$job" | jq -s -r '
          (.[0]) as $run | (.[1]) as $job |
          # duration calculation
          (
            if ($job.job_started_at and $job.job_completed_at) then
              ( ($job.job_completed_at | fromdateiso8601) -
                ($job.job_started_at  | fromdateiso8601) )
            else 0 end
          ) as $dur |
          [
            "'"$repo"'",
            $run.workflow_name,
            $run.workflow_file,
            ($run.run_id | tostring),
            ($run.run_number | tostring),
            $run.event,
            $run.branch,
            $run.run_started_at,
            ($job.job_id | tostring),
            $job.job_name,
            $job.runner_label,
            $job.runner_os,
            $job.runner_group,
            $job.status,
            $job.conclusion,
            $job.job_started_at,
            $job.job_completed_at,
            ($dur | tostring)
          ] | @csv
        '
      done >> "$tmp_jobs"

    processed=$((processed + 1))
    if (( processed % 50 == 0 )); then
      log_info "[$repo] Processed $processed / $run_count runs ..."
    fi

    # Rate limit: small sleep every 10 runs
    if (( processed % 10 == 0 )); then
      sleep 0.5
    fi
  done

  local job_count
  job_count=$(wc -l < "$tmp_jobs" | tr -d ' ')

  if [[ "$job_count" -gt 0 ]]; then
    echo "$CSV_HEADER" > "$csv_file"
    cat "$tmp_jobs" >> "$csv_file"
    log_ok "[$repo] Done. $job_count jobs → $csv_file"
  else
    log_warn "[$repo] No jobs found."
  fi
}

export -f fetch_repo log_info log_ok log_warn log_error
export CSV_HEADER RED GREEN YELLOW BLUE NC

# =============================================================================
# Run in parallel
# =============================================================================
log_info "Starting parallel fetch (max $PARALLEL) ..."
echo ""

PIDS=()
RESULTS=()
ACTIVE=0

for repo in "${REPOS[@]}"; do
  # Wait if at max parallel
  while (( ACTIVE >= PARALLEL )); do
    for i in "${!PIDS[@]}"; do
      if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
        wait "${PIDS[$i]}" || true
        unset 'PIDS[i]'
        ACTIVE=$((ACTIVE - 1))
      fi
    done
    sleep 0.2
  done

  fetch_repo "$repo" "$SINCE_DATE" "$UNTIL_DATE" "$STATUS" "$OUTDIR" &
  PIDS+=($!)
  ACTIVE=$((ACTIVE + 1))
done

# Wait for all remaining
for pid in "${PIDS[@]}"; do
  wait "$pid" || true
done

echo ""

# =============================================================================
# Merge all CSVs
# =============================================================================
MERGED="${OUTDIR}/jobs_all.csv"
echo "$CSV_HEADER" > "$MERGED"

for f in "${OUTDIR}"/jobs_*_*.csv; do
  [[ -f "$f" ]] && tail -n +2 "$f" >> "$MERGED"
done

TOTAL_JOBS=$(( $(wc -l < "$MERGED") - 1 ))
log_ok "All done. Total: $TOTAL_JOBS jobs → $MERGED"
echo ""
log_info "Next: analyze with DuckDB"
log_info "  duckdb < analyze.sql"
