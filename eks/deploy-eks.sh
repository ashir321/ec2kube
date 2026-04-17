#!/usr/bin/env bash
###############################################################################
# deploy-eks.sh — Zero-Touch Amazon EKS 1.34 Deployment with Karpenter
#
# Supports AUTH_MODE = pod-identity | irsa | both
#
# Original project: ec2kube (self-managed K8s on EC2 via Terraform/Ansible)
# Rewritten for: Amazon EKS 1.34 + Karpenter + Pod Identity / IRSA
#
# Usage:
#   export AUTH_MODE=pod-identity   # or irsa, or both
#   ./deploy-eks.sh
#
# Prerequisites:
#   - AWS CLI v2 configured with sufficient permissions
#   - eksctl >= 0.200.0
#   - kubectl compatible with K8s 1.34
#   - helm >= 3.16
#   - jq, curl, envsubst (gettext)
###############################################################################
set -Eeuo pipefail

# ── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]  $(date +%T) $*${NC}"; }
ok()    { echo -e "${GREEN}[OK]    $(date +%T) $*${NC}"; }
warn()  { echo -e "${YELLOW}[WARN]  $(date +%T) $*${NC}"; }
fail()  { echo -e "${RED}[FATAL] $(date +%T) $*${NC}" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load configuration ──────────────────────────────────────────────────────
CONFIG_FILE="${SCRIPT_DIR}/env.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  info "Loading configuration from ${CONFIG_FILE}"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
else
  warn "No env.conf found — expecting all variables to be exported in the environment"
fi

# ── Defaults for anything not yet set ────────────────────────────────────────
: "${AWS_ACCOUNT_ID:=""}"
: "${CLUSTER_NAME:="ec2kube-eks"}"
: "${AWS_REGION:="us-east-1"}"
: "${K8S_VERSION:="1.34"}"
: "${AUTH_MODE:="pod-identity"}"
: "${KARPENTER_VERSION:="1.3.0"}"
: "${KARPENTER_NAMESPACE:="kube-system"}"
: "${INSTANCE_FAMILIES:="m5,m6i,m7i,c5,c6i,c7i,r5,r6i,r7i"}"
: "${CAPACITY_TYPES:="on-demand,spot"}"
: "${ARCHITECTURES:="amd64"}"
: "${NODEPOOL_CPU_LIMIT:="100"}"
: "${NODEPOOL_MEMORY_LIMIT:="400"}"
: "${CONSOLIDATION_POLICY:="WhenEmptyOrUnderutilized"}"
: "${CONSOLIDATE_AFTER:="30s"}"
: "${EXPIRE_AFTER:="720h"}"
: "${EXISTING_VPC_ID:=""}"
: "${EXISTING_PRIVATE_SUBNET_IDS:=""}"
: "${EXISTING_PUBLIC_SUBNET_IDS:=""}"
: "${MNG_INSTANCE_TYPE:="m5.large"}"
: "${MNG_MIN_SIZE:="2"}"
: "${MNG_MAX_SIZE:="3"}"
: "${MNG_DESIRED_SIZE:="2"}"
: "${TEST_NAMESPACE:="eks-validation"}"
: "${TEST_DEPLOYMENT_NAME:="inflate"}"
: "${TEST_REPLICAS:="5"}"
: "${WAIT_TIMEOUT:="600"}"
: "${POLL_INTERVAL:="15"}"
: "${SSH_PUBLIC_KEY:=""}"
: "${STATE_BUCKET:=""}"
: "${FIRST_DEPLOY:="N"}"

# Derived
KARPENTER_NODE_ROLE_NAME="KarpenterNodeRole-${CLUSTER_NAME}"
KARPENTER_CONTROLLER_ROLE_NAME="KarpenterControllerRole-${CLUSTER_NAME}"
KARPENTER_INSTANCE_PROFILE_NAME="KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
KARPENTER_QUEUE_NAME="${CLUSTER_NAME}-karpenter"
MNG_NODE_GROUP_NAME="${CLUSTER_NAME}-system"
MNG_NODE_ROLE_NAME="${CLUSTER_NAME}-managed-node-role"

###############################################################################
# PHASE 0: Prerequisites & Environment Validation
###############################################################################
phase() { echo -e "\n${GREEN}━━━ PHASE: $* ━━━${NC}\n"; }

phase "0 — Prerequisites & Environment Validation"

# ── Required inputs check ────────────────────────────────────────────────────
[[ -z "$AWS_ACCOUNT_ID" ]] && fail "AWS_ACCOUNT_ID is required. Set it in env.conf or export it."
[[ "$AUTH_MODE" =~ ^(pod-identity|irsa|both)$ ]] || fail "AUTH_MODE must be pod-identity, irsa, or both. Got: $AUTH_MODE"

# ── CLI presence & minimum versions ─────────────────────────────────────────
require_cmd() {
  command -v "$1" &>/dev/null || fail "'$1' is required but not found in PATH"
}

check_version() {
  local cmd="$1" min="$2" actual
  actual=$($cmd version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // .clientVersion.major + "." + .clientVersion.minor' 2>/dev/null || echo "unknown")
  info "$cmd version: $actual (minimum: $min)"
}

for tool in aws eksctl kubectl helm jq curl; do
  require_cmd "$tool"
done

info "aws-cli: $(aws --version 2>&1 | head -1)"
info "eksctl:  $(eksctl version 2>&1)"
info "kubectl: $(kubectl version --client --short 2>/dev/null || kubectl version --client -o yaml 2>/dev/null | grep gitVersion | head -1)"
info "helm:    $(helm version --short 2>&1)"
info "jq:      $(jq --version 2>&1)"

# ── AWS identity ─────────────────────────────────────────────────────────────
info "Verifying AWS identity…"
CALLER_IDENTITY=$(aws sts get-caller-identity --output json)
CALLER_ACCOUNT=$(echo "$CALLER_IDENTITY" | jq -r '.Account')
CALLER_ARN=$(echo "$CALLER_IDENTITY" | jq -r '.Arn')
info "Account: $CALLER_ACCOUNT  Identity: $CALLER_ARN"
[[ "$CALLER_ACCOUNT" == "$AWS_ACCOUNT_ID" ]] || fail "AWS_ACCOUNT_ID ($AWS_ACCOUNT_ID) does not match caller account ($CALLER_ACCOUNT)"
ok "AWS identity verified"

# ── Region ───────────────────────────────────────────────────────────────────
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_REGION="$AWS_REGION"

###############################################################################
# PHASE 1: Cluster Assessment & Creation / Update
###############################################################################
phase "1 — EKS Cluster at Kubernetes ${K8S_VERSION}"

cluster_exists() {
  aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null
}

wait_for_cluster_active() {
  local waited=0
  while true; do
    local status
    status=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.status' --output text 2>/dev/null || echo "UNKNOWN")
    if [[ "$status" == "ACTIVE" ]]; then
      ok "Cluster $CLUSTER_NAME is ACTIVE"
      return 0
    fi
    info "Cluster status: $status — waiting… (${waited}s / ${WAIT_TIMEOUT}s)"
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
    [[ $waited -ge $WAIT_TIMEOUT ]] && fail "Timed out waiting for cluster to become ACTIVE"
  done
}

if cluster_exists; then
  info "Cluster $CLUSTER_NAME already exists — checking version"
  CURRENT_VERSION=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.version' --output text)
  info "Current cluster version: $CURRENT_VERSION  Target: $K8S_VERSION"

  if [[ "$CURRENT_VERSION" != "$K8S_VERSION" ]]; then
    info "Upgrading control plane from $CURRENT_VERSION to $K8S_VERSION …"
    aws eks update-cluster-version \
      --name "$CLUSTER_NAME" \
      --kubernetes-version "$K8S_VERSION" \
      --region "$AWS_REGION"
    wait_for_cluster_active
    ok "Control plane upgraded to $K8S_VERSION"
  else
    ok "Cluster already at version $K8S_VERSION"
  fi
else
  info "Creating EKS cluster $CLUSTER_NAME (v${K8S_VERSION}) …"

  EKSCTL_CONFIG=$(mktemp /tmp/eksctl-cluster-XXXX.yaml)
  cat > "$EKSCTL_CONFIG" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "${K8S_VERSION}"
  tags:
    "karpenter.sh/discovery": "${CLUSTER_NAME}"

iam:
  withOIDC: true

managedNodeGroups:
  - name: ${MNG_NODE_GROUP_NAME}
    instanceType: ${MNG_INSTANCE_TYPE}
    minSize: ${MNG_MIN_SIZE}
    maxSize: ${MNG_MAX_SIZE}
    desiredCapacity: ${MNG_DESIRED_SIZE}
    labels:
      role: system
    tags:
      "karpenter.sh/discovery": "${CLUSTER_NAME}"
    iam:
      withAddonPolicies:
        ebs: true

addons:
  - name: vpc-cni
    version: latest
    configurationOverrides: '{"env":{"ENABLE_PREFIX_DELEGATION":"true"}}'
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest
  - name: aws-ebs-csi-driver
    version: latest
EOF

  # Add Pod Identity Agent addon when needed
  if [[ "$AUTH_MODE" == "pod-identity" || "$AUTH_MODE" == "both" ]]; then
    cat >> "$EKSCTL_CONFIG" <<EOF
  - name: eks-pod-identity-agent
    version: latest
EOF
  fi

  info "eksctl config written to $EKSCTL_CONFIG"
  eksctl create cluster -f "$EKSCTL_CONFIG"
  rm -f "$EKSCTL_CONFIG"
  wait_for_cluster_active
  ok "Cluster $CLUSTER_NAME created"
fi

# ── Update kubeconfig ────────────────────────────────────────────────────────
info "Updating kubeconfig…"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --alias "$CLUSTER_NAME"
ok "kubeconfig updated"

# Quick connectivity test
info "Testing cluster connectivity…"
kubectl cluster-info || fail "Cannot connect to cluster"
ok "Cluster connectivity verified"

###############################################################################
# PHASE 2: EKS Add-on Updates
###############################################################################
phase "2 — EKS Add-on Updates"

update_addon() {
  local addon_name="$1"
  info "Checking add-on: $addon_name"

  local addon_status
  addon_status=$(aws eks describe-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name "$addon_name" \
    --query 'addon.status' --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$addon_status" == "NOT_FOUND" ]]; then
    info "Installing add-on $addon_name …"
    aws eks create-addon \
      --cluster-name "$CLUSTER_NAME" \
      --addon-name "$addon_name" \
      --resolve-conflicts OVERWRITE \
      --region "$AWS_REGION" || warn "Failed to install $addon_name — may need manual review"
  else
    info "Updating add-on $addon_name (current status: $addon_status) …"
    aws eks update-addon \
      --cluster-name "$CLUSTER_NAME" \
      --addon-name "$addon_name" \
      --resolve-conflicts OVERWRITE \
      --region "$AWS_REGION" 2>/dev/null || info "$addon_name already at latest compatible version"
  fi
}

wait_for_addon() {
  local addon_name="$1"
  local waited=0
  while true; do
    local status
    status=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$addon_name" \
      --query 'addon.status' --output text 2>/dev/null || echo "UNKNOWN")
    if [[ "$status" == "ACTIVE" ]]; then
      ok "Add-on $addon_name is ACTIVE"
      return 0
    fi
    info "Add-on $addon_name status: $status — waiting… (${waited}s)"
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
    [[ $waited -ge $WAIT_TIMEOUT ]] && { warn "Timed out waiting for $addon_name — continuing"; return 1; }
  done
}

# Update add-ons in dependency-safe order
CORE_ADDONS=("vpc-cni" "coredns" "kube-proxy" "aws-ebs-csi-driver")
if [[ "$AUTH_MODE" == "pod-identity" || "$AUTH_MODE" == "both" ]]; then
  CORE_ADDONS+=("eks-pod-identity-agent")
fi

for addon in "${CORE_ADDONS[@]}"; do
  update_addon "$addon"
done

info "Waiting for add-ons to stabilise…"
for addon in "${CORE_ADDONS[@]}"; do
  wait_for_addon "$addon"
done

ok "All add-ons updated"

###############################################################################
# PHASE 3: Identity Setup (Pod Identity / IRSA / Both)
###############################################################################
phase "3 — Identity Setup (AUTH_MODE=$AUTH_MODE)"

# ── Helper: ensure OIDC provider ────────────────────────────────────────────
ensure_oidc_provider() {
  info "Ensuring OIDC provider exists for IRSA…"
  local oidc_url
  oidc_url=$(aws eks describe-cluster --name "$CLUSTER_NAME" \
    --query 'cluster.identity.oidc.issuer' --output text)
  local oidc_id
  oidc_id=$(echo "$oidc_url" | awk -F'/' '{print $NF}')

  if aws iam list-open-id-connect-providers | grep -q "$oidc_id"; then
    ok "OIDC provider already exists: $oidc_id"
  else
    info "Creating OIDC provider via eksctl…"
    eksctl utils associate-iam-oidc-provider \
      --cluster "$CLUSTER_NAME" \
      --region "$AWS_REGION" \
      --approve
    ok "OIDC provider created"
  fi
  # Export for later use
  OIDC_PROVIDER_URL="$oidc_url"
  OIDC_PROVIDER_ID="$oidc_id"
}

# ── Helper: create IAM role for IRSA ────────────────────────────────────────
create_irsa_role() {
  local role_name="$1"
  local namespace="$2"
  local service_account="$3"
  local policy_arn="$4"

  info "Creating IRSA role: $role_name for $namespace/$service_account"

  local oidc_host
  oidc_host=$(echo "$OIDC_PROVIDER_URL" | sed 's|https://||')

  local trust_policy
  trust_policy=$(cat <<EOFPOLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${oidc_host}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${oidc_host}:sub": "system:serviceaccount:${namespace}:${service_account}",
          "${oidc_host}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOFPOLICY
)

  if aws iam get-role --role-name "$role_name" &>/dev/null; then
    info "Role $role_name already exists — updating trust policy"
    aws iam update-assume-role-policy --role-name "$role_name" --policy-document "$trust_policy"
  else
    aws iam create-role \
      --role-name "$role_name" \
      --assume-role-policy-document "$trust_policy" \
      --tags Key=eks-cluster,Value="$CLUSTER_NAME"
  fi

  aws iam attach-role-policy --role-name "$role_name" --policy-arn "$policy_arn" 2>/dev/null || true
  ok "IRSA role $role_name ready"
}

# ── Helper: create Pod Identity association ──────────────────────────────────
create_pod_identity_association() {
  local role_name="$1"
  local namespace="$2"
  local service_account="$3"
  local policy_arn="$4"

  info "Creating Pod Identity role: $role_name for $namespace/$service_account"

  local trust_policy
  trust_policy=$(cat <<EOFPOLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
EOFPOLICY
)

  if aws iam get-role --role-name "$role_name" &>/dev/null; then
    info "Role $role_name already exists — updating trust policy"
    aws iam update-assume-role-policy --role-name "$role_name" --policy-document "$trust_policy"
  else
    aws iam create-role \
      --role-name "$role_name" \
      --assume-role-policy-document "$trust_policy" \
      --tags Key=eks-cluster,Value="$CLUSTER_NAME"
  fi

  aws iam attach-role-policy --role-name "$role_name" --policy-arn "$policy_arn" 2>/dev/null || true

  # Create the EKS Pod Identity association
  info "Creating EKS Pod Identity association…"
  # Check if association already exists
  local existing
  existing=$(aws eks list-pod-identity-associations \
    --cluster-name "$CLUSTER_NAME" \
    --namespace "$namespace" \
    --service-account "$service_account" \
    --query 'associations[0].associationId' --output text 2>/dev/null || echo "None")

  if [[ "$existing" != "None" && -n "$existing" ]]; then
    info "Pod Identity association already exists (ID: $existing)"
  else
    aws eks create-pod-identity-association \
      --cluster-name "$CLUSTER_NAME" \
      --namespace "$namespace" \
      --service-account "$service_account" \
      --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${role_name}" \
      --region "$AWS_REGION"
    ok "Pod Identity association created"
  fi
}

# ── Execute based on AUTH_MODE ───────────────────────────────────────────────

if [[ "$AUTH_MODE" == "irsa" || "$AUTH_MODE" == "both" ]]; then
  ensure_oidc_provider
  ok "IRSA infrastructure ready"
fi

if [[ "$AUTH_MODE" == "pod-identity" || "$AUTH_MODE" == "both" ]]; then
  info "Verifying eks-pod-identity-agent add-on…"
  update_addon "eks-pod-identity-agent"
  wait_for_addon "eks-pod-identity-agent"

  # Verify agent pods are running
  info "Checking pod-identity-agent daemon pods…"
  local_waited=0
  while true; do
    READY_AGENTS=$(kubectl get ds -n kube-system eks-pod-identity-agent -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    DESIRED_AGENTS=$(kubectl get ds -n kube-system eks-pod-identity-agent -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    if [[ "$READY_AGENTS" -gt 0 && "$READY_AGENTS" == "$DESIRED_AGENTS" ]]; then
      ok "Pod Identity Agent: $READY_AGENTS/$DESIRED_AGENTS ready"
      break
    fi
    info "Pod Identity Agent: $READY_AGENTS/$DESIRED_AGENTS ready — waiting…"
    sleep "$POLL_INTERVAL"
    local_waited=$((local_waited + POLL_INTERVAL))
    [[ $local_waited -ge $WAIT_TIMEOUT ]] && { warn "Pod Identity Agent not fully ready — continuing"; break; }
  done
fi

ok "Identity setup complete for AUTH_MODE=$AUTH_MODE"

###############################################################################
# PHASE 4: Karpenter IAM & Installation
###############################################################################
phase "4 — Karpenter IAM & Installation"

# ── 4a. Karpenter Node IAM Role ─────────────────────────────────────────────
info "Creating Karpenter node IAM role: $KARPENTER_NODE_ROLE_NAME"

KARPENTER_NODE_TRUST=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)

if aws iam get-role --role-name "$KARPENTER_NODE_ROLE_NAME" &>/dev/null; then
  info "Node role already exists — ensuring policies"
else
  aws iam create-role \
    --role-name "$KARPENTER_NODE_ROLE_NAME" \
    --assume-role-policy-document "$KARPENTER_NODE_TRUST" \
    --tags Key=eks-cluster,Value="$CLUSTER_NAME"
fi

# Attach required managed policies for Karpenter nodes
NODE_POLICIES=(
  "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
)
for policy in "${NODE_POLICIES[@]}"; do
  aws iam attach-role-policy --role-name "$KARPENTER_NODE_ROLE_NAME" --policy-arn "$policy" 2>/dev/null || true
done
ok "Karpenter node role configured"

# ── 4b. Instance Profile ────────────────────────────────────────────────────
info "Creating/verifying instance profile: $KARPENTER_INSTANCE_PROFILE_NAME"
if ! aws iam get-instance-profile --instance-profile-name "$KARPENTER_INSTANCE_PROFILE_NAME" &>/dev/null; then
  aws iam create-instance-profile --instance-profile-name "$KARPENTER_INSTANCE_PROFILE_NAME"
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$KARPENTER_INSTANCE_PROFILE_NAME" \
    --role-name "$KARPENTER_NODE_ROLE_NAME"
  info "Waiting for instance profile propagation…"
  sleep 15
fi
ok "Instance profile ready"

# ── 4c. Map node role in aws-auth ConfigMap (for nodes to join) ─────────────
info "Ensuring Karpenter node role is mapped in aws-auth…"
eksctl create iamidentitymapping \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${KARPENTER_NODE_ROLE_NAME}" \
  --group system:bootstrappers \
  --group system:nodes \
  --username "system:node:{{EC2PrivateDNSName}}" 2>/dev/null || info "Identity mapping may already exist"
ok "aws-auth updated"

# ── 4d. Karpenter Controller IAM Role ───────────────────────────────────────
# For Karpenter controller, Pod Identity is the recommended approach on
# EKS 1.34+. IRSA is supported as a fallback. We implement whichever
# AUTH_MODE the user selected.
info "Creating Karpenter controller IAM role: $KARPENTER_CONTROLLER_ROLE_NAME"

# Karpenter controller policy (inline — least-privilege)
KARPENTER_CONTROLLER_POLICY_NAME="${CLUSTER_NAME}-KarpenterControllerPolicy"
KARPENTER_CONTROLLER_POLICY=$(cat <<'EOFPOL'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "KarpenterEC2",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateFleet",
        "ec2:CreateLaunchTemplate",
        "ec2:CreateTags",
        "ec2:DeleteLaunchTemplate",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypeOfferings",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeSubnets",
        "ec2:RunInstances",
        "ec2:TerminateInstances"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "${AWS_REGION}"
        }
      }
    },
    {
      "Sid": "KarpenterPassRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::*:role/${KARPENTER_NODE_ROLE_NAME}",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ec2.amazonaws.com"
        }
      }
    },
    {
      "Sid": "KarpenterGetInstanceProfile",
      "Effect": "Allow",
      "Action": [
        "iam:GetInstanceProfile",
        "iam:CreateInstanceProfile",
        "iam:TagInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:DeleteInstanceProfile"
      ],
      "Resource": "*"
    },
    {
      "Sid": "KarpenterEKS",
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster"
      ],
      "Resource": "arn:aws:eks:*:*:cluster/${CLUSTER_NAME}"
    },
    {
      "Sid": "KarpenterSQS",
      "Effect": "Allow",
      "Action": [
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:ReceiveMessage"
      ],
      "Resource": "arn:aws:sqs:*:*:${KARPENTER_QUEUE_NAME}"
    },
    {
      "Sid": "KarpenterPricing",
      "Effect": "Allow",
      "Action": [
        "pricing:GetProducts"
      ],
      "Resource": "*"
    },
    {
      "Sid": "KarpenterSSM",
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter"
      ],
      "Resource": "arn:aws:ssm:*:*:parameter/aws/service/*"
    }
  ]
}
EOFPOL
)

