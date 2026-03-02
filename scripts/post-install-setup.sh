#!/bin/bash
set -e

# Post-Install Setup Script for Lemonade Stand Assistant
# This script handles cluster-level configurations that cannot be done via Helm

NAMESPACE="${NAMESPACE:-lemonade-stand-assistant}"
GPU_REPLICAS="${GPU_REPLICAS:-3}"
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

# Step 1: Scale GPU MachineSets
echo ""
echo "Step 1: Ensuring GPU Worker Nodes are Available..."
echo "---------------------------------------------"

GPU_DESIRED_REPLICAS=$GPU_REPLICAS
GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-g5.4xlarge}"

echo "Target GPU instance type: $GPU_INSTANCE_TYPE"

# Try to find GPU machinesets matching the instance type, fallback to any GPU machineset
GPU_MACHINESETS=$(oc get machineset -n openshift-machine-api -o json | \
  jq -r --arg instance_type "$GPU_INSTANCE_TYPE" \
  '.items[] | select(.metadata.name | contains("gpu")) | select(.spec.template.spec.providerSpec.value.instanceType == $instance_type) | .metadata.name')

if [ -z "$GPU_MACHINESETS" ]; then
  echo "No machineset found with instance type $GPU_INSTANCE_TYPE, using any GPU machineset..."
  GPU_MACHINESETS=$(oc get machineset -n openshift-machine-api -o json | jq -r '.items[] | select(.metadata.name | contains("gpu")) | .metadata.name')
fi

if [ -z "$GPU_MACHINESETS" ]; then
    echo "WARNING: No GPU machinesets found. Skipping GPU node scaling."
    echo "The demo requires GPU nodes. Please ensure GPU nodes are available manually."
else
    for MACHINESET in $GPU_MACHINESETS; do
        CURRENT_REPLICAS=$(oc get machineset $MACHINESET -n openshift-machine-api -o jsonpath='{.spec.replicas}')
        echo "Found GPU machineset: $MACHINESET (current replicas: $CURRENT_REPLICAS)"

        if [ "$CURRENT_REPLICAS" -lt "$GPU_DESIRED_REPLICAS" ]; then
            echo "Scaling $MACHINESET from $CURRENT_REPLICAS to $GPU_DESIRED_REPLICAS replicas..."
            oc scale machineset $MACHINESET -n openshift-machine-api --replicas=$GPU_DESIRED_REPLICAS
            echo "✓ Machineset scaled"
        else
            echo "✓ Machineset already has $CURRENT_REPLICAS replicas (>= $GPU_DESIRED_REPLICAS)"
        fi
    done

    # Wait for GPU nodes to be ready
    echo ""
    echo "Waiting for GPU nodes to be ready..."
    EXPECTED_GPU_NODES=$GPU_DESIRED_REPLICAS

    wait_for "GPU nodes to be ready" \
        "[ \$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l) -ge $EXPECTED_GPU_NODES ]" \
        600

    # Verify GPU allocatable resources
    echo "Verifying GPU resources..."
    GPU_COUNT=$(oc get nodes -o json | jq '[.items[] | select(.status.allocatable."nvidia.com/gpu" != null) | .status.allocatable."nvidia.com/gpu" | tonumber] | add')
    echo "✓ Total allocatable GPUs in cluster: $GPU_COUNT"

    if [ "$GPU_COUNT" -lt "$GPU_DESIRED_REPLICAS" ]; then
        echo "WARNING: Expected at least $GPU_DESIRED_REPLICAS GPUs, but found $GPU_COUNT"
        echo "The demo may not have sufficient GPU resources."
    fi
fi

# Step 2: Enable User Workload Monitoring
echo ""
echo "Step 2: Enabling User Workload Monitoring..."
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

# Step 3: Enable TrustyAI in DataScienceCluster
echo ""
echo "Step 3: Enabling TrustyAI in DataScienceCluster..."
echo "---------------------------------------------"

# Find the DataScienceCluster (usually named 'default-dsc' or similar)
DSC_NAME=$(oc get datasciencecluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$DSC_NAME" ]; then
    echo "ERROR: No DataScienceCluster found. Is Red Hat OpenShift AI installed?"
    echo "Please install Red Hat OpenShift AI first."
    exit 1
fi

echo "Found DataScienceCluster: $DSC_NAME"

# Check if TrustyAI is already enabled
TRUSTYAI_STATUS=$(oc get datasciencecluster $DSC_NAME -o jsonpath='{.spec.components.trustyai.managementState}' 2>/dev/null || echo "")

if [ "$TRUSTYAI_STATUS" = "Managed" ]; then
    echo "✓ TrustyAI is already enabled in DataScienceCluster"
else
    echo "Enabling TrustyAI component..."
    oc patch datasciencecluster $DSC_NAME --type='json' -p='[
        {
            "op": "add",
            "path": "/spec/components/trustyai",
            "value": {
                "managementState": "Managed"
            }
        }
    ]' 2>/dev/null || \
    oc patch datasciencecluster $DSC_NAME --type='merge' -p='{"spec":{"components":{"trustyai":{"managementState":"Managed"}}}}'

    echo "✓ TrustyAI component enabled"
fi

# Wait for TrustyAI operator to be ready
echo "Waiting for TrustyAI operator to deploy..."
wait_for "TrustyAI operator deployment" \
    "oc get deployment trustyai-service-operator-controller-manager -n redhat-ods-applications" \
    $TIMEOUT

# Wait for GuardrailsOrchestrator CRD to be available
echo "Waiting for GuardrailsOrchestrator CRD..."
wait_for "GuardrailsOrchestrator CRD" \
    "oc get crd guardrailsorchestrators.trustyai.opendatahub.io" \
    $TIMEOUT

echo "✓ TrustyAI is ready and GuardrailsOrchestrator CRD is available"

# Step 4: Install Grafana Operator (Phase 1)
echo ""
echo "Step 4: Installing Grafana Operator..."
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

# Step 5: Wait for Grafana CRDs to be available
echo ""
echo "Step 5: Verifying Grafana CRDs..."
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

# Step 6: Verify ServiceMonitors are being scraped
echo ""
echo "Step 6: Verifying Metrics Collection..."
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
