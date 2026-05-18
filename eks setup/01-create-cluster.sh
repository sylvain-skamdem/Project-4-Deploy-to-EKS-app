#!/usr/bin/env bash
# Creates the EKS cluster and configures kubectl to talk to it.
# Usage: ./01-create-cluster.sh [cluster-name] [region]
set -euo pipefail

CLUSTER_NAME="${1:-lumiatechs-eks-cluster}"
REGION="${2:-us-east-1}"

echo "==> Creating EKS cluster '${CLUSTER_NAME}' in ${REGION} ..."
eksctl create cluster \
  --name        "${CLUSTER_NAME}" \
  --region      "${REGION}" \
  --nodegroup-name lumiatech-nodes \
  --node-type   t3.medium \
  --nodes       2 \
  --nodes-min   1 \
  --nodes-max   4 \
  --managed

echo ""
echo "==> Updating kubeconfig ..."
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

echo ""
echo "==> Verifying nodes ..."
kubectl get nodes

echo ""
echo "Cluster '${CLUSTER_NAME}' is ready."