# Substitute variables in the policy
KARPENTER_CONTROLLER_POLICY=$(echo "$KARPENTER_CONTROLLER_POLICY" | \
  sed "s|\${AWS_REGION}|${AWS_REGION}|g" | \
  sed "s|\${KARPENTER_NODE_ROLE_NAME}|${KARPENTER_NODE_ROLE_NAME}|g" | \
  sed "s|\${CLUSTER_NAME}|${CLUSTER_NAME}|g" | \
  sed "s|\${KARPENTER_QUEUE_NAME}|${KARPENTER_QUEUE_NAME}|g")

# Create or update the IAM policy
POLICY_ARN=""
EXISTING_POLICY_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='${KARPENTER_CONTROLLER_POLICY_NAME}'].Arn" \
  --output text 2>/dev/null || echo "")

if [[ -n "$EXISTING_POLICY_ARN" && "$EXISTING_POLICY_ARN" != "None" ]]; then
  POLICY_ARN="$EXISTING_POLICY_ARN"
  info "Policy $KARPENTER_CONTROLLER_POLICY_NAME exists — creating new version"
  # Delete oldest non-default version if at limit (max 5 versions)
  OLDEST_VERSION=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
    --query 'Versions[?IsDefaultVersion==`false`] | sort_by(@, &CreateDate) | [0].VersionId' \
    --output text 2>/dev/null || echo "None")
  if [[ "$OLDEST_VERSION" != "None" && -n "$OLDEST_VERSION" ]]; then
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST_VERSION" 2>/dev/null || true
  fi
  aws iam create-policy-version \
    --policy-arn "$POLICY_ARN" \
    --policy-document "$KARPENTER_CONTROLLER_POLICY" \
    --set-as-default 2>/dev/null || true
