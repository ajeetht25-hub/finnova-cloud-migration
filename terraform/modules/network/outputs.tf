output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = [for s in aws_subnet.public : s.id]
}

output "app_subnet_ids" {
  value = [for s in aws_subnet.app : s.id]
}

output "pci_subnet_ids" {
  value = [for s in aws_subnet.pci : s.id]
}

output "data_subnet_ids" {
  value = [for s in aws_subnet.data : s.id]
}

output "sg_alb_id" {
  value = aws_security_group.alb.id
}

output "sg_app_nodes_id" {
  value = aws_security_group.app_nodes.id
}

output "sg_pci_nodes_id" {
  value = aws_security_group.pci_nodes.id
}

output "sg_db_id" {
  value = aws_security_group.db.id
}
