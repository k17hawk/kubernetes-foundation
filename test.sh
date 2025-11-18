#!/bin/bash
set -e

echo "=== Flask MySQL Replication Test ==="

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check dependencies
if ! command_exists jq; then
    echo "❌ Error: 'jq' is required but not installed. Install with: sudo apt-get install jq"
    exit 1
fi

if ! command_exists minikube; then
    echo "❌ Error: 'minikube' is required but not installed or not in PATH"
    exit 1
fi

# Get app URL with error handling
echo "🔧 Getting service URL..."
APP_URL=$(minikube service flask-service -n flask-mysql --url 2>/dev/null || echo "")
if [ -z "$APP_URL" ]; then
    echo "❌ Error: Could not get service URL. Check if minikube and service are running."
    echo "   Try: minikube status && kubectl get svc -n flask-mysql"
    exit 1
fi

echo "Testing app at: $APP_URL"

# Function to make HTTP requests with error handling
http_request() {
    local url=$1
    local method=${2:-GET}
    local data=${3:-}
    local timeout=30
    
    if [ -z "$data" ]; then
        curl -s --max-time $timeout -X "$method" "$url"
    else
        curl -s --max-time $timeout -X "$method" "$url" \
            -H "Content-Type: application/json" \
            -d "$data"
    fi
    
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "❌ HTTP request failed with exit code: $exit_code"
        return $exit_code
    fi
    return 0
}

# Function to test endpoint and handle errors
test_endpoint() {
    local name=$1
    local url=$2
    local method=${3:-GET}
    local data=${4:-}
    
    echo -e "\n$name..."
    if [ -n "$data" ]; then
        response=$(http_request "$url" "$method" "$data")
    else
        response=$(http_request "$url" "$method")
    fi
    
    if [ $? -eq 0 ] && [ -n "$response" ]; then
        echo "$response" | jq . 2>/dev/null || echo "$response"
        echo "✅ $name - SUCCESS"
    else
        echo "❌ $name - FAILED"
        return 1
    fi
}

# Wait for service to be ready
echo "⏳ Waiting for service to be ready..."
for i in {1..30}; do
    if http_request "$APP_URL/health" > /dev/null 2>&1; then
        echo "✅ Service is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "❌ Service not ready after 30 attempts. Exiting."
        exit 1
    fi
    sleep 2
done

# Run tests
echo -e "\n🧪 Starting tests..."

test_endpoint "1. Testing health" "$APP_URL/health"

test_endpoint "2. Testing basic write" "$APP_URL/add/Initial%20test%20message"

test_endpoint "3. Testing bulk write (50 messages)" "$APP_URL/bulk/write" "POST" '{"count": 50, "message_length": 20}'

echo -e "\n4. Waiting 2 seconds for replication..."
sleep 2

test_endpoint "5. Testing bulk read from replica" "$APP_URL/bulk/read?limit=50"

test_endpoint "6. Testing JSON endpoint" "$APP_URL/json"

test_endpoint "7. Testing stats" "$APP_URL/stats"

test_endpoint "8. Running performance test" "$APP_URL/performance/test" "POST" '{
    "write_count": 100,
    "read_limit": 200,
    "concurrent_operations": 2
}'

echo -e "\n=== ✅ All Tests Complete ==="