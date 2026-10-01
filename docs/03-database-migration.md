# 03 – Database Migration Plan (MySQL 5.7, 800 GB → RDS MySQL 8.0)

## 1. Options considered

| Option | Downtime | Verdict |
|---|---|---|
| `mysqldump` / mydumper + restore | Hours (800 GB) | Rejected – blows the 5 min budget |
| Percona XtraBackup → S3 → RDS | Needs binlog catch-up; RDS MySQL only restores 5.6/5.7 (not 8.0) and we want 8.0 | Rejected |
| Native binlog replication (RDS as replica) | Minutes | Viable, but RDS cannot be an external replica without `mysql.rds_set_external_master` tuning, and the 5.7→8.0 hop plus reverse path is harder to operate |
| Dual-write in the application | Near zero | Rejected – requires code change in code being split, high consistency risk |
| **AWS DMS full-load + CDC** | **Write freeze ≈ 2–4 min** | **Chosen** – supports 5.7→8.0, built-in validation, restartable, and a reverse task gives a clean rollback |

## 2. Design

```
 On-prem MySQL 5.7 (read replica as DMS source)
        │  Site-to-Site VPN (TLS)
        ▼
 DMS replication instance (dms.r5.xlarge, Multi-AZ, private)
        │  Phase A: parallel full load (8 threads, large tables range-partitioned)
        │  Phase B: CDC from the captured binlog position (cached changes applied)
        ▼
 RDS MySQL 8.0 Multi-AZ (private data subnet, TLS-only)
```

Key decisions:

* **Read from the on-prem replica**, not the primary, to avoid impacting production; replica needs `log_slave_updates=ON`.
* **Schema first** with `mysqldump --no-data` (tables, indexes, FKs, routines, triggers) because DMS does not migrate secondary objects well; DMS runs with `TargetTablePrepMode=DO_NOTHING` and FK checks disabled during load.
* **Upgrade 5.7 → 8.0 on the way**: collation normalised to `utf8mb4_0900_ai_ci`, `mysqlsh util.checkForServerUpgrade` run first, staging app suite executed against the RDS 8.0 target.
* **Per-service DB users** are created on RDS at cutover; legacy credentials are never copied.
* Pre-flight: tables with no primary key must get one (query in `db/00-source-prereqs.sql`).
* Bandwidth: 800 GB at a sustained 200 Mbps ≈ 9 h. Full load runs over a weekend; if the VPN cannot sustain ≥ 100 Mbps use AWS Snowball Edge for the initial load and DMS CDC for catch-up.

## 3. Full-load step (commands)

Implemented in `db/01-schema-and-full-load.sh`; the essential commands:

```bash
# 1. schema only
mysqldump -h $SRC_HOST -u $SRC_USER -p"$SRC_PASS" --ssl-mode=REQUIRED \
  --no-data --routines --triggers --events --single-transaction \
  --databases orders inventory payment > schema.sql
mysql -h $TGT_HOST -u $TGT_USER -p"$TGT_PASS" --ssl-mode=VERIFY_IDENTITY < schema.sql

# 2. DMS instance + endpoints
aws dms create-replication-instance --replication-instance-identifier finnova-dms-ri \
  --replication-instance-class dms.r5.xlarge --allocated-storage 300 --multi-az --no-publicly-accessible \
  --vpc-security-group-ids $DMS_SG_ID --replication-subnet-group-identifier finnova-dms
aws dms create-endpoint --endpoint-identifier src-onprem-mysql57 --endpoint-type source --engine-name mysql ...
aws dms create-endpoint --endpoint-identifier tgt-rds-mysql80   --endpoint-type target --engine-name mysql ...

# 3. task: full load + ongoing replication
aws dms create-replication-task --replication-task-identifier finnova-orders-full-cdc \
  --migration-type full-load-and-cdc \
  --table-mappings file://table-mappings.json \
  --replication-task-settings file://task-settings.json ...
aws dms start-replication-task --replication-task-arn $TASK_ARN --start-replication-task-type start-replication
```

