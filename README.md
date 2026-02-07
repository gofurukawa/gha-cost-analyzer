# gha-cost-analyzer

GitHub Actions のジョブ実行履歴を複数リポジトリから並行取得し、DuckDB でコスト分析を行うツール。

`ubuntu-latest` → `ubuntu-slim` へのランナー移行候補を、実測データに基づいてランキングする。

## 前提

| ツール | 用途 | インストール |
|--------|------|-------------|
| `gh` | GitHub CLI (API呼び出し) | `brew install gh` |
| `jq` | JSON処理 | `brew install jq` |
| `duckdb` | CSV分析 | `brew install duckdb` |

```bash
# gh の認証 (未実施の場合)
gh auth login
```

## クイックスタート

```bash
# 1. リポジトリを直接指定して実行
./gha-cost-analyzer.sh myorg/repo1 myorg/repo2 myorg/repo3

# 2. ファイルで指定 (大量のリポジトリがある場合)
vim repos.txt   # リポジトリ一覧を記入
./gha-cost-analyzer.sh --repos-file repos.txt
```

## 使い方

### fetch.sh 単体

```bash
# 基本: 本日分 (UTC)、4並列
./fetch.sh myorg/repo1 myorg/repo2

# 特定日を取得
./fetch.sh --date 2025-01-06 myorg/repo1 myorg/repo2

# 期間を指定 (1月分)
./fetch.sh --from 2025-01-01 --to 2025-01-31 --repos-file repos.txt

# 並列数を変更
./fetch.sh --parallel 8 --date 2025-02-01 myorg/repo1 myorg/repo2

# 成功したジョブのみ
./fetch.sh --status success --date 2025-01-06 myorg/repo1
```

### analyze.sql 単体

```bash
# fetch.sh 実行後、DuckDB で分析 (output/*/jobs_all.csv を全て読み込み)
duckdb < analyze.sql

# 特定日のみ分析
duckdb -cmd "SET VARIABLE analysis_glob = '2025-01-06';" < analyze.sql

# 1月分のみ分析
duckdb -cmd "SET VARIABLE analysis_glob = '2025-01*';" < analyze.sql

# 特定リポジトリのみ分析
duckdb -cmd "SET VARIABLE analysis_repo = 'myorg/api-server';" < analyze.sql

# org 内の全リポジトリ
duckdb -cmd "SET VARIABLE analysis_repo = 'myorg/%';" < analyze.sql

# 組み合わせ (1月分 × 特定リポジトリ)
duckdb -cmd "SET VARIABLE analysis_glob = '2025-01*'; SET VARIABLE analysis_repo = 'myorg/api-server';" < analyze.sql

# インタラクティブに追加分析
duckdb
> .read analyze.sql
> SELECT * FROM jobs WHERE job_name LIKE '%lint%';
```

## オプション一覧

| オプション | デフォルト | 説明 |
|-----------|-----------|------|
| `--date YYYY-MM-DD` | 本日 (UTC) | 指定日1日分を取得 |
| `--from YYYY-MM-DD` | - | 期間の開始日 (`--to` と併用, UTC) |
| `--to YYYY-MM-DD` | - | 期間の終了日 (`--from` と併用, UTC) |
| `--parallel N` | 4 | 並行実行数 (リポジトリ単位) |
| `--outdir DIR` | ./output | CSV 出力ベースディレクトリ |
| `--repos-file FILE` | - | リポジトリ一覧ファイル |
| `--status STATUS` | completed | workflow run のフィルタ。completed=全完了 / success=成功のみ / failure=失敗のみ |

※ `--date` と `--from`/`--to` は排他。両方未指定時は本日分 (UTC) を取得。

## 出力ファイル

```
output/
├── 2025-01-06/                    # --date 2025-01-06 の結果
│   ├── jobs_myorg_repo1.csv       # リポジトリ別の生データ
│   ├── jobs_myorg_repo2.csv
│   └── jobs_all.csv               # 全リポジトリ結合
├── 2025-01-01_2025-01-31/         # --from 2025-01-01 --to 2025-01-31 の結果
│   ├── jobs_myorg_repo1.csv
│   └── jobs_all.csv
└── 2025-02-07/                    # 引数なし (本日分) の結果
    └── jobs_all.csv
```

`analyze.sql` は `output/*/jobs_all.csv` を glob で読み込むため、複数回の取得データをまとめて分析できる。
重複するジョブは `job_id` で自動的に排除される。

### jobs_all.csv のカラム

| カラム | 説明 |
|--------|------|
| repo | owner/repo |
| workflow_name | ワークフロー名 |
| workflow_file | ワークフローファイル名 |
| run_id | ワークフロー実行ID |
| run_number | 実行番号 |
| event | トリガーイベント (push, pull_request, ...) |
| branch | ブランチ名 |
| run_started_at | 実行開始時刻 |
| job_id | ジョブID |
| job_name | ジョブ名 |
| runner_label | ランナーラベル (ubuntu-latest, ubuntu-24.04 等) |
| runner_os | ランナーOS |
| runner_group | ランナーグループ名 |
| status | ステータス |
| conclusion | 結論 (success, failure, ...) |
| job_started_at | ジョブ開始時刻 |
| job_completed_at | ジョブ完了時刻 |
| duration_sec | 実行時間 (秒) |

## 分析レポートの内容

