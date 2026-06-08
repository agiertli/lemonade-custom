#!/bin/bash
set -e

# Benchmark runner for Lemonade Stand Assistant
# Runs load tests with different concurrent user counts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-lemonade-stand-assistant}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../benchmark-results}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Get application URL
APP_URL="https://$(oc get route lemonade-stand -n $NAMESPACE -o jsonpath='{.spec.host}')"

echo "========================================="
echo "Lemonade Stand - Load Test Suite"
echo "========================================="
echo "Application: $APP_URL"
echo "Timestamp: $TIMESTAMP"
echo "Output: $OUTPUT_DIR"
echo ""

# Test configurations
# Format: NAME|VUS|DURATION|DESCRIPTION
TESTS=(
    "1-user|1|2m|Single user baseline"
    "5-users|5|3m|Light load (5 concurrent users)"
    "10-users|10|3m|Medium load (10 concurrent users)"
    "50-users|50|5m|Heavy load (50 concurrent users)"
    "100-users|100|5m|Stress test (100 concurrent users)"
)

# Run each test
for test_config in "${TESTS[@]}"; do
    IFS='|' read -r name vus duration description <<< "$test_config"

    echo ""
    echo "========================================="
    echo "TEST: $description"
    echo "========================================="
    echo "Concurrent Users: $vus"
    echo "Duration: $duration"
    echo ""

    OUTPUT_FILE="$OUTPUT_DIR/${TIMESTAMP}_${name}.json"
    SUMMARY_FILE="$OUTPUT_DIR/${TIMESTAMP}_${name}_summary.txt"

    # Run k6 test
    k6 run \
        --out json="$OUTPUT_FILE" \
        --summary-export="$SUMMARY_FILE" \
        --vus "$vus" \
        --duration "$duration" \
        --env BASE_URL="$APP_URL" \
        --env REALISTIC=false \
        --env SAFE_ONLY=false \
        "$SCRIPT_DIR/k6-load-test.js" \
        2>&1 | tee "$OUTPUT_DIR/${TIMESTAMP}_${name}_console.log"

    echo ""
    echo "✓ Test completed: $name"
    echo "  Results: $OUTPUT_FILE"
    echo "  Summary: $SUMMARY_FILE"
    echo ""

    # Wait 30 seconds between tests to let system stabilize
    if [ "$name" != "100-users" ]; then
        echo "Waiting 30 seconds for system to stabilize..."
        sleep 30
    fi
done

echo ""
echo "========================================="
echo "All Tests Completed!"
echo "========================================="
echo ""
echo "Results saved to: $OUTPUT_DIR"
echo ""
echo "To analyze results:"
echo "  ls -lh $OUTPUT_DIR/${TIMESTAMP}_*"
echo ""

# Generate combined summary report
REPORT_FILE="$OUTPUT_DIR/${TIMESTAMP}_FULL_REPORT.md"

cat > "$REPORT_FILE" << EOF
# Lemonade Stand Load Test Report

**Date**: $(date)
**Application**: $APP_URL
**Test Run**: $TIMESTAMP

## Test Summary

| Test | Concurrent Users | Duration | Status |
|------|------------------|----------|--------|
EOF

for test_config in "${TESTS[@]}"; do
    IFS='|' read -r name vus duration description <<< "$test_config"
    echo "| $description | $vus | $duration | ✓ Completed |" >> "$REPORT_FILE"
done

cat >> "$REPORT_FILE" << EOF

## Result Files

\`\`\`
$(ls -lh "$OUTPUT_DIR/${TIMESTAMP}_"* | tail -n +2)
\`\`\`

## Quick Analysis

To view detailed metrics for each test:
\`\`\`bash
# View JSON results
jq . $OUTPUT_DIR/${TIMESTAMP}_*-users.json | less

# View summaries
cat $OUTPUT_DIR/${TIMESTAMP}_*-users_summary.txt
\`\`\`

## Key Metrics to Review

1. **Response Times** (http_req_duration)
   - p95 should be < 60s per test design
   - p99 indicates worst-case latency

2. **Success Rate** (sse_success_rate)
   - Should be > 80% per test design

3. **Error Rate** (sse_error_rate)
   - Should be < 20% per test design

4. **Throughput** (http_reqs)
   - Total requests handled during test

5. **SSE Metrics**
   - sse_ttfb_ms: Time to first byte
   - sse_total_time_ms: Total response time
   - sse_chunks_count: Streaming performance
   - sse_blocked_rate: Guardrail effectiveness
EOF

echo "Full report generated: $REPORT_FILE"
echo ""
