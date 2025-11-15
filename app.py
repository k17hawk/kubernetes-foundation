from flask import Flask, request, jsonify
import mysql.connector
import os
import sys
import time
import random
import string
from datetime import datetime

from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
import time

app = Flask(__name__)



# --- Logging startup info ---
print("=== Flask App Starting ===", file=sys.stderr)
print(f"Python version: {sys.version}", file=sys.stderr)

# Prefer Kubernetes variables but allow fallback
MYSQL_PRIMARY_HOST = os.getenv('MYSQL_PRIMARY_HOST') or os.getenv('MYSQL_HOST', 'mysql-primary.flask-mysql.svc.cluster.local')
MYSQL_REPLICA_HOST = os.getenv('MYSQL_REPLICA_HOST', 'mysql-replica.flask-mysql.svc.cluster.local')

print(f"MySQL Primary Host: {MYSQL_PRIMARY_HOST}", file=sys.stderr)
print(f"MySQL Replica Host: {MYSQL_REPLICA_HOST}", file=sys.stderr)

# --- Database configurations ---
MYSQL_PRIMARY_CONFIG = {
    'host': MYSQL_PRIMARY_HOST,
    'user': os.getenv('MYSQL_USER', 'flaskapp'),
    'password': os.getenv('MYSQL_PASSWORD', 'flask123'),
    'database': os.getenv('MYSQL_DATABASE', 'testdb'),
    'port': int(os.getenv('MYSQL_PORT', '3306'))
}

MYSQL_REPLICA_CONFIG = {
    'host': MYSQL_REPLICA_HOST,
    'user': os.getenv('MYSQL_USER', 'flaskapp'),
    'password': os.getenv('MYSQL_PASSWORD', 'flask123'),
    'database': os.getenv('MYSQL_DATABASE', 'testdb'),
    'port': int(os.getenv('MYSQL_PORT', '3306'))
}


# Add these metrics at the top of your app.py (after imports)
REQUEST_COUNT = Counter('flask_http_requests_total', 'Total HTTP Requests', ['method', 'endpoint', 'status'])
REQUEST_LATENCY = Histogram('flask_http_request_duration_seconds', 'HTTP request latency', ['method', 'endpoint'])
DB_CONNECTION_COUNT = Counter('flask_db_connections_total', 'Total DB connections', ['db_type', 'status'])
DB_QUERY_COUNT = Counter('flask_db_queries_total', 'Total DB queries', ['operation'])


@app.before_request
def before_request():
    request.start_time = time.time()

@app.after_request
def after_request(response):
    # Calculate request latency
    latency = time.time() - request.start_time
    REQUEST_LATENCY.labels(request.method, request.path).observe(latency)
    
    # Count requests
    REQUEST_COUNT.labels(request.method, request.path, response.status_code).inc()
    
    return response

# Add a metrics endpoint
@app.route('/metrics')
def metrics():
    return generate_latest(), 200, {'Content-Type': CONTENT_TYPE_LATEST}


def get_db_connection(use_primary=False):
    """Create and return MySQL connection with metrics"""
    config = MYSQL_PRIMARY_CONFIG if use_primary else MYSQL_REPLICA_CONFIG
    connection_type = "primary" if use_primary else "replica"

    try:
        print(f"Attempting MySQL {connection_type} connection to {config['host']}", file=sys.stderr)
        connection = mysql.connector.connect(**config)
        DB_CONNECTION_COUNT.labels(db_type=connection_type, status='success').inc()
        print(f"✅ MySQL {connection_type} connection established", file=sys.stderr)
        return connection
    except mysql.connector.Error as err:
        DB_CONNECTION_COUNT.labels(db_type=connection_type, status='error').inc()
        print(f"❌ MySQL {connection_type} connection error: {err}", file=sys.stderr)
        if not use_primary:
            print("🔄 Falling back to PRIMARY connection", file=sys.stderr)
            return get_db_connection(use_primary=True)
        return None
    except Exception as e:
        DB_CONNECTION_COUNT.labels(db_type=connection_type, status='error').inc()
        print(f"❌ Unexpected error: {e}", file=sys.stderr)
        return None


def generate_random_message(length=20):
    """Generate random message for testing"""
    return ''.join(random.choices(string.ascii_letters + string.digits, k=length))


