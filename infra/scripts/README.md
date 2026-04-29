# Operational Scripts — Usage Guide

ClickHouse on ECS の運用タスクを自動化するためのシェルスクリプト群。

## スクリプト一覧

| スクリプト | 用途 | 影響範囲 |
|---|---|---|
| `rolling-update.sh` | ECS タスクの再デプロイ（新Dockerイメージ反映） | ECSタスクのみ。EC2は再利用 |
| `instance-refresh.sh` | EC2 インスタンスを置換（AMI/タイプ/EBS変更） | ASG / EC2 / ECSタスク |
| `rebalance-shard.sh` | シャード追加後のテナント単位データ再分配 | ClickHouse データ本体 |
| `deploy.sh` | 既存：ECRビルド & プッシュ | ECRイメージ |
| `health-check.sh` | 既存：クラスタ状態の簡易確認 | 読み取りのみ |

---

## 共通環境変数

| 変数 | デフォルト | 説明 |
|---|---|---|
| `PROJECT` | `logplatform` | Terraform `var.project` と一致させる |
| `ENVIRONMENT` | `dev` | `dev` / `prod` |
| `AWS_REGION` | `ap-northeast-1` | |
| `CH_PASSWORD` | （必須） | `default` ユーザのパスワード。Secrets Managerから取得して環境変数にエクスポートする |
| `DRY_RUN` | `false` | `true`で書き込みなし（プラン確認のみ） |

### CH_PASSWORD の取得例

```bash
export CH_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$(aws secretsmanager list-secrets \
      --query 'SecretList[?starts_with(Name, `logplatform/dev/clickhouse-credentials-`)].Name | [0]' \
      --output text)" \
  --query SecretString --output text | jq -r .default_password)
```

### 実行環境の前提

スクリプトは ClickHouse の Service Discovery FQDN（`*.logplatform.local`）を解決できる場所から実行する必要がある。

- **VPC内のbastion EC2** から実行
- **CloudShell の VPC モード**
- **AWS Systems Manager Session Manager** 経由でbastionに入る

ローカル端末からは到達不能（Private DNS のため）。

---

## シナリオ 1: ECS AMI のセキュリティパッチ適用

**頻度**: 月次〜四半期 | **影響**: ECS Optimized AMI を最新化、各 EC2 を入れ替え

### 手順

1. **Terraform で AMI を最新化**

   `data.aws_ssm_parameter.ecs_ami_arm64` は `recommended` を参照しているため、`terraform apply` で Launch Template の新バージョンが作られる。

   ```bash
   cd infra/terraform
   terraform plan
   terraform apply
   ```

   この時点では既存 EC2 は古い AMI のまま。

2. **DRY_RUN で影響範囲を確認**

   ```bash
   DRY_RUN=true ./infra/scripts/instance-refresh.sh all
   ```

3. **業務時間外に ClickHouse を先に入れ替え**

   ClickHouse は1ラウンドあたり2ノード並列、計2ラウンド。各ラウンドで replication queue / lag / readonly チェックが入る。

   ```bash
   CH_PASSWORD=xxx ./infra/scripts/instance-refresh.sh clickhouse
   ```

   所要時間目安: 各ノードのASG instance-refresh が約5-10分 × 2ラウンド ≒ 20-30分。

4. **Keeper を1台ずつ入れ替え**

   quorum を維持するため逐次実行。

   ```bash
   ./infra/scripts/instance-refresh.sh keeper
   ```

   所要時間目安: 5-10分 × 3台 ≒ 15-30分。

5. **検証**

   - スクリプト末尾の `Cluster version report` で全ノードの`SELECT version()`を確認
   - `system.replicas`にreadonlyレプリカがないこと
   - サンプルクエリでDistributedテーブルの行数を確認

### NVMe キャッシュの扱い

EC2 置換でインスタンスストア NVMe は消失するため、新インスタンスは **コールドスタート**となる。S3 からの初回読み込みが遅いのは想定内。

---

## シナリオ 2: インスタンスタイプ変更

**頻度**: 年1-2回 | **影響**: r6gd.4xlarge → r7gd.4xlarge など

### 手順

1. **Terraform でインスタンスタイプを変更**

   ```hcl
   # variables.tf or terraform.tfvars
   clickhouse_instance_type = "r7gd.4xlarge"
   ```

   ```bash
   terraform apply
   ```

