# 05 – Runbook: Execution, Rollback, Validation

Audience: migration lead, DBA, platform engineer, release manager. Every phase has an owner, a go/no-go gate and a rollback.

## 0. Roles and communication

| Role | Responsibility |
|---|---|
| Migration lead | Owns go/no-go, runs the bridge call |
| DBA | DMS, validation, cutover script |
| Platform engineer | Terraform, EKS, pipelines |
| App lead(s) | Smoke tests, app config |
| Security | Segmentation test, secrets sign-off |
| Business owner | Final sign-off, decommission approval |

Comms: dedicated channel, status every 15 min during a cutover window, one rollback decider (migration lead).

## 1. Phase-by-phase execution

### Phase 0 – Foundations (dev → staging → prod)

1. `cd terraform/bootstrap && terraform apply -var env=<env>` (once per account).
2. `cd terraform/stack && terraform init -backend-config=envs/<env>.backend.hcl && terraform plan -var-file=envs/<env>.tfvars -out tfplan` → review → `terraform apply tfplan` (via the `terraform` workflow).
3. Install platform add-ons (Helm): AWS Load Balancer Controller, Secrets Store CSI driver + AWS provider, metrics-server, Cluster Autoscaler or Karpenter, Argo Rollouts.
4. Create GitHub Environments `dev`, `staging`, `prod` with variables (`AWS_ROLE_ARN_DEPLOY`, `EKS_CLUSTER`, `ECR_REGISTRY`, `INVENTORY_IRSA_ROLE_ARN`); add **required reviewers** to `prod`.
5. Establish the Site-to-Site VPN; test throughput with `iperf3` (record Mbps for DMS planning).

**Gate:** VPN stable 48 h, `terraform plan` shows no drift, node groups Ready, a hello-world pod can read a test secret via CSI.

### Phase 1 – Data plane preparation

1. On-prem: run `db/00-source-prereqs.sql`; fix tables without primary keys; confirm binlog settings.
2. Start `db/01-schema-and-full-load.sh` (full load + CDC). Monitor `describe-table-statistics` and CloudWatch `CDCLatencyTarget`.
3. Create the reverse task with `db/01b-create-reverse-task.sh` (do not start).
4. NFS: `aws datasync create-task` NFS → `finnova-prod-assets`; run the initial copy; schedule hourly delta syncs; verify with `--verify-mode ONLY_FILES_TRANSFERRED` then a final full verify.

**Gate:** CDC lag < 5 s for 24 h, `02-validate.sh` passes, DataSync delta < 5 min.

### Phase 2 – Stateless services and batch (staging first)

1. Merge to `main` → pipeline builds, scans, pushes `inventory` and deploys to dev, then staging automatically.
2. Repeat for order. Convert nightly cron scripts to Kubernetes `CronJob`s on the `batch` Spot group writing to the reports bucket.
3. Run the functional + load test suite in staging against the RDS 8.0 replica.

**Gate:** staging soak 72 h without SLO breach; HPA scaling verified at 2x peak.

### Phase 3 – Payment service

1. Deploy to the `payments` namespace on the PCI nodes with the canary procedure in section 3.
2. Run the segmentation test (section 5.4) and obtain Security sign-off.

**Gate:** all negative network tests blocked, secret access limited to the payment secret.

### Phase 4 – Cutover (change window, low-traffic period)

Pre-flight checklist (all must be ✔):

- [ ] CDC lag < 5 s for 24 h; full `02-validate.sh` passed within last 24 h
- [ ] Three successful staging rehearsals with timing recorded (p95 < 4 min)
- [ ] DNS TTL lowered to 30 s a day earlier
- [ ] Maintenance page tested; on-prem Ansible playbooks verified
- [ ] Reverse task created and test-started once in staging
- [ ] Rollback decider and DBA present; on-call engineers acknowledged
- [ ] Change approved; no sales event in the next 72 h

Execution:

1. `export TASK_ARN=... REVERSE_TASK_ARN=... SRC_HOST=... TGT_HOST=... EKS_CONTEXT=... ENV_NAME=prod`
2. `./db/03-cutover.sh` (scripted, timings printed). Watch the output on the bridge.
3. Shift web traffic: Route 53 weighted records 10 % → 50 % → 100 % to the ALB, 10 min at each step (the web tier can be moved before or after the DB depending on rehearsal results; the DB cutover is the single atomic step).

### Phase 5 – Hypercare and decommission

* 48 h hypercare with tightened alerts; daily `02-validate.sh` in read-only mode against on-prem (reverse task) for 14 days.
* After sign-off: stop the reverse task, delete DMS instance, take final on-prem snapshots, power off VMs, delete NFS after 30 more days, revoke legacy credentials, remove VPN if no longer needed.

## 2. Rollback matrix

| Trigger | Decision window | Procedure | Owner |
|---|---|---|---|
| Terraform apply fails | Any time | Fix forward or `terraform apply` the previous commit; state is versioned in S3 | Platform |
| Helm deployment fails readiness | Automatic | `helm upgrade --atomic` rolls back on its own | Pipeline |
| Smoke test fails after Helm success | Automatic | `_deploy.yml` runs `helm rollback` | Pipeline |
| Bad release found later | < 5 min | `inventory-service` workflow dispatch with `rollback_environment=prod` (or `helm rollback <release> <rev>`) | Release mgr |
| DB validation fails in freeze | Immediate | `./db/04-rollback.sh --before-switch` | DBA |
| DB / app failure after cutover | 14 days | `./db/04-rollback.sh --after-switch` (reverse replication already current) | DBA + lead |
| Web tier regression after traffic shift | Immediate | Set Route 53 weight back to 100 % on-prem (TTL 30 s) | Platform |
| Secret compromise | Immediate | Rotate the secret in Secrets Manager (CSI picks up within 60 s) and revoke the IRSA role session | Security |

