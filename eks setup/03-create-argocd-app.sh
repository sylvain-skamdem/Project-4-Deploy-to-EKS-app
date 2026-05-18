#!/usr/bin/env bash
# Registers the lumiatech Helm chart with ArgoCD so it watches the manifest repo.
# Usage: ./03-create-argocd-app.sh <your-github-username>
#
# Prerequisites:
#   - ArgoCD is installed and its LoadBalancer IP is assigned (run 02-install-argocd.sh first)
#   - argocd CLI is installed: https://argo-cd.readthedocs.io/en/stable/cli_installation/
set -euo pipefail

# Install argocd CLI on the fly if not present
if ! command -v argocd &>/dev/null; then
  echo "==> argocd CLI not found — installing ..."
  ARGOCD_VERSION=$(curl -fsSL https://raw.githubusercontent.com/argoproj/argo-cd/stable/VERSION)
  curl -fsSL -o /tmp/argocd \
    "https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/argocd-linux-amd64"
  sudo install -o root -g root -m 0755 /tmp/argocd /usr/local/bin/argocd
  rm /tmp/argocd
  echo "    argocd $(argocd version --client --short) installed."
fi

GITHUB_USERNAME="${1:-Ndzenyuy}"
if [[ -z "${GITHUB_USERNAME}" ]]; then
  echo "Usage: $0 <your-github-username>"
  exit 1
fi

MANIFEST_REPO="https://github.com/${GITHUB_USERNAME}/Project-4-Deploy-to-EKS-manifest-forked"
APP_NAMESPACE="lumiatech"

echo "==> Resolving ArgoCD LoadBalancer hostname ..."
ARGOCD_HOST=$(kubectl get svc argocd-server -n argocd \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
if [[ -z "${ARGOCD_HOST}" ]]; then
  echo "ERROR: argocd-server has no external hostname yet. Re-run after the LoadBalancer is ready."
  exit 1
fi
echo "    ArgoCD host: ${ARGOCD_HOST}"

echo ""
echo "==> Logging in to ArgoCD ..."
ARGOCD_PASS=$(kubectl get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath="{.data.password}" | base64 -d)
argocd login "${ARGOCD_HOST}" \
  --username admin \
  --password "${ARGOCD_PASS}" \
  --insecure

echo ""
echo "==> Creating namespace '${APP_NAMESPACE}' ..."
kubectl create namespace "${APP_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "==> Creating ArgoCD application pointing to ${MANIFEST_REPO} ..."
argocd app create lumiatech \
  --repo          "${MANIFEST_REPO}" \
  --path          helm/lumiatech \
  --dest-server   https://kubernetes.default.svc \
  --dest-namespace "${APP_NAMESPACE}" \
  --sync-policy   automated \
  --auto-prune \
  --self-heal

echo ""
echo "==> Triggering initial sync ..."
argocd app sync lumiatech

echo ""
echo "==> Application status:"
argocd app get lumiatech

echo ""
echo "Watch rollout with:"
echo "  kubectl get pods -n ${APP_NAMESPACE} -w"
echo "  kubectl get svc  -n ${APP_NAMESPACE}"
