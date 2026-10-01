# -----------------------------------------------------------------------------
# Secrets module
#  - One KMS CMK for application secrets
#  - One Secrets Manager secret per service (placeholder JSON; real values are
#    written by the DB-migration/rotation step, NEVER committed)
#  - One IRSA role per service, allowed to read ONLY its own secret
#    (payment's role is additionally bound to the PCI namespace + SA)
# -----------------------------------------------------------------------------

resource "aws_kms_key" "secrets" {
  description             = "${var.name} application secrets"
  enable_key_rotation     = true
  deletion_window_in_days = 14
  tags                    = var.tags
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

resource "aws_secretsmanager_secret" "svc" {
  for_each                = toset(var.services)
  name                    = "${var.name}/${each.key}/db"
  description             = "DB credentials for the ${each.key} service"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = var.recovery_window_days
  tags                    = merge(var.tags, { Service = each.key })
}

# Placeholder only so the secret has a version; ignore_changes keeps Terraform
# from ever overwriting the real value that the migration/rotation writes.
resource "aws_secretsmanager_secret_version" "placeholder" {
  for_each      = aws_secretsmanager_secret.svc
  secret_id     = each.value.id
  secret_string = jsonencode({ username = "CHANGE_ME", password = "CHANGE_ME", host = "CHANGE_ME", port = 3306 })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

locals {
  # service => namespace where its ServiceAccount lives
  sa_namespace = { for s in var.services : s => (s == "payment" ? var.pci_namespace : var.k8s_namespace) }
}

data "aws_iam_policy_document" "irsa_trust" {
  for_each = toset(var.services)

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${local.sa_namespace[each.key]}:${each.key}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "svc" {
  for_each           = toset(var.services)
  name               = "${var.name}-${each.key}-irsa"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust[each.key].json
  tags               = merge(var.tags, { Service = each.key })
}

data "aws_iam_policy_document" "read_own_secret" {
  for_each = toset(var.services)

  statement {
    sid       = "ReadOwnSecretOnly"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.svc[each.key].arn]
  }

  statement {
    sid       = "DecryptWithSecretsKeyOnly"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.secrets.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

data "aws_region" "current" {}

resource "aws_iam_role_policy" "svc" {
  for_each = toset(var.services)
  name     = "read-own-secret"
  role     = aws_iam_role.svc[each.key].id
  policy   = data.aws_iam_policy_document.read_own_secret[each.key].json
}