2. **dev 環境で全体検証**

   ```bash
   ENVIRONMENT=dev DRY_RUN=true ./infra/scripts/instance-refresh.sh all
   ENVIRONMENT=dev CH_PASSWORD=xxx ./infra/scripts/instance-refresh.sh all
   ```

3. **本番は1ノードからカナリア実行**

   ```bash
   ENVIRONMENT=prod CH_PASSWORD=xxx ./infra/scripts/instance-refresh.sh clickhouse --only s1r1
   ```

   - 24-48時間の様子見（QPS/p99 latency/replication lag）
   - 問題なければ全体実施

4. **本番全体実施**

   ```bash
   ENVIRONMENT=prod CH_PASSWORD=xxx ./infra/scripts/instance-refresh.sh all
   ```

### NVMe 容量変更時の注意

`r7gd.4xlarge` の NVMe は `r6gd.4xlarge` と容量が異なる。`storage_policy` の `move_factor` などキャッシュ前提のチューニングをしている場合は再評価する。

---

## シナリオ 3: EBS / Launch Template 設定変更

**頻度**: ad-hoc | **影響**: ルートEBSサイズ、user_data、IAMプロファイル変更時

EBS データ用ボリュームは Keeper のみ（gp3、20GB）。ClickHouse のデータ本体は S3 にあるためノード置換で失われない。

### 手順

```bash
# 1. Terraform で対象を変更（user_data / iam_instance_profile / ルートEBSなど）
terraform apply

# 2. instance-refresh で全置換
CH_PASSWORD=xxx ./infra/scripts/instance-refresh.sh all
```

### Keeper EBS のスナップショット

Keeper の EBS（`/mnt/keeper-data`）は ZooKeeper メタデータを保持する。Keeper instance-refresh 前にスナップショット取得を推奨:

```bash
for id in 1 2 3; do
  vol_id=$(aws ec2 describe-volumes \
    --filters "Name=tag:KeeperNode,Values=${id}" \
    --query 'Volumes[0].VolumeId' --output text)
  aws ec2 create-snapshot --volume-id "${vol_id}" \
    --description "pre-refresh keeper-${id} $(date +%Y%m%d)"
done
```

---

## シナリオ 4: シャード追加とデータ再分配（2 → 3 シャード）

**頻度**: ストレージ・CPU逼迫時 | **影響**: 中程度〜大（書き込み停止が必要）

### 全体フロー

```
[1] Terraform で新シャード追加
  └─ s3r1, s3r2 のASG/EC2/ECSサービスが起動
[2] 新シャードのヘルス確認 + remote_servers.xml の3シャード化
[3] アプリ側の書き込みを停止 or 一時バッファ化
[4] DRY_RUN で再分配プラン作成
[5] 再分配実行
[6] 整合性検証 → 書き込み再開
[7] 任意: OPTIMIZE TABLE FINAL
```

### 手順詳細

#### 4.1 新シャードのプロビジョニング

`infra/terraform/ecs_cluster.tf` の `clickhouse_nodes` に追加:

```hcl
locals {
  clickhouse_nodes = {
    "s1r1" = { shard = "01", replica = "clickhouse-shard1-replica1", az_index = 0 }
    "s1r2" = { shard = "01", replica = "clickhouse-shard1-replica2", az_index = 1 }
    "s2r1" = { shard = "02", replica = "clickhouse-shard2-replica1", az_index = 0 }
    "s2r2" = { shard = "02", replica = "clickhouse-shard2-replica2", az_index = 1 }
    "s3r1" = { shard = "03", replica = "clickhouse-shard3-replica1", az_index = 2 }  # 追加
    "s3r2" = { shard = "03", replica = "clickhouse-shard3-replica2", az_index = 0 }  # 追加
  }
}
```

`infra/clickhouse/config/remote_servers.xml` に3つ目のshardブロックを追加して、Dockerイメージを再ビルド・プッシュ・タスク再デプロイ:

```bash
./infra/scripts/deploy.sh
CH_PASSWORD=xxx ./infra/scripts/rolling-update.sh clickhouse
```

#### 4.2 スキーマを新シャードに伝播

