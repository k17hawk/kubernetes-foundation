#!/bin/bash
set -e

echo "🚀 FACEBOOK-STYLE PARALLEL WRITE LOAD TEST"
echo "================================================"

# Configuration
TARGET="${APP_URL:-http://localhost:5000}"
CONCURRENT_USERS=50
WRITES_PER_USER=3
MESSAGE_COUNT=10
TIMEOUT=30

TOTAL_EXPECTED_WRITES=$((CONCURRENT_USERS * WRITES_PER_USER * MESSAGE_COUNT))

echo "Target:           $TARGET"
echo "Concurrent Users: $CONCURRENT_USERS"
echo "Writes per User:  $WRITES_PER_USER"
echo "Messages per Write: $MESSAGE_COUNT"
echo "Total Expected Messages: $TOTAL_EXPECTED_WRITES"
echo ""

# Create temp files for coordination and results
SYNC_FILE=$(mktemp)
RESULTS_FILE=$(mktemp)
LATENCY_FILE=$(mktemp)

echo "SYNC_FILE: $SYNC_FILE"
echo "RESULTS_FILE: $RESULTS_FILE"
echo "LATENCY_FILE: $LATENCY_FILE"

# Cleanup function
cleanup() {
    rm -f "$SYNC_FILE" "$SYNC_FILE.start" "$RESULTS_FILE" "$LATENCY_FILE"
    echo "🧹 Cleaned up temp files"
}
trap cleanup EXIT

# Function for truly parallel writer with detailed metrics
parallel_writer() {
    local user_id=$1
    local writes=$2
    local msg_count=$3
    local timeout_val=$4
    local sync_file=$5
    local results_file=$6
    local latency_file=$7
    
    # WAIT for start signal - ALL users wait here until triggered
    while [ ! -f "${sync_file}.start" ]; do
        sleep 0.001
    done
    
    local user_success=0
    local user_fail=0
    local user_timeout=0
    local total_latency=0
    
    for ((i=1; i<=writes; i++)); do
        local message_length=$((20 + RANDOM % 30))
        local payload="{\"count\": $msg_count, \"message_length\": $message_length}"
        
        # HIGH PRECISION timing
        local start_time=$(date +%s%N)  # nanoseconds
        
        # Make the request with detailed timing
        local response
        response=$(timeout --signal=KILL ${timeout_val}s curl -s -X "POST" "$TARGET/bulk/write" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            -w "HTTP_CODE:%{http_code} TOTAL_TIME:%{time_total} CONNECT_TIME:%{time_connect} STARTTRANSFER_TIME:%{time_starttransfer}" \
            2>/dev/null) || true
        
        local exit_code=$?
        local end_time=$(date +%s%N)
        local duration_ns=$((end_time - start_time))
        local duration_ms=$((duration_ns / 1000000))
        
        # Parse curl metrics
        local http_code=$(echo "$response" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2)
        local total_time=$(echo "$response" | grep -o 'TOTAL_TIME:[0-9.]*' | cut -d: -f2)
        
        # Remove metrics from response body
        local body=$(echo "$response" | sed 's/HTTP_CODE:[0-9]*//g' | sed 's/TOTAL_TIME:[0-9.]*//g' | sed 's/CONNECT_TIME:[0-9.]*//g' | sed 's/STARTTRANSFER_TIME:[0-9.]*//g')
        
        # Record latency
        echo "$duration_ms" >> "$latency_file"
        
        if [ $exit_code -eq 124 ] || [ $exit_code -eq 137 ]; then
            ((user_timeout++)) || true
            echo "User $user_id-Write $i: TIMEOUT ${timeout_val}s" >> "$results_file"
        elif [ -n "$http_code" ]; then
            if [ "$http_code" -eq 200 ]; then
                ((user_success++)) || true
                total_latency=$((total_latency + duration_ms))
                echo "User $user_id-Write $i: SUCCESS ${duration_ms}ms (server:${total_time}s)" >> "$results_file"
            else
                ((user_fail++)) || true
                echo "User $user_id-Write $i: FAILED HTTP$http_code ${duration_ms}ms" >> "$results_file"
            fi
        else
            ((user_fail++)) || true
            echo "User $user_id-Write $i: FAILED_NO_RESPONSE ${duration_ms}ms" >> "$results_file"
        fi
        
        # Small random delay between writes (0-50ms)
        sleep_duration=$(echo "scale=3; $RANDOM/32767/20" | bc -l 2>/dev/null || echo "0.02")
        sleep "$sleep_duration"
    done
    
    # Record user summary
    local avg_latency=0
    if [ $user_success -gt 0 ]; then
        avg_latency=$((total_latency / user_success))
    fi
    echo "USER_SUMMARY $user_id: success=$user_success fail=$user_fail timeout=$user_timeout avg_latency=${avg_latency}ms" >> "$results_file"
}

