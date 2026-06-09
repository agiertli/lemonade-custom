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
TRANSLATION_SERVICE="${TRANSLATION_SERVICE:-false}"

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

# Translation service configuration
if [ "$TRANSLATION_SERVICE" = "true" ]; then
    HF_TOKEN_FILE="${HF_TOKEN_FILE:-$HOME/.cache/huggingface/token}"
    if [ -z "${HF_TOKEN:-}" ]; then
        if [ -f "$HF_TOKEN_FILE" ]; then
            HF_TOKEN=$(cat "$HF_TOKEN_FILE")
            echo "✓ HuggingFace token loaded from $HF_TOKEN_FILE"
        else
            echo "ERROR: TRANSLATION_SERVICE=true but no HF_TOKEN set and $HF_TOKEN_FILE not found."
            echo "Set HF_TOKEN env var or run: huggingface-cli login"
            exit 1
        fi
    fi
fi

echo "========================================="
echo "Lemonade Stand Assistant - Full Installation"
echo "========================================="
echo ""

# Run pre-installation validation
echo "Running pre-installation validation checks..."
echo "---------------------------------------------"
bash "$SCRIPT_DIR/pre-install-validation.sh"

echo ""
echo "Configuration:"
echo "  Repository Root: $REPO_ROOT"
echo "  Namespace: $NAMESPACE"
echo "  Production Mode: $PROD_MODE"
echo "  Translation Service: $TRANSLATION_SERVICE"
echo "  GPU for Detectors: $ENABLE_GPU_DETECTORS"
echo "  GPU Replicas: $GPU_REPLICAS"
echo "  GPU Instance Type: $GPU_INSTANCE_TYPE"
echo ""

# Export for post-install-setup.sh
export GPU_REPLICAS
export GPU_INSTANCE_TYPE
export TRANSLATION_SERVICE

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

if [ "$TRANSLATION_SERVICE" = "true" ]; then
    echo "Enabling translation service (TranslateGemma)..."
    HELM_ARGS="$HELM_ARGS --set translateService.enabled=true --set translateService.hfToken=$HF_TOKEN"
fi

helm upgrade --install lemonade-stand-assistant ./chart --namespace $NAMESPACE $HELM_ARGS

echo "✓ Application installed"

# Step 4: Install Grafana
echo ""
echo "Step 4: Installing Grafana Dashboards..."
echo "---------------------------------------------"

# Wait a bit for operator to be fully ready
sleep 10

# Clean up any backup template files that might have wrong configuration
if [ -f "$REPO_ROOT/grafana/templates/grafana.yaml.bak" ]; then
    echo "Removing old backup template file..."
    rm -f "$REPO_ROOT/grafana/templates/grafana.yaml.bak"
fi

# Delete old dashboard if it exists with incorrect datasource reference
# This ensures clean deployment with correct template
if oc get grafanadashboard guardrails-dashboard -n $NAMESPACE >/dev/null 2>&1; then
    DASHBOARD_JSON=$(oc get grafanadashboard guardrails-dashboard -n $NAMESPACE -o jsonpath='{.spec.json}' 2>/dev/null || echo "")
    if echo "$DASHBOARD_JSON" | grep -q '${DS_PROMETHEUS}'; then
        echo "Removing old dashboard with incorrect datasource reference..."
        oc delete grafanadashboard guardrails-dashboard -n $NAMESPACE --force --grace-period=0 2>/dev/null
        sleep 2
    fi
fi

helm upgrade --install lemonade-grafana ./grafana --namespace $NAMESPACE --set operator=false

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
else
    echo "✓ Grafana service account token already exists"
fi

# Wait for datasource to be created by Helm
echo "Waiting for Grafana datasource to be created..."
max_wait=30
elapsed=0
while ! oc get grafanadatasource prometheus-grafanadatasource -n $NAMESPACE >/dev/null 2>&1; do
    if [ $elapsed -ge $max_wait ]; then
        echo "ERROR: Timeout waiting for grafana datasource"
        exit 1
    fi
    echo -n "."
    sleep 2
    elapsed=$((elapsed + 2))
done
echo " Done!"

# Ensure datasource has the correct UID set in spec
# This must be done before datasource reconciliation
echo "Configuring datasource UID to 'Prometheus'..."
DATASOURCE_UID=$(oc get grafanadatasource prometheus-grafanadatasource -n $NAMESPACE -o jsonpath='{.spec.datasource.uid}' 2>/dev/null || echo "")
if [ "$DATASOURCE_UID" != "Prometheus" ]; then
    # Try add first (if field doesn't exist), fallback to replace
    oc patch grafanadatasource prometheus-grafanadatasource -n $NAMESPACE --type='json' \
      -p='[{"op": "add", "path": "/spec/datasource/uid", "value": "Prometheus"}]' 2>/dev/null || \
    oc patch grafanadatasource prometheus-grafanadatasource -n $NAMESPACE --type='json' \
      -p='[{"op": "replace", "path": "/spec/datasource/uid", "value": "Prometheus"}]' 2>/dev/null
    echo "✓ Datasource UID set to 'Prometheus'"
else
    echo "✓ Datasource UID already correct"
fi

# Trigger datasource reconciliation to pick up the token and UID
oc patch grafanadatasource prometheus-grafanadatasource -n $NAMESPACE --type=json \
  -p='[{"op": "replace", "path": "/spec/datasource/editable", "value": false}]' 2>/dev/null || true
sleep 2
oc patch grafanadatasource prometheus-grafanadatasource -n $NAMESPACE --type=json \
  -p='[{"op": "replace", "path": "/spec/datasource/editable", "value": true}]' 2>/dev/null || true
sleep 3

echo "✓ Datasource configured"

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
if [ "$TRANSLATION_SERVICE" = "true" ]; then
    echo "Translation Service:"
    echo "  oc get pods -l app=translate-service -n $NAMESPACE"
    echo ""
fi
echo "Monitor deployment status:"
echo "  oc get pods -n $NAMESPACE"
echo ""
echo "View logs:"
echo "  oc logs -f deployment/lemonade-stand -n $NAMESPACE"
echo ""
echo "Uninstall:"
echo "  helm uninstall lemonade-stand-assistant lemonade-grafana --namespace $NAMESPACE"
echo ""
