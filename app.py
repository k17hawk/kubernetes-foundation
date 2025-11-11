from flask import Flask, request
import mysql.connector
import os
import sys

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


def get_db_connection(use_primary=False):
    """Create and return MySQL connection"""
    config = MYSQL_PRIMARY_CONFIG if use_primary else MYSQL_REPLICA_CONFIG
    connection_type = "PRIMARY" if use_primary else "REPLICA"

    try:
        print(f"Attempting MySQL {connection_type} connection to {config['host']}", file=sys.stderr)
        connection = mysql.connector.connect(**config)
        print(f"✅ MySQL {connection_type} connection established", file=sys.stderr)
        return connection
    except mysql.connector.Error as err:
        print(f"❌ MySQL {connection_type} connection error: {err}", file=sys.stderr)
        if not use_primary:
            print("🔄 Falling back to PRIMARY connection", file=sys.stderr)
            return get_db_connection(use_primary=True)
        return None
    except Exception as e:
        print(f"❌ Unexpected error: {e}", file=sys.stderr)
        return None


@app.route('/')
def hello_world():
    print("GET / request received - using READ replica", file=sys.stderr)
    connection = get_db_connection(use_primary=False)
    if connection:
        try:
            cursor = connection.cursor()
            cursor.execute("SELECT id, message, created_at FROM messages ORDER BY id DESC")
            results = cursor.fetchall()
            cursor.close()
            connection.close()

            if results:
                html = "<h1>All Messages (Read from Replica)</h1><ul>"
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
            cursor.execute("SELECT id, message, created_at FROM messages ORDER BY id DESC")
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


if __name__ == '__main__':
    debug_mode = os.getenv('FLASK_ENV') == 'development'
    print("Primary Config:", MYSQL_PRIMARY_CONFIG, file=sys.stderr)
    print("Replica Config:", MYSQL_REPLICA_CONFIG, file=sys.stderr)
    app.run(host='0.0.0.0', port=5000, debug=debug_mode)
