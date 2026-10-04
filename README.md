# FinNova Order Management: Cloud Migration

This repo has my plan and a working proof of concept for moving the FinNova order system from on-prem VMware to AWS. The target is EKS for the services, RDS MySQL 8.0 for the database, S3 for files and Secrets Manager for passwords. Region is Mumbai (ap-south-1) and the pipelines use GitHub Actions. I used the inventory service as the example service.

Nothing has been deployed to a real AWS account.

## Where things are

| What | Where |
|---|---|
| Strategy, 6R table, risks, phases | `docs/01-strategy.md` |
| Architecture diagram | `docs/architecture.png` (also `.svg`) |
| Architecture and Terraform notes | `docs/02-architecture-and-iac.md` |
| Terraform (network, EKS, RDS, secrets, S3) | `terraform/` |
| Dockerfile and Helm chart | `services/inventory/`, `deploy/helm/inventory/` |
| Pipelines | `.github/workflows/` |
| Database migration plan and scripts | `docs/03-database-migration.md`, `db/` |
| Security and secrets | `docs/04-network-security-secrets.md` |
| Runbook, rollback, payment releases | `docs/05-runbook.md` |
| Cost estimate | `docs/06-cost-estimate.md` |

## What I finished

- Written design for all seven tasks, with code where it makes sense.
- Terraform split into 5 modules and one stack that dev, staging and prod all use through their own variable files.
- Inventory service with tests, a Dockerfile, and a Helm chart (probes, autoscaling, network policy, secrets).
- Two pipelines: one for the service and one for Terraform.
- Database scripts for the copy, validation, cutover and rollback.

## What I did not do

- Nothing is applied to AWS. The tests and the Terraform checks pass on GitHub. The build and plan jobs stop at the AWS login because I have no account connected.
- Extra cluster pieces (load balancer controller, autoscaler, Argo Rollouts), WAF rules and the DR region are described but not coded.
- Only the inventory service has code. Order and payment are covered in the design.
- The database scripts have been syntax checked but not run against real databases. The roughly 4 minute cutover is a target I would prove with practice runs in staging.
- No walkthrough video.

## Assumptions

- A VPN between the data centre and AWS exists, and MySQL binary logging can be turned on.
- Order, inventory and payment each have a schema in one MySQL instance.
- The target is MySQL 8.0 because 5.7 is end of life.
- Cost numbers are rough estimates. The on-prem figure is a guess and should be replaced with real finance numbers.
- No real company data or credentials are used. The application is a small skeleton I wrote for this exercise.

## How to try it

```bash
# Terraform checks (no AWS login needed)
cd terraform/stack
terraform init -backend=false
terraform validate

# Helm
helm lint deploy/helm/inventory -f deploy/helm/inventory/values-prod.yaml

# Service tests
cd services/inventory
npm test

# Real deployment (needs an AWS account)
cd terraform/bootstrap && terraform apply -var env=dev
cd ../stack
terraform init -backend-config=envs/dev.backend.hcl
terraform plan -var-file=envs/dev.tfvars
```
