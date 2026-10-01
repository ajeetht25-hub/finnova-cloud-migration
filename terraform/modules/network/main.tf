# -----------------------------------------------------------------------------
# Network module: VPC with four subnet tiers per AZ
#   public  : ALB, NAT gateways
#   app     : EKS general worker nodes (order, inventory, web, batch)
#   pci     : EKS dedicated nodes for the payment service (isolated)
#   data    : RDS, no route to the internet at all
# CIDR plan (/16 -> /20 per subnet):  public=0-2, app=4-6, pci=8-10, data=12-14
# -----------------------------------------------------------------------------

locals {
  az_count = length(var.azs)
  az_index = { for i, az in var.azs : az => i }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "${var.name}-vpc" })
}

# Lock down the default SG so nothing can use it accidentally.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-default-deny" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-igw" })
}

# ---------------------------- Subnets ----------------------------------------
resource "aws_subnet" "public" {
  for_each                = local.az_index
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, each.value)
  map_public_ip_on_launch = false
  tags = merge(var.tags, {
    Name                     = "${var.name}-public-${each.key}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "app" {
  for_each          = local.az_index
  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, each.value + 4)
  tags = merge(var.tags, {
    Name                              = "${var.name}-app-${each.key}"
    Tier                              = "app"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_subnet" "pci" {
  for_each          = local.az_index
  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, each.value + 8)
  tags = merge(var.tags, {
    Name = "${var.name}-pci-${each.key}"
    Tier = "pci"
  })
}

resource "aws_subnet" "data" {
  for_each          = local.az_index
  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, each.value + 12)
  tags = merge(var.tags, {
    Name = "${var.name}-data-${each.key}"
    Tier = "data"
  })
}

# ---------------------------- NAT --------------------------------------------
locals {
  nat_azs = var.single_nat_gateway ? [var.azs[0]] : var.azs
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)
  domain   = "vpc"
  tags     = merge(var.tags, { Name = "${var.name}-nat-${each.key}" })
}

resource "aws_nat_gateway" "this" {
  for_each      = toset(local.nat_azs)
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id
  tags          = merge(var.tags, { Name = "${var.name}-nat-${each.key}" })
  depends_on    = [aws_internet_gateway.this]
}

# ---------------------------- Route tables -----------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-public-rt" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ for app and pci, pointing at that AZ's NAT
# (or the single NAT in non-prod).
resource "aws_route_table" "app" {
  for_each = local.az_index
  vpc_id   = aws_vpc.this.id
  tags     = merge(var.tags, { Name = "${var.name}-app-rt-${each.key}" })
}

resource "aws_route" "app_nat" {
  for_each               = local.az_index
  route_table_id         = aws_route_table.app[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? var.azs[0] : each.key].id
}

resource "aws_route_table_association" "app" {
  for_each       = aws_subnet.app
  subnet_id      = each.value.id
  route_table_id = aws_route_table.app[each.key].id
}

resource "aws_route_table" "pci" {
  for_each = local.az_index
  vpc_id   = aws_vpc.this.id
  tags     = merge(var.tags, { Name = "${var.name}-pci-rt-${each.key}" })
}

resource "aws_route" "pci_nat" {
  for_each               = local.az_index
  route_table_id         = aws_route_table.pci[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? var.azs[0] : each.key].id
}

resource "aws_route_table_association" "pci" {
  for_each       = aws_subnet.pci
  subnet_id      = each.value.id
  route_table_id = aws_route_table.pci[each.key].id
}

# Data tier: NO default route. Reachable only from inside the VPC.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-data-rt" })
}

resource "aws_route_table_association" "data" {
  for_each       = aws_subnet.data
  subnet_id      = each.value.id
  route_table_id = aws_route_table.data.id
}

# ---------------------------- Gateway endpoint (S3) --------------------------
# Keeps S3 traffic (reports, uploads, ECR layers) off the NAT gateway.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = concat(
    [aws_route_table.data.id],
    [for rt in aws_route_table.app : rt.id],
    [for rt in aws_route_table.pci : rt.id],
  )
  tags = merge(var.tags, { Name = "${var.name}-s3-gw" })
}

data "aws_region" "current" {}

# ---------------------------- Network ACL for PCI subnets --------------------
# Stateless second layer: PCI subnets accept traffic only from the app tier
# (ALB/ingress path + order service) and talk out to data tier and HTTPS.
resource "aws_network_acl" "pci" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = [for s in aws_subnet.pci : s.id]
  tags       = merge(var.tags, { Name = "${var.name}-pci-nacl" })
}

resource "aws_network_acl_rule" "pci_in_from_app" {
  for_each       = aws_subnet.app
  network_acl_id = aws_network_acl.pci.id
  rule_number    = 100 + local.az_index[each.key]
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = each.value.cidr_block
  from_port      = 8443
  to_port        = 8443
}

resource "aws_network_acl_rule" "pci_in_from_pci" {
  for_each       = aws_subnet.pci
  network_acl_id = aws_network_acl.pci.id
  rule_number    = 120 + local.az_index[each.key]
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = each.value.cidr_block
  from_port      = 0
  to_port        = 0
}

