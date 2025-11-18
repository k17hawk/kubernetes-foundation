#!/bin/bash

# Enhanced Flask App Load Testing Script
# Tests Prometheus metrics with various load patterns

set -e

# Configuration
FLASK_URL="${FLASK_URL:-http://localhost:5000}"
DURATION="${DURATION:-60}"
CONCURRENT_USERS="${CONCURRENT_USERS:-5}"
TEST_MODE="${TEST_MODE:-mixed}"  # Options: mixed, read-heavy, write-heavy, stress

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Flask App Load Test with Metrics Validation${NC}"
echo -e "${BLUE}================================================${NC}"
echo "Target:           $FLASK_URL"
echo "Duration:         ${DURATION}s"
echo "Concurrent Users: $CONCURRENT_USERS"
echo "Test Mode:        $TEST_MODE"
echo ""

# Check if Flask app is accessible
echo -e "${YELLOW}🔍 Checking Flask app availability...${NC}"
if ! curl -s -f "$FLASK_URL/health" > /dev/null 2>&1; then
    echo -e "${RED}❌ Flask app not accessible at $FLASK_URL${NC}"
    echo "   Make sure to port-forward: kubectl port-forward -n flask-mysql svc/flask-app 5000:5000"
    exit 1
fi
echo -e "${GREEN}✅ Flask app is accessible${NC}"
echo ""

# Get baseline metrics
echo -e "${YELLOW}📊 Collecting baseline metrics...${NC}"
BASELINE_REQUESTS=$(curl -s "$FLASK_URL/metrics" | grep "flask_http_requests_total" | grep -v "#" | awk '{sum+=$2} END {print sum}')
BASELINE_MESSAGES=$(curl -s "$FLASK_URL/metrics" | grep "flask_messages_total" | grep -v "#" | awk '{print $2}')
echo "   Current total requests: ${BASELINE_REQUESTS:-0}"
echo "   Current messages in DB: ${BASELINE_MESSAGES:-0}"
echo ""

# Function to make requests with error handling
generate_traffic() {
    local endpoint=$1
    local method=${2:-GET}
    local data=$3
    local label=$4
    
    if [ "$method" = "POST" ]; then
        response=$(curl -s -w "\n%{http_code}" -X POST "$FLASK_URL$endpoint" \
            -H "Content-Type: application/json" \
            -d "$data" 2>/dev/null)
    else
        response=$(curl -s -w "\n%{http_code}" "$FLASK_URL$endpoint" 2>/dev/null)
    fi
    
    http_code=$(echo "$response" | tail -n1)
    
    # Track status codes
    if [ "$http_code" = "200" ]; then
        echo "success:$label" >> /tmp/load_test_results_$$
    else
        echo "error:$label:$http_code" >> /tmp/load_test_results_$$
    fi
}

# Function to run different test patterns
run_mixed_load() {
    generate_traffic "/" "GET" "" "read_home" &
    generate_traffic "/json" "GET" "" "read_json" &
    generate_traffic "/health" "GET" "" "health" &
    generate_traffic "/stats" "GET" "" "stats" &
    generate_traffic "/add/test-msg-$RANDOM" "GET" "" "write_add" &
    
    # Occasional bulk operations
    if [ $((RANDOM % 20)) -eq 0 ]; then
        generate_traffic "/bulk/write" "POST" '{"count": 50, "message_length": 20}' "bulk_write" &
    fi
    
    if [ $((RANDOM % 10)) -eq 0 ]; then
        generate_traffic "/bulk/read?limit=100" "GET" "" "bulk_read" &
    fi
}

run_read_heavy_load() {
    # 90% reads, 10% writes
    generate_traffic "/" "GET" "" "read_home" &
    generate_traffic "/json" "GET" "" "read_json" &
    generate_traffic "/json" "GET" "" "read_json" &
    generate_traffic "/stats" "GET" "" "stats" &
    generate_traffic "/bulk/read?limit=100" "GET" "" "bulk_read" &
    
    if [ $((RANDOM % 10)) -eq 0 ]; then
        generate_traffic "/add/test-$RANDOM" "GET" "" "write_add" &
    fi
}