# Check service availability
echo "🔍 Checking service availability..."
CHECK_RESPONSE=$(timeout 10s curl -s -o /dev/null -w "%{http_code}" "$TARGET/health" 2>/dev/null || echo "000")

if [ "$CHECK_RESPONSE" -eq 200 ]; then
    echo "✅ Service is accessible"
else
    echo "❌ Service is not accessible at $TARGET (HTTP $CHECK_RESPONSE)"
    exit 1
fi

# Get baseline metrics
echo "📊 Collecting baseline metrics..."
BASELINE_STATS=$(curl -s "$TARGET/stats" || echo '{"stats":{"message_count":0}}')
BASELINE_MESSAGES=$(echo "$BASELINE_STATS" | grep -o '"message_count":[0-9]*' | cut -d: -f2 | head -1 || echo "0")

echo "Baseline messages in DB: $BASELINE_MESSAGES"

echo ""
echo "🔥 Starting TRULY PARALLEL load test..."
echo "Launching $CONCURRENT_USERS users that will ALL start at the same time..."
echo ""

# Launch ALL users in background - they will wait for the start signal
PIDS=()
for ((user=1; user<=CONCURRENT_USERS; user++)); do
    parallel_writer $user $WRITES_PER_USER $MESSAGE_COUNT $TIMEOUT $SYNC_FILE $RESULTS_FILE $LATENCY_FILE &
    PIDS+=($!)
done

echo "⏳ All $CONCURRENT_USERS users are WAITING for start signal..."
sleep 2

echo ""
echo "🎯 FIRING START SIGNAL - ALL USERS START NOW!"
echo ""

# TRIGGER ALL USERS AT ONCE
touch "${SYNC_FILE}.start"

# Monitor progress with detailed metrics
echo "📈 Monitoring parallel execution..."
START_TIME=$(date +%s)

# Progress monitoring
monitor_progress() {
    local last_count=0
    while true; do
        local current_count
        current_count=$(grep -c "USER_SUMMARY" "$RESULTS_FILE" 2>/dev/null || echo "0")
        local completed=$((current_count - last_count))
        
        if [ $completed -gt 0 ]; then
            echo "📊 Progress: $current_count/$CONCURRENT_USERS users completed (+$completed)"
            last_count=$current_count
        fi
        
        # Show real-time request metrics
        local total_requests
        total_requests=$(grep -c "SUCCESS\|FAILED\|TIMEOUT" "$RESULTS_FILE" 2>/dev/null || echo "0")
        local success_requests
        success_requests=$(grep -c "SUCCESS" "$RESULTS_FILE" 2>/dev/null || echo "0")
        
        if [ $total_requests -gt 0 ]; then
            local success_rate=$((success_requests * 100 / total_requests))
            echo "   Requests: $success_requests/$total_requests successful ($success_rate%)"
        fi
        
        if [ $current_count -eq $CONCURRENT_USERS ]; then
            break
        fi
        sleep 2
    done
}

# Start monitoring
monitor_progress &
MONITOR_PID=$!

# Wait for all processes
for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

# Kill monitor
kill $MONITOR_PID 2>/dev/null || true
wait $MONITOR_PID 2>/dev/null || true

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

echo ""
echo "================================
📊 PARALLEL LOAD TEST RESULTS
================================"

# Calculate detailed statistics
TOTAL_REQUESTS=$(grep -c "SUCCESS\|FAILED\|TIMEOUT" "$RESULTS_FILE" 2>/dev/null || echo "0")
SUCCESS_REQUESTS=$(grep -c "SUCCESS" "$RESULTS_FILE" 2>/dev/null || echo "0")
FAILED_REQUESTS=$(grep -c "FAILED" "$RESULTS_FILE" 2>/dev/null || echo "0")
TIMEOUT_REQUESTS=$(grep -c "TIMEOUT" "$RESULTS_FILE" 2>/dev/null || echo "0")

SUCCESS_RATE=0
if [ $TOTAL_REQUESTS -gt 0 ]; then
    SUCCESS_RATE=$((SUCCESS_REQUESTS * 100 / TOTAL_REQUESTS))
fi