@app.route('/')
def hello_world():
    print("GET / request received - using READ replica", file=sys.stderr)
    connection = get_db_connection(use_primary=False)
    if connection:
        try:
            cursor = connection.cursor()
            cursor.execute("SELECT id, message, created_at FROM messages ORDER BY id DESC LIMIT 50")
            results = cursor.fetchall()
            cursor.close()
            connection.close()

            if results:
                html = "<h1>All Messages (Read from Replica)</h1>"
                html += f"<p>Total messages displayed: {len(results)}</p><ul>"
                for row in results:
                    html += f"<li>ID: {row[0]} - {row[1]} (Created: {row[2]})</li>"
                html += "</ul>"
                return html
            return 'No messages found in database'
        except mysql.connector.Error as err:
            return f'Error reading from database: {err}'
    return 'Cannot connect to MySQL database'


@app.route('/json')
def hello_json():
    print("GET /json request received - using READ replica", file=sys.stderr)
    connection = get_db_connection(use_primary=False)
    if connection:
        try:
            cursor = connection.cursor()
            cursor.execute("SELECT id, message, created_at FROM messages ORDER BY id DESC LIMIT 100")
            results = cursor.fetchall()
            cursor.close()
            connection.close()

            messages = [
                {'id': row[0], 'message': row[1], 'created_at': str(row[2]) if row[2] else None}
                for row in results
            ]
            return {'messages': messages, 'count': len(messages), 'read_from': 'replica'}
        except mysql.connector.Error as err:
            return {'error': f'Error reading from database: {err}'}
    return {'error': 'Cannot connect to MySQL database'}


@app.route('/health')
def health_check():
    print("GET /health request received - checking both databases", file=sys.stderr)

    primary_conn = get_db_connection(use_primary=True)
    primary_status = 'connected' if primary_conn else 'disconnected'
    if primary_conn:
        primary_conn.close()

    replica_conn = get_db_connection(use_primary=False)
    replica_status = 'connected' if replica_conn else 'disconnected'
    if replica_conn:
        replica_conn.close()

    overall_status = 'healthy' if primary_status == 'connected' else 'unhealthy'

    return {
        'status': overall_status,
        'databases': {
            'primary': primary_status,
            'replica': replica_status
        }
    }


@app.route('/add/<message>')
def add_message(message):
    print("POST /add request received - using WRITE primary", file=sys.stderr)
    connection = get_db_connection(use_primary=True)
    if connection:
        try:
            cursor = connection.cursor()
            DB_QUERY_COUNT.labels(operation='insert').inc()
            cursor.execute("INSERT INTO messages (message) VALUES (%s)", (message,))
            connection.commit()
            cursor.close()
            connection.close()
            return f'Added message: {message} (written to primary)'
        except mysql.connector.Error as err:
            return f'Error inserting into database: {err}'
    return 'Cannot connect to MySQL database'


@app.route('/clear')
def clear_messages():
    print("POST /clear request received - using WRITE primary", file=sys.stderr)
    connection = get_db_connection(use_primary=True)
    if connection:
        try:
            cursor = connection.cursor()
            cursor.execute("DELETE FROM messages")
            connection.commit()
            count = cursor.rowcount
            cursor.close()
            connection.close()
            return f'Cleared {count} messages from database (written to primary)'
        except mysql.connector.Error as err:
            return f'Error clearing database: {err}'
    return 'Cannot connect to MySQL database'


@app.route('/stats')
def get_stats():
    stats = {}
    replica_conn = get_db_connection(use_primary=False)
    if replica_conn:
        try:
            cursor = replica_conn.cursor()
            cursor.execute("SELECT COUNT(*) as count FROM messages")
            stats['message_count'] = cursor.fetchone()[0]
            stats['read_from'] = 'replica'
            cursor.close()
        except mysql.connector.Error as err:
            stats['read_error'] = str(err)
        finally:
            replica_conn.close()
    return {'stats': stats}


# === NEW BULK OPERATIONS ===

