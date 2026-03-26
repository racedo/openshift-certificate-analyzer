#!/bin/bash
# Update cert-discovery-app deployment with new code

set -e

echo "==> Updating ConfigMap with new app.py..."
oc create configmap cert-discovery-app-code \
  --from-file=app.py=Container/app.py \
  -n cert-discovery-app \
  --dry-run=client -o yaml | oc apply -f -

echo "==> Restarting deployment to pick up changes..."
oc rollout restart deployment/cert-discovery-app -n cert-discovery-app

echo "==> Waiting for deployment to be ready..."
oc rollout status deployment/cert-discovery-app -n cert-discovery-app --timeout=5m

echo "==> Getting pod name..."
POD_NAME=$(oc get pods -n cert-discovery-app -l app=cert-discovery -o jsonpath='{.items[0].metadata.name}')

echo "==> Pod name: $POD_NAME"
echo ""
echo "==> Tailing logs (Ctrl+C to stop)..."
oc logs -f -n cert-discovery-app $POD_NAME
