#!/usr/bin/env bash
# =============================================================================
# 01-schema-and-full-load.sh
# Step 1: copy schema (DMS does not create secondary indexes/FKs/triggers well)
# Step 2: create DMS infra + start FULL LOAD + CDC (full-load-and-cdc)
#
# Required env (export before running; no secrets in this file):
#   SRC_HOST, SRC_PORT, SRC_DMS_SECRET_ARN   on-prem source + DMS user secret
#   TGT_HOST, TGT_ADMIN_SECRET_ARN           RDS endpoint + RDS-managed admin secret
#   DMS_SUBNET_IDS, DMS_SG_ID                private subnets / SG with route to both sides
#   AWS_REGION
# =============================================================================
set -euo pipefail

: "${SRC_HOST:?}" "${TGT_HOST:?}" "${SRC_DMS_SECRET_ARN:?}" "${TGT_ADMIN_SECRET_ARN:?}"
: "${DMS_SUBNET_IDS:?}" "${DMS_SG_ID:?}" "${AWS_REGION:=ap-south-1}"
SRC_PORT="${SRC_PORT:-3306}"
DIR="$(cd "$(dirname "$0")" && pwd)"

secret() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text; }

SRC_USER=$(secret "$SRC_DMS_SECRET_ARN" | jq -r .username)
SRC_PASS=$(secret "$SRC_DMS_SECRET_ARN" | jq -r .password)
TGT_USER=$(secret "$TGT_ADMIN_SECRET_ARN" | jq -r .username)
TGT_PASS=$(secret "$TGT_ADMIN_SECRET_ARN" | jq -r .password)

echo "==> [1/6] Dump schema only (routines, triggers, events) from the source replica"
mysqldump -h "$SRC_HOST" -P "$SRC_PORT" -u "$SRC_USER" -p"$SRC_PASS" \
  --ssl-mode=REQUIRED \
  --no-data --routines --triggers --events --single-transaction \
  --set-gtid-purged=OFF \
  --databases orders inventory payment > "$DIR/schema.sql"

# MySQL 5.7 -> 8.0: normalise the default collation of 5.7 dumps
sed -i 's/utf8mb4_general_ci/utf8mb4_0900_ai_ci/g; s/NO_AUTO_CREATE_USER,\?//g' "$DIR/schema.sql"

echo "==> [2/6] Apply schema on RDS (TLS enforced)"
mysql -h "$TGT_HOST" -u "$TGT_USER" -p"$TGT_PASS" --ssl-mode=VERIFY_IDENTITY \
      --ssl-ca=/etc/ssl/certs/rds-global-bundle.pem < "$DIR/schema.sql"

echo "==> [3/6] Create DMS replication subnet group + instance"
aws dms create-replication-subnet-group \
  --replication-subnet-group-identifier finnova-dms \
  --replication-subnet-group-description "DMS for order-management migration" \
  --subnet-ids $DMS_SUBNET_IDS

aws dms create-replication-instance \
  --replication-instance-identifier finnova-dms-ri \
  --replication-instance-class dms.r5.xlarge \
  --allocated-storage 300 \
  --multi-az \
  --no-publicly-accessible \
  --vpc-security-group-ids "$DMS_SG_ID" \
  --replication-subnet-group-identifier finnova-dms \
  --kms-key-id alias/aws/dms
aws dms wait replication-instance-available \
  --filters Name=replication-instance-id,Values=finnova-dms-ri

echo "==> [4/6] Create source and target endpoints (SSL on both)"
SRC_ARN=$(aws dms create-endpoint --endpoint-identifier src-onprem-mysql57 \
  --endpoint-type source --engine-name mysql \
  --server-name "$SRC_HOST" --port "$SRC_PORT" \
  --username "$SRC_USER" --password "$SRC_PASS" \
  --ssl-mode require \
  --extra-connection-attributes "parallelLoadThreads=8;initstmt=SET FOREIGN_KEY_CHECKS=0" \
  --query Endpoint.EndpointArn --output text)

TGT_ARN=$(aws dms create-endpoint --endpoint-identifier tgt-rds-mysql80 \
  --endpoint-type target --engine-name mysql \
  --server-name "$TGT_HOST" --port 3306 \
  --username "$TGT_USER" --password "$TGT_PASS" \
  --ssl-mode verify-full --certificate-arn "${RDS_CA_CERT_ARN:?import rds-global-bundle first}" \
  --extra-connection-attributes "parallelLoadThreads=8;maxFileSize=512000;initstmt=SET FOREIGN_KEY_CHECKS=0" \
  --query Endpoint.EndpointArn --output text)

RI_ARN=$(aws dms describe-replication-instances \
  --filters Name=replication-instance-id,Values=finnova-dms-ri \
  --query 'ReplicationInstances[0].ReplicationInstanceArn' --output text)

echo "==> [5/6] Test connections"
for E in "$SRC_ARN" "$TGT_ARN"; do
  aws dms test-connection --replication-instance-arn "$RI_ARN" --endpoint-arn "$E" >/dev/null
done
sleep 30
aws dms describe-connections --filter Name=replication-instance-arn,Values="$RI_ARN" \
  --query 'Connections[].{ep:EndpointIdentifier,status:Status}' --output table

echo "==> [6/6] Create and start the task: FULL LOAD + ongoing CDC"
TASK_ARN=$(aws dms create-replication-task \
  --replication-task-identifier finnova-orders-full-cdc \
  --source-endpoint-arn "$SRC_ARN" --target-endpoint-arn "$TGT_ARN" \
  --replication-instance-arn "$RI_ARN" \
  --migration-type full-load-and-cdc \
  --table-mappings "file://$DIR/table-mappings.json" \
  --replication-task-settings "file://$DIR/task-settings.json" \
  --query ReplicationTask.ReplicationTaskArn --output text)

aws dms wait replication-task-ready --filters Name=replication-task-arn,Values="$TASK_ARN"
aws dms start-replication-task --replication-task-arn "$TASK_ARN" \
  --start-replication-task-type start-replication

echo "Task started: $TASK_ARN"
echo "Monitor: aws dms describe-replication-tasks --filters Name=replication-task-arn,Values=$TASK_ARN"
echo "         aws dms describe-table-statistics --replication-task-arn $TASK_ARN"
