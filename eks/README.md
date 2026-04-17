# ec2kube → EKS Modernization

Zero-touch automation for **Amazon EKS on Kubernetes 1.34** with **Karpenter** node management and **dual identity support** (EKS Pod Identity + IRSA).

> **Original project**: Self-managed Kubernetes cluster on EC2 using Terraform, Ansible, and Jenkins.
> **Modernized to**: Managed Amazon EKS with Karpenter autoscaling, current APIs, and production-safe defaults.

---

## Table of Contents

1. [Assumptions](#1-assumptions)
2. [Required Inputs](#2-required-inputs)
3. [Updated Zero-Touch Script](#3-updated-zero-touch-script)
4. [Step-by-Step Execution Flow](#4-step-by-step-execution-flow)
5. [What Changed](#5-what-changed)
6. [Pod Identity vs IRSA Notes](#6-pod-identity-vs-irsa-notes)
7. [Validation Checklist](#7-validation-checklist)
8. [Rollback Plan](#8-rollback-plan)
9. [Known Risks / Manual Review Items](#9-known-risks--manual-review-items)

---

## 1. Assumptions

| # | Assumption |
|---|-----------|
| 1 | Amazon EKS supports Kubernetes **1.34** at time of execution |
| 2 | The operator has an AWS account with permissions to create EKS clusters, IAM roles/policies, EC2 instances, SQS queues, and EventBridge rules |
| 3 | `aws`, `eksctl`, `kubectl`, `helm`, `jq`, and `curl` are installed and in `$PATH` |
| 4 | `eksctl` version ≥ 0.200.0 (supports EKS 1.34 and Pod Identity) |
| 5 | `kubectl` version is compatible with Kubernetes 1.34 (within ±1 minor version) |
| 6 | `helm` version ≥ 3.16.x |
| 7 | AWS CLI v2 is configured with credentials (`aws configure` or environment variables) |
| 8 | Karpenter **v1.3.0** (or the version specified) is compatible with EKS 1.34 |
| 9 | Karpenter uses `karpenter.sh/v1` (NodePool) and `karpenter.k8s.aws/v1` (EC2NodeClass) APIs |
| 10 | The cluster is **not greenfield** — the script handles both new creation and updates to existing clusters |
| 11 | Pod Identity is the **recommended** identity mechanism for new EKS 1.34 deployments; IRSA is supported as a fallback |
| 12 | For the Karpenter controller, Pod Identity is preferred when `AUTH_MODE=pod-identity` or `both`; IRSA annotation is added as fallback when `AUTH_MODE=irsa` or `both` |
| 13 | The managed node group (`system`) serves as a bootstrap pool for Karpenter pods and system workloads |
| 14 | Amazon Linux 2023 is the default node OS via `amiSelectorTerms: [{alias: al2023@latest}]` |

---

## 2. Required Inputs

All inputs are configured in **`eks/env.conf`**. Items marked **REQUIRED** must be filled in before running.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `AWS_ACCOUNT_ID` | **REQUIRED** | — | 12-digit AWS account ID |
| `CLUSTER_NAME` | optional | `ec2kube-eks` | EKS cluster name |
| `AWS_REGION` | optional | `us-east-1` | AWS region |
| `AUTH_MODE` | optional | `pod-identity` | Identity mode: `pod-identity`, `irsa`, or `both` |
| `K8S_VERSION` | optional | `1.34` | Target Kubernetes version |
| `KARPENTER_VERSION` | optional | `1.3.0` | Karpenter Helm chart version |
| `STATE_BUCKET` | optional | — | S3 bucket for Terraform state (legacy, not used by EKS scripts) |
| `SSH_PUBLIC_KEY` | optional | — | SSH public key for node access |
| `INSTANCE_FAMILIES` | optional | `m5,m6i,m7i,c5,c6i,c7i,r5,r6i,r7i` | Allowed EC2 instance families |
| `CAPACITY_TYPES` | optional | `on-demand,spot` | Node capacity types |
| `NODEPOOL_CPU_LIMIT` | optional | `100` | Max vCPUs Karpenter can provision |
| `NODEPOOL_MEMORY_LIMIT` | optional | `400` | Max memory (Gi) Karpenter can provision |
| `MNG_INSTANCE_TYPE` | optional | `m5.large` | Bootstrap managed node group instance type |
| `MNG_MIN_SIZE` | optional | `2` | Bootstrap node group minimum |
| `MNG_MAX_SIZE` | optional | `3` | Bootstrap node group maximum |
| `MNG_DESIRED_SIZE` | optional | `2` | Bootstrap node group desired count |

---

## 3. Updated Zero-Touch Script

### File Structure

```
ec2kube/
├── eks/
│   ├── deploy-eks.sh              # Main zero-touch deployment script
│   ├── teardown-eks.sh            # Safe teardown / rollback script
│   ├── env.conf                   # Configuration — edit before first run
│   └── manifests/
│       ├── ec2nodeclass.yaml      # Reference EC2NodeClass manifest
│       ├── nodepool.yaml          # Reference NodePool manifest
│       └── test-workload.yaml     # Test deployment for validation
├── Jenkinsfile.eks                # Modernized Jenkins pipeline
├── Jenkinsfile                    # Original pipeline (preserved)
├── networking/                    # Original Terraform (preserved)
├── instances/                     # Original Terraform (preserved)
├── node_asg/                      # Original Terraform (preserved)
├── ansible_infra/                 # Original Ansible (preserved)
└── README.md
```

### Quick Start

```bash
# 1. Edit configuration
vi eks/env.conf   # Set AWS_ACCOUNT_ID at minimum

# 2. Choose identity mode
export AUTH_MODE=pod-identity   # or: irsa, both

# 3. Deploy
./eks/deploy-eks.sh

# 4. Teardown (when needed)
./eks/teardown-eks.sh
# or non-interactive:
FORCE_DESTROY=Y ./eks/teardown-eks.sh
```

### Jenkins Pipeline

Use `Jenkinsfile.eks` for CI/CD:
1. Create a Jenkins pipeline job pointing to `Jenkinsfile.eks`
2. Set parameters: `AUTH_MODE`, `CLUSTER_NAME`, `TERRADESTROY`
3. Run the pipeline

---

## 4. Step-by-Step Execution Flow

The `deploy-eks.sh` script executes these phases in order:

| Phase | Description | Key Actions |
|-------|-------------|-------------|
| **0** | Prerequisites & Validation | Check CLIs, versions, AWS identity, region, account match |
| **1** | EKS Cluster | Check if cluster exists → create or upgrade to 1.34; update kubeconfig |
| **2** | Add-on Updates | Update vpc-cni, coredns, kube-proxy, ebs-csi-driver, (pod-identity-agent); wait for ACTIVE |
| **3** | Identity Setup | Based on `AUTH_MODE`: create OIDC provider (IRSA), install pod-identity-agent, verify agent health |
| **4** | Karpenter IAM | Create node role + instance profile; create controller role + policy; create SQS queue + EventBridge rules; tag subnets/SGs; install Karpenter via Helm |
| **5** | EC2NodeClass | Apply EC2NodeClass with AL2023 AMI, encrypted gp3 volumes, IMDSv2 |
| **6** | NodePools | Apply general-purpose NodePool with configurable instance families, capacity types, consolidation |
| **7** | Test Workload | Deploy `inflate` pods targeting Karpenter-managed nodes |
| **8** | Scale-Out Verification | Wait for Karpenter to provision nodes; verify pods reach Running state |
| **9** | Node Readiness | Print all nodes, pods, NodePools, EC2NodeClasses, Karpenter controller status |
| **10** | Consolidation Test | Scale to 0, observe node removal; scale back up |
| **11** | Identity Validation | Verify Pod Identity agent, associations, OIDC provider, SA annotations |
| **12** | Final Status | Print cluster info, add-on versions, next steps |

---

## 5. What Changed

### Architecture Changes

| Aspect | Original (ec2kube) | Modernized (EKS) |
|--------|-------------------|-------------------|
| **Cluster type** | Self-managed K8s on EC2 (kubeadm) | Amazon EKS managed control plane |
| **K8s version** | Unversioned (latest kubeadm) | Explicit 1.34 |
| **Control plane** | Single t3.medium EC2 instance | EKS managed (multi-AZ, HA) |
| **Worker nodes** | ASG with kubeadm join | Karpenter + bootstrap managed node group |
| **Node OS** | Ubuntu (bionic) with Docker | Amazon Linux 2023 (containerd) |
| **Networking** | Manual VPC + Flannel CNI | eksctl-managed VPC + Amazon VPC CNI |
| **Autoscaling** | Static ASG (2–5 nodes) | Karpenter dynamic provisioning |
| **Identity** | SSH keys + IAM users | Pod Identity / IRSA |
| **Provisioning** | Terraform + Ansible + Jenkins | eksctl + Helm + kubectl + bash |
| **Node joining** | kubeadm token + Ansible | EKS managed (auto-join via node role) |

### Specific Changes

| Item | Change | Reason |
|------|--------|--------|
| `kubeadm init/join` | Replaced by EKS managed control plane + Karpenter | EKS handles K8s lifecycle |
| Docker runtime | Removed | EKS 1.34 uses containerd; Docker/dockershim removed in K8s 1.24 |
| Flannel CNI | Replaced by Amazon VPC CNI | Native EKS networking with prefix delegation |
| `aws_launch_configuration` | Removed | Deprecated; Karpenter manages instance lifecycle |
| `aws_autoscaling_group` | Replaced by Karpenter NodePool | Dynamic, bin-packing provisioning |
| Ansible playbooks | Replaced by eksctl/kubectl/helm | No SSH-based bootstrapping needed |
| Terraform networking | Replaced by eksctl-managed VPC | Simpler, EKS-optimized defaults |
| `ec2_instance_facts` | Removed | No EC2 discovery needed with EKS |
| `aws_s3` inventory sharing | Removed | No Ansible inventory needed |
| Hardcoded AMI `ami-0e472ba40eb589f49` | Replaced by `amiSelectorTerms: [{alias: al2023@latest}]` | Always uses latest EKS-optimized AMI |
| `daemon.json` cgroupdriver | Removed | containerd uses systemd cgroup by default |
| Provisioner/AWSNodeTemplate | **Not used** | Using current NodePool + EC2NodeClass (Karpenter v1 API) |
| AWS provider `~> 3.74.1` | Removed | Using AWS CLI / eksctl instead of Terraform |
| S3 bucket module `2.6.0` | Removed | No Ansible infrastructure needed |
| Travis CI configs | Removed | Not needed for EKS deployment |
| `t2.micro` worker nodes | Replaced by configurable instance families | t2.micro insufficient for production K8s |

### Security Improvements

| Improvement | Details |
|-------------|---------|
| IMDSv2 required | `httpTokens: required` in EC2NodeClass prevents SSRF attacks |
| EBS encryption | `encrypted: true` on all node volumes |
| Least-privilege IAM | Karpenter controller policy scoped to specific resources |
| No SSH keys on nodes | Nodes managed via SSM; no SSH key pair by default |
| SQS encryption | `SqsManagedSseEnabled: true` for interruption queue |
| Pod Identity | Token-based, no long-lived credentials in pods |

---

## 6. Pod Identity vs IRSA Notes

### Overview

| Feature | Pod Identity | IRSA |
|---------|-------------|------|
| **Mechanism** | EKS Pod Identity Agent (DaemonSet) exchanges pod tokens for AWS credentials | OIDC-based web identity federation; projected service account tokens |
| **Trust policy** | `pods.eks.amazonaws.com` service principal | OIDC provider as federated principal |
| **Setup complexity** | Lower (no OIDC provider management) | Higher (OIDC provider + per-SA trust) |
| **EKS requirement** | Pod Identity Agent add-on must be installed | OIDC provider must be associated |
| **SDK requirement** | AWS SDK must support Pod Identity (2023+ SDK versions) | Supported by all modern SDKs |
| **Cross-account** | Supported via trust policy | Supported via trust policy |
| **Recommendation** | **Preferred for EKS 1.34+** | Fallback / legacy clusters |

### Karpenter Controller Identity Decision

**Recommendation**: Use **Pod Identity** for the Karpenter controller on EKS 1.34.

- Pod Identity is simpler to configure and manage at scale
- The Karpenter Helm chart supports both mechanisms
- When `AUTH_MODE=pod-identity`: Pod Identity association is created; no SA annotation needed
- When `AUTH_MODE=irsa`: OIDC-based role with SA annotation
- When `AUTH_MODE=both`: Pod Identity association + IRSA annotation; Pod Identity takes precedence

### Implementation Details

#### Pod Identity Flow
```
1. eks-pod-identity-agent installed as EKS add-on (DaemonSet)
2. IAM role created with trust: {"Service": "pods.eks.amazonaws.com"}
3. aws eks create-pod-identity-association links role ↔ (namespace, service-account)
4. Agent injects credentials into pod via mounted token
5. AWS SDKs detect credentials automatically
```

#### IRSA Flow
```
1. OIDC provider created/associated with cluster
2. IAM role created with web identity trust policy referencing OIDC provider
3. Service account annotated: eks.amazonaws.com/role-arn = <role-arn>
4. EKS projects token into pod at well-known path
5. AWS SDKs use token for sts:AssumeRoleWithWebIdentity
```

### When to Use Which

| Scenario | Recommendation |
|----------|---------------|
| New EKS 1.24+ cluster | Pod Identity |
| Existing cluster with IRSA already configured | Keep IRSA, migrate gradually |
| Cross-account access | Either works; Pod Identity is simpler |
| Application workloads | Pod Identity preferred |
| Karpenter controller | Pod Identity preferred on 1.34 |
| Third-party controllers that don't support Pod Identity yet | IRSA |

---

## 7. Validation Checklist

Run these commands after deployment to verify everything:

### Cluster & Identity
```bash
# AWS identity
aws sts get-caller-identity

# Cluster info
aws eks describe-cluster --name ec2kube-eks --query '{Version:cluster.version,Status:cluster.status}'

# kubectl connectivity
kubectl version
kubectl cluster-info
```

### Nodes
```bash
# All nodes (should show managed + Karpenter nodes)
kubectl get nodes -o wide

# Karpenter-managed nodes specifically
kubectl get nodes -l managed-by=karpenter
```

### Pods
```bash
# All pods
kubectl get pods -A

# Karpenter controller
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter

# Pod Identity agent (if AUTH_MODE includes pod-identity)
kubectl get ds -n kube-system eks-pod-identity-agent
```

### EKS Add-ons
```bash
# List add-ons and their status
aws eks list-addons --cluster-name ec2kube-eks
for addon in $(aws eks list-addons --cluster-name ec2kube-eks --query 'addons[]' --output text); do
  aws eks describe-addon --cluster-name ec2kube-eks --addon-name $addon \
    --query '{Name:addon.addonName,Version:addon.addonVersion,Status:addon.status}'
done
```

### Identity
```bash
# Pod Identity associations
aws eks list-pod-identity-associations --cluster-name ec2kube-eks

# OIDC provider
aws eks describe-cluster --name ec2kube-eks --query 'cluster.identity.oidc.issuer'

# Karpenter service account
kubectl get sa karpenter -n kube-system -o yaml
```

### Karpenter Resources
```bash
# NodePools
kubectl get nodepools

# EC2NodeClasses
kubectl get ec2nodeclasses

# Karpenter controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=20
```

### Test Workload
```bash
# Test pods (should all be Running)
kubectl get pods -n eks-validation

# Verify pods are on Karpenter nodes
kubectl get pods -n eks-validation -o wide
```

### Consolidation
```bash
# Scale to 0 and watch nodes drain
kubectl scale deployment inflate -n eks-validation --replicas=0
watch kubectl get nodes -l managed-by=karpenter

# Scale back up
kubectl scale deployment inflate -n eks-validation --replicas=5
watch kubectl get pods -n eks-validation
```

---

## 8. Rollback Plan

### Scenario: Karpenter Issues

```bash
# 1. Scale down test workload
kubectl scale deployment inflate -n eks-validation --replicas=0

# 2. Delete NodePools (stops new node provisioning)
kubectl delete nodepools --all

# 3. Wait for Karpenter nodes to drain
kubectl get nodes -l managed-by=karpenter -w

# 4. If needed, scale up managed node group
eksctl scale nodegroup --cluster=ec2kube-eks --name=ec2kube-eks-system --nodes=3

# 5. Uninstall Karpenter
helm uninstall karpenter -n kube-system
```

### Scenario: Identity Issues

```bash
# Switch from Pod Identity to IRSA (or vice versa)
# 1. Update AUTH_MODE in env.conf
# 2. Re-run deploy-eks.sh (idempotent)

# Emergency: remove Pod Identity associations
aws eks list-pod-identity-associations --cluster-name ec2kube-eks
aws eks delete-pod-identity-association --cluster-name ec2kube-eks --association-id <id>
```

### Scenario: Full Cluster Rollback

```bash
# Use the teardown script
FORCE_DESTROY=Y ./eks/teardown-eks.sh
```

### Scenario: Partial Failure During Deploy

The deploy script is designed to be **re-runnable**:
- `eksctl create cluster` checks if cluster exists first
- `helm upgrade --install` is idempotent
- `kubectl apply` is idempotent
- IAM role/policy creation checks for existence
- Simply re-run `./eks/deploy-eks.sh` after fixing the root cause

### Migration from Original ec2kube

If you have an existing self-managed cluster from the original ec2kube project:

1. **Do not destroy the old cluster first** — run EKS deployment in parallel
2. Migrate workloads from kubeadm cluster to EKS using standard kubectl commands
3. Verify all workloads are healthy on EKS
4. Tear down the old infrastructure:
   ```bash
   cd node_asg && terraform destroy -auto-approve
   cd ../instances && terraform destroy -auto-approve
   cd ../networking && terraform destroy -auto-approve
   cd ../ansible_infra && terraform destroy -auto-approve
   ```

---

## 9. Known Risks / Manual Review Items

| # | Risk / Item | Mitigation |
|---|-------------|------------|
| 1 | **EKS 1.34 availability**: EKS may not yet support 1.34 in all regions | Verify with `aws eks describe-addon-versions --kubernetes-version 1.34` before running |
| 2 | **Karpenter version compatibility**: v1.3.0 compatibility with K8s 1.34 must be verified | Check [Karpenter compatibility matrix](https://karpenter.sh/docs/upgrading/compatibility/) |
| 3 | **Service quotas**: Account may have insufficient EC2 instance limits | Review `aws service-quotas list-service-quotas --service-code ec2` |
| 4 | **VPC CIDR exhaustion**: Default VPC may run out of IPs under heavy scaling | Enable VPC CNI prefix delegation (enabled by default in this config) |
| 5 | **Spot interruptions**: Spot instances may be reclaimed | Karpenter handles interruptions via SQS + EventBridge; configure `consolidationPolicy` appropriately |
| 6 | **AMI updates**: `al2023@latest` always uses the newest AMI | Node rotation happens per `expireAfter` (default 30 days); set shorter for faster patching |
| 7 | **IRSA token expiry**: IRSA tokens expire after 12 hours by default | Applications must handle token refresh (all modern AWS SDKs do this automatically) |
| 8 | **Pod Identity SDK requirements**: Older AWS SDKs may not support Pod Identity | Ensure workload containers use AWS SDK versions from 2023 or later |
| 9 | **eksctl managed VPC**: If eksctl creates the VPC, it owns the lifecycle | Use `EXISTING_VPC_ID` in env.conf to use a pre-existing VPC instead |
| 10 | **aws-auth ConfigMap**: eksctl manages it; manual edits may be overwritten | Use `eksctl create iamidentitymapping` for additional entries |
| 11 | **Managed node group sizing**: Bootstrap MNG uses `m5.large` (cost) | Scale down or remove MNG after Karpenter is healthy (see next steps in deploy output) |
| 12 | **No Terraform state**: EKS resources are created via eksctl/AWS CLI, not Terraform | For Terraform-managed EKS, consider adapting to the `terraform-aws-modules/eks/aws` module |
| 13 | **Helm repository**: Karpenter chart at `https://charts.karpenter.sh` must be accessible | Verify network connectivity; consider mirroring to private registry |
| 14 | **EventBridge rules**: Created in the deployment account/region only | For multi-region, duplicate the SQS + EventBridge setup per region |
| 15 | **No GitOps**: This is an imperative deployment | For production, consider wrapping with ArgoCD/FluxCD for declarative management |

---

## Original README

The original self-managed Kubernetes deployment documentation is preserved below for reference.
The original Terraform, Ansible, and Jenkins files are preserved in their original directories.

See the original [`Jenkinsfile`](Jenkinsfile) and infrastructure directories (`networking/`, `instances/`, `node_asg/`, `ansible_infra/`) for the legacy approach.
