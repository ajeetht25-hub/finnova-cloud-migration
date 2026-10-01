# 06 – Cost Estimate & Optimization

> **Method and caveats.** AWS figures are rough monthly **on-demand list prices for us-east-1 / ap-south-1 order of magnitude**, built from the AWS Pricing Calculator line items below and rounded. Mumbai prices are typically 5–15 % higher; re-run the calculator with the final region before committing. The "before" column is an **assumed** on-prem TCO for the fictional FinNova (hardware amortised over 5 years, VMware licences, power/cooling/colo share, support contracts) and must be replaced with finance actuals. Scope = the Order Management domain only.

## 1. Before vs after (production, monthly, USD)

| Component | Before (on-prem, assumed) | After (AWS, on-demand) | After (with commitments) | Calculator line items |
|---|---|---|---|---|
| **Compute** (web/order/inventory/payment/batch) | 3,200 (2 app VMs, batch VM, Nginx, share of hosts + VMware) | 760 | 580 | EKS control plane $73; 3× m6i.xlarge app (~$420); 3× m6i.large PCI (~$210); batch Spot ~$30; ALB ~$25 |
| **Database** | 2,800 (2 DB hosts, MySQL support, SAN share, backup) | 1,040 | 790 | RDS db.r6g.xlarge Multi-AZ ≈ $760; 1 TB gp3 Multi-AZ ≈ $230; backup overage ≈ $50 |
| **Storage** (2 TB files) | 900 (NFS array amortisation + maintenance) | 35 | 35 | S3 2 TB with lifecycle (~$20 Standard + $12 IA/GIR + requests) |
| **Network / egress** | 600 (WAN, firewall share) | 215 | 215 | 3 NAT GWs ~$100 + data ~$60, VPN ~$40, data transfer out ~$15 |
| **Security & observability** | 400 | 120 | 120 | KMS + Secrets Manager ~$25, CloudWatch logs/metrics ~$70, GuardDuty ~$25 |
| **Datacenter share (power, space, ops)** | 1,600 | 0 | 0 | – |
| **Total** | **≈ 9,500** | **≈ 2,170** | **≈ 1,740** | |

One-time migration costs (not in monthly): DMS replication instance ~$130/month for about 2 months, DataSync ~$0.0125/GB × 2 TB ≈ $26, VPN, parallel running of both environments for ~1 month (~$2k), staging rehearsals.

### Non-production environments (monthly, on-demand)

| Environment | Estimate | Notes |
|---|---|---|
| dev | ~$350 | Spot t3 nodes, single NAT, db.t4g.medium; scheduled scale-to-zero nights/weekends can cut ~45 % |
| staging | ~$850 | m6i.large, single NAT, db.r6g.large single-AZ; torn down between rehearsals if cost matters |

## 2. Optimization opportunities

| # | Opportunity | Estimated saving | How |
|---|---|---|---|
| 1 | **Savings Plan / Reserved Instances** for steady load | ~$430/mo (≈ 20 %) | 1-yr Compute Savings Plan on the 6 baseline nodes (≈ 28 % of ~$630 ≈ $180), 1-yr RDS Reserved Instance on the instance only (≈ 33 % of ~$760 ≈ $250); storage is not discounted. Commit only after 2–4 weeks of real metrics |
| 2 | **Right-size RDS and nodes** | $100–250/mo | Start at db.r6g.xlarge; review Performance Insights/CloudWatch after 2 weeks; step down to db.r6g.large if CPU < 30 % and memory free > 50 %. Same for nodes using requests vs actual usage (VPA recommendations) |
| 3 | **Spot for batch and non-prod** | ~70 % off those nodes (~$60 prod+dev) | Reports are idempotent CronJobs on the `batch-spot` group with multiple instance types; dev apps on Spot |
| 4 | **S3 lifecycle** (implemented) | ~$20/mo vs Standard, more as data ages | Standard → IA at 30 d → Glacier IR at 90 d; 365-day expiry for reports; abort incomplete multipart uploads |
| 5 | **Cut NAT data charges** | $30–80/mo | S3 gateway endpoint (implemented); add interface endpoints for ECR, STS, Secrets Manager, CloudWatch Logs; one NAT in non-prod |
| 6 | **Autoscaling thresholds** | 10–20 % of compute | HPA CPU target 65 %, scale-down stabilisation 300 s; Cluster Autoscaler/Karpenter consolidation; scale non-prod to zero outside business hours |
| 7 | **Graviton** | ~15–20 % better price/performance | Build multi-arch images; move to m7g/c7g nodes and r6g/r7g RDS (RDS already Graviton here) |
| 8 | **Governance** | Prevents overruns | AWS Budgets 50/80/100 %, Cost Anomaly Detection, mandatory tags (`Environment`, `CostCenter`, `Owner`) via provider `default_tags`, monthly FinOps review |
| 9 | **Decommission quickly** | ~$130/mo + double-running | Remove DMS instance and on-prem assets as soon as the rollback window closes |

## 3. TCO reasoning (for the 6R discussion)

* Savings come mostly from removing capacity sized for the biggest sales peak: on-prem runs that capacity all year, AWS runs the baseline and bursts with HPA/autoscaling.
* The database is the largest AWS cost; Multi-AZ doubles it but replaces the on-prem replica and manual failover, so it is a like-for-like HA comparison.
* Break-even: migration effort (≈ 2 engineers × 3 months + one-time costs) pays back in about 6–9 months at the estimated delta of ~$7k/month; sensitivity: if the true on-prem TCO is only $6k/month the payback moves to ~2 years and the argument rests on elasticity and resilience, not cost.

## 4. Reproducing the estimate

AWS Pricing Calculator (https://calculator.aws): create an estimate named `finnova-prod` with: Amazon EKS (1 cluster), EC2 (3× m6i.xlarge + 3× m6i.large, Linux, On-Demand, EBS 50 GB gp3 each), RDS for MySQL (db.r6g.xlarge, Multi-AZ, 1000 GB gp3, 12,000 IOPS/500 MB/s, 14 d backup), S3 (2,048 GB split Standard/IA/GIR), Application Load Balancer, NAT Gateway ×3 (+ 2 TB/month processed), Secrets Manager (6 secrets), KMS (6 keys), CloudWatch (logs 100 GB/month), Site-to-Site VPN. Export the estimate as CSV and attach it with the submission.
