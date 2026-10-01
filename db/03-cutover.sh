#!/usr/bin/env bash
# =============================================================================
# 03-cutover.sh  -- scripted DB cutover. Target total write-freeze < 5 minutes.
# Run ONLY after: (a) CDC lag < 5 s for 24h, (b) 02-validate.sh passed with the
# full dataset, (c) at least 3 rehearsals in staging, (d) change approved.
#
# Timeline (T = freeze start):
#   T-30m  announce, scale web tier to desired size, lower DNS TTL (done a day ago)
#   T+0:00 set source READ ONLY, scale writers to 0 / maintenance page
#   T+0:30 wait for CDC latency == 0 (DMS CDCLatencyTarget)
#   T+1:30 fast validation (counts + invariants + last-N-rows checksum)
#   T+2:30 flip the app secret/endpoint to RDS, rollout restart services
#   T+3:30 smoke tests, lift maintenance page
#   T+4:00 writes enabled on RDS (target < 5:00)
# =============================================================================
set -euo pipefail
: "${TASK_ARN:?}" "${SRC_HOST:?}" "${TGT_HOST:?}" "${EKS_CONTEXT:?}" "${ENV_NAME:?}"

START=$(date +%s)
t() { echo "[T+$(( $(date +%s) - START ))s] $*"; }
secret() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text; }

SRC_ADMIN_SECRET_ARN="${SRC_ADMIN_SECRET_ARN:?}"
SA_USER=$(secret "$SRC_ADMIN_SECRET_ARN" | jq -r .username)
SA_PASS=$(secret "$SRC_ADMIN_SECRET_ARN" | jq -r .password)
src() { mysql -N -B -h "$SRC_HOST" -u "$SA_USER" -p"$SA_PASS" --ssl-mode=REQUIRED -e "$1"; }

t "Pre-check: CDC latency must be < 10s"
LAT=$(aws cloudwatch get-metric-statistics --namespace AWS/DMS --metric-name CDCLatencyTarget \
  --dimensions Name=ReplicationInstanceIdentifier,Value=finnova-dms-ri Name=ReplicationTaskIdentifier,Value=finnova-orders-full-cdc \
  --start-time "$(date -u -d '-5 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 60 --statistics Maximum \
  --query 'max(Datapoints[].Maximum)' --output text)
[ "${LAT%.*}" -lt 10 ] || { echo "CDC lag ${LAT}s too high, abort"; exit 1; }

t "1. Enable maintenance page + scale writers to zero"
kubectl --context "$EKS_CONTEXT" -n orders scale deploy/order deploy/inventory --replicas=0
kubectl --context "$EKS_CONTEXT" -n payments scale deploy/payment --replicas=0
# On-prem web tier: flip Nginx to the static maintenance page (Ansible/pre-staged config)
ansible-playbook -i onprem-inventory.ini maintenance_on.yml

t "2. Freeze source writes"
src "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;"
# kill any straggler write connections
for ID in $(src "SELECT id FROM information_schema.processlist WHERE user NOT IN ('dms_user','system user','event_scheduler','root') AND command<>'Sleep'"); do
  src "KILL $ID" || true
done
POS=$(src "SHOW MASTER STATUS" | awk '{print $1":"$2}')
t "Source frozen at binlog position $POS"

t "3. Wait for CDC to drain (latency 0 and no pending changes)"
L=999
for i in $(seq 1 60); do
  L=$(aws cloudwatch get-metric-statistics --namespace AWS/DMS --metric-name CDCLatencyTarget \
        --dimensions Name=ReplicationInstanceIdentifier,Value=finnova-dms-ri Name=ReplicationTaskIdentifier,Value=finnova-orders-full-cdc \
        --start-time "$(date -u -d '-1 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 60 --statistics Maximum \
        --query 'max(Datapoints[].Maximum)' --output text)
  [ "$L" != "None" ] && [ "${L%.*}" -le 1 ] && break
  sleep 2
done
[ "$L" != "None" ] && [ "${L%.*}" -le 1 ] || { t "CDC did not drain in time -> ROLLBACK"; ./04-rollback.sh --before-switch; exit 2; }
t "CDC drained (latency ${L}s)"

t "4. Fast validation (counts + invariants + latest-rows checksum)"
SAMPLE_PCT=2 CHUNK_ROWS=500000 ./02-validate.sh || { t "VALIDATION FAILED -> ROLLBACK"; ./04-rollback.sh --before-switch; exit 2; }

t "5. Stop forward task; enable reverse replication RDS -> on-prem (rollback safety net)"
aws dms stop-replication-task --replication-task-arn "$TASK_ARN"
aws dms start-replication-task --replication-task-arn "${REVERSE_TASK_ARN:?}" --start-replication-task-type start-replication
mysql -h "$TGT_HOST" -e "SET GLOBAL innodb_flush_log_at_trx_commit=1" 2>/dev/null || true  # restore durability

t "6. Point services at RDS: write per-service secrets, restart pods"
./05-rotate-service-secrets.sh "$ENV_NAME"   # creates least-priv DB users, writes Secrets Manager values
kubectl --context "$EKS_CONTEXT" -n orders scale deploy/order deploy/inventory --replicas=3
kubectl --context "$EKS_CONTEXT" -n payments scale deploy/payment --replicas=3
kubectl --context "$EKS_CONTEXT" -n orders rollout status deploy/order deploy/inventory --timeout=120s
kubectl --context "$EKS_CONTEXT" -n payments rollout status deploy/payment --timeout=120s

t "7. Smoke tests then lift maintenance page"
./06-smoke-tests.sh "$ENV_NAME" || { t "SMOKE FAILED -> ROLLBACK"; ./04-rollback.sh --after-switch; exit 3; }
ansible-playbook -i onprem-inventory.ini maintenance_off.yml   # or DNS weighted flip to AWS ALB

t "CUTOVER COMPLETE. Write-freeze duration: $(( $(date +%s) - START ))s (target < 300s)"
