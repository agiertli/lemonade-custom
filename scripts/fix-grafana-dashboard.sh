#!/bin/bash
set -e

# Script to ensure Grafana dashboard is properly configured
# This fixes the datasource UID issue that can occur during installation

NAMESPACE="${NAMESPACE:-lemonade-stand-assistant}"

echo "Validating and fixing Grafana dashboard configuration..."

# Wait for dashboard to exist
max_wait=30
elapsed=0
while ! oc get grafanadashboard guardrails-dashboard -n $NAMESPACE >/dev/null 2>&1; do
    if [ $elapsed -ge $max_wait ]; then
        echo "ERROR: Dashboard not found"
        exit 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done

# Check if dashboard has correct datasource UID
DASHBOARD_JSON=$(oc get grafanadashboard guardrails-dashboard -n $NAMESPACE -o jsonpath='{.spec.json}')

if echo "$DASHBOARD_JSON" | grep -q '${DS_PROMETHEUS}'; then
    echo "⚠ Dashboard has incorrect datasource reference, fixing..."

    # Fix the dashboard by replacing ${DS_PROMETHEUS} with Prometheus
    oc get grafanadashboard guardrails-dashboard -n $NAMESPACE -o json | \
    python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
dashboard_str = d['spec']['json'].replace('\${DS_PROMETHEUS}', 'Prometheus')
d['spec']['json'] = dashboard_str
print(json.dumps(d))
" | oc apply -f - >/dev/null 2>&1

    echo "✓ Dashboard datasource reference fixed"
else
    echo "✓ Dashboard datasource reference is correct"
fi

# Ensure datasource has correct UID
DATASOURCE_UID=$(oc get grafanadatasource prometheus-grafanadatasource -n $NAMESPACE -o jsonpath='{.spec.datasource.uid}' 2>/dev/null || echo "")

if [ "$DATASOURCE_UID" != "Prometheus" ]; then
    echo "⚠ Datasource UID missing or incorrect, fixing..."
    oc patch grafanadatasource prometheus-grafanadatasource -n $NAMESPACE --type='json' \
      -p='[{"op": "add", "path": "/spec/datasource/uid", "value": "Prometheus"}]' >/dev/null 2>&1
    echo "✓ Datasource UID set to 'Prometheus'"
else
    echo "✓ Datasource UID is correct"
fi

# Restart Grafana operator to ensure fresh reconciliation
echo "Restarting Grafana operator for clean reconciliation..."
oc delete pod -l app.kubernetes.io/name=grafana-operator -n $NAMESPACE >/dev/null 2>&1 || true
sleep 5

# Wait for new operator pod
oc wait --for=condition=ready pod -l app.kubernetes.io/name=grafana-operator -n $NAMESPACE --timeout=60s >/dev/null 2>&1

# Wait for dashboard to be synced
echo "Waiting for dashboard synchronization..."
sleep 15

# Restart Grafana pod to pick up changes
echo "Restarting Grafana pod..."
oc delete pod -l app=grafana -n $NAMESPACE >/dev/null 2>&1
oc wait --for=condition=ready pod -l app=grafana -n $NAMESPACE --timeout=120s >/dev/null 2>&1

echo "✓ Grafana dashboard configuration validated and fixed"
