#!/usr/bin/env bash
# =============================================================================
# 05-rotate-service-secrets.sh <env>
# Creates least-privilege MySQL users per service on RDS and writes the new
# credentials to Secrets Manager (the ONLY place they exist). The legacy
# on-prem credentials that lived in static config files are never reused.
# =============================================================================
set -euo pipefail
ENV_NAME="${1:?env}"
: "${TGT_HOST:?}" "${TGT_ADMIN_SECRET_ARN:?}"
secret() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text; }
A_USER=$(secret "$TGT_ADMIN_SECRET_ARN" | jq -r .username); A_PASS=$(secret "$TGT_ADMIN_SECRET_ARN" | jq -r .password)
tgt() { mysql -h "$TGT_HOST" -u "$A_USER" -p"$A_PASS" --ssl-mode=VERIFY_IDENTITY --ssl-ca=/etc/ssl/certs/rds-global-bundle.pem -e "$1"; }

for SVC in order inventory payment; do
  SCHEMA=$([ "$SVC" = order ] && echo orders || echo "$SVC")
  PASS=$(openssl rand -base64 36 | tr -d '/+=' | cut -c1-40)
  # Least privilege: DML on its own schema only; REQUIRE SSL; no GRANT OPTION
  tgt "CREATE USER IF NOT EXISTS 'svc_${SVC}'@'%' IDENTIFIED BY '${PASS}' REQUIRE SSL;
       ALTER USER 'svc_${SVC}'@'%' IDENTIFIED BY '${PASS}';
       GRANT SELECT, INSERT, UPDATE, DELETE ON \`${SCHEMA}\`.* TO 'svc_${SVC}'@'%';"
  aws secretsmanager put-secret-value \
    --secret-id "finnova-${ENV_NAME}/${SVC}/db" \
    --secret-string "$(jq -nc --arg u "svc_${SVC}" --arg p "$PASS" --arg h "$TGT_HOST" '{username:$u,password:$p,host:$h,port:3306}')" >/dev/null
  unset PASS
  echo "rotated ${SVC}"
done
