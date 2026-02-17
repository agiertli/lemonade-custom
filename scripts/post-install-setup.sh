#!/bin/bash
set -e

# Post-Install Setup Script for Lemonade Stand Assistant
# This script handles cluster-level configurations that cannot be done via Helm

NAMESPACE="${NAMESPACE:-lemonade-stand-assistant}"
TIMEOUT=300

echo "========================================="
echo "Lemonade Stand Assistant - Post-Install Setup"
echo "========================================="
echo ""

# Function to wait for condition
wait_for() {
    local description=$1
    local command=$2
    local timeout=$3
    local elapsed=0

    echo "Waiting for: $description"
    while ! eval "$command" >/dev/null 2>&1; do
        if [ $elapsed -ge $timeout ]; then
            echo "ERROR: Timeout waiting for $description"
            return 1
        fi
        echo -n "."
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo " Done!"
}

# Step 1: Enable User Workload Monitoring
echo ""
echo "Step 1: Enabling User Workload Monitoring..."
echo "---------------------------------------------"

if oc get configmap cluster-monitoring-config -n openshift-monitoring >/dev/null 2>&1; then
    echo "✓ User workload monitoring is already configured"
else
    echo "Creating cluster-monitoring-config..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF

    echo "Waiting for user workload monitoring pods to start..."
    wait_for "prometheus-user-workload pods" \
        "oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus | grep Running" \
        $TIMEOUT

    echo "✓ User workload monitoring enabled successfully"
fi

# Step 2: Install Grafana Operator (Phase 1)
echo ""
echo "Step 2: Installing Grafana Operator..."
echo "---------------------------------------------"

if oc get csv -n $NAMESPACE | grep -q "grafana-operator.*Succeeded"; then
    echo "✓ Grafana Operator is already installed"
else
    echo "Creating OperatorGroup and Subscription..."

    # Check if OperatorGroup exists
    if ! oc get operatorgroup -n $NAMESPACE | grep -q "$NAMESPACE"; then
        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: $NAMESPACE
  namespace: $NAMESPACE
spec:
  targetNamespaces:
    - $NAMESPACE
EOF
    fi

    # Create Subscription
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: $NAMESPACE
spec:
  channel: v5
  installPlanApproval: Automatic
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF

    echo "Waiting for Grafana Operator to be ready..."
    wait_for "Grafana Operator CSV" \
        "oc get csv -n $NAMESPACE | grep 'grafana-operator.*Succeeded'" \
        $TIMEOUT

    echo "✓ Grafana Operator installed successfully"
fi

# Step 3: Wait for Grafana CRDs to be available
echo ""
echo "Step 3: Verifying Grafana CRDs..."
echo "---------------------------------------------"

wait_for "Grafana CRD" \
    "oc get crd grafanas.grafana.integreatly.org" \
    $TIMEOUT

wait_for "GrafanaDashboard CRD" \
    "oc get crd grafanadashboards.grafana.integreatly.org" \
    $TIMEOUT

wait_for "GrafanaDatasource CRD" \
    "oc get crd grafanadatasources.grafana.integreatly.org" \
    $TIMEOUT

echo "✓ All Grafana CRDs are available"

# Step 4: Verify ServiceMonitors are being scraped
echo ""
echo "Step 4: Verifying Metrics Collection..."
echo "---------------------------------------------"

if oc get servicemonitor lemonade-stand -n $NAMESPACE >/dev/null 2>&1; then
    echo "✓ ServiceMonitor 'lemonade-stand' found"
else
    echo "⚠ ServiceMonitor 'lemonade-stand' not found - may be created by Helm chart"
fi

echo ""
echo "========================================="
echo "Post-Install Setup Complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. If not already done, install the main Helm chart:"
echo "   helm install lemonade-stand-assistant ./chart --namespace $NAMESPACE"
echo ""
echo "2. Install Grafana (requires operator to be ready):"
echo "   helm install lemonade-grafana ./grafana --namespace $NAMESPACE --set operator=false"
echo ""
echo "3. Get application URL:"
echo "   echo https://\$(oc get route lemonade-stand -n $NAMESPACE -o jsonpath='{.spec.host}')"
echo ""
echo "4. Get Grafana URL:"
echo "   echo https://\$(oc get route grafana-route -n $NAMESPACE -o jsonpath='{.spec.host}')"
echo ""
