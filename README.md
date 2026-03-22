# ClickHouse on ECS サンプル

ClickHouseクラスター（2 shard x 2 replica）をECS on EC2上に構築するサンプル。

## 前提条件

- Terraform >= 1.10.0
- AWS CLI (プロファイル設定済み)
- Docker（ECRイメージプッシュ用）

## デプロイ手順

### 1. Terraform変数の準備

```bash
cd infra/terraform
```

`terraform.tfvars`に以下を設定する（ファイルは`.gitignore`済み）:

```hcl
environment                  = "dev"
aws_profile                  = "<your-profile>"
aws_region                   = "ap-northeast-1"
vpc_cidr                     = "10.0.0.0/16"
availability_zones           = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]
clickhouse_default_password  = "<strong-password>"
clickhouse_readonly_password = "<strong-password>"
```

### 2. Terraform Init & Apply

```bash
terraform init
terraform plan
terraform apply
```

Apply後にoutputsが表示される。以降の手順で使う値:

```bash
# 主要なoutputを確認
terraform output vpc_id
terraform output private_subnet_ids
terraform output ecr_repository_urls
terraform output cloudshell_security_group_id
terraform output clickhouse_fqdns
```

### 3. ECRイメージのビルドとプッシュ

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=ap-northeast-1
ECR_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# ECRログイン
aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin ${ECR_BASE}

# ClickHouseイメージ（ECSノードはARM64のため --platform を指定）
docker build --platform linux/arm64 -t ${ECR_BASE}/logplatform-dev/clickhouse:latest \
  -f infra/clickhouse/Dockerfile infra/clickhouse/
docker push ${ECR_BASE}/logplatform-dev/clickhouse:latest

# Keeperイメージ
docker build --platform linux/amd64 -t ${ECR_BASE}/logplatform-dev/clickhouse-keeper:latest \
  -f infra/clickhouse/Dockerfile.keeper infra/clickhouse/
docker push ${ECR_BASE}/logplatform-dev/clickhouse-keeper:latest
```

### 4. ECSサービスの起動確認

```bash
CLUSTER=logplatform-dev

# Keeperサービスの状態確認（先に起動している必要がある）
aws ecs describe-services \
  --cluster ${CLUSTER} \
  --services logplatform-dev-keeper-1 logplatform-dev-keeper-2 logplatform-dev-keeper-3 \
  --query 'services[].{name:serviceName,running:runningCount,desired:desiredCount}' \
  --output table

# ClickHouseサービスの状態確認
aws ecs describe-services \
  --cluster ${CLUSTER} \
  --services logplatform-dev-ch-s1r1 logplatform-dev-ch-s1r2 logplatform-dev-ch-s2r1 logplatform-dev-ch-s2r2 \
  --query 'services[].{name:serviceName,running:runningCount,desired:desiredCount}' \
  --output table
```

全サービスの`runningCount`が`1`になるまで待つ。

### 5. CloudShell VPCからの動作確認

AWSコンソールからCloudShell VPC環境を使って、VPC内のClickHouseに直接アクセスする。

#### 5-1. CloudShell VPC環境の作成

AWSコンソール > CloudShell を開き、VPC環境を作成する:

- **VPC**: `terraform output vpc_id` の値
- **Subnet**: `terraform output private_subnet_ids` のいずれか
- **Security Group**: `terraform output cloudshell_security_group_id` の値

#### 5-2. ClickHouseへの接続確認

CloudShell VPC環境で以下を実行する。

```bash
# ClickHouseのFQDN（Service Discovery経由）
CH_HOST="clickhouse-shard1-replica1.logplatform.local"
CH_PASSWORD="<terraform.tfvarsで設定したdefaultパスワード>"

# Ping確認
curl -sf "http://${CH_HOST}:8123/ping"
# 期待結果: Ok.

# バージョン確認
curl -sf "http://${CH_HOST}:8123" \
  --user "default:${CH_PASSWORD}" \
  --data "SELECT version()"
# 期待結果: 24.8.x.x

# クラスター構成確認
curl -sf "http://${CH_HOST}:8123" \
  --user "default:${CH_PASSWORD}" \
  --data "SELECT cluster, shard_num, replica_num, host_name FROM system.clusters WHERE cluster = 'logs_cluster' FORMAT PrettyCompact"
