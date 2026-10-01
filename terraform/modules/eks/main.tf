# -----------------------------------------------------------------------------
# EKS module: private-endpoint cluster, KMS-encrypted secrets, IRSA (OIDC),
# three managed node groups: app (on-demand), pci (tainted, dedicated), batch (spot)
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# ------------------------------ KMS for K8s secrets ---------------------------
resource "aws_kms_key" "eks" {
  description             = "${var.name} EKS secrets envelope encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 14
  tags                    = var.tags
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# ------------------------------ Cluster role ---------------------------------
data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = concat(var.app_subnet_ids, var.pci_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# ------------------------------ OIDC provider (IRSA) --------------------------
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  tags            = var.tags
}

# ------------------------------ Node role (shared minimal policies) ----------
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  for_each           = toset(["app", "pci", "batch"])
  name               = "${var.name}-node-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

locals {
  node_policies = [
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore", # SSM instead of SSH keys
  ]
  node_role_policy_pairs = {
    for pair in setproduct(["app", "pci", "batch"], local.node_policies) :
    "${pair[0]}|${pair[1]}" => { role = pair[0], policy = pair[1] }
  }
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each   = local.node_role_policy_pairs
  role       = aws_iam_role.node[each.value.role].name
  policy_arn = each.value.policy
}

# ------------------------------ Launch templates -----------------------------
# Needed to attach our own SGs (tier isolation), IMDSv2-only, encrypted root.
resource "aws_launch_template" "node" {
  for_each = {
    app   = var.app_node_sg_id
    pci   = var.pci_node_sg_id
    batch = var.app_node_sg_id
  }

  name_prefix            = "${var.name}-${each.key}-"
  vpc_security_group_ids = [each.value, aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # pods cannot reach node credentials
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name}-${each.key}" })
  }
}

# ------------------------------ Node groups ----------------------------------
resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "app"
  node_role_arn   = aws_iam_role.node["app"].arn
  subnet_ids      = var.app_subnet_ids
  instance_types  = var.app_node_group.instance_types
  capacity_type   = var.app_node_group.capacity_type

  scaling_config {
    min_size     = var.app_node_group.min_size
    desired_size = var.app_node_group.desired_size
    max_size     = var.app_node_group.max_size
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node["app"].id
    version = aws_launch_template.node["app"].latest_version
  }

  labels = { "workload" = "general" }
  tags   = var.tags

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size] # cluster-autoscaler / Karpenter owns this
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

resource "aws_eks_node_group" "pci" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "pci"
  node_role_arn   = aws_iam_role.node["pci"].arn
  subnet_ids      = var.pci_subnet_ids
  instance_types  = var.pci_node_group.instance_types
  capacity_type   = "ON_DEMAND"

  scaling_config {
    min_size     = var.pci_node_group.min_size
    desired_size = var.pci_node_group.desired_size
    max_size     = var.pci_node_group.max_size
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node["pci"].id
    version = aws_launch_template.node["pci"].latest_version
  }

  labels = {
    "workload" = "pci"
    "pci"      = "true"
  }

  # Only pods that tolerate this taint (the payment service) can land here.
  taint {
    key    = "pci"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

resource "aws_eks_node_group" "batch" {
  count           = var.batch_node_group.max_size > 0 ? 1 : 0
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "batch-spot"
  node_role_arn   = aws_iam_role.node["batch"].arn
  subnet_ids      = var.app_subnet_ids
  instance_types  = var.batch_node_group.instance_types
  capacity_type   = "SPOT"

  scaling_config {
    min_size     = var.batch_node_group.min_size
    desired_size = var.batch_node_group.desired_size
    max_size     = var.batch_node_group.max_size
  }

  launch_template {
    id      = aws_launch_template.node["batch"].id
    version = aws_launch_template.node["batch"].latest_version
  }

  labels = { "workload" = "batch" }

  taint {
    key    = "workload"
    value  = "batch"
    effect = "NO_SCHEDULE"
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# ------------------------------ Add-ons ---------------------------------------
resource "aws_eks_addon" "this" {
  for_each     = toset(["vpc-cni", "kube-proxy", "coredns", "aws-ebs-csi-driver"])
  cluster_name = aws_eks_cluster.this.name
  addon_name   = each.key

  # Let NetworkPolicy be enforced by the VPC CNI.
  configuration_values = each.key == "vpc-cni" ? jsonencode({ enableNetworkPolicy = "true" }) : null

  tags       = var.tags
  depends_on = [aws_eks_node_group.app]
}
