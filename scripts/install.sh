#!/bin/bash
set -e

# All-in-One Installation Script for Lemonade Stand Assistant
# This script handles the complete deployment in the correct order

# Detect script directory and repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Change to repository root
cd "$REPO_ROOT"

NAMESPACE="${NAMESPACE:-lemonade-stand-assistant}"
PROD_MODE="${PROD_MODE:-false}"

# Set defaults based on mode
if [ "$PROD_MODE" = "true" ]; then
    ENABLE_GPU_DETECTORS="${ENABLE_GPU_DETECTORS:-true}"
    GPU_REPLICAS="${GPU_REPLICAS:-7}"
    GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-g6.4xlarge}"
else
    ENABLE_GPU_DETECTORS="${ENABLE_GPU_DETECTORS:-true}"
    GPU_REPLICAS="${GPU_REPLICAS:-3}"
    GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-g5.4xlarge}"
fi

echo "========================================="
echo "Lemonade Stand Assistant - Full Installation"
echo "========================================="
echo ""
echo "Configuration:"
echo "  Repository Root: $REPO_ROOT"
echo "  Namespace: $NAMESPACE"
echo "  Production Mode: $PROD_MODE"
echo "  GPU for Detectors: $ENABLE_GPU_DETECTORS"
echo "  GPU Replicas: $GPU_REPLICAS"
echo "  GPU Instance Type: $GPU_INSTANCE_TYPE"
echo ""

# Export for post-install-setup.sh
export GPU_REPLICAS
export GPU_INSTANCE_TYPE

# Step 1: Create namespace
echo "Step 1: Creating namespace..."
echo "---------------------------------------------"
if oc get namespace $NAMESPACE >/dev/null 2>&1; then
    echo "✓ Namespace '$NAMESPACE' already exists"
else
    oc new-project $NAMESPACE
    echo "✓ Namespace '$NAMESPACE' created"
fi

# Step 2: Run post-install setup (cluster configs)
echo ""
echo "Step 2: Configuring cluster-level settings..."
echo "---------------------------------------------"
bash "$SCRIPT_DIR/post-install-setup.sh"

# Step 3: Install main application
echo ""
echo "Step 3: Installing Lemonade Stand Assistant..."
echo "---------------------------------------------"

HELM_ARGS=""
if [ "$PROD_MODE" = "true" ]; then
    echo "Installing with PRODUCTION configuration..."
    HELM_ARGS="-f ./chart/values-prod.yaml"
elif [ "$ENABLE_GPU_DETECTORS" = "true" ]; then
    echo "Enabling GPU for detector models..."
    HELM_ARGS="--set detectors.hap.useGpu=true --set detectors.promptInjection.useGpu=true"
fi

helm install lemonade-stand-assistant ./chart --namespace $NAMESPACE $HELM_ARGS

echo "✓ Application installed"

# Step 4: Install Grafana
echo ""
echo "Step 4: Installing Grafana Dashboards..."
echo "---------------------------------------------"

# Wait a bit for operator to be fully ready
sleep 10

helm install lemonade-grafana ./grafana --namespace $NAMESPACE --set operator=false

echo "✓ Grafana installed"

# Step 4.5: Create Grafana Service Account Token
echo ""
echo "Creating Grafana service account token..."
echo "---------------------------------------------"

# Wait for Grafana service account to be created
max_wait=60
elapsed=0
while ! oc get sa grafana-sa -n $NAMESPACE >/dev/null 2>&1; do
    if [ $elapsed -ge $max_wait ]; then
        echo "ERROR: Timeout waiting for grafana-sa service account"
        exit 1
    fi
    echo -n "."
    sleep 2
    elapsed=$((elapsed + 2))
done
echo " Done!"

# Create the token secret if it doesn't exist
if ! oc get secret grafana-sa-token -n $NAMESPACE >/dev/null 2>&1; then
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: grafana-sa-token
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/service-account.name: grafana-sa
type: kubernetes.io/service-account-token
EOF
    echo "✓ Grafana service account token created"

    # Wait a few seconds for token to be populated
    sleep 5

    # Trigger datasource reconciliation to pick up the token
    oc patch grafanadatasource prometheus-grafanadatasource -n $NAMESPACE --type=json \
      -p='[{"op": "replace", "path": "/spec/datasource/editable", "value": false}]' 2>/dev/null || true
    sleep 2
    oc patch grafanadatasource prometheus-grafanadatasource -n $NAMESPACE --type=json \
      -p='[{"op": "replace", "path": "/spec/datasource/editable", "value": true}]' 2>/dev/null || true

    echo "✓ Datasource configured"
else
    echo "✓ Grafana service account token already exists"
fi

# Step 5: Wait for pods to be ready
echo ""
echo "Step 5: Waiting for pods to be ready..."
echo "---------------------------------------------"

echo "Waiting for application pods..."
oc wait --for=condition=ready pod -l app=lemonade-stand -n $NAMESPACE --timeout=300s || true

echo "Waiting for Grafana pod..."
oc wait --for=condition=ready pod -l app=grafana -n $NAMESPACE --timeout=300s || true

# Step 6: Fix and validate Grafana dashboard
echo ""
echo "Step 6: Validating Grafana Dashboard Configuration..."
echo "---------------------------------------------"
bash "$SCRIPT_DIR/fix-grafana-dashboard.sh"

echo ""
echo "========================================="
echo "Installation Complete!"
echo "========================================="
echo ""
echo "Access URLs:"
echo ""
echo "Application:"
APP_URL=$(oc get route lemonade-stand -n $NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null || echo "Not ready yet")
echo "  https://$APP_URL"
echo ""
echo "Grafana Dashboard:"
GRAFANA_URL=$(oc get route grafana-route -n $NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null || echo "Not ready yet")
echo "  https://$GRAFANA_URL"
echo "  (Login with OpenShift credentials)"
echo ""
echo "Monitor deployment status:"
echo "  oc get pods -n $NAMESPACE"
echo ""
echo "View logs:"
echo "  oc logs -f deployment/lemonade-stand -n $NAMESPACE"
echo ""
echo "Uninstall:"
echo "  helm uninstall lemonade-stand-assistant lemonade-grafana --namespace $NAMESPACE"
echo ""
