#!/usr/bin/env bash
# Installs ArgoCD on the EKS cluster, exposes it via a LoadBalancer, and
# prints the initial admin password + UI URL.
# Run after 01-create-cluster.sh.
set -euo pipefail

echo "==> Creating argocd namespace ..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "==> Applying ArgoCD install manifest ..."
# --server-side avoids the "annotation too long" error on applicationsets.argoproj.io CRD
# (client-side apply stores the full manifest in an annotation, which exceeds 262144 bytes)
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo ""
echo "==> Waiting for ArgoCD deployments to roll out (this may take 2-3 minutes) ..."
for deploy in argocd-server argocd-repo-server argocd-application-controller \
              argocd-dex-server argocd-redis argocd-notifications-controller; do
  if kubectl get deploy "${deploy}" -n argocd &>/dev/null; then
    kubectl rollout status deploy/"${deploy}" -n argocd --timeout=300s
  fi
done

# argocd-application-controller is a StatefulSet, not a Deployment
if kubectl get statefulset argocd-application-controller -n argocd &>/dev/null; then
  kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
fi

echo ""
echo "==> ArgoCD pods:"
kubectl get pods -n argocd

echo ""
echo "==> Patching argocd-server service to LoadBalancer ..."
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "LoadBalancer"}}'

echo ""
echo "Waiting for external hostname (may take 2-3 minutes) ..."
WAIT_SECS=0
MAX_WAIT=180
until ARGOCD_HOST=$(kubectl get svc argocd-server -n argocd \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null) \
      && [[ -n "${ARGOCD_HOST}" ]]; do
  if (( WAIT_SECS >= MAX_WAIT )); then
    echo "ERROR: LoadBalancer hostname not assigned after ${MAX_WAIT}s."
    echo "Check IAM permissions and that the AWS Load Balancer Controller is running."
    exit 1
  fi
  sleep 10
  (( WAIT_SECS += 10 ))
  echo "  ... still waiting (${WAIT_SECS}s)"
done

echo ""
echo "==> Initial admin password:"
ARGOCD_PASS=$(kubectl get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath="{.data.password}" | base64 --decode)
echo "${ARGOCD_PASS}"

echo ""
echo "ArgoCD UI : https://${ARGOCD_HOST}  (username: admin)"
echo ""
echo "Save the password above — script 03 reads it automatically from the secret."
