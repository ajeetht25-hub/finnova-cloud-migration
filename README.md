# FinNova Retail – Order Management Cloud Migration (L2 Assessment Submission)

**Candidate:** Ajeeth T  **Target cloud:** AWS (ap-south-1)  **CI/CD:** GitHub Actions  **Reference microservice:** Inventory

This repository is a proof-of-concept migration of the Order Management domain from on-prem VMware to AWS (EKS + RDS MySQL 8.0 + S3 + Secrets Manager), as specified in the assignment. Cloud choice justification is in `docs/01-strategy.md`.

## What is in the repo

| Deliverable (checklist #) | Location |
|---|---|
| 1. Assessment & strategy: 6R, dependency map, risk register, phases | `docs/01-strategy.md` |
| 2. Target architecture diagram | `docs/architecture.svg` (+ Mermaid in `docs/02-architecture-and-iac.md`) |
| 3. Terraform: VPC, subnets, SGs, EKS, RDS, secrets, S3, state | `terraform/` |
| 4. Dockerfile + Helm chart (inventory service) | `services/inventory/`, `deploy/helm/inventory/` |
| 5. CI/CD pipeline (build → test → scan → push → deploy, promotion, rollback) | `.github/workflows/` |
| 6. DB migration plan + scripts (DMS full load + CDC, validation, cutover, rollback) | `docs/03-database-migration.md`, `db/` |
| 7. Security and secrets handling | `docs/04-network-security-secrets.md`, `terraform/modules/secrets` |
| 8. Runbook (execution, rollback, validation, payment zero-downtime) | `docs/05-runbook.md` |
| 9. Cost estimate and optimization | `docs/06-cost-estimate.md` |
| 10. Walkthrough video | Not recorded (see "Skipped") |

## Completed

* All seven assignment tasks have a written design and implementation artifacts.
* Terraform: 5 modules + a single multi-environment root stack (`dev`/`staging`/`prod` via tfvars + backend config), remote state bootstrap.
* Inventory service skeleton with unit tests, hardened multi-stage distroless Dockerfile, Helm chart with probes, resources, HPA, PDB, NetworkPolicy and Secrets Store CSI integration.
* Pipelines for the service and for Terraform.

## Assumptions (full list in `docs/01-strategy.md` §1)

* VPN to AWS exists; MySQL binlog can be enabled; schemas `orders`, `inventory`, `payment` live in one MySQL instance.
* Target is MySQL **8.0** (5.7 is end-of-life); app compatibility is verified in staging.
* Cost numbers are estimates from calculator line items, and the on-prem baseline is an assumption to be replaced with real finance data.
* No real company data, credentials or source code are used. The fictional application is a minimal skeleton written for this exercise.

## Skipped / not done (stated explicitly per ground rules)

* **Not applied to a live AWS account.** Checks actually run while preparing this submission: inventory unit tests (3/3 pass) and lint, `bash -n` syntax check on all `db/*.sh`, JSON parse of the DMS configs, SVG parse. **`terraform validate`, `helm lint` and the Docker build were NOT run** (tools/network not available in the authoring environment); the `terraform` and `inventory-service` workflows run them on the first PR, so expect to fix minor issues there. Expected runtime behaviour is explained in the runbook.
* Platform add-ons (ALB controller, Secrets Store CSI/ASCP, autoscaler, Argo Rollouts), WAF rules and DR region are described but not coded.
* Order and payment services have no code or charts; inventory is the reference implementation of the pattern (payment-specific rollout is designed in the runbook §3).
* Walkthrough video not recorded.
* Scripts under `db/` were written for review and syntax-checked (`bash -n`), but not executed against real databases. The cutover timeline is a design target to be proven by the three staging rehearsals.

## How to review

```bash
# Terraform (no credentials needed for validation)
cd terraform/stack
terraform init -backend=false && terraform validate
terraform fmt -check -recursive ..

# Helm
helm lint deploy/helm/inventory -f deploy/helm/inventory/values-prod.yaml
helm template inv deploy/helm/inventory -f deploy/helm/inventory/values-prod.yaml \
  --set image.repository=example --set image.tag=abc123

# Service
cd services/inventory && npm test
docker build -t inventory:local .

# Real deployment (needs an AWS account)
cd terraform/bootstrap && terraform apply -var env=dev
cd ../stack && terraform init -backend-config=envs/dev.backend.hcl && terraform plan -var-file=envs/dev.tfvars
```

## Suggested discussion topics (least-confident trade-offs)

1. DMS vs native replication for the 5.7 → 8.0 hop and the rollback story (reverse task).
2. Shared RDS instance for three schemas in phase 1 versus per-service databases (blast radius vs cost).
3. Canary on a shared PCI node group instead of full blue/green for payment (scope vs isolation of releases).
4. What breaks first at 10x: single-writer RDS, NAT egress cost, ALB target limits.