`analyze.sql` は以下の分析を実行する:

1. **概要サマリー** — 全体の規模感
2. **リポジトリ別サマリー** — どのリポジトリがコストを使っているか
3. **ランナーラベル別使用状況** — 現在のランナー構成
4. **slim 移行候補** — 中央値≤60秒の短時間ジョブ (1分課金なのでコスト増なし)
5. **slim 移行済みジョブの実績** — before/after 比較
6. **月次トレンド** — コスト推移

## コスト前提

| ランナー | Billing SKU | 単価/分 | private | public |
|---------|-------------|---------|---------|--------|
| ubuntu-slim (Linux 1-core) | `linux_slim` | $0.002 | 1-core / 5 GB | 1-core / 5 GB |
| ubuntu-latest (Linux 2-core) | `linux` | $0.006 | 2-core / 7 GB | 4-core / 16 GB |
| windows-latest (Windows 2-core) | `windows` | $0.010 | 2-core / 7 GB | 4-core / 16 GB |
| macos-latest (macOS 3-core/4-core) | `macos` | $0.062 | 3-core / 7 GB | 3-core / 7 GB |

※ 課金は1分単位切り上げ。10秒のジョブでも1分として課金される。
※ public リポジトリでは Linux/Windows のスペックが private より高い (4-core / 16 GB)。かつ利用は無料・無制限。

参考:
- [GitHub Actions の課金について - Baseline minute costs](https://docs.github.com/ja/billing/concepts/product-billing/github-actions#baseline-minute-costs)
- [Actions Runner Pricing](https://docs.github.com/ja/billing/reference/actions-runner-pricing)
- [Standard GitHub-hosted runners for public repositories](https://docs.github.com/ja/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job#standard-github-hosted-runners-for-public-repositories)

## 運用フロー

```
1. [計測]  ./gha-cost-analyzer.sh --repos-file repos.txt
                ↓
2. [分析]  セクション4 の slim 移行候補を確認
                ↓
3. [移行]  変更対象を選定し、ubuntu-latest → ubuntu-slim に変更
                ↓
4. [検証]  ある程度動かしてから、再度 ./gha-cost-analyzer.sh → セクション5 の before/after 比較で効果確認
```

## API レート制限について

GitHub API のレート制限は 5,000 req/hour (認証済み)。
1 run あたり最低2回の API 呼び出しが必要なため、
大量のリポジトリ・run がある場合は取得期間を短くするか、`--parallel` を下げて対応する。

```bash
# レート残量の確認
gh api rate_limit --jq '.rate | "\(.remaining)/\(.limit) (reset: \(.reset | strftime("%H:%M:%S")))"'
```

## カスタム分析例

```sql
-- DuckDB でインタラクティブに分析
duckdb

-- jobs テーブルを読み込み
.read analyze.sql

-- 特定ワークフローの詳細
SELECT job_name, runner_label,
       COUNT(*) as runs,
       MEDIAN(duration_sec) as median_sec
FROM jobs
WHERE workflow_file = 'ci.yml'
GROUP BY 1, 2
ORDER BY runs DESC;

-- 失敗率が高いジョブ
SELECT job_name,
       COUNT(*) as total,
       SUM(CASE WHEN conclusion = 'failure' THEN 1 ELSE 0 END) as failures,
       ROUND(SUM(CASE WHEN conclusion = 'failure' THEN 1 ELSE 0 END)::DOUBLE / COUNT(*) * 100, 1) as fail_pct
FROM jobs
GROUP BY 1
HAVING COUNT(*) >= 10
ORDER BY fail_pct DESC;
```

## ubuntu-latest vs ubuntu-slim の違い

ubuntu-slim は単なるスペックダウンではなく、実行環境・プリインストールソフトウェアが大きく異なる。

| | ubuntu-latest | ubuntu-slim |
|---|---|---|
| 実行環境 | VM | コンテナ (共有 VM 上) |
| CPU / RAM (private) | 2-core / 7 GB | 1-core / 5 GB |
| 最大実行時間 | 6 時間 | **15 分** |
| ステータス | GA | GA |

### プリインストールソフトウェアの主な差異

| カテゴリ | ubuntu-latest | ubuntu-slim |
|---------|---|---|
| ブラウザ (Chrome, Firefox, Edge) | あり | **なし** |
| Java (8/11/17/21) | あり | **なし** |
| Go, Ruby, .NET, PHP, Rust | あり | **なし** |
| データベース (PostgreSQL, MySQL) | あり | **なし** |
| Android SDK / NDK | あり | **なし** |
| Docker CLI | あり | あり |
| Node.js, Python | あり | あり |
| Git, jq, curl | あり | あり |
| AWS / Azure / GCP CLI | あり | あり |

### 移行できないケース

- 実行時間が 15 分を超えるジョブ
- ブラウザテスト (Selenium, Playwright 等) を実行するジョブ
- Java, Go 等のランタイムが必要なビルドジョブ (別途インストールが必要)

### 参考
- [ubuntu-slim GA 発表](https://github.blog/changelog/2026-01-22-1-vcpu-linux-runner-now-generally-available-in-github-actions/)
- [ubuntu-latest イメージ仕様](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md)
- [ubuntu-slim イメージ仕様](https://github.com/actions/runner-images/blob/main/images/ubuntu-slim/ubuntu-slim-Readme.md)
