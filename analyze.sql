-- =============================================================================
-- gha-cost-analyzer/analyze.sql
--
-- DuckDB で GitHub Actions ジョブデータを分析する。
-- Usage:
--   duckdb < analyze.sql
--   duckdb -cmd ".read analyze.sql"
--
-- 入力: output/*/jobs_all.csv (日付別ディレクトリの全データ)
-- =============================================================================

-- ----------------------------------------------------------------------------
-- 0. 設定 (必要に応じてここだけ変更すれば全クエリに反映される)
-- ----------------------------------------------------------------------------

-- 表示設定: markdown テーブル形式で出力
.mode markdown

-- 入出力ディレクトリ (fetch.sh の --outdir に合わせる)
-- COALESCE: -cmd で事前に SET された値があればそちらを優先
SET VARIABLE outdir = COALESCE(getvariable('outdir'), 'output');

-- 分析対象パターン (デフォルト: 全日付ディレクトリ)
--   duckdb -cmd "SET VARIABLE analysis_glob = '2025-01-06';" < analyze.sql
--   duckdb -cmd "SET VARIABLE analysis_glob = '2025-01*';" < analyze.sql
SET VARIABLE analysis_glob = COALESCE(getvariable('analysis_glob'), '*');

-- 分析対象リポジトリ (デフォルト: 全リポジトリ)
--   duckdb -cmd "SET VARIABLE analysis_repo = 'myorg/api-server';" < analyze.sql
--   duckdb -cmd "SET VARIABLE analysis_repo = 'myorg/%';" < analyze.sql
SET VARIABLE analysis_repo = COALESCE(getvariable('analysis_repo'), '%');

-- 単価定義
-- ref: https://docs.github.com/ja/billing/reference/actions-runner-pricing
SET VARIABLE cost_linux_slim = 0.002;  -- Linux 1-core (ubuntu-slim)
SET VARIABLE cost_linux_std  = 0.006;  -- Linux 2-core (ubuntu-latest 等)
SET VARIABLE cost_windows    = 0.010;  -- Windows 2-core
SET VARIABLE cost_macos      = 0.062;  -- macOS 3-core/4-core

-- ----------------------------------------------------------------------------
-- 1. データ読み込み
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE jobs AS
SELECT
  repo,
  workflow_name,
  workflow_file,
  CAST(run_id AS BIGINT) AS run_id,
  CAST(run_number AS INTEGER) AS run_number,
  event,
  branch,
  TRY_CAST(run_started_at AS TIMESTAMP) AS run_started_at,
  CAST(job_id AS BIGINT) AS job_id,
  job_name,
  runner_label,
  runner_os,
  runner_group,
  status,
  conclusion,
  TRY_CAST(job_started_at AS TIMESTAMP) AS job_started_at,
  TRY_CAST(job_completed_at AS TIMESTAMP) AS job_completed_at,
  CAST(duration_sec AS INTEGER) AS duration_sec,
  -- 課金時間 (1分単位切り上げ)
  GREATEST(CEIL(CAST(duration_sec AS DOUBLE) / 60.0), 1)::INTEGER AS billed_min,
  -- ランナーOS正規化
  CASE
    WHEN LOWER(runner_os) LIKE '%ubuntu%' OR LOWER(runner_os) LIKE '%linux%' THEN 'Linux'
    WHEN LOWER(runner_os) LIKE '%windows%' THEN 'Windows'
    WHEN LOWER(runner_os) LIKE '%macos%'   THEN 'macOS'
    ELSE 'Other'
  END AS os_category,
  -- slim判定
  CASE
    WHEN runner_label LIKE '%slim%' THEN true
    ELSE false
  END AS is_slim
FROM read_csv(
  getvariable('outdir') || '/' || getvariable('analysis_glob') || '/jobs_all.csv',
  header=true,
  auto_detect=true,
  ignore_errors=true,
  union_by_name=true
)
WHERE repo LIKE getvariable('analysis_repo')
-- 日付範囲の重複で同一ジョブが複数ディレクトリに存在する場合の重複排除
QUALIFY ROW_NUMBER() OVER (PARTITION BY CAST(job_id AS BIGINT) ORDER BY 1) = 1;

CREATE OR REPLACE TABLE pricing AS
SELECT * FROM (VALUES
  ('Linux',   'standard', getvariable('cost_linux_std')),
  ('Linux',   'slim',     getvariable('cost_linux_slim')),
  ('Windows', 'standard', getvariable('cost_windows')),
  ('macOS',   'standard', getvariable('cost_macos'))
) AS t(os_category, runner_type, cost_per_min);


.print ''
.print '## 1. 概要サマリー'
.print ''

SELECT
  COUNT(DISTINCT repo) AS repos,
  COUNT(DISTINCT workflow_name) AS workflows,
  COUNT(DISTINCT job_name) AS unique_jobs,
  COUNT(*) AS total_job_runs,
  SUM(duration_sec) AS total_duration_sec,
  ROUND(SUM(duration_sec) / 3600.0, 1) AS total_hours,
  SUM(billed_min) AS total_billed_min
FROM jobs;


.print ''
.print '## 2. リポジトリ別サマリー'
.print ''

SELECT
  repo,
  COUNT(DISTINCT job_name) AS unique_jobs,
  COUNT(*) AS job_runs,
  ROUND(SUM(duration_sec) / 3600.0, 1) AS hours,
  SUM(billed_min) AS billed_min,
  ROUND(SUM(billed_min) * getvariable('cost_linux_std'), 2) AS est_cost_usd
FROM jobs
WHERE os_category = 'Linux'
GROUP BY repo
ORDER BY billed_min DESC;


.print ''
.print '## 3. ランナーラベル別の使用状況'
.print ''

SELECT
  runner_label,
  os_category,
  is_slim,
  COUNT(*) AS job_runs,
  SUM(billed_min) AS billed_min,
  ROUND(AVG(duration_sec), 1) AS avg_sec,
  MEDIAN(duration_sec) AS median_sec
FROM jobs
GROUP BY runner_label, os_category, is_slim
ORDER BY billed_min DESC;


.print ''
.print '## 4. slim 移行候補 (中央値 ≤ 60秒の短時間ジョブ)'
.print ''

SELECT
  repo,
  workflow_file,
  job_name,
  runner_label,
  COUNT(*) AS run_count,
  MEDIAN(duration_sec)::INTEGER AS median_sec,
  MAX(duration_sec) AS max_sec,
  SUM(billed_min) AS current_billed_min,
  ROUND(SUM(billed_min) * getvariable('cost_linux_std'), 2) AS current_cost,
  ROUND(SUM(billed_min) * getvariable('cost_linux_slim'), 2) AS slim_cost_same_time
FROM jobs
WHERE os_category = 'Linux'
  AND is_slim = false
  AND conclusion = 'success'
GROUP BY repo, workflow_file, job_name, runner_label
HAVING MEDIAN(duration_sec) <= 60 AND COUNT(*) >= 3
ORDER BY current_billed_min DESC;


.print ''
.print '## 5. slim 移行済みジョブの実績 (before/after 比較)'
.print ''

-- slim と同名ジョブの非slim版が両方あれば比較
WITH labeled AS (
  SELECT
    repo,
    job_name,
    is_slim,
    COUNT(*) AS runs,
    ROUND(AVG(duration_sec), 1) AS avg_sec,
    MEDIAN(duration_sec)::INTEGER AS median_sec,
    MAX(duration_sec) AS max_sec,
    ROUND(AVG(billed_min), 2) AS avg_billed_min
  FROM jobs
  WHERE os_category = 'Linux' AND conclusion = 'success'
  GROUP BY repo, job_name, is_slim
)
SELECT
  s.repo,
  s.job_name,
  -- before (standard)
  b.runs AS std_runs,
  b.avg_sec AS std_avg_sec,
  b.median_sec AS std_median_sec,
  -- after (slim)
  s.runs AS slim_runs,
  s.avg_sec AS slim_avg_sec,
  s.median_sec AS slim_median_sec,
  -- 変化率
  ROUND((s.median_sec - b.median_sec)::DOUBLE / NULLIF(b.median_sec, 0) * 100, 1)
    AS duration_change_pct,
  -- コスト変化 (per job)
  ROUND(b.avg_billed_min * getvariable('cost_linux_std'), 4) AS std_cost_per_job,
  ROUND(s.avg_billed_min * getvariable('cost_linux_slim'), 4) AS slim_cost_per_job
FROM labeled s
JOIN labeled b ON s.repo = b.repo AND s.job_name = b.job_name
WHERE s.is_slim = true AND b.is_slim = false
ORDER BY s.repo, s.job_name;


.print ''
.print '## 6. 月次トレンド (コスト推移)'
.print ''

SELECT
  STRFTIME(run_started_at, '%Y-%m') AS month,
  os_category,
  is_slim,
  COUNT(*) AS job_runs,
  SUM(billed_min) AS billed_min,
  ROUND(SUM(billed_min) *
    CASE
      WHEN os_category = 'Linux' AND is_slim THEN getvariable('cost_linux_slim')
      WHEN os_category = 'Linux'             THEN getvariable('cost_linux_std')
      WHEN os_category = 'Windows'           THEN getvariable('cost_windows')
      WHEN os_category = 'macOS'             THEN getvariable('cost_macos')
      ELSE getvariable('cost_linux_std')
    END, 2) AS est_cost_usd
FROM jobs
WHERE run_started_at IS NOT NULL
GROUP BY month, os_category, is_slim
ORDER BY month, os_category, is_slim;


.print ''
.print 'Done!'
