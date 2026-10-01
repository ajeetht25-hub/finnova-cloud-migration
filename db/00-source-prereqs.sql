-- =============================================================================
-- 00-source-prereqs.sql  (run on the ON-PREM MySQL 5.7 primary, as an admin)
-- Prepares the source for DMS full load + CDC.
-- my.cnf must contain (restart required if not already set):
--   server_id                 = 101
--   log_bin                   = mysql-bin
--   binlog_format             = ROW
--   binlog_row_image          = FULL
--   expire_logs_days          = 7      -- keep binlogs >= longest expected lag/outage
--   gtid_mode / enforce_gtid_consistency = ON   (recommended; required for reverse replication ease)
--   log_slave_updates         = ON     -- on the replica we will read from, if using it
-- TIP: point DMS at the existing READ REPLICA to avoid load on the primary
--      (replica must have log_slave_updates=ON so it writes binlogs for DMS).
-- =============================================================================

-- Dedicated least-privilege migration user (password supplied at run time, not committed)
CREATE USER 'dms_user'@'%' IDENTIFIED BY '<<SET_AT_RUNTIME_FROM_SECRETS_MANAGER>>' REQUIRE SSL;

GRANT SELECT, REPLICATION CLIENT, REPLICATION SLAVE, SHOW VIEW, EVENT, TRIGGER
  ON *.* TO 'dms_user'@'%';

-- Sanity checks DMS needs
SHOW VARIABLES LIKE 'log_bin';            -- ON
SHOW VARIABLES LIKE 'binlog_format';      -- ROW
SHOW VARIABLES LIKE 'binlog_row_image';   -- FULL
SHOW VARIABLES LIKE 'expire_logs_days';   -- >= 7

-- Pre-flight: tables without a primary key cannot be validated/CDC-replicated reliably
SELECT t.table_schema, t.table_name
FROM information_schema.tables t
LEFT JOIN information_schema.table_constraints c
  ON c.table_schema = t.table_schema AND c.table_name = t.table_name AND c.constraint_type = 'PRIMARY KEY'
WHERE t.table_type = 'BASE TABLE'
  AND t.table_schema IN ('orders', 'inventory', 'payment')
  AND c.constraint_name IS NULL;
-- Every row returned here must get a PK (or a unique key) BEFORE the full load starts.
