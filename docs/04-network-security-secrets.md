# 04 – Network Segmentation, Security & Secrets

## 1. Network segmentation

CIDR plan (prod `10.30.0.0/16`, one /20 per subnet per AZ):

| Tier | Subnets | Contains | Route to internet | Ingress allowed from |
|---|---|---|---|---|
| Public | `10.30.0.0/20` … | ALB, NAT gateways | IGW | Internet → 443 (ALB SG only) |
| App | `10.30.64.0/20` … | EKS `app` nodes (web, order, inventory), `batch` Spot nodes | Egress via NAT | ALB SG → 8080 |
| **PCI** | `10.30.128.0/20` … | EKS `pci` nodes (payment service **only**) | Egress via NAT, HTTPS only | App SG → 8443 only |
| Data | `10.30.192.0/20` … | RDS | **None** | App SG + PCI SG → 3306 |

### Allowed flows (everything else is denied)

| From | To | Port | Enforced by |
|---|---|---|---|
| Internet | ALB | 443 | ALB SG |
| ALB | web/order pods | 8080 | App-node SG referencing ALB SG |
| order service | payment service | 8443 (mTLS) | PCI-node SG (source = App SG), PCI NACL, Kubernetes NetworkPolicy |
| order / inventory / batch | RDS | 3306 | DB SG (source = App SG) |
| payment | RDS | 3306 | DB SG (source = PCI SG) |
| payment | PSP / AWS APIs | 443 | PCI SG egress, NACL egress 443 |
| pods | Secrets Manager / STS | 443 | via NAT (or interface endpoints) |
| anything else, incl. App ⇄ PCI on other ports, PCI → internet on other ports, Internet → data | | | **denied** |

### How the payment service is isolated

Defence in depth: five independent layers, so a mistake in one does not break isolation.

1. **Subnet + route table**: dedicated PCI subnets and route tables, no peering with other tiers other than the allowed flows.
2. **Network ACL** (stateless): inbound 8443 only from app subnets; outbound 443 (PSP), 3306 to data subnets, ephemeral replies. Everything else is implicitly denied.
3. **Security group**: `pci-nodes` SG accepts only 8443 from `app-nodes` SG. Not shared with any other workload.
4. **Dedicated node group**: nodes labelled `pci=true` and tainted `pci=true:NoSchedule`. Only the payment Deployment tolerates the taint and has the matching `nodeSelector`, so no non-PCI pod shares a host.
5. **Identity & Kubernetes**: separate `payments` namespace; own ServiceAccount bound to its own IRSA role (`finnova-prod-payment-irsa`) that can read only the payment secret; default-deny NetworkPolicy allowing ingress only from the `orders` namespace pods labelled `app=order`; Pod Security Standard `restricted` on the namespace.

Plus: VPC Flow Logs on all traffic, EKS audit logs, GuardDuty (EKS + RDS protection) and a quarterly segmentation test (attempt blocked flows from app tier and verify they are denied and alerted) as PCI evidence.

## 2. Secrets: from static files to Secrets Manager

### Before
Static config files on the VMs with embedded plaintext DB credentials (`db.properties`/`.env`), copied between servers, readable by anyone with shell access, not rotated.

### After

```
 Terraform ──creates──> Secrets Manager secret  finnova-prod/inventory/db   (KMS CMK, value set out-of-band)
                                  ▲
 05-rotate-service-secrets.sh ────┘ writes {username,password,host,port} at cutover (never in Git/state)
                                  │ GetSecretValue (own secret only, via IRSA)
 Pod ── ServiceAccount (IRSA) ──> Secrets Store CSI driver + AWS provider
                                  │ mounts as a read-only file  /mnt/secrets/db
 App reads DB_SECRET_FILE ──> loadDbConfig()   (re-read every 60 s => rotation without redeploy)
```

* **Storage**: one secret per service per environment, encrypted with a customer-managed KMS key. RDS admin credential is **RDS-managed** (`manage_master_user_password`), auto-rotated, and only DBAs/DMS roles can read it.
* **Retrieval at runtime**: the Helm chart creates a `SecretProviderClass` and mounts it with the CSI volume; pod identity comes from IRSA, so there are no AWS keys in the pod. The application reads the file path in `DB_SECRET_FILE` (see `services/inventory/src/config.js`).
* **No plaintext anywhere**: not in the image (Trivy secret scan + gitleaks in CI), not in environment variables, not in Helm values, not in Terraform state (placeholder with `ignore_changes`).
* **Rotation**: Secrets Manager rotation Lambda (MySQL single-user/alternating-user strategy) every 30 days; because the app re-reads the mounted file, rotation needs no restart. Legacy credentials from the old config files are revoked after the 14-day rollback window.

### Least-privilege IAM (excerpt from `terraform/modules/secrets/main.tf`)

```hcl
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
    values   = ["secretsmanager.ap-south-1.amazonaws.com"]
  }
}
```

Trust policy: `sts:AssumeRoleWithWebIdentity` restricted to `system:serviceaccount:<namespace>:<service>` and `aud=sts.amazonaws.com`. The payment role is bound to the `payments` namespace only.

## 3. Other IAM / access boundaries

| Principal | Allowed | Not allowed |
|---|---|---|
| GitHub Actions build role (OIDC, repo+branch condition) | ECR push to `finnova/*` | EKS, RDS, secrets |
| GitHub Actions deploy role (per env) | `eks:DescribeCluster`; mapped through EKS access entry to a namespaced Kubernetes role | cluster-admin, other namespaces |
| Terraform plan role | Read-only | Any write |
| Terraform apply role | Provisioning, behind approval | Used from laptops (blocked by trust policy) |
| Node roles | EKS worker, ECR read-only, SSM core | Secrets Manager, S3, RDS |
| Humans | SSO, read-only by default; break-glass role with MFA and alerting | Static IAM users/keys |

## 4. Encryption summary

| Data | At rest | In transit |
|---|---|---|
| RDS | KMS CMK (storage, PI, logs) | TLS enforced (`require_secure_transport`), `VERIFY_IDENTITY` from clients |
| S3 | SSE-KMS + bucket keys | Bucket policy denies non-TLS |
| EKS secrets / etcd | KMS envelope encryption | TLS to private API endpoint |
| EBS (nodes) | Encrypted gp3 | – |
| Service ↔ payment | – | mTLS on 8443 |
| DMS | Encrypted instance storage | SSL on both endpoints, over VPN |
| Terraform state | KMS-encrypted S3 | TLS |