# 期待結果: 2 shards x 2 replicas = 4行

# Keeper接続確認
curl -sf "http://${CH_HOST}:8123" \
  --user "default:${CH_PASSWORD}" \
  --data "SELECT * FROM system.zookeeper WHERE path = '/' LIMIT 3 FORMAT PrettyCompact"
# エラーなく結果が返ればKeeper接続OK

# レプリケーション状態確認
curl -sf "http://${CH_HOST}:8123" \
  --user "default:${CH_PASSWORD}" \
  --data "SELECT count() as queue_size FROM system.replication_queue"
# 期待結果: 0（または小さな数値）

# ストレージディスク確認（S3 + キャッシュ）
curl -sf "http://${CH_HOST}:8123" \
  --user "default:${CH_PASSWORD}" \
  --data "SELECT name, type, path FROM system.disks FORMAT PrettyCompact"
# 期待結果: s3, s3_cache, default の3ディスクが表示
```

#### 5-3. テーブル作成

スキーマ定義（`infra/clickhouse/schema/logs.sql`）を順番に実行する。
`ON CLUSTER` 句により、1ノードに対して実行すれば全ノードに反映される。

> **Note**: 再デプロイ後にテーブル作成で `REPLICA_ALREADY_EXISTS` エラーが出る場合は、
> Keeperにレプリカメタデータが残っている。以下でクリーンアップしてから再作成する:
>
> ```bash
> # Keeperからレプリカメタデータを削除
> for pair in "01 1" "02 2"; do
>   shard_id=${pair%% *}; shard_num=${pair##* }
>   for n in 1 2; do
>     curl -sf "http://${CH_HOST}:8123" \
>       --user "default:${CH_PASSWORD}" \
>       --data "SYSTEM DROP REPLICA 'clickhouse-shard${shard_num}-replica${n}' FROM ZKPATH '/clickhouse/tables/${shard_id}/logs_local'"
>   done
> done
> ```

```bash
# データベース作成
curl -sf "http://${CH_HOST}:8123" \
  --user "default:${CH_PASSWORD}" \
  --data "CREATE DATABASE IF NOT EXISTS logs ON CLUSTER 'logs_cluster'"

# ローカルテーブル作成（ReplicatedMergeTree）
curl -sf "http://${CH_HOST}:8123" \
  --user "default:${CH_PASSWORD}" \
  --data "
CREATE TABLE IF NOT EXISTS logs.logs_local ON CLUSTER 'logs_cluster'
(
    tenant_id    String,
    timestamp    DateTime64(3),
    trace_id     String DEFAULT '',
    span_id      String DEFAULT '',
    severity     Enum8('TRACE'=0, 'DEBUG'=1, 'INFO'=2, 'WARN'=3, 'ERROR'=4, 'FATAL'=5),
    service      LowCardinality(String),
    host         LowCardinality(String),
    message      String,
    attributes   Map(String, String),
    resource     Map(String, String),
    INDEX idx_message message TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 1,
    INDEX idx_trace_id trace_id TYPE bloom_filter(0.01) GRANULARITY 1
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/logs_local',
    '{replica}'
)
PARTITION BY (tenant_id, toYYYYMM(timestamp))
ORDER BY (tenant_id, service, severity, timestamp)
TTL toDateTime(timestamp) + INTERVAL 30 DAY DELETE
SETTINGS
    storage_policy = 's3_policy',
    index_granularity = 8192,
    ttl_only_drop_parts = 1
"

# Distributedテーブル作成（クロスシャードクエリ用）
curl -sf "http://${CH_HOST}:8123" \
  --user "default:${CH_PASSWORD}" \
  --data "
CREATE TABLE IF NOT EXISTS logs.logs ON CLUSTER 'logs_cluster'
(
    tenant_id    String,
    timestamp    DateTime64(3),
    trace_id     String DEFAULT '',
    span_id      String DEFAULT '',
    severity     Enum8('TRACE'=0, 'DEBUG'=1, 'INFO'=2, 'WARN'=3, 'ERROR'=4, 'FATAL'=5),
    service      LowCardinality(String),
    host         LowCardinality(String),
    message      String,
    attributes   Map(String, String),
    resource     Map(String, String)
)
ENGINE = Distributed('logs_cluster', 'logs', 'logs_local', sipHash64(tenant_id))
"

# テーブル作成の確認
curl -sf "http://${CH_HOST}:8123" \
  --user "default:${CH_PASSWORD}" \
  --data "SHOW TABLES FROM logs FORMAT PrettyCompact"
# 期待結果: logs_local, logs
```

#### 5-4. データの挿入・読み取り・更新・削除

```bash
# INSERT: テストデータの挿入（Distributedテーブル経由）
curl -sf "http://${CH_HOST}:8123" \
  --user "default:${CH_PASSWORD}" \
  --data "INSERT INTO logs.logs (tenant_id, timestamp, severity, service, host, message) VALUES ('test-tenant', now(), 'INFO', 'api', 'host-1', 'Hello ClickHouse')"

# SELECT: データの読み取り確認
curl -sf "http://${CH_HOST}:8123" \
  --user "default:${CH_PASSWORD}" \
  --data "SELECT * FROM logs.logs WHERE tenant_id = 'test-tenant' FORMAT PrettyCompact"

# SELECT: 別シャードのノードからも読めることを確認（Distributedテーブル）
CH_HOST2="clickhouse-shard2-replica1.logplatform.local"
curl -sf "http://${CH_HOST2}:8123" \
  --user "default:${CH_PASSWORD}" \
  --data "SELECT * FROM logs.logs WHERE tenant_id = 'test-tenant' FORMAT PrettyCompact"

# UPDATE: メッセージを更新（ClickHouseではALTER TABLE ... UPDATE を使う）
curl -sf "http://${CH_HOST}:8123" \
  --user "default:${CH_PASSWORD}" \
  --data "ALTER TABLE logs.logs_local ON CLUSTER 'logs_cluster' UPDATE message = 'Updated message' WHERE tenant_id = 'test-tenant'"

# 更新結果の確認（mutationは非同期のため少し待つ）
sleep 3
curl -sf "http://${CH_HOST}:8123" \
  --user "default:${CH_PASSWORD}" \
  --data "SELECT * FROM logs.logs WHERE tenant_id = 'test-tenant' FORMAT PrettyCompact"

# DELETE: テストデータの削除
curl -sf "http://${CH_HOST}:8123" \
  --user "default:${CH_PASSWORD}" \
  --data "ALTER TABLE logs.logs_local ON CLUSTER 'logs_cluster' DELETE WHERE tenant_id = 'test-tenant'"
```

> **Note**: ClickHouseのUPDATE/DELETEは「mutation」として非同期に実行される。
> 分析ワークロード向けのため、頻繁な行単位の更新には向かない。

## ディレクトリ構成

```
infra/
├── terraform/
│   ├── main.tf              # Provider, backend
│   ├── variables.tf         # 変数定義
│   ├── terraform.tfvars     # 環境固有値（.gitignore）
│   ├── outputs.tf           # 出力値
│   ├── networking.tf        # VPC, SG
│   ├── iam.tf               # IAMロール, ポリシー
│   ├── s3.tf                # S3バケット
│   ├── ecr.tf               # ECRリポジトリ
│   ├── kinesis.tf           # Kinesis Data Streams
│   ├── service_discovery.tf # Cloud Map
│   ├── ecs_cluster.tf       # ECSクラスター, EC2, ASG
│   ├── ecs_keeper.tf        # Keeper ECSサービス
│   ├── ecs_clickhouse.tf    # ClickHouse ECSサービス
│   ├── alb_nlb.tf           # ALB
│   └── templates/
│       ├── clickhouse_user_data.sh
│       └── keeper_user_data.sh
├── clickhouse/
│   ├── Dockerfile           # ClickHouseサーバーイメージ
│   ├── Dockerfile.keeper    # Keeperイメージ
│   ├── config/              # XML設定（全値from_envで外部注入）
│   └── schema/
│       └── logs.sql         # テーブル定義
└── scripts/
    ├── deploy.sh            # デプロイスクリプト（ECS/EKS抽象化）
    └── health-check.sh      # ヘルスチェック
```