run_write_heavy_load() {
    # 70% writes, 30% reads
    generate_traffic "/add/msg-$RANDOM" "GET" "" "write_add" &
    generate_traffic "/add/data-$RANDOM" "GET" "" "write_add" &
    generate_traffic "/bulk/write" "POST" '{"count": 25, "message_length": 15}' "bulk_write" &
    generate_traffic "/json" "GET" "" "read_json" &
    
    if [ $((RANDOM % 5)) -eq 0 ]; then
        generate_traffic "/stats" "GET" "" "stats" &
    fi
}

run_stress_load() {
    # Maximum load with all operations
    generate_traffic "/" "GET" "" "stress_read" &
    generate_traffic "/json" "GET" "" "stress_read" &
    generate_traffic "/add/stress-$RANDOM" "GET" "" "stress_write" &
    generate_traffic "/bulk/write" "POST" '{"count": 100, "message_length": 30}' "stress_bulk_write" &
    generate_traffic "/bulk/read?limit=500" "GET" "" "stress_bulk_read" &
    generate_traffic "/stress/write" "POST" '{"concurrent_writes": 3, "messages_per_write": 50}' "stress_concurrent" &
    generate_traffic "/stress/read?concurrent_reads=5&read_limit=100" "GET" "" "stress_concurrent_read" &
}

# Initialize results file
> /tmp/load_test_results_$$

# Start time
start_time=$(date +%s)
request_count=0
progress_interval=5

echo -e "${GREEN}📊 Starting traffic generation (${TEST_MODE} mode)...${NC}"
echo ""

# Run load test based on mode
while true; do
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    
    if [ $elapsed -ge $DURATION ]; then
        break
    fi
    
    # Generate traffic based on test mode
    for i in $(seq 1 $CONCURRENT_USERS); do
        case $TEST_MODE in
            "read-heavy")
                run_read_heavy_load
                ;;
            "write-heavy")
                run_write_heavy_load
                ;;
            "stress")
                run_stress_load
                ;;
            *)
                run_mixed_load
                ;;
        esac
        request_count=$((request_count + 5))
    done
    
    # Show progress
    if [ $((elapsed % progress_interval)) -eq 0 ] && [ $elapsed -gt 0 ]; then
        remaining=$((DURATION - elapsed))
        success_count=$(grep -c "^success:" /tmp/load_test_results_$$ 2>/dev/null || echo 0)
        error_count=$(grep -c "^error:" /tmp/load_test_results_$$ 2>/dev/null || echo 0)
        total_responses=$((success_count + error_count))
        
        if [ $total_responses -gt 0 ]; then
            success_rate=$(awk "BEGIN {printf \"%.1f\", ($success_count/$total_responses)*100}")
        else
            success_rate="0.0"
        fi
        
        echo -e "${BLUE}⏱️  ${elapsed}s/${DURATION}s${NC} | Requests: ~$request_count | Success: $success_count | Errors: $error_count | Rate: ${success_rate}%"
    fi
    
    # Delay based on test mode
    case $TEST_MODE in
        "stress")
            sleep 0.05
            ;;
        *)
            sleep 0.2
            ;;
    esac
done

echo ""
echo -e "${YELLOW}⏳ Waiting for pending requests to complete...${NC}"
wait

# Calculate final stats
end_time=$(date +%s)
actual_duration=$((end_time - start_time))
success_count=$(grep -c "^success:" /tmp/load_test_results_$$ 2>/dev/null || echo 0)
error_count=$(grep -c "^error:" /tmp/load_test_results_$$ 2>/dev/null || echo 0)
total_responses=$((success_count + error_count))

echo ""
echo -e "${BLUE}================================${NC}"
echo -e "${GREEN}✅ Load test completed!${NC}"
echo -e "${BLUE}================================${NC}"
echo "Duration:          ${actual_duration}s"
echo "Requests sent:     ~${request_count}"
echo "Responses:         ${total_responses}"
echo "Successful:        ${success_count}"
echo "Errors:            ${error_count}"

if [ $total_responses -gt 0 ]; then
    success_rate=$(awk "BEGIN {printf \"%.2f\", ($success_count/$total_responses)*100}")
    avg_rps=$(awk "BEGIN {printf \"%.2f\", $total_responses/$actual_duration}")
    echo "Success Rate:      ${success_rate}%"
    echo "Avg Requests/sec:  ${avg_rps}"
