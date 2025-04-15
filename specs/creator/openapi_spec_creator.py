#!/usr/bin/env python3
"""
Non-invasive OpenAPI specification generator for Flask applications.
This script inspects a Flask application without modifying its code.

Usage: python openapi_spec_creator.py -e <flask_app_file> -o <output_file>
"""
import sys
import os
import importlib.util
import inspect
import json
import re
import argparse
from apispec import APISpec
from apispec.ext.marshmallow import MarshmallowPlugin

def load_flask_app(file_path):
    """Load a Flask application from a file without modifying it."""
    try:
        # Get absolute path
        abs_path = os.path.abspath(file_path)
        
        # Extract filename and directory
        directory, filename = os.path.split(abs_path)
        module_name = os.path.splitext(filename)[0]
        
        # Add the directory to sys.path temporarily
        original_sys_path = sys.path.copy()
        if directory:
            sys.path.insert(0, directory)
        
        # Import the module
        spec = importlib.util.spec_from_file_location(module_name, abs_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        
        # Find the Flask app instance
        app = None
        for name, obj in inspect.getmembers(module):
            if str(type(obj)).endswith("'flask.app.Flask'>"):
                app = obj
                break
        
        # Restore original sys.path
        sys.path = original_sys_path
        
        if app is None:
            raise ValueError(f"Could not find a Flask app instance in {file_path}")
        
        return app
    
    except Exception as e:
        print(f"Error loading Flask app: {e}")
        sys.exit(1)

def extract_route_info(app):
    """Extract information from the Flask routes."""
    routes = []
    
    for rule in app.url_map.iter_rules():
        # Skip the static endpoint and other non-API endpoints
        if rule.endpoint == 'static' or rule.endpoint.startswith('_'):
            continue
        
        # Get the view function
        view_func = app.view_functions.get(rule.endpoint)
        if not view_func:
            continue
        
        # Extract methods
        methods = [m.lower() for m in rule.methods if m not in ['HEAD', 'OPTIONS']]
        
        # Extract path parameters
        path_params = []
        for arg in rule.arguments:
            path_params.append({
                "name": arg,
                "in": "path",
                "required": True,
                "schema": {"type": "string"}
            })
        
        # Parse docstring for description and possibly more details
        description = view_func.__doc__.strip() if view_func.__doc__ else f"Endpoint {rule.endpoint}"
        
        # Convert Flask-style route to OpenAPI path format
        # Example: /users/<int:user_id> -> /users/{user_id}
        path = str(rule)
        path = re.sub(r'<(?:int|float|string|path|uuid):([^>]+)>', r'{\1}', path)
        path = re.sub(r'<([^>]+)>', r'{\1}', path)
        
        # Add route info
        for method in methods:
            routes.append({
                "path": path,
                "method": method,
                "operation_id": rule.endpoint,
                "description": description,
                "parameters": path_params,
            })
    
    return routes

def generate_openapi_spec(app):
    """Generate OpenAPI specification from a Flask app."""
    # Create an APISpec
    spec = APISpec(
        title=app.name,
        version="1.0.0",
        openapi_version="3.0.2",
        plugins=[MarshmallowPlugin()],
    )
    
    # Add server information
    spec_dict = spec.to_dict()
    spec_dict["servers"] = [{
        "url": "http://localhost:5000",
        "description": "Local development server"
    }]
    
    # Extract routes
    routes = extract_route_info(app)
    
    # Add paths to the spec
    for route in routes:
        operation = {
            "operationId": route["operation_id"],
            "description": route["description"],
            "responses": {
                "200": {
                    "description": "Successful response"
                }
            }
        }
        
        if route["parameters"]:
            operation["parameters"] = route["parameters"]
        
        spec.path(
            path=route["path"],
            operations={route["method"]: operation}
        )
    
    # Update the spec with server information
    spec_dict.update(spec.to_dict())
    return spec_dict

def parse_arguments():
    parser = argparse.ArgumentParser(description='Generate OpenAPI specification from Flask application')
    parser.add_argument('-e', '--endpoint', required=True, help='Path to Flask application file')
    parser.add_argument('-o', '--output', required=True, help='Output file path for OpenAPI specification')
    return parser.parse_args()

def main():
    args = parse_arguments()
    
    # Validate input file exists
    if not os.path.exists(args.endpoint):
        print(f"Error: Input file '{args.endpoint}' not found")
        sys.exit(1)
    
    # Create output directory if it doesn't exist
    output_dir = os.path.dirname(args.output)
    if output_dir and not os.path.exists(output_dir):
        os.makedirs(output_dir)
    
    app = load_flask_app(args.endpoint)
    
    # Generate the OpenAPI spec
    spec = generate_openapi_spec(app)
    
    # Write to output file
    with open(args.output, "w") as f:
        json.dump(spec, f, indent=2)
    
    print(f"✅ Successfully generated OpenAPI specification at {args.output}")

if __name__ == "__main__":
    main()