@app.route('/bulk/write', methods=['POST'])
def bulk_write():
    """Bulk write messages to test write performance"""
    data = request.get_json()
    count = data.get('count', 100)
    message_length = data.get('message_length', 20)
    
    print(f"BULK WRITE: Writing {count} messages", file=sys.stderr)
    
    connection = get_db_connection(use_primary=True)
    if not connection:
        return {'error': 'Cannot connect to MySQL database'}, 500
    
    try:
        cursor = connection.cursor()
        start_time = time.time()
        
        # Generate and insert messages in batches for better performance
        batch_size = 100
        total_inserted = 0
        
        for i in range(0, count, batch_size):
            current_batch_size = min(batch_size, count - i)
            messages = []
            
            for j in range(current_batch_size):
                message = generate_random_message(message_length)
                messages.append((message,))
            
            # Use executemany for batch insert
            cursor.executemany(
                "INSERT INTO messages (message) VALUES (%s)",
                messages
            )
            total_inserted += cursor.rowcount
        
        connection.commit()
        end_time = time.time()
        
        cursor.close()
        connection.close()
        
        return {
            'operation': 'bulk_write',
            'messages_inserted': total_inserted,
            'batch_size': batch_size,
            'total_time_seconds': round(end_time - start_time, 2),
            'messages_per_second': round(total_inserted / (end_time - start_time), 2),
            'written_to': 'primary'
        }
        
    except mysql.connector.Error as err:
        return {'error': f'Error during bulk write: {err}'}, 500


@app.route('/bulk/read', methods=['GET'])
def bulk_read():
    """Bulk read messages to test read performance"""
    limit = request.args.get('limit', 1000, type=int)
    use_primary = request.args.get('use_primary', 'false').lower() == 'true'
    
    connection_type = "PRIMARY" if use_primary else "REPLICA"
    print(f"BULK READ: Reading {limit} messages from {connection_type}", file=sys.stderr)
    
    connection = get_db_connection(use_primary=use_primary)
    if not connection:
        return {'error': 'Cannot connect to MySQL database'}, 500
    
    try:
        cursor = connection.cursor()
        start_time = time.time()
        
        # Perform multiple reads to simulate heavy read load
        read_iterations = 5
        total_rows = 0
        
        for i in range(read_iterations):
            cursor.execute(f"""
                SELECT id, message, created_at 
                FROM messages 
                ORDER BY id DESC 
                LIMIT {limit}
            """)
            results = cursor.fetchall()
            total_rows += len(results)
        
        end_time = time.time()
        cursor.close()
        connection.close()
        
        return {
            'operation': 'bulk_read',
            'limit_per_query': limit,
            'read_iterations': read_iterations,
            'total_rows_read': total_rows,
            'total_time_seconds': round(end_time - start_time, 2),
            'reads_per_second': round(total_rows / (end_time - start_time), 2),
            'read_from': 'primary' if use_primary else 'replica'
        }
        
    except mysql.connector.Error as err:
        return {'error': f'Error during bulk read: {err}'}, 500


@app.route('/stress/write', methods=['POST'])
def stress_write():
    """Stress test write operations with concurrent connections"""
    data = request.get_json()
    concurrent_writes = data.get('concurrent_writes', 5)
    messages_per_write = data.get('messages_per_write', 100)
    
    print(f"STRESS WRITE: {concurrent_writes} concurrent writes, {messages_per_write} messages each", file=sys.stderr)
    
    results = []
    start_time = time.time()
    
    # Simulate concurrent writes (in reality, this would be parallel requests)
    for i in range(concurrent_writes):
        connection = get_db_connection(use_primary=True)
        if connection:
            try:
                cursor = connection.cursor()
                messages = [(generate_random_message(20),) for _ in range(messages_per_write)]
                
                cursor.executemany(
                    "INSERT INTO messages (message) VALUES (%s)",
                    messages
                )
                connection.commit()
                cursor.close()
                connection.close()
                
                results.append({
                    'batch': i + 1,
                    'messages_written': messages_per_write,
                    'status': 'success'
                })
            except mysql.connector.Error as err:
                results.append({
                    'batch': i + 1,
                    'status': 'error',
                    'error': str(err)
                })
    
    end_time = time.time()
    
    successful_writes = len([r for r in results if r['status'] == 'success'])
    total_messages = successful_writes * messages_per_write
    
    return {
        'operation': 'stress_write',
        'concurrent_writes': concurrent_writes,
        'messages_per_write': messages_per_write,
        'successful_batches': successful_writes,
        'total_messages_written': total_messages,
        'total_time_seconds': round(end_time - start_time, 2),
        'messages_per_second': round(total_messages / (end_time - start_time), 2),
        'batch_results': results
    }


