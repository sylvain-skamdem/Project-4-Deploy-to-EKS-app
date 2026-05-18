#!/usr/bin/env bash
# Triggers the first CI/CD pipeline run by pushing an empty commit to main,
# then tails the rollout in the cluster.
# Run after all secrets are set and ArgoCD is configured.
set -euo pipefail

APP_NAMESPACE="lumiatech"

echo "==> Pushing empty trigger commit to main ..."
git commit --allow-empty -m "ci: trigger initial deployment"
git push origin main

echo ""
echo "Pipeline started. Watch it at:"
echo "  https://github.com/<your-username>/Project-4-Deploy-to-EKS-app/actions"

echo ""
echo "==> Watching pod rollout in namespace '${APP_NAMESPACE}' ..."
echo "(Press Ctrl+C to stop watching)"
kubectl get pods -n "${APP_NAMESPACE}" -w &
WATCH_PID=$!

echo ""
echo "==> Services in namespace '${APP_NAMESPACE}':"
kubectl get svc -n "${APP_NAMESPACE}"

echo ""
echo "Once the EXTERNAL-IP is assigned, open it in a browser."
echo "Default credentials: admin_vp / admin_vp"

wait "${WATCH_PID}"