Config files: `db/table-mappings.json` (three schemas, temp tables excluded, `order_items` range-partitioned for parallel load) and `db/task-settings.json` (batch apply, `ValidationSettings.EnableValidation=true`, 8 parallel full-load subtasks, LOB limited mode).

Password handling: credentials are fetched from Secrets Manager inside the script and never written to disk or Git.

## 4. Cutover (target < 5 minutes of write freeze)

Scripted in `db/03-cutover.sh` so that nothing is typed during the window.

| T+ | Action | Control |
|---|---|---|
| T-1 day | Lower DNS TTL to 30 s; confirm CDC lag < 5 s for 24 h; run full `02-validate.sh` | Go/No-Go checklist |
| T-30 min | Pre-scale AWS pods, warm connection pools, announce | |
| 0:00 | Maintenance page on, scale writers to 0, set source `super_read_only=ON`, kill stragglers | Writes stopped |
| 0:30 | Wait until DMS `CDCLatencyTarget` ≤ 1 s | Source and target converge |
| 1:30 | Fast validation (counts, invariants, sampled checksums) | Fail ⇒ rollback #1 |
| 2:00 | Stop forward task, **start reverse task (RDS → on-prem)**, restore `innodb_flush_log_at_trx_commit=1` | Safety net |
| 2:15 | Create service users + write new Secrets Manager values, scale AWS pods up | New credentials only |
| 3:30 | Smoke tests incl. canary write/read | Fail ⇒ rollback #2 |
| 4:00 | Lift maintenance page / flip DNS to the ALB | **Cutover done** |

Rehearsal: at least three full dress rehearsals in staging against a production-sized restore; time each step and tighten the script until p95 < 4 min.

## 5. Validation approach

Four layers, from cheap to thorough (`db/02-validate.sh`):

1. **DMS row-level validation** – continuous during CDC; any `Mismatched records` fails the gate.
2. **Exact row counts** for every table on both sides.
3. **Chunked checksums** – each table is split into PK ranges of 200 k rows; `COUNT(*)` plus a `BIT_XOR` of per-row MD5 is compared per range. Catches silent value drift that counts miss. Full pass before cutover, a 2 % sample inside the freeze window to stay inside the time budget, 100 % again after cutover (in the background, read-only).
4. **Business invariants** – order count/total/max id, stock-on-hand sums, payment transaction totals.

Post-cutover monitoring for 48 h: replication to on-prem lag, error rate, p95 latency, deadlocks, slow-query log, RDS CPU/IOPS/connections.

## 6. Rollback plan

| Situation | Action | Data loss |
|---|---|---|
| Validation fails inside the freeze (apps still stopped) | `04-rollback.sh --before-switch`: remove `read_only`, lift maintenance page. On-prem was never replaced. | None |
| Smoke test fails or severe issue within the first hours (writes already on RDS) | `04-rollback.sh --after-switch`: stop AWS writers, let the **reverse DMS task** drain RDS → on-prem, stop it, enable on-prem writes, repoint traffic. | None (reverse CDC kept on-prem current) |
| Problem found days later | Same procedure while the reverse task is still running (window: 14 days). After that, point-in-time restore of RDS + forward fix. | Bounded by RPO of the restore |
| Reverse replication broken | Fall back to the last RDS snapshot taken at T+0 and the on-prem binlogs; escalate (documented as the residual risk). | Writes made after cutover since the break |

On-prem databases and the DMS instance are kept for the 14-day window, then decommissioned after sign-off.

## 7. Post-load tuning

* After full load: set `innodb_flush_log_at_trx_commit=1` (durability), enable Performance Insights review, `ANALYZE TABLE` on large tables, confirm optimizer plans for the top 20 queries on 8.0.
* Add RDS Proxy later (connection pooling for HPA bursts) – deferred to keep the PoC small.
