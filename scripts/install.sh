#!/bin/bash
set -e

# All-in-One Installation Script for Lemonade Stand Assistant
# This script handles the complete deployment in the correct order

NAMESPACE="${NAMESPACE:-lemonade-stand-assistant}"
ENABLE_GPU_DETECTORS="${ENABLE_GPU_DETECTORS:-false}"

echo "========================================="
echo "Lemonade Stand Assistant - Full Installation"
echo "========================================="
echo ""
echo "Configuration:"
echo "  Namespace: $NAMESPACE"
echo "  GPU for Detectors: $ENABLE_GPU_DETECTORS"
echo ""

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
./scripts/post-install-setup.sh

# Step 3: Install main application
echo ""
echo "Step 3: Installing Lemonade Stand Assistant..."
echo "---------------------------------------------"

HELM_ARGS=""
if [ "$ENABLE_GPU_DETECTORS" = "true" ]; then
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

# Step 5: Wait for pods to be ready
echo ""
echo "Step 5: Waiting for pods to be ready..."
echo "---------------------------------------------"

echo "Waiting for application pods..."
oc wait --for=condition=ready pod -l app=lemonade-stand -n $NAMESPACE --timeout=300s || true

echo "Waiting for Grafana pod..."
oc wait --for=condition=ready pod -l app=grafana -n $NAMESPACE --timeout=300s || true

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