# Return traffic for outbound connections (PSP HTTPS, ECR, STS).
resource "aws_network_acl_rule" "pci_in_ephemeral" {
  network_acl_id = aws_network_acl.pci.id
  rule_number    = 200
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "pci_out_https" {
  network_acl_id = aws_network_acl.pci.id
  rule_number    = 100
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

resource "aws_network_acl_rule" "pci_out_mysql" {
  for_each       = aws_subnet.data
  network_acl_id = aws_network_acl.pci.id
  rule_number    = 110 + local.az_index[each.key]
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = each.value.cidr_block
  from_port      = 3306
  to_port        = 3306
}

resource "aws_network_acl_rule" "pci_out_ephemeral_to_app" {
  for_each       = aws_subnet.app
  network_acl_id = aws_network_acl.pci.id
  rule_number    = 130 + local.az_index[each.key]
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = each.value.cidr_block
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "pci_out_pci" {
  for_each       = aws_subnet.pci
  network_acl_id = aws_network_acl.pci.id
  rule_number    = 140 + local.az_index[each.key]
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = each.value.cidr_block
  from_port      = 0
  to_port        = 0
}

# ---------------------------- Security groups --------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public ALB: HTTPS from the internet"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name}-alb-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_security_group" "app_nodes" {
  name        = "${var.name}-app-nodes"
  description = "EKS general worker nodes"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name}-app-nodes-sg" })
}

resource "aws_security_group" "pci_nodes" {
  name        = "${var.name}-pci-nodes"
  description = "EKS dedicated PCI worker nodes (payment service)"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name}-pci-nodes-sg" })
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "RDS MySQL: only app + pci nodes on 3306"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name}-db-sg" })
}

# ALB -> app nodes (service/pod ports via ALB IP target type)
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app_nodes.id
  description                  = "App traffic from ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

# Node <-> node inside the app tier (kubelet, CoreDNS, pod-to-pod)
resource "aws_vpc_security_group_ingress_rule" "app_self" {
  security_group_id            = aws_security_group.app_nodes.id
  description                  = "App nodes talk to each other"
  referenced_security_group_id = aws_security_group.app_nodes.id
  ip_protocol                  = "-1"
}

# Order service (app tier) -> payment service (pci tier) on 8443 only.
resource "aws_vpc_security_group_ingress_rule" "pci_from_app" {
  security_group_id            = aws_security_group.pci_nodes.id
  description                  = "Payment API (mTLS) from app tier only"
  referenced_security_group_id = aws_security_group.app_nodes.id
  from_port                    = 8443
  to_port                      = 8443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "pci_self" {
  security_group_id            = aws_security_group.pci_nodes.id
  description                  = "PCI nodes talk to each other (CoreDNS, kubelet)"
  referenced_security_group_id = aws_security_group.pci_nodes.id
  ip_protocol                  = "-1"
}

# EKS control plane -> nodes is handled by the cluster SG in the eks module.

# Egress: nodes may reach HTTPS (ECR, STS, Secrets Manager, PSP) and DB.
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app_nodes.id
  description       = "HTTPS out (via NAT)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_dns_udp" {
  security_group_id = aws_security_group.app_nodes.id
  description       = "DNS"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app_nodes.id
  description                  = "MySQL to data tier"
  referenced_security_group_id = aws_security_group.db.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_self_out" {
  security_group_id            = aws_security_group.app_nodes.id
  description                  = "Node to node"
  referenced_security_group_id = aws_security_group.app_nodes.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "app_to_pci" {
  security_group_id            = aws_security_group.app_nodes.id
  description                  = "Order service to payment API"
  referenced_security_group_id = aws_security_group.pci_nodes.id
  from_port                    = 8443
  to_port                      = 8443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "pci_https" {
  security_group_id = aws_security_group.pci_nodes.id
  description       = "HTTPS out to PSP / AWS APIs (via NAT)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "pci_dns_udp" {
  security_group_id = aws_security_group.pci_nodes.id
  description       = "DNS"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_egress_rule" "pci_to_db" {
  security_group_id            = aws_security_group.pci_nodes.id
  description                  = "MySQL to data tier"
  referenced_security_group_id = aws_security_group.db.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "pci_self_out" {
  security_group_id            = aws_security_group.pci_nodes.id
  description                  = "Node to node"
  referenced_security_group_id = aws_security_group.pci_nodes.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "ALB to app pods"
  referenced_security_group_id = aws_security_group.app_nodes.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

# DB accepts only from app + pci nodes. No CIDR rules, no 0.0.0.0/0.
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from app nodes"
  referenced_security_group_id = aws_security_group.app_nodes.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_pci" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from PCI nodes"
  referenced_security_group_id = aws_security_group.pci_nodes.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
}

# ---------------------------- Flow logs --------------------------------------
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_log_retention_days
  tags              = var.tags
}

data "aws_iam_policy_document" "flow_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow" {
  name               = "${var.name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "flow_write" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.flow.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow.id
  policy = data.aws_iam_policy_document.flow_write.json
}

resource "aws_flow_log" "this" {
  vpc_id          = aws_vpc.this.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow.arn
  log_destination = aws_cloudwatch_log_group.flow.arn
  tags            = var.tags
}
