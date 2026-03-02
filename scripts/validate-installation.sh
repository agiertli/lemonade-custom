#!/bin/bash
# Validation script for Lemonade Stand Assistant installation
# Run this after install.sh completes to verify everything is working

NAMESPACE="${NAMESPACE:-lemonade-stand-assistant}"

echo "========================================="
echo "Lemonade Stand Assistant - Installation Validation"
echo "========================================="
echo ""

PASSED=0
FAILED=0

check() {
    local description=$1
    local command=$2

    echo -n "Checking: $description... "
    if eval "$command" >/dev/null 2>&1; then
        echo "✓ PASS"
        PASSED=$((PASSED + 1))
    else
        echo "✗ FAIL"
        FAILED=$((FAILED + 1))
    fi
}

echo "GPU Resources:"
echo "---------------------------------------------"
check "GPU nodes are available" "[ \$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l) -ge 3 ]"
check "GPU machineset scaled to 3" "[ \$(oc get machineset -n openshift-machine-api -o json | jq -r '.items[] | select(.metadata.name | contains(\"gpu\")) | .spec.replicas' | head -1) -eq 3 ]"

echo ""
echo "TrustyAI Component:"
echo "---------------------------------------------"
check "TrustyAI is enabled" "[ \$(oc get datasciencecluster -o jsonpath='{.items[0].spec.components.trustyai.managementState}') = 'Managed' ]"
check "GuardrailsOrchestrator CRD exists" "oc get crd guardrailsorchestrators.trustyai.opendatahub.io"
check "TrustyAI operator is running" "oc get deployment trustyai-service-operator-controller-manager -n redhat-ods-applications"

echo ""
echo "Application Pods:"
echo "---------------------------------------------"
check "lemonade-stand pod is running" "oc get pod -l app=lemonade-stand -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running"
check "llama-32 predictor is running" "oc get pod -l serving.kserve.io/inferenceservice=llama-32 -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running"
check "HAP detector is running" "oc get pod -l serving.kserve.io/inferenceservice=guardrails-detector-ibm-hap -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running"
check "Prompt injection detector is running" "oc get pod -l serving.kserve.io/inferenceservice=prompt-injection-detector -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running"
check "Lingua detector is running" "oc get pod -l app=lingua-detector -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running"
check "Guardrails orchestrator is running" "oc get pod -l app=guardrails-orchestrator -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running"

echo ""
echo "InferenceServices:"
echo "---------------------------------------------"
check "llama-32 InferenceService is ready" "[ \$(oc get inferenceservice llama-32 -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}') = 'True' ]"
check "HAP InferenceService is ready" "[ \$(oc get inferenceservice guardrails-detector-ibm-hap -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}') = 'True' ]"
check "Prompt injection InferenceService is ready" "[ \$(oc get inferenceservice prompt-injection-detector -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}') = 'True' ]"

echo ""
echo "Grafana Setup:"
echo "---------------------------------------------"
check "Grafana pod is running" "oc get pod -l app=grafana -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running"
check "Grafana service account exists" "oc get sa grafana-sa -n $NAMESPACE"
check "Grafana service account token exists" "oc get secret grafana-sa-token -n $NAMESPACE"
check "Grafana datasource exists" "oc get grafanadatasource prometheus-grafanadatasource -n $NAMESPACE"
check "Grafana datasource is synchronized" "[ \$(oc get grafanadatasource prometheus-grafanadatasource -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type==\"DatasourceSynchronized\")].status}') = 'True' ]"
check "Grafana dashboard exists" "oc get grafanadashboard guardrails-dashboard -n $NAMESPACE"
check "Grafana dashboard is synchronized" "[ \$(oc get grafanadashboard guardrails-dashboard -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type==\"DashboardSynchronized\")].status}') = 'True' ]"

echo ""
echo "Monitoring:"
echo "---------------------------------------------"
check "User workload monitoring is enabled" "oc get configmap cluster-monitoring-config -n openshift-monitoring"
check "ServiceMonitor for lemonade-stand exists" "oc get servicemonitor lemonade-stand -n $NAMESPACE"
check "ServiceMonitor for llama-32 exists" "oc get servicemonitor llama-32-metrics -n $NAMESPACE"

echo ""
echo "Routes:"
echo "---------------------------------------------"
check "Lemonade stand route exists" "oc get route lemonade-stand -n $NAMESPACE"
check "Grafana route exists" "oc get route grafana-route -n $NAMESPACE"

echo ""
echo "========================================="
echo "Validation Summary"
echo "========================================="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "✓ All checks passed!"
    echo ""
    echo "Access URLs:"
    echo "  Application: https://$(oc get route lemonade-stand -n $NAMESPACE -o jsonpath='{.spec.host}')"
    echo "  Grafana: https://$(oc get route grafana-route -n $NAMESPACE -o jsonpath='{.spec.host}')"
    echo ""
    exit 0
else
    echo "✗ Some checks failed. Please review the output above."
    echo ""
    echo "Troubleshooting commands:"
    echo "  oc get pods -n $NAMESPACE"
    echo "  oc get inferenceservice -n $NAMESPACE"
    echo "  oc logs -l app=lemonade-stand -n $NAMESPACE"
    echo ""
    exit 1
fi
