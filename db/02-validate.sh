#!/usr/bin/env bash
# =============================================================================
# 02-validate.sh  -- post-load / pre-cutover / post-cutover data validation
#
# Layers (cheap -> expensive):
#   L1  DMS built-in row-level validation status (continuous, from the task)
#   L2  Exact row counts per table (source vs target)
#   L3  Chunked checksum on every table by primary-key range (catches value drift
#       that equal counts hide). For tables > 50M rows, sample N% of chunks.
#   L4  Business invariants (sums/latest ids) on money- and stock-bearing tables
#
# Exit code 0 = all OK. Non-zero = DO NOT CUT OVER (or ROLL BACK if after cutover).
# Credentials are read from Secrets Manager at run time. Nothing is stored.
# =============================================================================
set -euo pipefail

: "${SRC_HOST:?}" "${TGT_HOST:?}" "${SRC_DMS_SECRET_ARN:?}" "${TGT_ADMIN_SECRET_ARN:?}" "${TASK_ARN:?}"
SCHEMAS="${SCHEMAS:-orders inventory payment}"
CHUNK_ROWS="${CHUNK_ROWS:-200000}"
SAMPLE_PCT="${SAMPLE_PCT:-100}"          # 100 = every chunk; use 10 for huge tables in dry runs
FAIL=0

secret() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text; }
S_USER=$(secret "$SRC_DMS_SECRET_ARN" | jq -r .username); S_PASS=$(secret "$SRC_DMS_SECRET_ARN" | jq -r .password)
T_USER=$(secret "$TGT_ADMIN_SECRET_ARN" | jq -r .username); T_PASS=$(secret "$TGT_ADMIN_SECRET_ARN" | jq -r .password)

src() { mysql -N -B -h "$SRC_HOST" -u "$S_USER" -p"$S_PASS" --ssl-mode=REQUIRED -e "$1"; }
tgt() { mysql -N -B -h "$TGT_HOST" -u "$T_USER" -p"$T_PASS" --ssl-mode=VERIFY_IDENTITY \
          --ssl-ca=/etc/ssl/certs/rds-global-bundle.pem -e "$1"; }

echo "=== L1: DMS validation state ==="
aws dms describe-table-statistics --replication-task-arn "$TASK_ARN" \
  --query 'TableStatistics[?ValidationState!=`Validated` && ValidationState!=null].{t:TableName,state:ValidationState,fail:ValidationFailedRecords,susp:ValidationSuspendedRecords}' \
  --output table
BAD=$(aws dms describe-table-statistics --replication-task-arn "$TASK_ARN" \
  --query 'length(TableStatistics[?ValidationFailedRecords>`0` || ValidationState==`Mismatched records`])' --output text)
[ "$BAD" = "0" ] || { echo "L1 FAIL: $BAD tables with mismatches"; FAIL=1; }

echo "=== L2: exact row counts ==="
for S in $SCHEMAS; do
  for T in $(src "SELECT table_name FROM information_schema.tables WHERE table_schema='$S' AND table_type='BASE TABLE'"); do
    A=$(src "SELECT COUNT(*) FROM \`$S\`.\`$T\`")
    B=$(tgt "SELECT COUNT(*) FROM \`$S\`.\`$T\`")
    if [ "$A" != "$B" ]; then echo "MISMATCH $S.$T src=$A tgt=$B"; FAIL=1; else echo "ok  $S.$T $A"; fi
  done
done

echo "=== L3: chunked checksums (PK ranges of $CHUNK_ROWS rows, sample ${SAMPLE_PCT}%) ==="
chunk_sum() {  # $1=conn-fn  $2=schema $3=table $4=pk $5=lo $6=hi
  local cols
  cols=$($1 "SELECT GROUP_CONCAT(CONCAT('IFNULL(CAST(\`',column_name,'\` AS CHAR),\"~\")') ORDER BY ordinal_position SEPARATOR ',\"|\",')
             FROM information_schema.columns WHERE table_schema='$2' AND table_name='$3'")
  $1 "SELECT COUNT(*), IFNULL(BIT_XOR(CAST(CONV(SUBSTRING(MD5(CONCAT_WS('#',$cols)),1,16),16,10) AS UNSIGNED)),0)
        FROM \`$2\`.\`$3\` WHERE \`$4\` >= $5 AND \`$4\` < $6"
}
for S in $SCHEMAS; do
  for T in $(src "SELECT table_name FROM information_schema.tables WHERE table_schema='$S' AND table_type='BASE TABLE'"); do
    PK=$(src "SELECT column_name FROM information_schema.key_column_usage WHERE table_schema='$S' AND table_name='$T' AND constraint_name='PRIMARY' ORDER BY ordinal_position LIMIT 1")
    TYPE=$(src "SELECT data_type FROM information_schema.columns WHERE table_schema='$S' AND table_name='$T' AND column_name='$PK'")
    case "$TYPE" in int|bigint|mediumint|smallint) ;; *) echo "skip $S.$T (non-numeric PK; covered by L1/L2)"; continue;; esac
    MAX=$(src "SELECT IFNULL(MAX(\`$PK\`),0) FROM \`$S\`.\`$T\`")
    for ((lo=0; lo<=MAX; lo+=CHUNK_ROWS)); do
      (( RANDOM % 100 < SAMPLE_PCT )) || continue
      hi=$((lo+CHUNK_ROWS))
      A=$(chunk_sum src "$S" "$T" "$PK" $lo $hi); B=$(chunk_sum tgt "$S" "$T" "$PK" $lo $hi)
      [ "$A" = "$B" ] || { echo "CHECKSUM MISMATCH $S.$T pk[$lo,$hi) src=($A) tgt=($B)"; FAIL=1; }
    done
    echo "checked $S.$T"
  done
done

echo "=== L4: business invariants ==="
for Q in \
  "SELECT COUNT(*), IFNULL(SUM(total_amount),0), IFNULL(MAX(id),0) FROM orders.orders" \
  "SELECT COUNT(*), IFNULL(SUM(quantity_on_hand),0) FROM inventory.stock" \
  "SELECT COUNT(*), IFNULL(SUM(amount),0), IFNULL(MAX(id),0) FROM payment.transactions"; do
  A=$(src "$Q"); B=$(tgt "$Q")
  [ "$A" = "$B" ] && echo "ok  $Q => $A" || { echo "INVARIANT MISMATCH: $Q src=($A) tgt=($B)"; FAIL=1; }
done

if [ "$FAIL" -eq 0 ]; then echo "VALIDATION PASSED"; else echo "VALIDATION FAILED"; fi
exit "$FAIL"
