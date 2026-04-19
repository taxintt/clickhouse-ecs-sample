# MgBench Benchmark

[Brown University Benchmark (MgBench)](https://clickhouse.com/docs/getting-started/example-datasets/brown-benchmark) を利用した ClickHouse クラスターのベンチマーク環境。

## 前提条件

- ClickHouse クラスター（`logs_cluster`: 2 shard x 2 replica）がデプロイ済み
- CloudShell VPC 環境から ClickHouse ノードにアクセス可能
- 環境変数の設定:

```bash
export CH_HOST="clickhouse-shard1-replica1.logplatform.local"
export CH_PASSWORD="<clickhouse default password>"
```

## ディレクトリ構成

```
benchmark/
├── schema/
│   ├── mgbench_tables.sql           # MgBench 3テーブル (ReplicatedMergeTree + Distributed)
│   └── mgbench_tables_extended.sql  # 全文検索用 拡張テーブル (3パターン)
├── data/
│   ├── load_data.sh                 # 公式データセットのロード
│   ├── amplify_data.sh              # データ増幅 (数億レコード規模)
│   └── populate_extended.sh         # 全文検索用テーブルへのデータ投入
├── queries/
│   ├── mgbench_baseline.sql         # MgBench Q1.1-Q3.4 (14クエリ)
│   └── fulltext_search.sql          # 全文検索ベンチマーク (8クエリ)
├── run_benchmark.sh                 # SELECT 性能測定
├── run_insert_benchmark.sh          # INSERT 性能測定
├── run_fulltext_benchmark.sh        # 全文検索性能測定
└── results/                         # ベンチマーク結果 (TSV)
```

## データセット

MgBench は以下の3テーブルで構成される:

| テーブル | 内容 | カラム数 | 元データ行数 |
|---|---|---|---|
| `logs1` | システムメトリクス (CPU, メモリ, ディスク, ネットワーク) | 21 | ~22M |
| `logs2` | Web サーバーアクセスログ | 5 | ~18M |
| `logs3` | IoT センサーイベントログ | 8 | ~20M |

## 実行手順

### Phase 1: テーブル作成 & データロード

```bash
cd benchmark

# テーブル作成（1文ずつ実行）
grep -v '^--' schema/mgbench_tables.sql | grep -v '^$' | \
  tr '\n' ' ' | sed 's/;/;\n/g' | while IFS= read -r stmt; do
    stmt=$(echo "$stmt" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    if [ -n "$stmt" ]; then
      echo ">>> ${stmt:0:70}..."
      curl -s "http://${CH_HOST}:8123" --user "default:${CH_PASSWORD}" -d "${stmt}"
    fi
  done

# テーブル確認（6テーブル表示されること）
curl -s "http://${CH_HOST}:8123" --user "default:${CH_PASSWORD}" \
  -d "SHOW TABLES FROM mgbench FORMAT PrettyCompact"

# データロード（公式データセットからHTTP経由で取得）
./data/load_data.sh --host "$CH_HOST" --password "$CH_PASSWORD"
```

### Phase 2: SELECT 性能測定 (ベースライン)

MgBench 公式 14 クエリを cold run 1回 + warm run 3回で測定。

```bash
./run_benchmark.sh --host "$CH_HOST" --password "$CH_PASSWORD" --tag baseline
```

結果: `results/baseline_*.tsv`

### Phase 3: データ増幅 & 増幅後 SELECT 再測定

タイムスタンプシフト + 識別子サフィックスで2倍ずつ増幅。

```bash
# 1億レコード規模に増幅（30分〜1時間）
./data/amplify_data.sh --host "$CH_HOST" --password "$CH_PASSWORD" \
  --target-logs1 100000000 --target-logs2 100000000 --target-logs3 100000000

# 増幅後に SELECT 再測定
./run_benchmark.sh --host "$CH_HOST" --password "$CH_PASSWORD" --tag amplified
```

結果: `results/amplified_*.tsv`

### Phase 4: INSERT 性能測定

バッチ INSERT (`INSERT INTO ... SELECT`) と HTTP ストリーミング INSERT の速度を測定。

```bash
./run_insert_benchmark.sh --host "$CH_HOST" --password "$CH_PASSWORD"
```

- バッチ INSERT: 100万 / 1,000万 / 1億行
- HTTP ストリーミング: 10万 / 100万 / 1,000万行
- 結果: `results/insert_*.tsv`

### Phase 5: 全文検索性能測定

3パターンのインデックス × 8クエリパターンを比較。

```bash
# 拡張テーブル作成
grep -v '^--' schema/mgbench_tables_extended.sql | grep -v '^$' | \
  tr '\n' ' ' | sed 's/;/;\n/g' | while IFS= read -r stmt; do
    stmt=$(echo "$stmt" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    if [ -n "$stmt" ]; then
      echo ">>> ${stmt:0:70}..."
      curl -s "http://${CH_HOST}:8123" --user "default:${CH_PASSWORD}" -d "${stmt}"
    fi
  done

# raw_log カラム付きデータ投入
./data/populate_extended.sh --host "$CH_HOST" --password "$CH_PASSWORD"

# 全文検索ベンチマーク
./run_fulltext_benchmark.sh --host "$CH_HOST" --password "$CH_PASSWORD"
```

結果: `results/fulltext_*.tsv`

#### インデックスパターン

| パターン | インデックス | 得意な検索 |
|---|---|---|
| `noidx` | なし | ベースライン比較用 |
| `tokenbf` | `tokenbf_v1(32768, 3, 0)` | `hasToken()` による完全トークン一致 |
| `ngrambf` | `ngrambf_v1(4, 32768, 3, 0)` | `LIKE '%keyword%'` 等の部分文字列一致 |

#### 検索パターン (ft1-ft8)

| ID | 検索方法 | 説明 |
|---|---|---|
| ft1 | `LIKE '[ERROR]%'` | プレフィックス一致 |
| ft2 | `LIKE '%NullPointerException%'` | 部分一致 |
| ft3 | `hasToken(raw_log, 'ERROR')` | 完全トークン一致 |
| ft4 | `multiSearchAny(...)` | 複数キーワード検索 |
| ft5 | `positionCaseInsensitive(...)` | 大文字小文字無視 |
| ft6 | `match(raw_log, 'status=(4\|5)\\d{2}')` | 正規表現 |
| ft7 | `hasToken()` + 時間範囲 | 実運用パターン（エラーログ時系列） |
| ft8 | `multiSearchAny()` + 集計 | エラー種別分析 |

## 結果ファイルのフォーマット

すべての結果は TSV 形式で `results/` に保存される。

### SELECT / 全文検索ベンチマーク

```
query_id    run_type    run_num    elapsed_sec
q1.1        cold        1          0.385
q1.1        warm        1          0.017
```

### INSERT ベンチマーク

```
test_type      table    batch_size    elapsed_sec    rows_inserted    rows_per_sec
batch_insert   logs2    1000000       0.683          1000000          1462859
```

## トラブルシューティング

### REPLICA_ALREADY_EXISTS エラー

テーブル削除後に Keeper にメタデータが残る場合:

```bash
for pair in "01 1" "02 2"; do
  shard_id=${pair%% *}; shard_num=${pair##* }
  for n in 1 2; do
    curl -s "http://${CH_HOST}:8123" --user "default:${CH_PASSWORD}" \
      -d "SYSTEM DROP REPLICA 'clickhouse-shard${shard_num}-replica${n}' FROM ZKPATH '/clickhouse/tables/${shard_id}/<table_path>'"
  done
done
```

### CloudShell VPC 環境へのファイル転送

CloudShell VPC 環境ではコンソールからのファイルアップロード機能がないため、GitHub 経由で取得する:

```bash
git clone https://github.com/taxintt/clickhouse-ecs-sample.git
cd clickhouse-ecs-sample
git checkout feature/add-mgbench-benchmark
cd benchmark
```

## クリーンアップ

ベンチマーク完了後にデータを削除する場合:

```bash
curl -s "http://${CH_HOST}:8123" --user "default:${CH_PASSWORD}" \
  -d "DROP DATABASE IF EXISTS mgbench ON CLUSTER 'logs_cluster'"
```

# otel_logs

## Phase 1: CloudShell VPC環境でリポジトリ取得
```bash
git clone https://github.com/taxintt/clickhouse-ecs-sample.git
```

## Phase 2: 環境変数設定
```bash
export CH_HOST="clickhouse-shard1-replica1.logplatform.local"
export CH_PASSWORD="<clickhouse default password>"
```

## Phase 3: テーブル作成
```bash
grep -v '^--' schema/otel_logs_tables.sql | grep -v '^$' | \
  tr '\n' ' ' | sed 's/;/;\n/g' | while IFS= read -r stmt; do
    stmt=$(echo "$stmt" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    if [ -n "$stmt" ]; then
      echo ">>> ${stmt:0:70}..."
      curl -s "http://${CH_HOST}:8123" --user "default:${CH_PASSWORD}" -d "${stmt}"
    fi
  done
```

## Phase 4: テーブル確認
```bash
curl -s "http://${CH_HOST}:8123" --user "default:${CH_PASSWORD}" \
  -d "SHOW TABLES FROM otel FORMAT PrettyCompact"
```

## Phase 5: データ投入（1000万行）
```bash
./data/load_otel_data.sh --host "$CH_HOST" --password "$CH_PASSWORD" --rows 10000000
```

## Phase 6: 測定
```bash
./measure_s3_storage.sh --host "$CH_HOST" --password "$CH_PASSWORD" --tag baseline
```

## Phase 7: AWS CLI側クロスチェック（S3バケット名はterraform outputで確認）
```bash
aws s3 ls --summarize --recursive s3://<bucket>/clickhouse/
```

## Phase 8: クリーンアップ
```bash
curl -s "http://${CH_HOST}:8123" --user "default:${CH_PASSWORD}" \
  -d "DROP DATABASE IF EXISTS otel ON CLUSTER 'logs_cluster'"
```