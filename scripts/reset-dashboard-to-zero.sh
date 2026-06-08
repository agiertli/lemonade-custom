#!/bin/bash
set -e

# Quick reset of Grafana dashboard metrics to zero
# Restarts all predictor pods to reset their metric counters

NAMESPACE="${NAMESPACE:-lemonade-stand-assistant}"

echo "========================================="
echo "Resetting Dashboard Metrics to Zero"
echo "========================================="
echo ""

echo "This will restart all predictor pods to reset their metrics."
echo "Downtime: ~30-60 seconds per service"
echo ""

# Delete all predictor pods
echo "Deleting predictor pods..."
oc delete pod -l component=predictor -n $NAMESPACE

echo ""
echo "Waiting for new pods to start..."
sleep 10

# Wait for all pods to be ready
echo ""
echo "Waiting for InferenceServices to become ready..."
for isvc in llama-32 guardrails-detector-ibm-hap guardrails-detector-prompt-injection; do
    echo "  Waiting for $isvc..."
    oc wait --for=condition=Ready isvc/$isvc -n $NAMESPACE --timeout=5m 2>/dev/null || true
done

echo ""
echo "Waiting additional 30 seconds for metrics to stabilize..."
sleep 30

echo ""
echo "========================================="
echo "✓ Dashboard Reset Complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Open Grafana dashboard"
echo "2. Set time range to 'Last 5 minutes'"
echo "3. Click the refresh button (or wait 10 seconds)"
echo "4. All panels should now show zero"
echo ""
echo "Metrics will start from zero as you use the application."
echo ""