fi

# Get post-test metrics
echo ""
echo -e "${YELLOW}📊 Collecting post-test metrics...${NC}"
sleep 2  # Wait for metrics to update

FINAL_REQUESTS=$(curl -s "$FLASK_URL/metrics" | grep "flask_http_requests_total" | grep -v "#" | awk '{sum+=$2} END {print sum}')
FINAL_MESSAGES=$(curl -s "$FLASK_URL/metrics" | grep "flask_messages_total" | grep -v "#" | awk '{print $2}')

echo "   Total requests (Prometheus): ${FINAL_REQUESTS:-0} (was ${BASELINE_REQUESTS:-0})"
echo "   Messages in DB: ${FINAL_MESSAGES:-0} (was ${BASELINE_MESSAGES:-0})"

if [ -n "$FINAL_REQUESTS" ] && [ -n "$BASELINE_REQUESTS" ]; then
    new_requests=$((FINAL_REQUESTS - BASELINE_REQUESTS))
    echo "   New requests: $new_requests"
fi

# Error breakdown
if [ $error_count -gt 0 ]; then
    echo ""
    echo -e "${RED}❌ Error Breakdown:${NC}"
    grep "^error:" /tmp/load_test_results_$$ | cut -d: -f2- | sort | uniq -c | while read count error; do
        echo "   $count x $error"
    done
fi

# Success breakdown
echo ""
echo -e "${GREEN}✅ Success Breakdown by Operation:${NC}"
grep "^success:" /tmp/load_test_results_$$ | cut -d: -f2 | sort | uniq -c | while read count operation; do
    echo "   $count x $operation"
done

# Cleanup
rm -f /tmp/load_test_results_$$

# Show next steps
echo ""
echo -e "${BLUE}================================${NC}"
echo -e "${YELLOW}📈 Next Steps: Analyze Metrics${NC}"
echo -e "${BLUE}================================${NC}"
echo ""
echo "1. View raw metrics:"
echo "   curl $FLASK_URL/metrics"
echo ""
echo "2. Port-forward to Prometheus (if not already):"
echo "   kubectl port-forward -n flask-mysql svc/prometheus 9090:9090"
echo ""
echo "3. Open Prometheus UI:"
echo "   http://localhost:9090"
echo ""
echo "4. Try these Prometheus queries:"
echo ""
echo -e "${GREEN}   # Request rate during test${NC}"
echo "   rate(flask_http_requests_total[1m])"
echo ""
echo -e "${GREEN}   # Request rate by endpoint${NC}"
echo "   sum(rate(flask_http_requests_total[1m])) by (endpoint)"
echo ""
echo -e "${GREEN}   # Success vs error rate${NC}"
echo "   sum(rate(flask_http_requests_total{status=~\"2..\"}[1m]))"
echo "   sum(rate(flask_http_requests_total{status=~\"4..|5..\"}[1m]))"
echo ""
echo -e "${GREEN}   # 95th percentile latency${NC}"
echo "   histogram_quantile(0.95, rate(flask_http_request_duration_seconds_bucket[1m]))"
echo ""
echo -e "${GREEN}   # Database query rate (primary vs replica)${NC}"
echo "   sum(rate(flask_db_queries_total[1m])) by (db_type, operation)"
echo ""
echo -e "${GREEN}   # MySQL queries per second${NC}"
echo "   rate(mysql_global_status_queries{instance_type=\"primary\"}[1m])"
echo "   rate(mysql_global_status_queries{instance_type=\"replica\"}[1m])"
echo ""
echo -e "${GREEN}   # Replication lag${NC}"
echo "   mysql_slave_status_seconds_behind_master{instance_type=\"replica\"}"
echo ""
echo -e "${YELLOW}💡 Pro tip:${NC} Run multiple tests with different modes:"
echo "   TEST_MODE=read-heavy DURATION=30 ./load_test.sh"
echo "   TEST_MODE=write-heavy DURATION=30 ./load_test.sh"
echo "   TEST_MODE=stress DURATION=30 ./load_test.sh"
echo ""