# -----------------------------------------------------------------------------
# RDS MySQL 8.0 (target of the DMS migration)
#  - private subnets only, publicly_accessible = false, SG-referenced access
#  - encryption at rest (KMS CMK), TLS enforced in transit (require_secure_transport)
#  - master password generated and owned by RDS in Secrets Manager (never in state/tfvars)
#  - binlog ROW format on so the instance can also act as a source for the
#    reverse-replication rollback path
# -----------------------------------------------------------------------------

resource "aws_kms_key" "rds" {
  description             = "${var.name} RDS storage, logs, Performance Insights"
  enable_key_rotation     = true
  deletion_window_in_days = 14
  tags                    = var.tags
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.name}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-data"
  subnet_ids = var.data_subnet_ids
  tags       = var.tags
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-mysql80-"
  family      = "mysql8.0"
  description = "FinNova MySQL 8.0 parameters"

  # Encryption in transit: reject any non-TLS connection.
  parameter {
    name  = "require_secure_transport"
    value = "1"
  }

  # Needed for DMS CDC and for the reverse-replication rollback path.
  parameter {
    name  = "binlog_format"
    value = "ROW"
  }

  parameter {
    name  = "binlog_row_image"
    value = "FULL"
  }

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_0900_ai_ci"
  }

  parameter {
    name         = "slow_query_log"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "long_query_time"
    value        = "1"
    apply_method = "immediate"
  }

  # Faster bulk load during DMS full load; flip back after migration.
  parameter {
    name         = "innodb_flush_log_at_trx_commit"
    value        = "2"
    apply_method = "immediate"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-mysql"
  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.db_name
  username = "dbadmin"

  # RDS creates and rotates the master secret in Secrets Manager.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.rds.arn

  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn
  iops                  = 12000
  storage_throughput    = 500

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.db_security_group_id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.this.name

  backup_retention_period = var.backup_retention_days
  backup_window           = "21:00-22:00" # 02:30-03:30 IST
  maintenance_window      = "sun:22:30-sun:23:30"
  copy_tags_to_snapshot   = true

  enabled_cloudwatch_logs_exports       = ["error", "slowquery", "audit"]
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_kms_key_id       = var.performance_insights_enabled ? aws_kms_key.rds.arn : null
  performance_insights_retention_period = var.performance_insights_enabled ? 7 : null

  auto_minor_version_upgrade = true
  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = var.skip_final_snapshot
  final_snapshot_identifier  = var.skip_final_snapshot ? null : "${var.name}-mysql-final"

  iam_database_authentication_enabled = true

  tags = var.tags
}