## 3. Zero-downtime deployment for the payment service (PCI-aware)

**Chosen strategy: canary with automated analysis (Argo Rollouts) on a dedicated PCI node group, with blue/green semantics for the database and message contracts.**

Why not plain rolling update: payment requests are not safely retryable by clients and each release changes money-moving code, so we want a *measured* exposure (1 % → 10 % → 50 % → 100 %) with automatic abort, not instant replacement of all pods.

Why not full blue/green: a full duplicate environment would double the PCI-scoped footprint (more in-scope nodes, more audit evidence). A canary inside the existing PCI node group keeps the scope constant.

Mechanics:

1. **Capacity**: PCI node group has headroom (`maxSurge=25 %`, Cluster Autoscaler may add a node, always inside the PCI subnets with the same SG/IRSA). The canary pods use the same ServiceAccount, taint toleration and NetworkPolicy, so isolation is identical for old and new versions.
2. **Traffic split**: the order service calls the payment `Service`; Argo Rollouts shifts weight at the ALB target-group level (or via the Gateway API/service mesh) 1 % → 10 % → 50 % → 100 % with a pause and `AnalysisTemplate` between steps.
3. **Automated analysis** (Prometheus/CloudWatch): HTTP 5xx rate < 0.5 %, p95 latency < 400 ms, payment authorisation success rate not lower than baseline − 0.5 %, PSP error ratio, DB error ratio. Any breach aborts and returns 100 % to the stable ReplicaSet automatically.
4. **Request safety**: all payment calls carry an **idempotency key**; the service persists it, so retries during pod termination cannot double-charge. In-flight requests finish: `preStop` sleep 15 s, `terminationGracePeriodSeconds` 60 s, readiness fails first on SIGTERM, ALB deregistration delay 30 s.
5. **Database changes**: expand/contract only. Release N adds nullable columns/tables (compatible with N-1), release N+1 starts using them, release N+2 removes old structures. This is what makes rollback of the app safe at any step.
6. **Availability guards**: PDB `minAvailable: 2`, topology spread across AZs, readiness probe that verifies PSP connectivity and DB pool, startup probe to avoid premature traffic.
7. **PCI compliance during deploy**: the image comes only from the hardened pipeline (scan gate, signed with cosign, admission policy verifies signature), deployment needs a **two-person approval** (GitHub Environment reviewers), every promotion is logged (change record = workflow run + commit SHA) and no human `kubectl` access to the namespace.
8. **Rollback**: automated on analysis failure; manual is `kubectl argo rollouts abort/undo payment -n payments` or `helm rollback`.

## 4. Post-migration validation checklist

**Data**

- [ ] `02-validate.sh` passes on RDS vs on-prem (all four layers)
- [ ] Auto-increment values on RDS ≥ source max + safety margin
- [ ] No tables without primary keys; FKs/triggers/routines present (`information_schema` diff)
- [ ] File counts and checksums match between NFS and S3 (DataSync verify report)

**Application**

- [ ] All pods Ready; zero restarts in 1 h; HPA reacts to a load test
- [ ] Order → inventory → payment end-to-end test order succeeds
- [ ] Nightly report job produced its report in S3 and in the same format
- [ ] Canary order cleaned up

**Security**

- [ ] No plaintext credentials in repos, images (Trivy), configs or env vars (`kubectl describe` check)
- [ ] RDS not publicly accessible; DB SG sources limited to the two node SGs
- [ ] Negative network tests blocked (section 5.4)
- [ ] CloudTrail/Config/GuardDuty enabled; flow logs flowing
- [ ] Legacy credentials revoked (after rollback window)

**Operations**

- [ ] Alarms: RDS CPU/connections/replica lag, 5xx, pod restarts, node pressure, NAT bytes, budget alerts
- [ ] Backups: RDS automated backup exists, one restore test performed
- [ ] Runbook and on-call rotation updated

**Cost**

- [ ] Budgets at 50 / 80 / 100 %, cost allocation tags visible, DMS instance removed, Savings Plan evaluated after 2 weeks of data

## 5. Failure drill: failed production cutover in real time (for the follow-up discussion)

1. **Detect**: validation fails, smoke test fails, error rate > 2 % or the 5-minute budget is about to be exceeded.
2. **Decide**: the migration lead decides within 60 s; bias to rollback if there is any doubt about data integrity.
3. **Act**: before the switch → `04-rollback.sh --before-switch` (seconds). After the switch → `--after-switch`: stop AWS writers, drain the reverse task, enable on-prem.
4. **Verify**: row counts + invariants in the *reverse* direction, smoke test against on-prem, lift the maintenance page.
5. **Communicate** and open a blameless review: capture timings, logs, root cause; schedule a new rehearsal before the next attempt.

### 5.4 Segmentation test (run in Phase 3 and quarterly)

```bash
# From an order pod: should SUCCEED (allowed flow)
kubectl -n orders exec deploy/order -- wget -qO- --timeout=3 https://payment.payments.svc:8443/healthz
# From inventory pod: should FAIL (NetworkPolicy)
kubectl -n orders exec deploy/inventory -- wget -qO- --timeout=3 https://payment.payments.svc:8443/healthz
# From a payment pod: reaching the batch namespace or the internet on 80 should FAIL
kubectl -n payments exec deploy/payment -- wget -qO- --timeout=3 http://example.com
# Secrets: payment role must not read other secrets
kubectl -n payments exec deploy/payment -- aws secretsmanager get-secret-value --secret-id finnova-prod/order/db   # AccessDenied
```
