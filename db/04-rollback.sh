#!/usr/bin/env bash
# =============================================================================
# 04-rollback.sh
#   --before-switch : validation failed while apps are still stopped.
#                     Rollback = just un-freeze the on-prem primary. Zero data loss.
#   --after-switch  : apps already write to RDS. Reverse DMS task has been copying
#                     RDS -> on-prem since step 5, so the on-prem primary is current.
#                     Rollback = stop apps, drain reverse CDC, re-enable on-prem, repoint.
# Decision window: full rollback is supported for 14 days (on-prem retained, reverse task running).
# =============================================================================
set -euo pipefail
MODE="${1:?--before-switch|--after-switch}"
: "${SRC_HOST:?}" "${EKS_CONTEXT:?}" "${SRC_ADMIN_SECRET_ARN:?}"
secret() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text; }
SA_USER=$(secret "$SRC_ADMIN_SECRET_ARN" | jq -r .username); SA_PASS=$(secret "$SRC_ADMIN_SECRET_ARN" | jq -r .password)
src() { mysql -N -B -h "$SRC_HOST" -u "$SA_USER" -p"$SA_PASS" --ssl-mode=REQUIRED -e "$1"; }

case "$MODE" in
  --before-switch)
    echo "Un-freezing on-prem primary (no writes ever reached RDS as the system of record)"
    src "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;"
    ansible-playbook -i onprem-inventory.ini maintenance_off.yml
    ;;
  --after-switch)
    echo "Stopping AWS writers"
    kubectl --context "$EKS_CONTEXT" -n orders scale deploy/order deploy/inventory --replicas=0
    kubectl --context "$EKS_CONTEXT" -n payments scale deploy/payment --replicas=0
    echo "Waiting for reverse replication (RDS -> on-prem) to drain"
    for i in $(seq 1 60); do
      L=$(aws cloudwatch get-metric-statistics --namespace AWS/DMS --metric-name CDCLatencyTarget \
          --dimensions Name=ReplicationInstanceIdentifier,Value=finnova-dms-ri Name=ReplicationTaskIdentifier,Value=finnova-reverse-cdc \
          --start-time "$(date -u -d '-1 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 60 --statistics Maximum \
          --query 'max(Datapoints[].Maximum)' --output text)
      [ "${L%.*}" -le 1 ] && break; sleep 2
    done
    aws dms stop-replication-task --replication-task-arn "${REVERSE_TASK_ARN:?}"
    src "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;"
    echo "Re-pointing on-prem apps (they still use the legacy config) and DNS back to the DC"
    ansible-playbook -i onprem-inventory.ini maintenance_off.yml
    echo "Post-rollback: run 02-validate.sh with SRC/TGT swapped to confirm RDS == on-prem"
    ;;
  *) echo "unknown mode"; exit 1;;
esac
echo "ROLLBACK COMPLETE"