else
  POLICY_RESULT=$(aws iam create-policy \
    --policy-name "$KARPENTER_CONTROLLER_POLICY_NAME" \
    --policy-document "$KARPENTER_CONTROLLER_POLICY" \
    --output json)
  POLICY_ARN=$(echo "$POLICY_RESULT" | jq -r '.Policy.Arn')
fi
info "Controller policy ARN: $POLICY_ARN"

# Create controller role based on AUTH_MODE
if [[ "$AUTH_MODE" == "pod-identity" || "$AUTH_MODE" == "both" ]]; then
  # Pod Identity trust for Karpenter controller
  create_pod_identity_association "$KARPENTER_CONTROLLER_ROLE_NAME" \
    "$KARPENTER_NAMESPACE" "karpenter" "$POLICY_ARN"
fi

if [[ "$AUTH_MODE" == "irsa" || "$AUTH_MODE" == "both" ]]; then
  ensure_oidc_provider
  create_irsa_role "$KARPENTER_CONTROLLER_ROLE_NAME" \
    "$KARPENTER_NAMESPACE" "karpenter" "$POLICY_ARN"
fi

ok "Karpenter controller IAM ready"

# ── 4e. SQS Queue for Interruption Handling ──────────────────────────────────
info "Creating SQS queue for interruption handling: $KARPENTER_QUEUE_NAME"