```sql
-- ON CLUSTER で全シャードに適用
CREATE DATABASE IF NOT EXISTS logs ON CLUSTER 'logs_cluster';
CREATE TABLE IF NOT EXISTS logs.logs_local ON CLUSTER 'logs_cluster' (...) ENGINE = ReplicatedMergeTree(...);
CREATE TABLE IF NOT EXISTS logs.logs ON CLUSTER 'logs_cluster' (...) ENGINE = Distributed('logs_cluster', 'logs', 'logs_local', sipHash64(tenant_id));
```

#### 4.3 書き込みを一時停止

アプリ側のINSERTパイプラインを止める。`rebalance-shard.sh`はサーバの`InsertedRows`をサンプリングして`WRITE_RATE_THRESHOLD=10/sec`を超えると abort する。

#### 4.4 DRY_RUN でプラン確認

```bash
CH_PASSWORD=xxx \
NEW_SHARD_COUNT=3 \
DRY_RUN=true \
./infra/scripts/rebalance-shard.sh
```

出力例:

```
Cluster topology confirmed: 3 shards
Sharding key verified: sipHash64(tenant_id)
Observed write rate: 0 inserts/sec
Querying shard 1 via clickhouse-shard1-replica1.logplatform.local...
Querying shard 2 via clickhouse-shard2-replica1.logplatform.local...
Querying shard 3 via clickhouse-shard3-replica1.logplatform.local...
Rebalance plan: /var/tmp/rebalance-plan-20260425-103000.tsv
  tenants to move: 47
  rows to move:    382194810
```

`/var/tmp/rebalance-plan-*.tsv` を目視で確認:

```
tenant-foo	1	3	5234511
tenant-bar	2	3	1098234
...
```

(tenant_id, src_shard, dst_shard, row_count)

#### 4.5 実行

```bash
CH_PASSWORD=xxx NEW_SHARD_COUNT=3 ./infra/scripts/rebalance-shard.sh
```

各テナントについて以下を実行:
1. `INSERT INTO ... FROM cluster('logs_cluster', ...) WHERE _shard_num={src} AND tenant_id={tid}` (insert_quorum=2)
2. `SYSTEM SYNC REPLICA` （src 側両レプリカの同期）
3. `SELECT count()` で src/dst 行数照合
4. `DELETE FROM ... WHERE tenant_id={tid} SETTINGS mutations_sync=2`
5. state file に記録

#### 4.6 失敗時のレジューム

進捗は `/var/tmp/rebalance-state-<timestamp>.log` に追記される。中断した場合:

```bash
CH_PASSWORD=xxx NEW_SHARD_COUNT=3 \
./infra/scripts/rebalance-shard.sh \
  --resume /var/tmp/rebalance-state-20260425-103000.log
```

state file の `DONE` 行に該当する tenant はスキップされる。

#### 4.7 整合性検証

```sql
-- 全シャードの行数（Distributed経由）
SELECT count() FROM logs.logs;

-- シャード別分布
SELECT
  shardNum() AS shard,
  count() AS rows
FROM clusterAllReplicas('logs_cluster', logs.logs_local)
GROUP BY shard
ORDER BY shard;

-- 想定: 各シャードがほぼ均等（テナント分布次第）
```

#### 4.8 書き込みを再開

#### 4.9 任意: 物理的な掃除

lightweight DELETE は論理削除のため、parts に削除マーカが残る。古いシャードのストレージ効率を上げたい場合:

```sql
OPTIMIZE TABLE logs.logs_local ON CLUSTER 'logs_cluster' FINAL;
```

ただし大規模パーティションで CPU/IO 負荷が大きいため、業務時間外に実施。

---

## シナリオ 5: TTL自然減衰による「待ちアプローチ」

**頻度**: シャード追加時の代替案 | **影響**: 30日かけて段階的に再分散

`rebalance-shard.sh` を使わず、新シャードに新規書き込みを偏らせて TTL（30日）で旧シャードのデータを自然消滅させる方法。

### メリット
- 書き込み停止不要
- スクリプト不要
- データ移動リスクなし

### デメリット
- 完全均衡まで30日
- 即座のストレージ・CPU逼迫緩和には使えない

### 手順

`remote_servers.xml` で新シャードに `<weight>` を高めに設定:

```xml
<shard>
  <weight>1</weight>  <!-- 既存shard -->
  ...
</shard>
<shard>
  <weight>1</weight>
  ...
</shard>
<shard>
  <weight>3</weight>  <!-- 新shard、新規書き込みの3/5を引き受ける -->
  ...
</shard>
```

新規行の `sipHash64(tenant_id) % sum(weights)` で新シャードに3/5、既存に1/5ずつ。30日後に再評価して `<weight>1</weight>` に戻す。

> **注意**: weight=3にする場合、`rebalance-shard.sh` の `verify_sharding_key` チェックが weight 統一性違反で abort する。アプローチ間の併用はできない。

---

## シナリオ 6: 単発のローリングデプロイ（コード変更時）

**頻度**: 都度 | **影響**: ECSタスクのみ（EC2は触らない）

ClickHouse の設定（`config.xml` / `users.xml`）や Dockerfile を変更してイメージを再ビルドした場合:

```bash
# 1. 新イメージをECRへプッシュ
./infra/scripts/deploy.sh

# 2. ローリングで再デプロイ（既存EC2上で新タスクが起動）
DRY_RUN=true ./infra/scripts/rolling-update.sh all
CH_PASSWORD=xxx ./infra/scripts/rolling-update.sh all
```

**`instance-refresh.sh` との使い分け:**

| 変更内容 | 使うスクリプト |
|---|---|
| ClickHouse config / Dockerfile / アプリ更新 | `rolling-update.sh` |
| AMI / instance type / EBS / user_data | `instance-refresh.sh` |

---

## シナリオ 7: トラブルシューティング

### 7.1 instance-refresh が中途半端に止まった

旧インスタンスが既に停止し、新インスタンスは起動したが ECS タスクが配置されていない状態。

**確認:**
```bash
aws ecs describe-services \
  --cluster logplatform-dev \
  --services logplatform-dev-ch-s1r1 \
  --query 'services[0].{desired:desiredCount,running:runningCount,events:events[0:3]}'
```

**復旧:**
- ECS イベントを見て、`placement_constraints` の不整合（`clickhouse_node` 属性の不在）が原因なら、新EC2のuser_data出力を確認
- 必要なら instance-refresh をrerun（idempotent）:
  ```bash
  ./infra/scripts/instance-refresh.sh clickhouse --only s1r1
  ```

### 7.2 rebalance 中に readonly replica が出た

Keeper への書き込みが詰まると ReplicatedMergeTree が一時的に readonly になる。

**確認:**
```sql
SELECT database, table, replica_name, is_readonly, absolute_delay
FROM system.replicas
WHERE is_readonly = 1;
```

**対応:**
- `rebalance-shard.sh` は `verify_tenant_counts` 失敗時に dst 側ロールバックして abort する
- Keeper の状況確認: `echo mntr | nc keeper-1.logplatform.local 9181`
- Keeper quorum が健全になってから `--resume` で再開

### 7.3 instance-refresh の status を直接見たい

```bash
aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name logplatform-dev-ch-s1r1 \
  --query 'InstanceRefreshes[0].{Status:Status,Pct:PercentageComplete,Reason:StatusReason}'
```

### 7.4 emergency: instance-refresh をキャンセル

```bash
aws autoscaling cancel-instance-refresh \
  --auto-scaling-group-name logplatform-dev-ch-s1r1
```

スクリプト側は `Cancelled` を検知して abort する。

---

## 環境変数チューニング

| 変数 | デフォルト | 推奨 | 用途 |
|---|---|---|---|
| `HEALTH_TIMEOUT` | 300 | 600（大規模） | health/replication queue/lag のpolling上限 |
| `QUERY_DRAIN_TIMEOUT` | 120 | 300（重いクエリ） | in-flightクエリ完了待ち |
| `REPLICATION_LAG_THRESHOLD` | 10 | 5（厳しめ） | 次ノード進行の許容lag (秒) |
| `INSTANCE_REFRESH_TIMEOUT` | 1200 | 1800（NVMeフォーマット長め） | ASG instance-refresh 全体の上限 |
| `INSERT_QUORUM_TIMEOUT_MS` | 600000 | 大テナントは1800000 | INSERT で両レプリカ確認待ち |
| `MUTATION_SYNC_TIMEOUT` | 600 | 大テナントは1800 | DELETE mutation の伝播待ち |
| `WRITE_RATE_THRESHOLD` | 10 | 0（厳格） | rebalance時のwrite rate上限 |

