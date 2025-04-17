#!/usr/bin/env python3
"""
Non-invasive OpenAPI specification generator for Flask applications.
This script inspects a Flask application through static analysis without executing its code.

Usage: python openapi_spec_creator.py -e <flask_app_file> -o <output_file>

Note: This generator sets the base path to '/proxy' for all endpoints.
"""
import sys
import os
import re
import json
import ast
import argparse
from apispec import APISpec
from apispec.ext.marshmallow import MarshmallowPlugin

class FlaskRouteVisitor(ast.NodeVisitor):
    """AST visitor to extract Flask routes without executing the code."""
    def __init__(self):
        self.routes = []
        self.app_name = None
        self.current_app_var = None
        self.possible_app_vars = set()
        
    def visit_Assign(self, node):
        # Detect Flask app instantiation: app = Flask(__name__)
        if isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Name) and node.value.func.id == 'Flask':
            for target in node.targets:
                if isinstance(target, ast.Name):
                    self.possible_app_vars.add(target.id)
                    # Use the first Flask instance as the app name if not already set
                    if not self.app_name:
                        self.app_name = target.id
        # Continue visiting
        self.generic_visit(node)
        
    def visit_Call(self, node):
        # Find route decorators: @app.route('/path', methods=['GET'])
        if isinstance(node.func, ast.Attribute) and node.func.attr == 'route':
            if isinstance(node.func.value, ast.Name) and node.func.value.id in self.possible_app_vars:
                self.current_app_var = node.func.value.id
                self._process_route_decorator(node)
        # Also check for @app.get('/path'), @app.post('/path') etc.
        elif isinstance(node.func, ast.Attribute) and node.func.attr in ['get', 'post', 'put', 'delete', 'patch']:
            if isinstance(node.func.value, ast.Name) and node.func.value.id in self.possible_app_vars:
                self.current_app_var = node.func.value.id
                self._process_http_method_decorator(node)
        # Continue visiting
        self.generic_visit(node)
    
    def _process_route_decorator(self, node):
        path = None
        methods = ['get']  # Default to GET if not specified
        endpoint = None
        
        # Extract path from first argument
        if node.args:
            path = self._extract_string_value(node.args[0])
        
        # Extract methods from keyword arguments
        for keyword in node.keywords:
            if keyword.arg == 'methods':
                methods = self._extract_list_of_strings(keyword.value)
            elif keyword.arg == 'endpoint':
                endpoint = self._extract_string_value(keyword.value)
        
        if path:
            self._add_route(path, methods, endpoint)
    
    def _process_http_method_decorator(self, node):
        path = None
        method = node.func.attr.lower()  # get, post, etc.
        endpoint = None
        
        # Extract path from first argument
        if node.args:
            path = self._extract_string_value(node.args[0])
        
        # Extract endpoint from keyword arguments
        for keyword in node.keywords:
            if keyword.arg == 'endpoint':
                endpoint = self._extract_string_value(keyword.value)
        
        if path:
            self._add_route(path, [method], endpoint)
    
    def _extract_string_value(self, node):
        if isinstance(node, ast.Str):
            return node.s
        return None
    
    def _extract_list_of_strings(self, node):
        if isinstance(node, ast.List):
            methods = []
            for elt in node.elts:
                if isinstance(elt, ast.Str):
                    methods.append(elt.s.lower())
            return methods
        return ['get']  # Default to GET if not a list
    
    def _add_route(self, path, methods, endpoint=None):
        # Generate an endpoint name if not specified
        if not endpoint:
            endpoint = f"endpoint_{len(self.routes)}"
        
        # Extract path parameters
        path_params = []
        path_param_matches = re.finditer(r'<(?:(?:int|float|string|path|uuid):)?([^>]+)>', path)
        for match in path_param_matches:
            param_name = match.group(1)
            path_params.append({
                "name": param_name,
                "in": "path",
                "required": True,
                "schema": {"type": "string"}
            })
        
        # Convert Flask-style route to OpenAPI path format
        openapi_path = re.sub(r'<(?:int|float|string|path|uuid):([^>]+)>', r'{\1}', path)
        openapi_path = re.sub(r'<([^>]+)>', r'{\1}', openapi_path)
        
        # Add route for each method
        for method in methods:
            self.routes.append({
                "path": openapi_path,
                "method": method,
                "operation_id": endpoint,
                "description": f"Endpoint for {method.upper()} {path}",
                "parameters": path_params,
            })

def extract_routes_from_file(file_path):
    """Extract Flask routes from a Python file without executing it."""
    try:
        with open(file_path, 'r') as f:
            source_code = f.read()
        
        tree = ast.parse(source_code)
        visitor = FlaskRouteVisitor()
        visitor.visit(tree)
        
        app_name = visitor.app_name or "FlaskApp"
        return app_name, visitor.routes
    
    except Exception as e:
        print(f"Error analyzing Flask app: {e}")
        sys.exit(1)

def generate_openapi_spec(app_name, routes):
    """Generate OpenAPI specification from analyzed routes."""
    # Create an APISpec
    spec = APISpec(
        title=app_name,
        version="1.0.0",
        openapi_version="3.0.2",
        plugins=[MarshmallowPlugin()],
    )
    
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
        
        # Add the path to the spec
        spec.path(
            path=route["path"],
            operations={route["method"]: operation}
        )
    
    # Get the finished spec
    spec_dict = spec.to_dict()
    
    # Add base path as /proxy
    spec_dict["servers"] = [
        {
            "url": "/proxy/flask",
            "description": "API with base path"
        }
    ]
    
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
    
    # Extract routes using static analysis
    app_name, routes = extract_routes_from_file(args.endpoint)
    
    # Generate the OpenAPI spec
    spec = generate_openapi_spec(app_name, routes)
    
    # Write to output file
    with open(args.output, "w") as f:
        json.dump(spec, f, indent=2)
    
    print(f"✅ Successfully generated OpenAPI specification at {args.output}")
    print(f"Found {len(routes)} routes in the Flask application")

if __name__ == "__main__":
    main()