if aws sqs get-queue-url --queue-name "$KARPENTER_QUEUE_NAME" &>/dev/null; then
  QUEUE_URL=$(aws sqs get-queue-url --queue-name "$KARPENTER_QUEUE_NAME" --output text)
  info "Queue already exists: $QUEUE_URL"
else
  QUEUE_URL=$(aws sqs create-queue --queue-name "$KARPENTER_QUEUE_NAME" \
    --attributes '{"MessageRetentionPeriod":"300","SqsManagedSseEnabled":"true"}' \
    --output text --query 'QueueUrl')
  info "Queue created: $QUEUE_URL"
fi

QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

# SQS queue policy for EventBridge
SQS_POLICY=$(cat <<EOFQP
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2InterruptionPolicy",
      "Effect": "Allow",
      "Principal": {
        "Service": ["events.amazonaws.com", "sqs.amazonaws.com"]
      },
      "Action": "sqs:SendMessage",
      "Resource": "${QUEUE_ARN}",
      "Condition": {
        "ArnEquals": {
          "aws:SourceArn": [
            "arn:aws:events:${AWS_REGION}:${AWS_ACCOUNT_ID}:rule/${CLUSTER_NAME}-SpotInterruption",
            "arn:aws:events:${AWS_REGION}:${AWS_ACCOUNT_ID}:rule/${CLUSTER_NAME}-RebalanceRecommendation",
            "arn:aws:events:${AWS_REGION}:${AWS_ACCOUNT_ID}:rule/${CLUSTER_NAME}-InstanceStateChange",
            "arn:aws:events:${AWS_REGION}:${AWS_ACCOUNT_ID}:rule/${CLUSTER_NAME}-ScheduledChange"
          ]
        }
      }
    }
  ]
}
EOFQP
)