---

## トポロジ自動discoveryと2レプリカ整合性ガード

### CH_NODES の動的discovery

`rolling-update.sh` / `instance-refresh.sh` / `rebalance-shard.sh` は起動時に `system.clusters` から実際のシャード/レプリカ構成を読み取り、`CH_NODES` / `CH_ROUND_1` / `CH_ROUND_2` を上書きする。これによりシャード追加（s3r1, s3r2 など）後も自動でカバーされる。

- bootstrap: `s1r1` (canonical) で coordinator到達確認 → `discover_ch_topology` を呼び出し
- 失敗時のフォールバック:
  - `rolling-update.sh` / `instance-refresh.sh`: 静的デフォルト（s1r1〜s2r2）+ warning
  - `rebalance-shard.sh`: **abort**（rebalance correctness が完全な topology に依存するため）
- skip条件: `DRY_RUN=true` または `CH_PASSWORD` 未設定時は静的デフォルトを使用

### `rebalance-shard.sh` の2レプリカ整合性ガード

データ移動でレプリカ間の不整合に起因する**データロス**を防ぐため、`move_tenant` フローに以下を組み込んでいる:

```
[1] require_zero_lag_on_shard(src/dst)          # absolute_delay = 0 を全レプリカで確認
[2] sync_all_replicas_for_shard(src)            # SYSTEM SYNC REPLICA を src の全レプリカに発行
[3] copy_tenant: INSERT FROM cluster(...)       # insert_quorum=2 で dst 両レプリカ確定
[4] sync_all_replicas_for_shard(src) + (dst)    # post-copy で再度全レプリカ同期
[5] verify_tenant_counts(src, dst)              # 全レプリカで count() を取り、相互一致を確認
[6] DELETE FROM src WHERE tid SETTINGS mutations_sync = 2
```

`verify_tenant_counts` は `src_shard` と `dst_shard` の **全レプリカ** に対して `count()` を実行し、

1. src 内のレプリカ間で count が一致していること
2. dst 内のレプリカ間で count が一致していること
3. src と dst の count が一致していること

の3条件を全て満たさない場合は dst 側の挿入をロールバックして abort する。これにより `cluster()` が片側レプリカのみから読んだ際の divergence をDELETE前に検出できる。

---

## ライブラリ構成

```
infra/scripts/
├── instance-refresh.sh       # EC2置換
├── rebalance-shard.sh        # データ再分配
├── rolling-update.sh         # ECSタスク再デプロイ
├── deploy.sh / health-check.sh  # 既存
└── lib/
    ├── common.sh             # log/abort/dry_run_guard
    ├── ch-cluster-lib.sh     # ch_query / ch_query_strict / ch_query_param / health / drain
    ├── keeper-lib.sh         # quorum / znode
    └── asg-lib.sh            # ASG instance-refresh / ECS container instance待ち
```

`source` チェーン: 各メインスクリプトが `lib/common.sh` → `lib/keeper-lib.sh` → `lib/ch-cluster-lib.sh` (+ asg-libは instance-refresh のみ)。

---

## チェックリスト（本番実行前）

### instance-refresh.sh

- [ ] Terraform `apply` で Launch Template 新バージョンが反映済み
- [ ] DRY_RUN で対象ノードが意図通りか確認済み
- [ ] dev環境で `--only s1r1` POC 実施済み
- [ ] `CH_PASSWORD` を Secrets Manager から正しく取得済み
- [ ] 業務時間外（または通知済み）
- [ ] `system.replicas` に readonly レプリカが無いことを事前確認

### rebalance-shard.sh

- [ ] 新シャードの ECS サービスが Healthy
- [ ] `remote_servers.xml` に新シャード定義が反映され、全ノードでロード済み
- [ ] スキーマ（`ON CLUSTER`）が新シャードに伝播済み
- [ ] アプリ側 INSERT を停止済み（または `WRITE_RATE_THRESHOLD` で検知される状態）
- [ ] `DRY_RUN=true` で生成されたプランファイルを目視レビュー済み
- [ ] state file の保管先（`REBALANCE_STATE_DIR`）が永続的（`/tmp` ではなく `/var/tmp` 推奨）
- [ ] 失敗時の連絡先・ロールバック責任者を決定済み
