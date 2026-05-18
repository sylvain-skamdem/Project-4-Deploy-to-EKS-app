#!/usr/bin/env bash
# Tears down everything created by 01-03:
#   - ArgoCD application + namespace
#   - App namespace (lumiatech)
#   - All LoadBalancer services (so AWS ELBs are released before VPC teardown)
#   - EKS cluster + node groups + VPC (via eksctl)
#   - Local kubeconfig entry
#
# Usage: ./99-destroy-all.sh [cluster-name] [region]
set -euo pipefail

CLUSTER_NAME="${1:-lumiatechs-eks-cluster}"
REGION="${2:-us-east-1}"
APP_NAMESPACE="lumiatech"

echo "=========================================================="
echo "  DESTROY ALL — cluster: ${CLUSTER_NAME}  region: ${REGION}"
echo "=========================================================="
echo ""
echo "This will permanently delete the EKS cluster and all AWS"
echo "resources created alongside it."
echo ""
read -rp "Type 'yes' to confirm: " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Delete ArgoCD application (stops GitOps sync before we tear down)
# ---------------------------------------------------------------------------
echo ""
echo "==> [1/5] Deleting ArgoCD application ..."
if command -v argocd &>/dev/null && \
   kubectl get namespace argocd &>/dev/null 2>&1; then

  ARGOCD_HOST=$(kubectl get svc argocd-server -n argocd \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

  if [[ -n "${ARGOCD_HOST}" ]]; then
    ARGOCD_PASS=$(kubectl get secret argocd-initial-admin-secret \
      -n argocd -o jsonpath="{.data.password}" 2>/dev/null | base64 --decode || true)
    argocd login "${ARGOCD_HOST}" \
      --username admin --password "${ARGOCD_PASS}" --insecure 2>/dev/null || true
    argocd app delete lumiatech --cascade --yes 2>/dev/null || true
    echo "    ArgoCD app 'lumiatech' deleted."
  else
    echo "    ArgoCD LoadBalancer hostname not found — skipping argocd CLI delete."
  fi
else
  echo "    argocd CLI or argocd namespace not found — skipping."
fi

# ---------------------------------------------------------------------------
# 2. Delete LoadBalancer services FIRST (releases AWS ELBs before VPC teardown)
#    eksctl delete cluster can fail if ELBs still hold subnet/SG references.
# ---------------------------------------------------------------------------
echo ""
echo "==> [2/5] Deleting LoadBalancer services (releasing AWS ELBs) ..."
for ns in "${APP_NAMESPACE}" argocd; do
  if kubectl get namespace "${ns}" &>/dev/null 2>&1; then
    LB_SVCS=$(kubectl get svc -n "${ns}" \
      -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' \
      2>/dev/null || true)
    if [[ -n "${LB_SVCS}" ]]; then
      while IFS= read -r svc; do
        echo "    Deleting LoadBalancer service: ${ns}/${svc}"
        kubectl delete svc "${svc}" -n "${ns}" --ignore-not-found
      done <<< "${LB_SVCS}"
      echo "    Waiting 30s for ELBs to deregister ..."
      sleep 30
    else
      echo "    No LoadBalancer services in namespace '${ns}'."
    fi
  fi
done

# ---------------------------------------------------------------------------
# 3. Delete application namespace
# ---------------------------------------------------------------------------
echo ""
echo "==> [3/5] Deleting application namespace '${APP_NAMESPACE}' ..."
kubectl delete namespace "${APP_NAMESPACE}" --ignore-not-found --timeout=120s || true

# ---------------------------------------------------------------------------
# 4. Delete ArgoCD namespace
# ---------------------------------------------------------------------------
echo ""
echo "==> [4/5] Deleting ArgoCD namespace ..."
kubectl delete namespace argocd --ignore-not-found --timeout=120s || true

# ---------------------------------------------------------------------------
# 5. Delete EKS cluster (CloudFormation stacks: node group + cluster + VPC)
# ---------------------------------------------------------------------------
echo ""
echo "==> [5/5] Deleting EKS cluster '${CLUSTER_NAME}' (this takes 10-15 minutes) ..."
eksctl delete cluster \
  --name   "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --wait

echo ""
echo "==> Removing kubeconfig entry for the cluster ..."
kubectl config delete-context \
  "$(kubectl config get-contexts -o name 2>/dev/null \
     | grep "${CLUSTER_NAME}" || true)" 2>/dev/null || true
kubectl config delete-cluster \
  "$(kubectl config get-clusters 2>/dev/null \
     | grep "${CLUSTER_NAME}" || true)" 2>/dev/null || true

echo ""
echo "=========================================================="
echo "  All done. Cluster '${CLUSTER_NAME}' and associated AWS"
echo "  resources have been deleted."
echo "=========================================================="