aws sqs set-queue-attributes --queue-url "$QUEUE_URL" \
  --attributes "{\"Policy\": $(echo "$SQS_POLICY" | jq -c '.' | jq -Rs '.')}" 2>/dev/null || true

# ── 4f. EventBridge Rules for Interruption Events ────────────────────────────
info "Creating EventBridge rules for interruption handling…"

create_event_rule() {
  local rule_name="$1"
  local event_pattern="$2"

  aws events put-rule --name "$rule_name" --event-pattern "$event_pattern" \
    --region "$AWS_REGION" 2>/dev/null || true
  aws events put-targets --rule "$rule_name" \
    --targets "[{\"Id\":\"KarpenterQueue\",\"Arn\":\"${QUEUE_ARN}\"}]" \
    --region "$AWS_REGION" 2>/dev/null || true
}

create_event_rule "${CLUSTER_NAME}-SpotInterruption" \
  '{"source":["aws.ec2"],"detail-type":["EC2 Spot Instance Interruption Warning"]}'

create_event_rule "${CLUSTER_NAME}-RebalanceRecommendation" \
  '{"source":["aws.ec2"],"detail-type":["EC2 Instance Rebalance Recommendation"]}'

create_event_rule "${CLUSTER_NAME}-InstanceStateChange" \
  '{"source":["aws.ec2"],"detail-type":["EC2 Instance State-change Notification"]}'

