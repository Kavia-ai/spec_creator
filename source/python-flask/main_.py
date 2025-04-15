from flask import Flask, request, jsonify
from flask_cors import CORS
import os
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

# Initialize Flask app
app = Flask(__name__)
CORS(app, resources={r"/api/*": {"origins": ["http://localhost:8085"]}})  # Enable CORS for specific origin

# Sample in-memory database
users = []
user_id_counter = 1

# Root endpoint
@app.route('/')
def home():
    return jsonify({"message": "Welcome to the Flask API"})

# Get all users
@app.route('/api/users', methods=['GET'])
def get_users():
    return jsonify(users), 200

# Get a specific user
@app.route('/api/users/<int:user_id>', methods=['GET'])
def get_user(user_id):
    user = next((user for user in users if user['id'] == user_id), None)
    if user:
        return jsonify(user), 200
    return jsonify({"error": "User not found"}), 404

# Create a new user
@app.route('/api/users', methods=['POST'])
def create_user():
    global user_id_counter
    data = request.get_json()
    
    if not data or 'name' not in data or 'email' not in data:
        return jsonify({"error": "Name and email are required"}), 400
    
    new_user = {
        "id": user_id_counter,
        "name": data['name'],
        "email": data['email']
    }
    
    users.append(new_user)
    user_id_counter += 1
    
    return jsonify(new_user), 201

# Update a user
@app.route('/api/users/<int:user_id>', methods=['PUT'])
def update_user(user_id):
    user = next((user for user in users if user['id'] == user_id), None)
    if not user:
        return jsonify({"error": "User not found"}), 404
    
    data = request.get_json()
    if 'name' in data:
        user['name'] = data['name']
    if 'email' in data:
        user['email'] = data['email']
    
    return jsonify(user), 200

# Delete a user
@app.route('/api/users/<int:user_id>', methods=['DELETE'])
def delete_user(user_id):
    global users
    user = next((user for user in users if user['id'] == user_id), None)
    if not user:
        return jsonify({"error": "User not found"}), 404
    
    users = [user for user in users if user['id'] != user_id]
    return jsonify({"message": "User deleted successfully"}), 200

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 5000))
    app.run(debug=True, host='0.0.0.0', port=port)
