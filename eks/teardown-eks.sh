#!/usr/bin/env bash
###############################################################################
# teardown-eks.sh — Safe teardown / rollback for EKS + Karpenter deployment
#
# This script removes resources created by deploy-eks.sh in reverse order.
# It is designed to be safe and idempotent — re-running is harmless.
#
# Usage:
#   ./teardown-eks.sh                # interactive (prompts before each phase)
#   FORCE_DESTROY=Y ./teardown-eks.sh  # non-interactive
###############################################################################
set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]  $(date +%T) $*${NC}"; }
ok()    { echo -e "${GREEN}[OK]    $(date +%T) $*${NC}"; }
warn()  { echo -e "${YELLOW}[WARN]  $(date +%T) $*${NC}"; }
fail()  { echo -e "${RED}[FATAL] $(date +%T) $*${NC}" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config
CONFIG_FILE="${SCRIPT_DIR}/env.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

: "${AWS_ACCOUNT_ID:=""}"
: "${CLUSTER_NAME:="ec2kube-eks"}"
: "${AWS_REGION:="us-east-1"}"
: "${KARPENTER_NAMESPACE:="kube-system"}"
: "${TEST_NAMESPACE:="eks-validation"}"
: "${FORCE_DESTROY:="N"}"

KARPENTER_NODE_ROLE_NAME="KarpenterNodeRole-${CLUSTER_NAME}"
KARPENTER_CONTROLLER_ROLE_NAME="KarpenterControllerRole-${CLUSTER_NAME}"
KARPENTER_INSTANCE_PROFILE_NAME="KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
KARPENTER_QUEUE_NAME="${CLUSTER_NAME}-karpenter"
KARPENTER_CONTROLLER_POLICY_NAME="${CLUSTER_NAME}-KarpenterControllerPolicy"

export AWS_DEFAULT_REGION="$AWS_REGION"

confirm() {
  if [[ "$FORCE_DESTROY" == "Y" ]]; then
    return 0
  fi
  echo -e -n "${YELLOW}$1 [y/N]: ${NC}"
  read -r response
  [[ "$response" =~ ^[Yy] ]]
}

echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED} EKS CLUSTER TEARDOWN: ${CLUSTER_NAME}${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ── Phase 1: Remove test workload ────────────────────────────────────────────
if confirm "Delete test namespace '${TEST_NAMESPACE}' and all workloads?"; then
  info "Removing test namespace…"
  kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found --timeout=60s 2>/dev/null || true
  ok "Test namespace removed"
fi

# ── Phase 2: Remove Karpenter NodePools & EC2NodeClasses ─────────────────────
if confirm "Delete all Karpenter NodePools and EC2NodeClasses?"; then
  info "Removing NodePools…"
  kubectl delete nodepools --all --timeout=120s 2>/dev/null || true

  info "Waiting for Karpenter-managed nodes to drain (up to 5 minutes)…"
  waited=0
  while true; do
    karp_nodes=$(kubectl get nodes -l "managed-by=karpenter" --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ "$karp_nodes" -eq 0 ]]; then
      ok "All Karpenter nodes terminated"
      break
    fi
    info "Karpenter nodes remaining: $karp_nodes — waiting…"
    sleep 15
    waited=$((waited + 15))
    [[ $waited -ge 300 ]] && { warn "Timeout waiting for Karpenter nodes — proceeding"; break; }
  done

  info "Removing EC2NodeClasses…"
  kubectl delete ec2nodeclasses --all --timeout=60s 2>/dev/null || true
  ok "Karpenter resources removed"
fi

# ── Phase 3: Uninstall Karpenter Helm release ───────────────────────────────
if confirm "Uninstall Karpenter Helm release?"; then
  info "Uninstalling Karpenter…"
  helm uninstall karpenter -n "$KARPENTER_NAMESPACE" 2>/dev/null || true
  ok "Karpenter uninstalled"
fi