# Calculate latency statistics
if [ -f "$LATENCY_FILE" ] && [ $(wc -l < "$LATENCY_FILE") -gt 0 ]; then
    LATENCY_DATA=$(sort -n "$LATENCY_FILE")
    LATENCY_COUNT=$(echo "$LATENCY_DATA" | wc -l)
    AVG_LATENCY=$(echo "$LATENCY_DATA" | awk '{sum+=$1} END {print int(sum/NR)}')
    P95_LATENCY=$(echo "$LATENCY_DATA" | awk 'BEGIN {c=0} {a[c]=$1; c++} END {print a[int(c*0.95)-1]}')
    P99_LATENCY=$(echo "$LATENCY_DATA" | awk 'BEGIN {c=0} {a[c]=$1; c++} END {print a[int(c*0.99)-1]}')
    MAX_LATENCY=$(echo "$LATENCY_DATA" | tail -1)
else
    AVG_LATENCY=0
    P95_LATENCY=0
    P99_LATENCY=0
    MAX_LATENCY=0
    LATENCY_COUNT=0
fi

echo ""
echo "⏱️  TIMING METRICS:"
echo "   Total test time: ${TOTAL_TIME}s"
echo "   Concurrent users: $CONCURRENT_USERS"
echo "   Total write attempts: $TOTAL_REQUESTS"
echo ""

echo "📈 REQUEST METRICS:"
echo "   Successful writes: $SUCCESS_REQUESTS"
echo "   Failed writes: $FAILED_REQUESTS"
echo "   Timeout writes: $TIMEOUT_REQUESTS"
echo "   Success rate: $SUCCESS_RATE%"
echo ""

echo "⚡ LATENCY METRICS:"
echo "   Average latency: ${AVG_LATENCY}ms"
echo "   95th percentile: ${P95_LATENCY}ms"
echo "   99th percentile: ${P99_LATENCY}ms"
echo "   Maximum latency: ${MAX_LATENCY}ms"
echo "   Samples measured: $LATENCY_COUNT"
echo ""

# Get final metrics
echo "📊 Collecting final system metrics..."
FINAL_STATS=$(curl -s "$TARGET/stats" || echo '{"stats":{"message_count":0}}')
FINAL_MESSAGES=$(echo "$FINAL_STATS" | grep -o '"message_count":[0-9]*' | cut -d: -f2 | head -1 || echo "0")

MESSAGES_ADDED=$((FINAL_MESSAGES - BASELINE_MESSAGES))

echo "💾 DATABASE METRICS:"
echo "   Final messages in DB: $FINAL_MESSAGES"
echo "   Messages added: $MESSAGES_ADDED"
echo "   Expected messages: $TOTAL_EXPECTED_WRITES"

# Calculate throughput
WRITES_PER_SECOND=0
MESSAGES_PER_SECOND=0
if [ $TOTAL_TIME -gt 0 ]; then
    WRITES_PER_SECOND=$(echo "scale=2; $SUCCESS_REQUESTS / $TOTAL_TIME" | bc -l 2>/dev/null || echo "0")
    MESSAGES_PER_SECOND=$(echo "scale=2; $MESSAGES_ADDED / $TOTAL_TIME" | bc -l 2>/dev/null || echo "0")
    echo "   Write throughput: $WRITES_PER_SECOND requests/second"
    echo "   Message throughput: $MESSAGES_PER_SECOND messages/second"
fi

# Show some individual user results
echo ""
echo "👥 SAMPLE USER RESULTS:"
grep "USER_SUMMARY" "$RESULTS_FILE" | head -5

# System health check
echo ""
echo "🔍 POST-TEST HEALTH CHECK:"
HEALTH_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET/health" 2>/dev/null || echo "000")
if [ "$HEALTH_RESPONSE" -eq 200 ]; then
    echo "✅ Service health: GOOD"
else
    echo "❌ Service health: DEGRADED (HTTP $HEALTH_RESPONSE)"
fi

READ_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET/bulk/read?limit=5" 2>/dev/null || echo "000")
if [ "$READ_RESPONSE" -eq 200 ]; then
    echo "✅ Read functionality: WORKING"
else
    echo "❌ Read functionality: BROKEN"
fi

echo ""
echo "================================
🎯 TEST COMPLETE
================================"

# Save detailed results
echo ""
echo "💾 Detailed results saved to:"
echo "   User summaries: $RESULTS_FILE"
echo "   Latency data: $LATENCY_FILE"

# Show performance summary
echo ""
echo "📋 PERFORMANCE SUMMARY:"
echo "   Parallel Users: $CONCURRENT_USERS"
echo "   Success Rate: $SUCCESS_RATE%"
echo "   Avg Latency: ${AVG_LATENCY}ms"
echo "   Throughput: ${WRITES_PER_SECOND} writes/sec"
echo "   Total Messages: $MESSAGES_ADDED"