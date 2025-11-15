#!/bin/bash
set -e

echo "=== Flask MySQL Replication Test ==="
APP_URL=$(minikube service flask-service -n flask-mysql --url)
echo "Testing app at: $APP_URL"

echo -e "\n1. Testing health..."
curl -s $APP_URL/health | jq .

echo -e "\n2. Testing basic write..."
curl -s "$APP_URL/add/Initial%20test%20message"

echo -e "\n3. Testing bulk write (50 messages)..."
curl -s -X POST $APP_URL/bulk/write \
  -H "Content-Type: application/json" \
  -d '{"count": 50, "message_length": 20}' | jq .

echo -e "\n4. Waiting 2 seconds for replication..."
sleep 2

echo -e "\n5. Testing bulk read from replica..."
curl -s "$APP_URL/bulk/read?limit=50" | jq .

echo -e "\n6. Testing JSON endpoint..."
curl -s $APP_URL/json | jq .

echo -e "\n7. Testing stats..."
curl -s $APP_URL/stats | jq .

echo -e "\n8. Running performance test..."
curl -s -X POST $APP_URL/performance/test \
  -H "Content-Type: application/json" \
  -d '{
    "write_count": 100,
    "read_limit": 200,
    "concurrent_operations": 2
  }' | jq .

echo -e "\n=== Test Complete ==="