# ── Phase 4: Remove EventBridge rules ───────────────────────────────────────
if confirm "Delete EventBridge rules and SQS queue?"; then
  for rule_suffix in SpotInterruption RebalanceRecommendation InstanceStateChange ScheduledChange; do
    rule_name="${CLUSTER_NAME}-${rule_suffix}"
    info "Removing EventBridge rule: $rule_name"
    aws events remove-targets --rule "$rule_name" --ids KarpenterQueue --region "$AWS_REGION" 2>/dev/null || true
    aws events delete-rule --name "$rule_name" --region "$AWS_REGION" 2>/dev/null || true
  done

  info "Deleting SQS queue: $KARPENTER_QUEUE_NAME"
  QUEUE_URL=$(aws sqs get-queue-url --queue-name "$KARPENTER_QUEUE_NAME" --output text 2>/dev/null || echo "")
  if [[ -n "$QUEUE_URL" ]]; then
    aws sqs delete-queue --queue-url "$QUEUE_URL" 2>/dev/null || true
  fi
  ok "EventBridge and SQS resources removed"
fi

# ── Phase 5: Remove IAM resources ───────────────────────────────────────────
if confirm "Delete Karpenter IAM roles, policies, and instance profiles?"; then
  # Remove instance profile
  info "Removing instance profile: $KARPENTER_INSTANCE_PROFILE_NAME"
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$KARPENTER_INSTANCE_PROFILE_NAME" \
    --role-name "$KARPENTER_NODE_ROLE_NAME" 2>/dev/null || true
  aws iam delete-instance-profile \
    --instance-profile-name "$KARPENTER_INSTANCE_PROFILE_NAME" 2>/dev/null || true

  # Remove node role
  info "Removing node role: $KARPENTER_NODE_ROLE_NAME"
  for policy_arn in $(aws iam list-attached-role-policies --role-name "$KARPENTER_NODE_ROLE_NAME" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo ""); do
    aws iam detach-role-policy --role-name "$KARPENTER_NODE_ROLE_NAME" --policy-arn "$policy_arn" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$KARPENTER_NODE_ROLE_NAME" 2>/dev/null || true

  # Remove controller role
  info "Removing controller role: $KARPENTER_CONTROLLER_ROLE_NAME"
  for policy_arn in $(aws iam list-attached-role-policies --role-name "$KARPENTER_CONTROLLER_ROLE_NAME" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo ""); do
    aws iam detach-role-policy --role-name "$KARPENTER_CONTROLLER_ROLE_NAME" --policy-arn "$policy_arn" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$KARPENTER_CONTROLLER_ROLE_NAME" 2>/dev/null || true

  # Remove Pod Identity associations
  info "Removing Pod Identity associations…"
  for assoc_id in $(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
    --query 'associations[].associationId' --output text 2>/dev/null || echo ""); do
    aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" \
      --association-id "$assoc_id" 2>/dev/null || true
  done

  # Remove controller policy
  info "Removing controller policy: $KARPENTER_CONTROLLER_POLICY_NAME"
  POLICY_ARN=$(aws iam list-policies --scope Local \
    --query "Policies[?PolicyName=='${KARPENTER_CONTROLLER_POLICY_NAME}'].Arn" \
    --output text 2>/dev/null || echo "")
  if [[ -n "$POLICY_ARN" && "$POLICY_ARN" != "None" ]]; then
    # Delete non-default versions first
    for ver in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
      --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null || echo ""); do
      aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$ver" 2>/dev/null || true
    done
    aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
  fi
  ok "IAM resources removed"
fi

# ── Phase 6: Delete EKS Cluster ─────────────────────────────────────────────
if confirm "DELETE the EKS cluster '${CLUSTER_NAME}'? (This is irreversible!)"; then
  info "Deleting EKS cluster $CLUSTER_NAME …"
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait
  ok "Cluster $CLUSTER_NAME deleted"
else
  info "Cluster deletion skipped"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} TEARDOWN COMPLETE${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${YELLOW}Manual review items:${NC}"
echo -e "    - Verify no orphaned EC2 instances remain"
echo -e "    - Verify no orphaned EBS volumes remain"
echo -e "    - Verify no orphaned ENIs remain in the VPC"
echo -e "    - Check CloudWatch log groups: /aws/eks/${CLUSTER_NAME}/*"
echo -e "    - Remove OIDC provider if no longer needed"
echo ""