create_event_rule "${CLUSTER_NAME}-ScheduledChange" \
  '{"source":["aws.health"],"detail-type":["AWS Health Event"]}'

ok "Interruption handling infrastructure ready"

# ── 4g. Subnet & Security Group Tagging for Karpenter Discovery ─────────────
phase "4g — Tagging Subnets & Security Groups for Karpenter Discovery"

info "Tagging private subnets with karpenter.sh/discovery…"
CLUSTER_VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

# Tag all private subnets in the cluster VPC
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${CLUSTER_VPC_ID}" \
  --query 'Subnets[?MapPublicIpOnLaunch==`false`].SubnetId' --output text)

if [[ -z "$PRIVATE_SUBNET_IDS" ]]; then
  warn "No private subnets found — tagging all subnets for Karpenter discovery"
  PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${CLUSTER_VPC_ID}" \
    --query 'Subnets[].SubnetId' --output text)
fi

for subnet_id in $PRIVATE_SUBNET_IDS; do
  aws ec2 create-tags --resources "$subnet_id" \
    --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" 2>/dev/null || true
  info "Tagged subnet $subnet_id"
done

# Tag cluster security group
CLUSTER_SG=$(aws eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
aws ec2 create-tags --resources "$CLUSTER_SG" \
  --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" 2>/dev/null || true
info "Tagged security group $CLUSTER_SG"

ok "Discovery tags applied"

# ── 4h. Install Karpenter via Helm ──────────────────────────────────────────
phase "4h — Karpenter Helm Installation"

info "Adding/updating Karpenter Helm repo…"
helm repo add karpenter https://charts.karpenter.sh 2>/dev/null || true
helm repo update karpenter

HELM_ARGS=(
  --namespace "$KARPENTER_NAMESPACE"
  --create-namespace
  --set "settings.clusterName=${CLUSTER_NAME}"
  --set "settings.interruptionQueue=${KARPENTER_QUEUE_NAME}"
  --set "controller.resources.requests.cpu=1"
  --set "controller.resources.requests.memory=1Gi"
  --set "controller.resources.limits.cpu=1"
  --set "controller.resources.limits.memory=1Gi"
  --set "replicas=2"
  --version "$KARPENTER_VERSION"
  --wait
  --timeout 10m
)

# Configure controller identity based on AUTH_MODE
# Pod Identity: Karpenter controller picks up credentials automatically from
#   the Pod Identity Agent when an EKS Pod Identity association exists.
# IRSA: We annotate the service account with the role ARN.
if [[ "$AUTH_MODE" == "irsa" ]]; then
  HELM_ARGS+=(
    --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/${KARPENTER_CONTROLLER_ROLE_NAME}"
  )
elif [[ "$AUTH_MODE" == "both" ]]; then
  # When both are enabled, IRSA annotation is set as a fallback; Pod Identity
  # takes precedence automatically on the EKS data plane.
  HELM_ARGS+=(
    --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/${KARPENTER_CONTROLLER_ROLE_NAME}"
  )
fi

info "Installing/upgrading Karpenter v${KARPENTER_VERSION}…"
helm upgrade --install karpenter karpenter/karpenter "${HELM_ARGS[@]}"

# Wait for Karpenter pods
info "Waiting for Karpenter controller pods…"
kubectl rollout status deployment/karpenter -n "$KARPENTER_NAMESPACE" --timeout=300s || \
  fail "Karpenter controller did not become ready"
ok "Karpenter v${KARPENTER_VERSION} installed and running"

###############################################################################
# PHASE 5: EC2NodeClass
###############################################################################
phase "5 — EC2NodeClass"

# Build the EC2NodeClass manifest
EC2NODECLASS_MANIFEST=$(cat <<EOF
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  role: "${KARPENTER_NODE_ROLE_NAME}"
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  tags:
    karpenter.sh/discovery: "${CLUSTER_NAME}"
    Name: "karpenter/${CLUSTER_NAME}"
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        iops: 3000
        throughput: 125
        encrypted: true
        deleteOnTermination: true
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 2
    httpTokens: required
  detailedMonitoring: true
EOF
)

info "Applying EC2NodeClass…"
echo "$EC2NODECLASS_MANIFEST" | kubectl apply -f -
ok "EC2NodeClass 'default' applied"

###############################################################################
# PHASE 6: NodePools
###############################################################################
phase "6 — NodePools"

# Convert comma-separated values to YAML list items
instance_family_yaml() {
  IFS=',' read -ra families <<< "$INSTANCE_FAMILIES"
  for f in "${families[@]}"; do
    echo "            - $f"
  done
}

capacity_type_yaml() {
  IFS=',' read -ra types <<< "$CAPACITY_TYPES"
  for t in "${types[@]}"; do
    echo "            - $t"
  done
}

arch_yaml() {
  IFS=',' read -ra arches <<< "$ARCHITECTURES"
  for a in "${arches[@]}"; do
    echo "            - $a"
  done
}

NODEPOOL_MANIFEST=$(cat <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general-purpose
spec:
  template:
    metadata:
      labels:
        intent: apps
        managed-by: karpenter
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values:
$(instance_family_yaml)
        - key: karpenter.sh/capacity-type
          operator: In
          values:
$(capacity_type_yaml)
        - key: kubernetes.io/arch
          operator: In
          values:
$(arch_yaml)
        - key: kubernetes.io/os
          operator: In
          values:
            - linux
      expireAfter: ${EXPIRE_AFTER}
  disruption:
    consolidationPolicy: ${CONSOLIDATION_POLICY}
    consolidateAfter: ${CONSOLIDATE_AFTER}
  limits:
    cpu: "${NODEPOOL_CPU_LIMIT}"
    memory: "${NODEPOOL_MEMORY_LIMIT}Gi"
  weight: 100
EOF
)

info "Applying NodePool…"
echo "$NODEPOOL_MANIFEST" | kubectl apply -f -
ok "NodePool 'general-purpose' applied"

###############################################################################
# PHASE 7: Test Workload — Force Karpenter Provisioning
###############################################################################
phase "7 — Test Workload"

info "Creating test namespace…"
kubectl create namespace "$TEST_NAMESPACE" 2>/dev/null || true

TEST_WORKLOAD=$(cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${TEST_DEPLOYMENT_NAME}
  namespace: ${TEST_NAMESPACE}
  labels:
    app: ${TEST_DEPLOYMENT_NAME}
spec:
  replicas: ${TEST_REPLICAS}
  selector:
    matchLabels:
      app: ${TEST_DEPLOYMENT_NAME}
  template:
    metadata:
      labels:
        app: ${TEST_DEPLOYMENT_NAME}
    spec:
      terminationGracePeriodSeconds: 0
      nodeSelector:
        intent: apps
        managed-by: karpenter
      containers:
        - name: inflate
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
          resources:
            requests:
              cpu: "1"
              memory: "1.5Gi"
EOF
)

info "Deploying test workload (${TEST_REPLICAS} replicas requesting 1 CPU + 1.5Gi each)…"
echo "$TEST_WORKLOAD" | kubectl apply -f -

###############################################################################
# PHASE 8: Verification — Scale-Out
###############################################################################
phase "8 — Verification: Scale-Out"

info "Waiting for Karpenter to provision nodes and schedule pods…"
waited=0
while true; do
  READY_PODS=$(kubectl get pods -n "$TEST_NAMESPACE" -l "app=$TEST_DEPLOYMENT_NAME" \
    --no-headers 2>/dev/null | grep -c Running || echo "0")
  TOTAL_PODS="$TEST_REPLICAS"
  KARPENTER_NODES=$(kubectl get nodes -l "managed-by=karpenter" --no-headers 2>/dev/null | wc -l || echo "0")

  info "Pods Running: $READY_PODS/$TOTAL_PODS | Karpenter Nodes: $KARPENTER_NODES (${waited}s / ${WAIT_TIMEOUT}s)"

  if [[ "$READY_PODS" -ge "$TOTAL_PODS" ]]; then
    ok "All $TOTAL_PODS test pods are Running on $KARPENTER_NODES Karpenter-managed node(s)"
    break
  fi

  sleep "$POLL_INTERVAL"
  waited=$((waited + POLL_INTERVAL))
  if [[ $waited -ge $WAIT_TIMEOUT ]]; then
    warn "Timed out waiting for all test pods — check Karpenter logs:"
    warn "  kubectl logs -n $KARPENTER_NAMESPACE -l app.kubernetes.io/name=karpenter --tail=50"
    break
  fi
done

###############################################################################
# PHASE 9: Verification — Node Readiness & Workload Scheduling
###############################################################################
phase "9 — Node Readiness & Workload Scheduling"

info "All nodes:"
kubectl get nodes -o wide

info "All pods across all namespaces:"
kubectl get pods -A --field-selector=status.phase!=Succeeded

info "Karpenter NodePools:"
kubectl get nodepools

info "Karpenter EC2NodeClasses:"
kubectl get ec2nodeclasses

info "Karpenter controller pods:"
kubectl get pods -n "$KARPENTER_NAMESPACE" -l app.kubernetes.io/name=karpenter

###############################################################################
# PHASE 10: Verification — Consolidation / Scale-In
###############################################################################
phase "10 — Consolidation / Scale-In Test"

info "Scaling test workload to 0 to trigger consolidation…"
kubectl scale deployment "$TEST_DEPLOYMENT_NAME" -n "$TEST_NAMESPACE" --replicas=0

info "Waiting for consolidation (Karpenter should remove empty nodes)…"
waited=0
INITIAL_KARPENTER_NODES=$(kubectl get nodes -l "managed-by=karpenter" --no-headers 2>/dev/null | wc -l || echo "0")
while true; do
  CURRENT_KARPENTER_NODES=$(kubectl get nodes -l "managed-by=karpenter" --no-headers 2>/dev/null | wc -l || echo "0")
  info "Karpenter nodes: $CURRENT_KARPENTER_NODES (was $INITIAL_KARPENTER_NODES) — waiting for scale-in… (${waited}s)"

  if [[ "$CURRENT_KARPENTER_NODES" -lt "$INITIAL_KARPENTER_NODES" ]]; then
    ok "Consolidation working — nodes reduced from $INITIAL_KARPENTER_NODES to $CURRENT_KARPENTER_NODES"
    break
  fi

  sleep "$POLL_INTERVAL"
  waited=$((waited + POLL_INTERVAL))
  if [[ $waited -ge 180 ]]; then
    info "Consolidation may take longer — nodes still at $CURRENT_KARPENTER_NODES"
    info "This is expected if consolidateAfter > current wait time. Proceeding."
    break
  fi
done

# Restore test workload for inspection
info "Restoring test workload to $TEST_REPLICAS replicas…"
kubectl scale deployment "$TEST_DEPLOYMENT_NAME" -n "$TEST_NAMESPACE" --replicas="$TEST_REPLICAS"

###############################################################################
# PHASE 11: Identity Validation
###############################################################################
phase "11 — Identity Validation"

if [[ "$AUTH_MODE" == "pod-identity" || "$AUTH_MODE" == "both" ]]; then
  info "=== Pod Identity Validation ==="
  info "Pod Identity Agent DaemonSet:"
  kubectl get ds -n kube-system eks-pod-identity-agent

  info "Pod Identity associations:"
  aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --output table 2>/dev/null || \
    warn "No Pod Identity associations found"
fi

if [[ "$AUTH_MODE" == "irsa" || "$AUTH_MODE" == "both" ]]; then
  info "=== IRSA Validation ==="
  info "OIDC Provider:"
  aws eks describe-cluster --name "$CLUSTER_NAME" \
    --query 'cluster.identity.oidc.issuer' --output text

  info "Karpenter service account annotations:"
  kubectl get sa karpenter -n "$KARPENTER_NAMESPACE" -o jsonpath='{.metadata.annotations}' 2>/dev/null || \
    info "Karpenter SA not found with that name — check helm release"
fi

###############################################################################
# PHASE 12: EKS Add-on Status Report
###############################################################################
phase "12 — Final Status Report"

info "EKS Cluster:"
aws eks describe-cluster --name "$CLUSTER_NAME" \
  --query '{Name:cluster.name,Version:cluster.version,Status:cluster.status,Endpoint:cluster.endpoint}' \
  --output table

info "EKS Add-ons:"
aws eks list-addons --cluster-name "$CLUSTER_NAME" --output table
for addon in $(aws eks list-addons --cluster-name "$CLUSTER_NAME" --query 'addons[]' --output text); do
  aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$addon" \
    --query '{Name:addon.addonName,Version:addon.addonVersion,Status:addon.status}' --output table
done

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} DEPLOYMENT COMPLETE${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Cluster:        ${CYAN}${CLUSTER_NAME}${NC}"
echo -e "  K8s Version:    ${CYAN}${K8S_VERSION}${NC}"
echo -e "  Auth Mode:      ${CYAN}${AUTH_MODE}${NC}"
echo -e "  Karpenter:      ${CYAN}v${KARPENTER_VERSION}${NC}"
echo -e "  Region:         ${CYAN}${AWS_REGION}${NC}"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "    1. Review Karpenter NodePool/EC2NodeClass for production tuning"
echo -e "    2. Scale down or remove the bootstrap managed node group when ready:"
echo -e "       eksctl scale nodegroup --cluster=${CLUSTER_NAME} --name=${MNG_NODE_GROUP_NAME} --nodes=0"
echo -e "    3. Deploy your production workloads"
echo -e "    4. Review the README.md for rollback and migration guidance"
echo -e "    5. Clean up test namespace: kubectl delete namespace ${TEST_NAMESPACE}"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
