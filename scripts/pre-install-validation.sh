#!/bin/bash
set -e

# Pre-Installation Validation Script
# This script validates the installation environment and templates BEFORE installation
# to catch any configuration issues early

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "========================================="
echo "Pre-Installation Validation"
echo "========================================="
echo ""

VALIDATION_FAILED=false

# Validation 1: Check for backup files that could cause issues
echo "Validating template files..."
BACKUP_FILES=$(find "$REPO_ROOT/grafana/templates" -name "*.bak" -o -name "*.old" -o -name "*~" 2>/dev/null || true)
if [ -n "$BACKUP_FILES" ]; then
    echo "❌ FAIL: Found backup files in templates directory:"
    echo "$BACKUP_FILES"
    echo "   These files may cause Helm to deploy incorrect configurations."
    echo "   Remove them before installation."
    VALIDATION_FAILED=true
else
    echo "✓ No backup files found in templates"
fi

# Validation 2: Verify datasource UID is hardcoded in template
echo ""
echo "Validating Grafana datasource template..."
DATASOURCE_UID=$(grep -A 20 "kind: GrafanaDatasource" "$REPO_ROOT/grafana/templates/grafana.yaml" | grep "uid:" | grep -v "#" | awk '{print $2}')
if [ "$DATASOURCE_UID" != "Prometheus" ]; then
    echo "❌ FAIL: Datasource UID is not set to 'Prometheus' in template"
    echo "   Found: $DATASOURCE_UID"
    echo "   Expected: Prometheus"
    VALIDATION_FAILED=true
else
    echo "✓ Datasource UID correctly set to 'Prometheus'"
fi

# Validation 3: Check dashboard doesn't use template variables
echo ""
echo "Validating dashboard template..."
if grep -q '${DS_PROMETHEUS}' "$REPO_ROOT/grafana/templates/grafana.yaml"; then
    echo "❌ FAIL: Dashboard uses undefined template variable \${DS_PROMETHEUS}"
    echo "   All datasource references must be hardcoded to 'Prometheus'"
    VALIDATION_FAILED=true
else
    echo "✓ Dashboard uses hardcoded datasource UIDs"
fi

# Validation 4: Verify all dashboard panel datasources
echo ""
echo "Validating dashboard panel datasources..."
DASHBOARD_UIDS=$(helm template test ./grafana --set operator=false 2>&1 | grep -o '"uid":[[:space:]]*"[^"]*"' | grep -v "Grafana" | grep -v "34d7e0c2" | grep -v "Prometheus" || true)
if [ -n "$DASHBOARD_UIDS" ]; then
    echo "❌ FAIL: Found dashboard panels with non-Prometheus datasource UIDs:"
    echo "$DASHBOARD_UIDS"
    VALIDATION_FAILED=true
else
    echo "✓ All dashboard panels use 'Prometheus' datasource UID"
fi

# Validation 5: Verify Helm chart syntax
echo ""
echo "Validating Helm chart syntax..."
if ! helm template test ./grafana --set operator=false >/dev/null 2>&1; then
    echo "❌ FAIL: Helm chart template validation failed"
    echo "   Run: helm template ./grafana --set operator=false"
    VALIDATION_FAILED=true
else
    echo "✓ Helm chart templates are valid"
fi

# Validation 6: Check main application chart
echo ""
echo "Validating main application chart..."
if ! helm template test ./chart >/dev/null 2>&1; then
    echo "❌ FAIL: Main application Helm chart validation failed"
    echo "   Run: helm template ./chart"
    VALIDATION_FAILED=true
else
    echo "✓ Main application chart is valid"
fi

# Validation 7: Verify prod values file exists and is valid
echo ""
echo "Validating production values file..."
if [ ! -f "$REPO_ROOT/chart/values-prod.yaml" ]; then
    echo "❌ FAIL: Production values file not found"
    VALIDATION_FAILED=true
elif ! helm template test ./chart -f ./chart/values-prod.yaml >/dev/null 2>&1; then
    echo "❌ FAIL: Production values file is invalid"
    VALIDATION_FAILED=true
else
    echo "✓ Production values file is valid"
fi

# Final result
echo ""
echo "========================================="
if [ "$VALIDATION_FAILED" = true ]; then
    echo "❌ VALIDATION FAILED"
    echo "========================================="
    echo ""
    echo "Please fix the issues above before running installation."
    exit 1
else
    echo "✅ ALL VALIDATIONS PASSED"
    echo "========================================="
    echo ""
    echo "The installation is ready to proceed."
    echo ""
    echo "To install:"
    echo "  Development mode: ./scripts/install.sh"
    echo "  Production mode:  PROD_MODE=true ./scripts/install.sh"
    echo ""
fi