@app.route('/stress/read', methods=['GET'])
def stress_read():
    """Stress test read operations"""
    concurrent_reads = request.args.get('concurrent_reads', 10, type=int)
    read_limit = request.args.get('read_limit', 100, type=int)
    use_primary = request.args.get('use_primary', 'false').lower() == 'true'
    
    print(f"STRESS READ: {concurrent_reads} concurrent reads from {'PRIMARY' if use_primary else 'REPLICA'}", file=sys.stderr)
    
    results = []
    start_time = time.time()
    
    # Simulate concurrent reads
    for i in range(concurrent_reads):
        connection = get_db_connection(use_primary=use_primary)
        if connection:
            try:
                cursor = connection.cursor()
                cursor.execute(f"""
                    SELECT id, message, created_at 
                    FROM messages 
                    ORDER BY id DESC 
                    LIMIT {read_limit}
                """)
                results_data = cursor.fetchall()
                cursor.close()
                connection.close()
                
                results.append({
                    'read_operation': i + 1,
                    'rows_returned': len(results_data),
                    'status': 'success'
                })
            except mysql.connector.Error as err:
                results.append({
                    'read_operation': i + 1,
                    'status': 'error',
                    'error': str(err)
                })
    
    end_time = time.time()
    
    successful_reads = len([r for r in results if r['status'] == 'success'])
    total_rows = sum([r['rows_returned'] for r in results if r['status'] == 'success'])
    
    return {
        'operation': 'stress_read',
        'concurrent_reads': concurrent_reads,
        'read_limit_per_query': read_limit,
        'successful_reads': successful_reads,
        'total_rows_read': total_rows,
        'total_time_seconds': round(end_time - start_time, 2),
        'reads_per_second': round(total_rows / (end_time - start_time), 2),
        'read_from': 'primary' if use_primary else 'replica',
        'read_results': results
    }


@app.route('/performance/test', methods=['POST'])
def performance_test():
    """Comprehensive performance test with both read and write operations"""
    data = request.get_json()
    write_count = data.get('write_count', 500)
    read_limit = data.get('read_limit', 1000)
    concurrent_operations = data.get('concurrent_operations', 3)
    
    print(f"PERFORMANCE TEST: {write_count} writes, {read_limit} reads, {concurrent_operations} concurrent", file=sys.stderr)
    
    performance_results = {}
    
    # Test bulk write
    write_start = time.time()
    write_response = bulk_write()
    write_end = time.time()
    
    # Wait a moment for replication
    time.sleep(2)
    
    # Test bulk read from replica
    read_start = time.time()
    read_response = bulk_read()
    read_end = time.time()
    
    # Test stress operations
    stress_write_response = stress_write()
    stress_read_response = stress_read()
    
    performance_results = {
        'test_summary': {
            'write_operations': write_count,
            'read_operations': read_limit,
            'concurrent_operations': concurrent_operations,
            'total_test_time': round(read_end - write_start, 2)
        },
        'bulk_write': write_response,
        'bulk_read': read_response,
        'stress_write': stress_write_response,
        'stress_read': stress_read_response,
        'timing': {
            'write_duration': round(write_end - write_start, 2),
            'read_duration': round(read_end - read_start, 2),
            'replication_lag_estimate': '2 seconds (fixed wait)'
        }
    }
    
    return performance_results


@app.route('/test/endpoints')
def test_endpoints():
    """List all available test endpoints"""
    endpoints = {
        'basic_operations': {
            'GET /': 'Display recent messages (reads from replica)',
            'GET /json': 'JSON API for messages (reads from replica)',
            'GET /health': 'Health check for both databases',
            'GET /add/<message>': 'Add single message (writes to primary)',
            'GET /clear': 'Clear all messages (writes to primary)',
            'GET /stats': 'Get message statistics (reads from replica)'
        },
        'bulk_operations': {
            'POST /bulk/write': 'Bulk write messages',
            'GET /bulk/read': 'Bulk read messages',
            'POST /stress/write': 'Stress test write operations',
            'GET /stress/read': 'Stress test read operations',
            'POST /performance/test': 'Comprehensive performance test'
        },
        'bulk_write_example': {
            'method': 'POST',
            'url': '/bulk/write',
            'body': {'count': 1000, 'message_length': 20}
        },
        'bulk_read_example': {
            'method': 'GET', 
            'url': '/bulk/read?limit=1000&use_primary=false'
        }
    }
    return jsonify(endpoints)


if __name__ == '__main__':
    debug_mode = os.getenv('FLASK_ENV') == 'development'
    print("Primary Config:", MYSQL_PRIMARY_CONFIG, file=sys.stderr)
    print("Replica Config:", MYSQL_REPLICA_CONFIG, file=sys.stderr)
    app.run(host='0.0.0.0', port=5000, debug=debug_mode)