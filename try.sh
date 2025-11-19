# Add some messages
for i in {1..10}; do
  curl http://localhost:5000/add/test-message-$i
done

# Read messages
curl http://localhost:5000/
curl http://localhost:5000/json

# Bulk operations
curl -X POST http://localhost:5000/bulk/write \
  -H "Content-Type: application/json" \
  -d '{"count": 100, "message_length": 20}'

curl "http://localhost:5000/bulk/read?limit=100"

# Stress test
curl -X POST http://localhost:5000/stress/write \
  -H "Content-Type: application/json" \
  -d '{"concurrent_writes": 3, "messages_per_write": 50}'