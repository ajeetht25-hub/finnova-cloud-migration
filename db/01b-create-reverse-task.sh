#!/usr/bin/env bash
# =============================================================================
# 01b-create-reverse-task.sh
# Creates (but does NOT start) the reverse CDC task RDS -> on-prem, used as the
# rollback safety net after cutover. Started in 03-cutover.sh step 5.
# Prereqs: RDS binlog ROW (set in the parameter group), on-prem accepts writes from a
#          DMS user with INSERT/UPDATE/DELETE on the 3 schemas (grant only at cutover).
# =============================================================================
set -euo pipefail
: "${SRC_HOST:?}" "${TGT_HOST:?}" "${REV_SRC_SECRET_ARN:?}" "${REV_TGT_SECRET_ARN:?}" "${RDS_CA_CERT_ARN:?}"
DIR="$(cd "$(dirname "$0")" && pwd)"
secret() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text; }

RS_USER=$(secret "$REV_SRC_SECRET_ARN" | jq -r .username); RS_PASS=$(secret "$REV_SRC_SECRET_ARN" | jq -r .password)
RT_USER=$(secret "$REV_TGT_SECRET_ARN" | jq -r .username); RT_PASS=$(secret "$REV_TGT_SECRET_ARN" | jq -r .password)

REV_SRC=$(aws dms create-endpoint --endpoint-identifier rev-src-rds --endpoint-type source --engine-name mysql \
  --server-name "$TGT_HOST" --port 3306 --username "$RS_USER" --password "$RS_PASS" \
  --ssl-mode verify-full --certificate-arn "$RDS_CA_CERT_ARN" --query Endpoint.EndpointArn --output text)
REV_TGT=$(aws dms create-endpoint --endpoint-identifier rev-tgt-onprem --endpoint-type target --engine-name mysql \
  --server-name "$SRC_HOST" --port 3306 --username "$RT_USER" --password "$RT_PASS" \
  --ssl-mode require --query Endpoint.EndpointArn --output text)
RI_ARN=$(aws dms describe-replication-instances --filters Name=replication-instance-id,Values=finnova-dms-ri \
  --query 'ReplicationInstances[0].ReplicationInstanceArn' --output text)

# cdc-only: starts from "now"; the first full load already put the same data on-prem
aws dms create-replication-task --replication-task-identifier finnova-reverse-cdc \
  --source-endpoint-arn "$REV_SRC" --target-endpoint-arn "$REV_TGT" --replication-instance-arn "$RI_ARN" \
  --migration-type cdc \
  --table-mappings "file://$DIR/table-mappings.json" \
  --replication-task-settings "file://$DIR/task-settings.json" \
  --query ReplicationTask.ReplicationTaskArn --output text
