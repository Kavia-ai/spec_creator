#!/usr/bin/env python3
"""
Non-invasive OpenAPI specification generator for Django applications.
This script inspects a Django application through static analysis without executing its code.

Usage: python django_creator.py -e <django_project_root> -o <output_file>

Note: This generator sets the base path to '/proxy/django' for all endpoints.
"""
import sys
import os
import re
import json
import ast
import argparse
import importlib.util
import traceback
from pathlib import Path
from apispec import APISpec
from apispec.ext.marshmallow import MarshmallowPlugin
from typing import List, Dict, Any, Optional, Set, Tuple

class DjangoURLPatternVisitor(ast.NodeVisitor):
    """AST visitor to extract Django URL patterns without executing the code."""
    def __init__(self):
        self.patterns = []
        self.imports = {}
        self.current_namespace = None
        self.include_patterns = []
        
    def visit_Import(self, node):
        """Process import statements."""
        for name in node.names:
            self.imports[name.name.split('.')[-1]] = name.name
        self.generic_visit(node)
        
    def visit_ImportFrom(self, node):
        """Process from ... import statements."""
        if node.module:
            for name in node.names:
                self.imports[name.name] = f"{node.module}.{name.name}"
        self.generic_visit(node)
        
    def visit_Assign(self, node):
        """Process variable assignments for urlpatterns."""
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == 'urlpatterns':
                if isinstance(node.value, ast.List):
                    for element in node.value.elts:
                        self._process_url_pattern(element)
        self.generic_visit(node)
        
    def _process_url_pattern(self, node):
        """Process a URL pattern from urlpatterns list."""
        if not isinstance(node, ast.Call):
            return
            
        # Handle path() or re_path() or url()
        if isinstance(node.func, ast.Name) and node.func.id in ('path', 're_path', 'url'):
            route_pattern = None
            view_func = None
            name = None
            
            # Get the path/route pattern
            if node.args and len(node.args) >= 1:
                if isinstance(node.args[0], ast.Str):
                    route_pattern = node.args[0].s
                    
            # Get the view function/class
            if len(node.args) >= 2:
                view_func = self._extract_view_func(node.args[1])
                
            # Look for name in keywords
            for keyword in node.keywords:
                if keyword.arg == 'name' and isinstance(keyword.value, ast.Str):
                    name = keyword.value.s
                    
            if route_pattern is not None and view_func is not None:
                self.patterns.append({
                    'path': route_pattern,
                    'view': view_func,
                    'name': name,
                    'namespace': self.current_namespace
                })
                
        # Handle include() for nested URLconf
        elif isinstance(node.func, ast.Name) and node.func.id == 'include':
            if node.args and len(node.args) >= 1:
                include_path = None
                namespace = None
                
                # Get the include path
                if isinstance(node.args[0], ast.Str):
                    include_path = node.args[0].s
                elif isinstance(node.args[0], ast.Tuple) and len(node.args[0].elts) >= 1:
                    if isinstance(node.args[0].elts[0], ast.Str):
                        include_path = node.args[0].elts[0].s
                        
                # Look for namespace in keywords
                for keyword in node.keywords:
                    if keyword.arg == 'namespace' and isinstance(keyword.value, ast.Str):
                        namespace = keyword.value.s
                        
                if include_path:
                    self.include_patterns.append({
                        'include': include_path,
                        'namespace': namespace
                    })
                    
    def _extract_view_func(self, node):
        """Extract view function or class from AST node."""
        if isinstance(node, ast.Name):
            return node.id
        elif isinstance(node, ast.Attribute):
            if isinstance(node.value, ast.Name):
                return f"{node.value.id}.{node.attr}"
        return None


class DjangoViewSetVisitor(ast.NodeVisitor):
    """AST visitor to extract ViewSet class information."""
    def __init__(self):
        self.viewsets = {}
        self.current_class = None
        self.base_classes = []
        
    def visit_ClassDef(self, node):
        """Process class definitions to find ViewSet classes."""
        # Save the current class name
        prev_class = self.current_class
        self.current_class = node.name
        
        # Check bases to see if it's a ViewSet
        is_viewset = False
        base_classes = []
        
        for base in node.bases:
            if isinstance(base, ast.Name):
                base_name = base.id
                base_classes.append(base_name)
                if base_name.endswith('ViewSet') or base_name.endswith('ModelViewSet'):
                    is_viewset = True
            elif isinstance(base, ast.Attribute) and isinstance(base.value, ast.Name):
                base_name = f"{base.value.id}.{base.attr}"
                base_classes.append(base_name)
                if base_name.endswith('ViewSet') or base_name.endswith('ModelViewSet'):
                    is_viewset = True
                    
        self.base_classes = base_classes
        
        # If it's a ViewSet, gather info about its methods
        if is_viewset:
            methods = {}
            for item in node.body:
                if isinstance(item, ast.FunctionDef):
                    method = item.name
                    doc = ast.get_docstring(item)
                    # Standard ViewSet methods
                    if method in ('list', 'create', 'retrieve', 'update', 'partial_update', 'destroy'):
                        http_method = self._get_http_method_for_action(method)
                        methods[method] = {
                            'http_method': http_method,
                            'description': doc or f"{method.capitalize()} method"
                        }
                    # Custom methods with action decorator
                    elif method not in ('__init__', 'get_queryset', 'get_serializer_class'):
                        action_info = self._extract_action_info(item)
                        if action_info:
                            methods[method] = action_info
                            methods[method]['description'] = doc or f"{method.capitalize()} method"
            
            # Get the queryset model and serializer if defined
            queryset_model = self._extract_queryset_model(node)
            serializer_class = self._extract_serializer_class(node)
            
            self.viewsets[node.name] = {
                'methods': methods,
                'base_classes': base_classes,
                'queryset_model': queryset_model,
                'serializer_class': serializer_class
            }
            
        # Visit child nodes
        self.generic_visit(node)
        
        # Restore previous class context
        self.current_class = prev_class
        
    def _get_http_method_for_action(self, action: str) -> str:
        """Map standard ViewSet action to HTTP method."""
        action_map = {
            'list': 'get',
            'create': 'post',
            'retrieve': 'get',
            'update': 'put',
            'partial_update': 'patch',
            'destroy': 'delete'
        }
        return action_map.get(action, 'get')
        
    def _extract_action_info(self, node: ast.FunctionDef) -> Optional[Dict[str, Any]]:
        """Extract information from @action decorator."""
        for decorator in node.decorator_list:
            if isinstance(decorator, ast.Call) and isinstance(decorator.func, ast.Name) and decorator.func.id == 'action':
                action_info = {
                    'detail': False,  # Default value
                    'http_method': 'get',  # Default value
                    'custom': True
                }
                
                # Process decorator arguments
                for keyword in decorator.keywords:
                    if keyword.arg == 'detail' and isinstance(keyword.value, ast.Constant):
                        action_info['detail'] = keyword.value.value
                    elif keyword.arg == 'methods':
                        if isinstance(keyword.value, ast.List) and keyword.value.elts:
                            # Take the first method in the list
                            if isinstance(keyword.value.elts[0], ast.Str):
                                action_info['http_method'] = keyword.value.elts[0].s.lower()
                            elif hasattr(keyword.value.elts[0], 'value'):  # For Python 3.8+ Constant
                                action_info['http_method'] = keyword.value.elts[0].value.lower()
                return action_info
        return None
        
    def _extract_queryset_model(self, node: ast.ClassDef) -> Optional[str]:
        """Extract the model from queryset attribute."""
        for item in node.body:
            if isinstance(item, ast.Assign):
                for target in item.targets:
                    if isinstance(target, ast.Name) and target.id == 'queryset':
                        if isinstance(item.value, ast.Call) and isinstance(item.value.func, ast.Attribute):
                            if item.value.func.attr == 'all' and isinstance(item.value.func.value, ast.Name):
                                return item.value.func.value.id
        return None
        
    def _extract_serializer_class(self, node: ast.ClassDef) -> Optional[str]:
        """Extract the serializer_class attribute."""
        for item in node.body:
            if isinstance(item, ast.Assign):
                for target in item.targets:
                    if isinstance(target, ast.Name) and target.id == 'serializer_class':
                        if isinstance(item.value, ast.Name):
                            return item.value.id
        return None


class DjangoModelVisitor(ast.NodeVisitor):
    """AST visitor to extract Django model fields."""
    def __init__(self):
        self.models = {}
        self.current_class = None
        
    def visit_ClassDef(self, node):
        """Process class definitions to find Model classes."""
        # Check if it's a Model class
        is_model = False
        for base in node.bases:
            if isinstance(base, ast.Name) and base.id == 'Model':
                is_model = True
            elif isinstance(base, ast.Attribute) and isinstance(base.value, ast.Name):
                if base.value.id == 'models' and base.attr == 'Model':
                    is_model = True
                    
        if is_model:
            fields = {}
            for item in node.body:
                if isinstance(item, ast.Assign):
                    for target in item.targets:
                        if isinstance(target, ast.Name):
                            field_name = target.id
                            field_type = self._extract_field_type(item.value)
                            if field_type:
                                fields[field_name] = field_type
                                
            self.models[node.name] = {
                'fields': fields,
                'doc': ast.get_docstring(node)
            }
            
        self.generic_visit(node)
        
    def _extract_field_type(self, node):
        """Extract field type from field definition."""
        if isinstance(node, ast.Call):
            if isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name):
                if node.func.value.id == 'models':
                    return node.func.attr
        return None


def pluralize(word):
    """Convert singular to plural with better handling of English language rules."""
    if not word:
        return word
        
    word = word.lower()  # Ensure lowercase for consistency
    
    # Special cases and irregular plurals
    irregulars = {
        'person': 'people',
        'man': 'men',
        'woman': 'women',
        'child': 'children',
        'foot': 'feet',
        'tooth': 'teeth',
        'goose': 'geese',
        'mouse': 'mice',
        'ox': 'oxen',
        'leaf': 'leaves',
        'life': 'lives',
        'knife': 'knives',
        'wife': 'wives',
        'elf': 'elves',
        'loaf': 'loaves',
        'potato': 'potatoes',
        'tomato': 'tomatoes',
        'cactus': 'cacti',
        'focus': 'foci',
        'fungus': 'fungi',
        'nucleus': 'nuclei',
        'syllabus': 'syllabi',
        'analysis': 'analyses',
        'diagnosis': 'diagnoses',
        'basis': 'bases',
        'crisis': 'crises',
        'thesis': 'theses',
        'datum': 'data',
        'medium': 'media',
        'criterion': 'criteria',
        'index': 'indices',
        'matrix': 'matrices',
        'vertex': 'vertices',
        'alumnus': 'alumni',
        'series': 'series',
        'species': 'species',
        'deer': 'deer',
        'fish': 'fish',
        'sheep': 'sheep',
        'moose': 'moose',
        'aircraft': 'aircraft',
    }
    
    # Check for irregular plural
    if word in irregulars:
        return irregulars[word]
    
    # Words ending in -is change to -es
    if word.endswith('is'):
        return word[:-2] + 'es'
    
    # Words ending in -on change to -a
    if word.endswith('on'):
        return word[:-2] + 'a'
    
    # Words ending in -us change to -i
    if word.endswith('us'):
        return word[:-2] + 'i'
    
    # Words ending in -f or -fe change to -ves
    if word.endswith('f'):
        return word[:-1] + 'ves'
    if word.endswith('fe'):
        return word[:-2] + 'ves'
    
    # Words ending in -y change to -ies (if consonant before y)
    if word.endswith('y') and word[-2] not in 'aeiou':
        return word[:-1] + 'ies'
    
    # Words ending in -o change to -oes (common cases)
    if word.endswith('o') and word[-2] not in 'aeiou':
        # Exceptions
        if word in ['photo', 'piano', 'halo', 'studio', 'video', 'radio', 'solo']:
            return word + 's'
        return word + 'es'
    
    # Words ending in -ex or -ix change to -ices
    if word.endswith(('ex', 'ix')):
        return word[:-2] + 'ices'
    
    # Words ending in -s, -ss, -sh, -ch, -x, -z change to -es
    if word.endswith(('s', 'ss', 'sh', 'ch', 'x', 'z')):
        return word + 'es'
    
    # Default: add s
    return word + 's'


def join_paths(base_path: str, sub_path: str) -> str:
    """
    Properly join two URL paths handling leading and trailing slashes correctly.
    """
    # Normalize paths to not have trailing slashes unless they're the root path
    base_clean = base_path.rstrip('/') if base_path != '/' else '/'
    sub_clean = sub_path.lstrip('/')
    
    # Join paths
    if base_clean == '/':
        return f"/{sub_clean}"
    else:
        return f"{base_clean}/{sub_clean}"


def extract_urls_from_file(file_path: str) -> List[Dict[str, Any]]:
    """Extract URL patterns from a Django URLs file."""
    try:
        with open(file_path, 'r') as f:
            source_code = f.read()
            
        print(f"Analyzing URL patterns in: {file_path}")
        
        patterns = []
        
        # Look for ViewSet imports first to map viewset names to their potential import paths
        viewset_imports = {}
        import_matches = re.finditer(r'from\s+([\w.]+)\s+import\s+([^#\n]+)', source_code)
        for match in import_matches:
            module_path = match.group(1)
            imports = match.group(2).strip()
            for imp in imports.split(','):
                imp = imp.strip()
                if 'ViewSet' in imp:
                    viewset_name = imp.split(' as ')[-1].strip()
                    viewset_imports[viewset_name] = f"{module_path}.{imp.split(' as ')[0].strip()}"
                    print(f"  Found ViewSet import: {viewset_name}")
        
        # Handle Django REST Framework router patterns
        router_patterns = []
        
        # Look for explicit router variable patterns like router = DefaultRouter()
        router_match = re.search(r'(\w+)\s*=\s*(?:routers\.)?(?:Default)?Router', source_code)
        
        # If no explicit router variable, look for common DRF router usage patterns
        if not router_match:
            # Check for direct router.register calls without variable assignment
            register_patterns = re.findall(r'(?:router|DefaultRouter\(\))\.register\([\'"]([^\'"]+)[\'"],\s*(\w+)', source_code)
            if register_patterns:
                print(f"  Found DRF router register calls directly")
                # Process each register call
                for path, viewset in register_patterns:
                    print(f"  Router registration: {path} -> {viewset}")
                    # Normalize path - ensure it has no trailing slash except for root
                    normalized_path = path.rstrip('/') or '/'
                    
                    # Try to infer model name from ViewSet name
                    model_name = None
                    if viewset.endswith('ViewSet'):
                        model_name = viewset[:-7]  # Remove 'ViewSet' suffix
                    
                    # Get a better path name using model name if available
                    if model_name:
                        # Convert to kebab-case pluralized endpoint
                        endpoint = model_name_to_endpoint(model_name)
                        # Use the explicit path from router.register if it looks meaningful
                        # otherwise use our inferred endpoint name
                        if path == '/' or path == '' or path == model_name.lower() or path == pluralize(model_name.lower()):
                            better_path = f"api/{endpoint}"
                            print(f"  Transforming generic path '{path}' to '{better_path}'")
                            normalized_path = better_path
                    
                    # Add list endpoint
                    router_patterns.append({
                        'path': normalized_path,
                        'view': viewset,
                        'name': f"{viewset}_list", 
                        'namespace': None
                    })
                    # Add detail endpoint with proper path joining
                    router_patterns.append({
                        'path': join_paths(normalized_path, '{pk}'),
                        'view': viewset,
                        'name': f"{viewset}_detail",
                        'namespace': None
                    })
            
            # If no direct router.register calls, check for viewsets that appear to be used in routing
            elif viewset_imports and '/api/' in file_path:
                print(f"  No router found but ViewSet imports detected in API urls file")
                for viewset_name in viewset_imports:
                    if viewset_name.endswith('ViewSet'):
                        # Extract model name from the ViewSet name
                        model_name = viewset_name.replace('ViewSet', '')
                        
                        # Convert model name to kebab-case endpoint
                        endpoint = model_name_to_endpoint(model_name)
                        
                        print(f"  Inferring router registration for {viewset_name} at api/{endpoint}")
                        # Add list endpoint
                        router_patterns.append({
                            'path': f"api/{endpoint}",
                            'view': viewset_name,
                            'name': f"{viewset_name}_list",
                            'namespace': None
                        })
                        # Add detail endpoint with proper path joining
                        router_patterns.append({
                            'path': join_paths(f"api/{endpoint}", '{pk}'),
                            'view': viewset_name,
                            'name': f"{viewset_name}_detail",
                            'namespace': None
                        })
        else:
            # Process explicit router variable patterns
            router_name = router_match.group(1)
            print(f"  Found DRF router '{router_name}' in {file_path}")
            
            # Extract router.register patterns with better regex
            register_patterns = re.findall(
                rf'{router_name}\.register\([\'"]([^\'"]+)[\'"],\s*(\w+)', source_code)
            
            if register_patterns:
                print(f"  Found {len(register_patterns)} router registrations")
                for path, viewset in register_patterns:
                    print(f"  Router registration: {path} -> {viewset}")
                    
                    # Normalize path - ensure it has no trailing slash except for root
                    normalized_path = path.rstrip('/') or '/'
                    
                    # Try to determine viewset actions from imports or common patterns
                    custom_actions = []
                    
                    # Look for @action decorators
                    action_pattern = re.compile(rf'{viewset}.*?@action.*?def\s+(\w+)', re.DOTALL)
                    action_matches = action_pattern.findall(source_code)
                    
                    # If not found, check if the viewset is imported and look in the source file 
                    if not action_matches and viewset in viewset_imports:
                        imported_path = viewset_imports[viewset]
                        module_parts = imported_path.split('.')
                        viewset_file = None
                        
                        # Try to find the file that contains the ViewSet
                        for root, dirs, files in os.walk(os.path.dirname(file_path)):
                            for filename in files:
                                if filename.endswith('.py') and module_parts[-1].lower() in filename.lower():
                                    viewset_file = os.path.join(root, filename)
                                    break
                            if viewset_file:
                                break
                        
                        if viewset_file:
                            try:
                                with open(viewset_file, 'r') as vf:
                                    viewset_code = vf.read()
                                    # Look for custom actions
                                    action_matches = re.findall(r'@action.*?def\s+(\w+)', viewset_code, re.DOTALL)
                                    if action_matches:
                                        print(f"  Found custom actions in {viewset}: {', '.join(action_matches)}")
                            except Exception as e:
                                print(f"  Error reading viewset file: {e}")
                    
                    # Create standard viewset routes
                    # Add list endpoint
                    router_patterns.append({
                        'path': normalized_path,
                        'view': viewset,
                        'name': f"{viewset}_list",
                        'namespace': None
                    })
                    
                    # Add detail endpoint with proper path joining
                    router_patterns.append({
                        'path': join_paths(normalized_path, '{pk}'),
                        'view': viewset,
                        'name': f"{viewset}_detail",
                        'namespace': None
                    })
                    
                    # Add custom action endpoints if found
                    for action in action_matches:
                        # Check for common patterns in action names to guess if it's detail or list
                        is_detail = any(detail_word in action for detail_word in 
                                      ['delete', 'edit', 'update', 'get_', 'set_', 'by_id'])
                        
                        if is_detail:
                            router_patterns.append({
                                'path': join_paths(join_paths(normalized_path, '{pk}'), action),
                                'view': viewset,
                                'name': f"{viewset}_{action}",
                                'namespace': None
                            })
                        else:
                            router_patterns.append({
                                'path': join_paths(normalized_path, action),
                                'view': viewset,
                                'name': f"{viewset}_{action}",
                                'namespace': None
                            })
            else:
                print("  No router.register() calls found despite router being defined")
        
        # Look for various URL pattern styles
        
        # 1. Django 2.0+ path() style
        path_patterns = re.findall(r'path\([\'"]([^\'"]*)[\'"],\s*([^),]+)', source_code)
        for path, view in path_patterns:
            # Skip admin, static, media paths
            if any(skip in path for skip in ['admin', 'static', 'media']):
                continue
                
            # Handle include() patterns
            if 'include' in view:
                include_match = re.search(r'include\([\'"]([^\'"]+)[\'"]', view)
                if include_match:
                    included_app = include_match.group(1)
                    print(f"  Found include: {included_app} at {path}")
                    # Process included patterns recursively
                    include_info = {'include': included_app}
                    included_patterns = process_included_urls(file_path, include_info)
                    if included_patterns:
                        # Prepend the parent path to all included patterns with proper path joining
                        for pattern in included_patterns:
                            pattern['path'] = join_paths(path, pattern['path'])
                        patterns.extend(included_patterns)
            else:
                # Regular view pattern
                view_name = view.strip()
                # Extract the view name from expressions like views.my_view or MyViewClass.as_view()
                view_match = re.search(r'(\w+)(?:\.as_view\(\)|$|\W)', view_name)
                if view_match:
                    view_name = view_match.group(1)
                patterns.append({
                    'path': path,
                    'view': view_name,
                    'name': None,
                    'namespace': None
                })
        
        # 2. Old-style url() patterns with regex
        url_patterns = re.findall(r'url\(r[\'"]([^\'"]*)[\'"],\s*([^),]+)', source_code)
        for path, view in url_patterns:
            # Convert regex patterns to path format (simplified)
            path = re.sub(r'\(\?P<([^>]+)>[^)]+\)', r'{\1}', path)
            
            # Handle include() in the same way
            if 'include' in view:
                include_match = re.search(r'include\([\'"]([^\'"]+)[\'"]', view)
                if include_match:
                    included_app = include_match.group(1)
                    print(f"  Found include: {included_app} at {path}")
                    include_info = {'include': included_app}
                    included_patterns = process_included_urls(file_path, include_info)
                    if included_patterns:
                        for pattern in included_patterns:
                            pattern['path'] = join_paths(path, pattern['path'])
                        patterns.extend(included_patterns)
            else:
                view_name = view.strip()
                view_match = re.search(r'(\w+)(?:\.as_view\(\)|$|\W)', view_name)
                if view_match:
                    view_name = view_match.group(1)
                patterns.append({
                    'path': path,
                    'view': view_name,
                    'name': None,
                    'namespace': None
                })
        
        # Add router patterns 
        if router_patterns:
            print(f"  Adding {len(router_patterns)} router patterns")
            patterns.extend(router_patterns)
        
        # Look for additional API URL patterns
        api_prefix_match = re.search(r'path\([\'"]api/?[\'"]', source_code)
        if api_prefix_match:
            print("  Found API URL prefix, looking for nested API endpoints")
            api_dir = os.path.dirname(file_path)
            for root, dirs, files in os.walk(api_dir):
                for file in files:
                    if file == 'urls.py' and os.path.join(root, file) != file_path:
                        api_urls_path = os.path.join(root, file)
                        print(f"  Checking nested API urls in {api_urls_path}")
                        try:
                            sub_patterns = extract_urls_from_file(api_urls_path)
                            if sub_patterns:
                                print(f"  Found {len(sub_patterns)} nested API patterns")
                                # Prefix all patterns with /api using proper path joining
                                for pattern in sub_patterns:
                                    pattern['path'] = join_paths('api', pattern['path'].lstrip('/'))
                                patterns.extend(sub_patterns)
                        except Exception as e:
                            print(f"  Error processing {api_urls_path}: {e}")
        
        if patterns:
            print(f"  Found {len(patterns)} URL patterns")
            for pattern in patterns[:5]:  # Show just the first 5 to avoid verbose output
                print(f"    - {pattern['path']} -> {pattern['view']}")
            if len(patterns) > 5:
                print(f"    - ... and {len(patterns) - 5} more")
                
        return patterns
    except Exception as e:
        print(f"Error analyzing URLs file {file_path}: {e}")
        return []


def process_included_urls(parent_file: str, include_info: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Process included URL patterns."""
    try:
        include_path = include_info['include']
        namespace = include_info.get('namespace')
        
        # Handle relative imports based on parent file location
        parent_dir = os.path.dirname(parent_file)
        
        # Convert Django dotted path to file path
        if include_path.endswith('.urls'):
            module_parts = include_path.split('.')
            file_path = os.path.join(parent_dir, *module_parts[:-1], f"{module_parts[-1]}.py")
        else:
            # Handle app-level URLs
            file_path = os.path.join(parent_dir, include_path, 'urls.py')
            
        if not os.path.exists(file_path):
            # Try a different approach for app-level URLs
            if '.' in include_path:
                module_parts = include_path.split('.')
                file_path = os.path.join(parent_dir, *module_parts[:-1], f"{module_parts[-1]}.py")
                
        if os.path.exists(file_path):
            sub_patterns = extract_urls_from_file(file_path)
            
            # Add namespace to patterns if provided
            if namespace:
                for pattern in sub_patterns:
                    pattern['namespace'] = namespace
                    
            return sub_patterns
    except Exception as e:
        print(f"Error processing included URLs: {e}")
    
    return []


def extract_views_from_file(file_path: str) -> Dict[str, Any]:
    """Extract view classes and functions from a file."""
    try:
        with open(file_path, 'r') as f:
            source_code = f.read()
            
        tree = ast.parse(source_code)
        viewset_visitor = DjangoViewSetVisitor()
        viewset_visitor.visit(tree)
        
        return viewset_visitor.viewsets
    except Exception as e:
        print(f"Error analyzing views file: {e}")
        return {}


def extract_models_from_file(file_path: str) -> Dict[str, Any]:
    """Extract model classes from a file."""
    try:
        with open(file_path, 'r') as f:
            source_code = f.read()
            
        tree = ast.parse(source_code)
        model_visitor = DjangoModelVisitor()
        model_visitor.visit(tree)
        
        # Process model data to extract more information
        processed_models = {}
        for model_name, model_info in model_visitor.models.items():
            processed_models[model_name] = {
                'fields': {},
                'validations': {},
                'relationships': []
            }
            
            for field_name, field_type in model_info['fields'].items():
                # Map Django field types to OpenAPI types
                openapi_type = map_django_field_type_to_openapi(field_type)
                processed_models[model_name]['fields'][field_name] = openapi_type
                
                # Check for relationship fields and track them
                if field_type in ['ForeignKey', 'OneToOneField', 'ManyToManyField']:
                    processed_models[model_name]['relationships'].append({
                        'field': field_name,
                        'type': field_type
                    })
            
            # Add documentation if available
            if model_info['doc']:
                processed_models[model_name]['description'] = model_info['doc']
        
        # Try to extract additional field information from the source code
        for model_name in processed_models:
            model_pattern = re.compile(rf'class\s+{model_name}\s*\(.*?\):.*?(?=class|\Z)', re.DOTALL)
            model_match = model_pattern.search(source_code)
            
            if model_match:
                model_code = model_match.group(0)
                
                # Look for field validations
                required_fields = re.findall(r'validators=\[.*?validate_required.*?\]', model_code)
                for req_field in required_fields:
                    field_match = re.search(r'(\w+)\s*=\s*models\.\w+\(.*?validators=\[.*?validate_required.*?\]', model_code)
                    if field_match:
                        field_name = field_match.group(1)
                        processed_models[model_name]['validations'][field_name] = {'required': True}
                
                # Look for explicit required=True in field definitions
                required_fields = re.findall(r'(\w+)\s*=\s*models\.\w+\(.*?null\s*=\s*False.*?\)', model_code)
                for field_name in required_fields:
                    processed_models[model_name]['validations'][field_name] = {'required': True}
                
                # Look for max_length constraints
                max_length_fields = re.findall(r'(\w+)\s*=\s*models\.\w+\(.*?max_length\s*=\s*(\d+).*?\)', model_code)
                for field_name, max_length in max_length_fields:
                    if field_name not in processed_models[model_name]['validations']:
                        processed_models[model_name]['validations'][field_name] = {}
                    processed_models[model_name]['validations'][field_name]['max_length'] = int(max_length)
        
        return processed_models
    except Exception as e:
        print(f"Error analyzing models file: {e}")
        return {}


def map_django_field_type_to_openapi(django_field_type):
    """Map Django field types to OpenAPI schema types."""
    # Map common Django field types to OpenAPI types
    field_type_mapping = {
        'CharField': 'string',
        'TextField': 'string',
        'EmailField': 'string',
        'URLField': 'string',
        'SlugField': 'string',
        'UUIDField': 'string',
        'FileField': 'string',
        'ImageField': 'string',
        'BooleanField': 'boolean',
        'NullBooleanField': 'boolean',
        'IntegerField': 'integer',
        'PositiveIntegerField': 'integer',
        'PositiveSmallIntegerField': 'integer',
        'SmallIntegerField': 'integer',
        'BigIntegerField': 'integer',
        'FloatField': 'number',
        'DecimalField': 'number',
        'DateField': 'string',
        'TimeField': 'string',
        'DateTimeField': 'string',
        'DurationField': 'string',
        'JSONField': 'object',
        'ForeignKey': 'integer', # Simplified, typically an ID reference
        'OneToOneField': 'integer', # Simplified, typically an ID reference
        'ManyToManyField': 'array', # Simplified, typically an array of IDs
    }
    
    # Return the mapped type or default to string if not found
    return field_type_mapping.get(django_field_type, 'string')


def find_views_file(project_root: str, view_name: str) -> Optional[str]:
    """Find the file containing a view class or function."""
    for root, _, files in os.walk(project_root):
        for file in files:
            if file.endswith('.py'):
                file_path = os.path.join(root, file)
                try:
                    with open(file_path, 'r') as f:
                        content = f.read()
                        
                    if re.search(rf'class\s+{view_name}\b', content) or re.search(rf'def\s+{view_name}\b', content):
                        return file_path
                except Exception:
                    pass
    return None


def model_name_to_endpoint(model_name):
    """
    Convert model name to appropriate RESTful endpoint name.
    Example: UserProfile -> user-profiles
    """
    # Convert CamelCase to kebab-case first
    # e.g. UserProfile -> user-profile
    s1 = re.sub('(.)([A-Z][a-z]+)', r'\1-\2', model_name)
    kebab = re.sub('([a-z0-9])([A-Z])', r'\1-\2', s1).lower()
    
    # Then pluralize
    return pluralize(kebab)


def analyze_django_project(project_root: str) -> Dict[str, Any]:
    """Analyze a Django project to extract routes, views, and models."""
    project_data = {
        'urls': [],
        'views': {},
        'models': {},
        'app_name': os.path.basename(project_root)
    }
    
    # Keep track of endpoints we've already added to avoid duplicates
    added_endpoints = set()
    
    print(f"\n1. Analyzing Django project structure...")
    
    # Find all urls.py files
    urls_files = []
    for root, dirs, files in os.walk(project_root):
        if 'urls.py' in files:
            file_path = os.path.join(root, 'urls.py')
            urls_files.append(file_path)
            # Quick check if this contains API endpoints (for better diagnosis)
            try:
                with open(file_path, 'r') as f:
                    content = f.read()
                    if any(api_marker in content for api_marker in 
                          ['rest_framework', 'router', 'api', 'viewsets', 'APIView']):
                        print(f"   Found potential API definitions in {file_path}")
            except Exception:
                pass
    
    print(f"   Found {len(urls_files)} urls.py files")
    
    # First specifically look for api/urls.py if it exists - this commonly contains REST endpoints
    api_urls = None
    for file in urls_files:
        if '/api/urls.py' in file or '/apis/urls.py' in file:
            api_urls = file
            print(f"   Found API URLs file: {api_urls}")
            api_patterns = extract_urls_from_file(api_urls)
            if api_patterns:
                # Prefix API paths if not already done
                for pattern in api_patterns:
                    if not pattern['path'].startswith('api/') and not pattern['path'].startswith('/api/'):
                        pattern['path'] = f"api/{pattern['path'].lstrip('/')}"
                project_data['urls'].extend(api_patterns)
            
    # Start with the main urls.py file (prioritize project-level urls.py)
    main_urls = None
    for file in urls_files:
        # Check for main urls.py in common project structures
        if '/project/urls.py' in file or '/config/urls.py' in file:
            main_urls = file
            print(f"   Using main URLs file: {main_urls}")
            break
            
    if not main_urls and urls_files:
        main_urls = urls_files[0]
        print(f"   Falling back to: {main_urls}")
        
    if main_urls:
        main_patterns = extract_urls_from_file(main_urls)
        if main_patterns:
            project_data['urls'].extend(main_patterns)
        print(f"   Extracted {len(project_data['urls'])} URL patterns")
    else:
        print("   No urls.py files found")
        
    # If no URLs found yet, try all urls.py files
    if not project_data['urls']:
        print("   No URL patterns found in main files, checking all urls.py files...")
        for file in urls_files:
            if file != main_urls and file != api_urls:  # Skip already processed files
                patterns = extract_urls_from_file(file)
                if patterns:
                    # Try to determine if these are API endpoints from the file path
                    if 'api' in file.lower():
                        for pattern in patterns:
                            if not pattern['path'].startswith('api/'):
                                pattern['path'] = f"api/{pattern['path'].lstrip('/')}"
                    project_data['urls'].extend(patterns)
    
    # Find all models and views
    print(f"\n2. Looking for views and models...")
    view_files = []
    model_files = []
    viewset_files = []
    serializer_files = []
    
    for root, dirs, files in os.walk(project_root):
        for file in files:
            if file.endswith('.py'):
                file_path = os.path.join(root, file)
                
                # Skip migrations, __pycache__, and tests
                if any(skip in file_path for skip in ['migrations', '__pycache__', 'tests']):
                    continue
                
                # Try to determine file type by examining content
                try:
                    with open(file_path, 'r') as f:
                        content = f.read()
                    
                    # Check for model indicators
                    if file == 'models.py' or 'models.Model' in content or 'db.models' in content:
                        model_files.append(file_path)
                        
                    # Check for viewset indicators  
                    if 'ViewSet' in content or 'ModelViewSet' in content:
                        viewset_files.append(file_path)
                        
                    # Check for view indicators
                    if file == 'views.py' or 'View' in content or 'APIView' in content:
                        view_files.append(file_path)
                    
                    # Check for serializer indicators
                    if file == 'serializers.py' or 'Serializer' in content:
                        serializer_files.append(file_path)
                        
                except Exception as e:
                    print(f"   Warning: Couldn't read {file_path}: {e}")
                    
    print(f"   Found {len(model_files)} model files, {len(view_files)} view files, and {len(viewset_files)} viewset files")
                    
    # Extract from model files
    for file_path in model_files:
        models = extract_models_from_file(file_path)
        if models:
            print(f"   Extracted {len(models)} models from {file_path}")
            project_data['models'].update(models)
        
    # Extract from viewset files first (they're most likely to contain API endpoints)
    for file_path in viewset_files:
        views = extract_views_from_file(file_path)
        if views:
            print(f"   Extracted {len(views)} viewsets from {file_path}")
            project_data['views'].update(views)
    
    # Extract from view files
    for file_path in view_files:
        # Skip if already processed as a viewset file
        if file_path in viewset_files:
            continue
            
        views = extract_views_from_file(file_path)
        if views:
            print(f"   Extracted {len(views)} views from {file_path}")
            project_data['views'].update(views)
    
    # Helper function to add endpoints
    def add_endpoint_if_not_exists(path, view, name=None, namespace=None):
        """Helper to add an endpoint only if it doesn't already exist"""
        # Check if we already have this endpoint
        endpoint_key = f"{path}:{view}"
        if endpoint_key in added_endpoints:
            return False
            
        # Add to tracking set
        added_endpoints.add(endpoint_key)
        
        # Add to URLs
        project_data['urls'].append({
            'path': path,
            'view': view,
            'name': name,
            'namespace': namespace
        })
        return True
    
    # Check if we have actual API endpoints or only documentation endpoints
    has_api_endpoints = False
    for pattern in project_data['urls']:
        path = pattern.get('path', '')
        if path.startswith('api/') or '/api/' in path:
            has_api_endpoints = True
            # Track this endpoint
            added_endpoints.add(f"{path}:{pattern.get('view', '')}")
            break
    
    # Use serializers to infer API endpoints if we only have documentation endpoints
    if (not has_api_endpoints and serializer_files) or (len(project_data['urls']) <= 5 and serializer_files):
        print(f"   No API endpoints found, checking serializers for clues about API structure...")
        for file_path in serializer_files:
            try:
                with open(file_path, 'r') as f:
                    content = f.read()
                    
                # Extract model names from serializers to infer viewsets
                serializer_models = re.findall(r'class\s+(\w+)Serializer', content)
                for model in serializer_models:
                    # Create a synthetic ViewSet for each model that has a serializer
                    print(f"   Inferring ViewSet for model {model} from serializer")
                    viewset_name = f"{model}ViewSet"
                    project_data['views'][viewset_name] = {
                        'base_classes': ['ModelViewSet'],
                        'methods': {
                            'list': {'http_method': 'get', 'description': f'List all {model.lower()}s'},
                            'create': {'http_method': 'post', 'description': f'Create a new {model.lower()}'},
                            'retrieve': {'http_method': 'get', 'description': f'Get a single {model.lower()}'},
                            'update': {'http_method': 'put', 'description': f'Update a {model.lower()}'},
                            'partial_update': {'http_method': 'patch', 'description': f'Partially update a {model.lower()}'},
                            'destroy': {'http_method': 'delete', 'description': f'Delete a {model.lower()}'}
                        }
                    }
                    
                    # Generate synthetic endpoints for this model using kebab-case
                    model_endpoint = model_name_to_endpoint(model)
                    
                    print(f"   Adding synthetic endpoints for {model}: /api/{model_endpoint}/")
                    # Add list/create endpoint
                    add_endpoint_if_not_exists(
                        f"api/{model_endpoint}/", 
                        viewset_name,
                        f"{model.lower()}-list"
                    )
                    
                    # Add detail endpoint
                    add_endpoint_if_not_exists(
                        f"api/{model_endpoint}/{{id}}/", 
                        viewset_name,
                        f"{model.lower()}-detail"
                    )
            except Exception as e:
                print(f"   Warning: Couldn't process {file_path}: {e}")
    
    # If we still have no API endpoints but we've got models, create synthetic endpoints
    if not has_api_endpoints and project_data['models']:
        print(f"   Creating synthetic REST endpoints based on models (found {len(project_data['models'])} models)")
        for model_name in project_data['models']:
            # Use kebab-case for endpoint names
            model_endpoint = model_name_to_endpoint(model_name)
                
            viewset_name = f"{model_name}ViewSet"
            if viewset_name not in project_data['views']:
                # Create synthetic viewset
                project_data['views'][viewset_name] = {
                    'base_classes': ['ModelViewSet'],
                    'methods': {
                        'list': {'http_method': 'get', 'description': f'List all {model_name.lower()}s'},
                        'create': {'http_method': 'post', 'description': f'Create a new {model_name.lower()}'},
                        'retrieve': {'http_method': 'get', 'description': f'Get a single {model_name.lower()}'},
                        'update': {'http_method': 'put', 'description': f'Update a {model_name.lower()}'},
                        'partial_update': {'http_method': 'patch', 'description': f'Partially update a {model_name.lower()}'},
                        'destroy': {'http_method': 'delete', 'description': f'Delete a {model_name.lower()}'}
                    }
                }
            
            print(f"   Adding synthetic endpoints for {model_name}: /api/{model_endpoint}/")
            # Add list/create endpoint
            add_endpoint_if_not_exists(
                f"api/{model_endpoint}/", 
                viewset_name,
                f"{model_name.lower()}-list"
            )
            
            # Add detail endpoint
            add_endpoint_if_not_exists(
                f"api/{model_endpoint}/{{id}}/", 
                viewset_name,
                f"{model_name.lower()}-detail"
            )
                        
    print(f"\n3. Summary:")
    print(f"   - URL patterns: {len(project_data['urls'])}")
    print(f"   - Views/ViewSets: {len(project_data['views'])}")
    print(f"   - Models: {len(project_data['models'])}")
                    
    return project_data


def convert_django_path_to_openapi(path: str) -> str:
    """Convert Django-style URL pattern to OpenAPI path format."""
    if not path:
        return '/'
        
    # Normalize leading slash
    if not path.startswith('/'):
        path = '/' + path
        
    # Replace Django-style path parameters with OpenAPI style
    # <int:pk> or <pk> to {pk}
    openapi_path = re.sub(r'<(?:[^:]+:)?([^>]+)>', r'{\1}', path)
    
    # Handle regex patterns like (?P<pk>\d+) to {pk}
    openapi_path = re.sub(r'\(\?P<([^>]+)>[^)]+\)', r'{\1}', openapi_path)
    
    # Remove trailing slashes for OpenAPI consistency
    if openapi_path.endswith('/') and len(openapi_path) > 1:
        openapi_path = openapi_path[:-1]
        
    # Special case for proxy/django
    if openapi_path == '/':
        openapi_path = '/proxy/django'
    
    return openapi_path


def generate_openapi_spec(project_path, output_file=None):
    """Generate an OpenAPI specification for a Django project."""
    try:
        # Discover the project structure
        print(f"Analyzing Django project at {project_path}...")
        
        # Find and parse all model files
        models_data = {}
        views_data = {}
        
        for root, dirs, files in os.walk(project_path):
            for file in files:
                if file.endswith('.py'):
                    filepath = os.path.join(root, file)
                    
                    # Extract models
                    if file == 'models.py' or file.endswith('_models.py'):
                        models = extract_models_from_file(filepath)
                        models_data.update(models)
                    
                    # Extract views
                    if file == 'views.py' or file.endswith('_views.py') or file.endswith('_viewsets.py'):
                        views = extract_views_from_file(filepath)
                        views_data.update(views)
        
        print(f"Found {len(models_data)} models and {len(views_data)} views/viewsets")
        
        # Extract URL patterns
        urls_data = []
        urls_file = find_urls_file(project_path)
        if urls_file:
            urls_data = extract_urls_from_file(urls_file)
        
        # Create the base OpenAPI structure
        openapi_spec = {
            "openapi": "3.0.3",
            "info": {
                "title": "Django API",
                "description": "API generated from Django project",
                "version": "1.0.0"
            },
            "servers": [
                {
                    "url": "/proxy/django",
                    "description": "Django API"
                }
            ],
            "paths": {},
            "components": {
                "schemas": {},
                "securitySchemes": {
                    "BearerAuth": {
                        "type": "http",
                        "scheme": "bearer"
                    }
                }
            }
        }
        
        # Generate schemas for models
        for model_name, model_info in models_data.items():
            schema = {
                "type": "object",
                "properties": {},
                "required": []
            }
            
            for field_name, field_info in model_info['fields'].items():
                # Handle the case where field_info is a string (simple type) instead of a dictionary
                if isinstance(field_info, str):
                    field_type = field_info
                    schema_field = {
                        "type": convert_django_type_to_openapi(field_type)
                    }
                else:
                    field_type = field_info.get('type', 'string')
                    schema_field = {
                        "type": convert_django_type_to_openapi(field_type)
                    }
                    
                    # Add format if applicable
                    openapi_format = get_openapi_format_for_field(field_type)
                    if openapi_format:
                        schema_field["format"] = openapi_format
                    
                    # Add description if available
                    if 'help_text' in field_info:
                        schema_field["description"] = field_info['help_text']
                    
                    # Add enum values if choices are defined
                    if 'choices' in field_info:
                        schema_field["enum"] = [choice[0] for choice in field_info['choices']]
                
                # Handle relationship fields
                if field_type in ['ForeignKey', 'OneToOneField', 'ManyToManyField']:
                    related_model = None
                    if isinstance(field_info, dict):
                        related_model = field_info.get('related_model')
                    
                    if related_model and related_model in models_data:
                        if field_type == 'ManyToManyField':
                            schema_field = {
                                "type": "array",
                                "items": {
                                    "$ref": f"#/components/schemas/{related_model}"
                                }
                            }
                        else:
                            schema_field = {
                                "$ref": f"#/components/schemas/{related_model}"
                            }
                
                schema["properties"][field_name] = schema_field
                
                # Add to required fields if known to be required
                # This is simplified since we don't have full field info in all cases
                if isinstance(field_info, dict) and not field_info.get('null', False) and not field_info.get('blank', False):
                    if field_name != 'id':  # Skip id field as typically auto-generated
                        schema["required"].append(field_name)
            
            # Only add required field if there are any required fields
            if not schema["required"]:
                del schema["required"]
                
            # Add the model schema to the OpenAPI spec
            openapi_spec["components"]["schemas"][model_name] = schema
        
        # Add paths from URL patterns
        for url_pattern in urls_data:
            path = url_pattern.get('path', '')
            view = url_pattern.get('view', '')
            
            # Skip admin URLs
            if 'admin' in path:
                continue
            
            # Convert Django path parameters to OpenAPI parameters
            path_params = []
            openapi_path = path
            
            # Convert Django URL parameters (like <int:pk>) to OpenAPI parameters ({pk})
            pattern = r'<(?:[^:]+:)?([^>]+)>'
            matches = re.findall(pattern, path)
            
            for param in matches:
                path_params.append({
                    "name": param,
                    "in": "path",
                    "required": True,
                    "schema": {
                        "type": "string"
                    }
                })
                openapi_path = re.sub(r'<(?:[^:]+:)?' + param + '>', '{' + param + '}', openapi_path)
            
            # Add trailing slash if not present (Django convention)
            if not openapi_path.endswith('/') and openapi_path != '':
                openapi_path += '/'
            
            # Ensure path starts with /
            if not openapi_path.startswith('/'):
                openapi_path = '/' + openapi_path
            
            # Find model associated with this path or view
            model_name = infer_model_from_path_or_view(openapi_path, view, models_data, views_data)
            
            # Determine what HTTP methods this endpoint supports
            supported_methods = get_supported_methods_for_view(view, views_data)
            
            # Add operations for each supported method
            for method in supported_methods:
                method_lower = method.lower()
                
                # Skip OPTIONS and HEAD for simplicity
                if method_lower in ['options', 'head']:
                    continue
                
                operation = {
                    "summary": f"{method} {openapi_path}",
                    "operationId": generate_operation_id(method_lower, openapi_path, view),
                    "parameters": path_params.copy(),
                    "responses": {
                        "200": {
                            "description": "Successful operation"
                        }
                    }
                }
                
                # Add request body for POST, PUT, PATCH
                if method_lower in ['post', 'put', 'patch'] and model_name:
                    operation["requestBody"] = {
                        "content": {
                            "application/json": {
                                "schema": {
                                    "$ref": f"#/components/schemas/{model_name}"
                                }
                            }
                        },
                        "required": True
                    }
                
                # Add response content for GET, POST, PUT, PATCH
                if method_lower in ['get', 'post', 'put', 'patch'] and model_name:
                    # For collection endpoints (GET /users/)
                    if method_lower == 'get' and not any(p for p in path_params if p["name"] in ["pk", "id"]):
                        operation["responses"]["200"]["content"] = {
                            "application/json": {
                                "schema": {
                                    "type": "array",
                                    "items": {
                                        "$ref": f"#/components/schemas/{model_name}"
                                    }
                                }
                            }
                        }
                    else:
                        # For single-item endpoints
                        operation["responses"]["200"]["content"] = {
                            "application/json": {
                                "schema": {
                                    "$ref": f"#/components/schemas/{model_name}"
                                }
                            }
                        }
                
                # Initialize the path if it doesn't exist
                if openapi_path not in openapi_spec["paths"]:
                    openapi_spec["paths"][openapi_path] = {}
                
                # Add the operation to the path
                openapi_spec["paths"][openapi_path][method_lower] = operation
        
        # Generate synthetic endpoints for models that don't have explicit URL patterns
        synthetic_endpoints = generate_synthetic_endpoints(views_data, models_data, openapi_spec)
        
        # Add synthetic endpoints to the OpenAPI spec
        for endpoint in synthetic_endpoints:
            path = endpoint['path']
            method = endpoint['method']
            operation = endpoint['operation']
            
            # Initialize the path if it doesn't exist
            if path not in openapi_spec["paths"]:
                openapi_spec["paths"][path] = {}
            
            # Add the operation to the path
            openapi_spec["paths"][path][method] = operation
        
        # Write the OpenAPI spec to a file if an output file is provided
        if output_file:
            with open(output_file, 'w') as f:
                json.dump(openapi_spec, f, indent=2)
            print(f"OpenAPI specification written to {output_file}")
        
        return openapi_spec
    
    except Exception as e:
        traceback.print_exc()
        print(f"Error generating OpenAPI specification: {str(e)}")
        return None


def infer_model_from_path_or_view(path, view_name, available_models, views_data=None):
    """Infer model name from path or view name."""
    # Try to extract from path
    path_parts = path.strip('/').split('/')
    for part in path_parts:
        # Clean the part (remove api prefix, version numbers)
        clean_part = re.sub(r'^v\d+', '', part)  # Remove version like v1
        clean_part = clean_part.rstrip('s')  # Remove trailing s for plurals
        
        # Check if this part is a model name
        for model in available_models:
            if clean_part.lower() == model.lower():
                return model
    
    # Try to extract from view name
    clean_view = view_name.replace('ViewSet', '').replace('View', '')
    for model in available_models:
        if clean_view.lower() == model.lower():
            return model
    
    # If views_data is provided, try to get the model from the viewset
    if views_data and view_name in views_data:
        # Try to get queryset model
        queryset_model = views_data[view_name].get('queryset_model')
        if queryset_model and queryset_model in available_models:
            return queryset_model
    
    return None


def parse_arguments():
    parser = argparse.ArgumentParser(description='Generate OpenAPI specification from Django application')
    parser.add_argument('-e', '--endpoint', required=True, help='Path to Django project root')
    parser.add_argument('-o', '--output', required=True, help='Output file path for OpenAPI specification')
    return parser.parse_args()


def main():
    args = parse_arguments()
    
    # Validate input directory exists
    if not os.path.isdir(args.endpoint):
        print(f"Error: Input directory '{args.endpoint}' not found or is not a directory")
        sys.exit(1)
    
    # Create output directory if it doesn't exist
    output_dir = os.path.dirname(args.output)
    if output_dir and not os.path.exists(output_dir):
        os.makedirs(output_dir)
    
    print(f"Analyzing Django project at {args.endpoint}")
    
    # Regular flow for all Django projects - rely on static analysis instead of hardcoding
    project_data = analyze_django_project(args.endpoint)
    
    print(f"Generating OpenAPI specification")
    spec = generate_openapi_spec(args.endpoint, args.output)
    
    if spec is not None:
        print(f"✅ Successfully generated OpenAPI specification at {args.output}")
        print(f"Found {len(spec.get('paths', {}))} paths in the Django application")
        print(f"Base path set to '/proxy/django'")
    else:
        print(f"❌ Failed to generate OpenAPI specification")
        sys.exit(1)


def generate_synthetic_endpoints(views_data, models_data, openapi_spec):
    """Generate synthetic endpoints for viewsets that might not be captured in URL patterns."""
    synthetic_endpoints = []
    
    # Look for ViewSets in views data
    for view_name, view_info in views_data.items():
        # Check if this is a ViewSet
        if not view_name.endswith('ViewSet') and not any(base.endswith('ViewSet') for base in view_info.get('base_classes', [])):
            continue
        
        # Try to determine the model this viewset works with
        model_name = None
        
        # First try to extract from class name (UserViewSet -> User)
        clean_name = view_name.replace('ViewSet', '')
        if clean_name in models_data:
            model_name = clean_name
        
        # If not found, try to infer from serializer if available
        if not model_name and 'serializer_class' in view_info:
            serializer = view_info['serializer_class']
            # Extract model name from serializer (UserSerializer -> User)
            serializer_model = serializer.replace('Serializer', '')
            if serializer_model in models_data:
                model_name = serializer_model
        
        # Skip if we can't determine the model
        if not model_name:
            continue
            
        # Generate base path from model name (kebab-case pluralized)
        endpoint = model_name_to_endpoint(model_name)
        base_path = f"/api/{endpoint}"
        
        # Check if this path already exists in the OpenAPI spec
        path_exists = False
        for path in openapi_spec['paths'].keys():
            if path.startswith(base_path):
                path_exists = True
                break
        
        # Skip if paths for this model already exist
        if path_exists:
            continue
            
        # Add list endpoint (GET /api/users/)
        list_path = f"{base_path}/"
        list_operation = {
            "summary": f"List {model_name} objects",
            "operationId": f"list_{model_name.lower()}s",
            "responses": {
                "200": {
                    "description": "Successful operation",
                    "content": {
                        "application/json": {
                            "schema": {
                                "type": "array",
                                "items": {
                                    "$ref": f"#/components/schemas/{model_name}"
                                }
                            }
                        }
                    }
                },
                "401": {
                    "description": "Unauthorized"
                }
            },
            "security": [{"BearerAuth": []}]
        }
        synthetic_endpoints.append({
            'path': list_path,
            'method': 'get',
            'operation': list_operation
        })
        
        # Add create endpoint (POST /api/users/)
        create_operation = {
            "summary": f"Create {model_name} object",
            "operationId": f"create_{model_name.lower()}",
            "requestBody": {
                "content": {
                    "application/json": {
                        "schema": {
                            "$ref": f"#/components/schemas/{model_name}"
                        }
                    }
                },
                "required": True
            },
            "responses": {
                "201": {
                    "description": "Created",
                    "content": {
                        "application/json": {
                            "schema": {
                                "$ref": f"#/components/schemas/{model_name}"
                            }
                        }
                    }
                },
                "400": {
                    "description": "Bad request"
                },
                "401": {
                    "description": "Unauthorized"
                }
            },
            "security": [{"BearerAuth": []}]
        }
        synthetic_endpoints.append({
            'path': list_path,
            'method': 'post',
            'operation': create_operation
        })
        
        # Add detail endpoint (GET /api/users/{id}/)
        detail_path = f"{base_path}/{{id}}/"
        detail_operation = {
            "summary": f"Get {model_name} object",
            "operationId": f"get_{model_name.lower()}",
            "parameters": [
                {
                    "name": "id",
                    "in": "path",
                    "required": True,
                    "schema": {
                        "type": "integer",
                        "format": "int64"
                    }
                }
            ],
            "responses": {
                "200": {
                    "description": "Successful operation",
                    "content": {
                        "application/json": {
                            "schema": {
                                "$ref": f"#/components/schemas/{model_name}"
                            }
                        }
                    }
                },
                "404": {
                    "description": "Not found"
                },
                "401": {
                    "description": "Unauthorized"
                }
            },
            "security": [{"BearerAuth": []}]
        }
        synthetic_endpoints.append({
            'path': detail_path,
            'method': 'get',
            'operation': detail_operation
        })
        
        # Add update endpoint (PUT /api/users/{id}/)
        update_operation = {
            "summary": f"Update {model_name} object",
            "operationId": f"update_{model_name.lower()}",
            "parameters": [
                {
                    "name": "id",
                    "in": "path",
                    "required": True,
                    "schema": {
                        "type": "integer",
                        "format": "int64"
                    }
                }
            ],
            "requestBody": {
                "content": {
                    "application/json": {
                        "schema": {
                            "$ref": f"#/components/schemas/{model_name}"
                        }
                    }
                },
                "required": True
            },
            "responses": {
                "200": {
                    "description": "Successful operation",
                    "content": {
                        "application/json": {
                            "schema": {
                                "$ref": f"#/components/schemas/{model_name}"
                            }
                        }
                    }
                },
                "400": {
                    "description": "Bad request"
                },
                "404": {
                    "description": "Not found"
                },
                "401": {
                    "description": "Unauthorized"
                }
            },
            "security": [{"BearerAuth": []}]
        }
        synthetic_endpoints.append({
            'path': detail_path,
            'method': 'put',
            'operation': update_operation
        })
        
        # Add delete endpoint (DELETE /api/users/{id}/)
        delete_operation = {
            "summary": f"Delete {model_name} object",
            "operationId": f"delete_{model_name.lower()}",
            "parameters": [
                {
                    "name": "id",
                    "in": "path",
                    "required": True,
                    "schema": {
                        "type": "integer",
                        "format": "int64"
                    }
                }
            ],
            "responses": {
                "204": {
                    "description": "No content"
                },
                "404": {
                    "description": "Not found"
                },
                "401": {
                    "description": "Unauthorized"
                }
            },
            "security": [{"BearerAuth": []}]
        }
        synthetic_endpoints.append({
            'path': detail_path,
            'method': 'delete',
            'operation': delete_operation
        })
    
    return synthetic_endpoints


def find_urls_file(project_root: str) -> Optional[str]:
    """Find the main urls.py file in a Django project."""
    # First check for common project-level urls.py locations
    common_locations = [
        os.path.join(project_root, 'project', 'urls.py'),
        os.path.join(project_root, 'config', 'urls.py'),
        os.path.join(project_root, os.path.basename(project_root), 'urls.py')
    ]
    
    for location in common_locations:
        if os.path.exists(location):
            return location
    
    # Look for any urls.py file
    for root, _, files in os.walk(project_root):
        if 'urls.py' in files:
            return os.path.join(root, 'urls.py')
    
    return None


def convert_django_type_to_openapi(django_type):
    """Convert Django field type to OpenAPI type."""
    # Map of Django field types to OpenAPI types
    type_map = {
        'CharField': 'string',
        'TextField': 'string',
        'EmailField': 'string',
        'URLField': 'string',
        'SlugField': 'string',
        'UUIDField': 'string',
        'FileField': 'string',
        'ImageField': 'string',
        'BooleanField': 'boolean',
        'NullBooleanField': 'boolean',
        'IntegerField': 'integer',
        'PositiveIntegerField': 'integer',
        'PositiveSmallIntegerField': 'integer',
        'SmallIntegerField': 'integer',
        'BigIntegerField': 'integer',
        'FloatField': 'number',
        'DecimalField': 'number',
        'DateField': 'string',
        'TimeField': 'string',
        'DateTimeField': 'string',
        'DurationField': 'string',
        'JSONField': 'object',
        'ForeignKey': 'integer',
        'OneToOneField': 'integer',
        'ManyToManyField': 'array',
        'string': 'string',
        'integer': 'integer',
        'boolean': 'boolean',
        'number': 'number',
        'object': 'object',
        'array': 'array'
    }
    
    return type_map.get(django_type, 'string')


def get_openapi_format_for_field(field_type):
    """Get OpenAPI format for field type."""
    # Map of Django field types to OpenAPI formats
    format_map = {
        'DateField': 'date',
        'DateTimeField': 'date-time',
        'EmailField': 'email',
        'URLField': 'uri',
        'UUIDField': 'uuid',
        'IPAddressField': 'ipv4',
        'GenericIPAddressField': 'ipv4',
        'TimeField': 'time',
        'DecimalField': 'decimal'
    }
    
    return format_map.get(field_type)


def get_supported_methods_for_view(view_name, views_data):
    """Determine what HTTP methods a view supports."""
    # Default methods for REST views
    default_methods = ['GET', 'POST', 'PUT', 'DELETE']
    
    # Check if we have information about this view
    if views_data and view_name in views_data:
        methods = []
        view_info = views_data[view_name]
        
        # Check each common method type
        if 'methods' in view_info:
            for method_name, method_info in view_info['methods'].items():
                http_method = method_info.get('http_method', '').upper()
                if http_method:
                    methods.append(http_method)
        
        return methods if methods else default_methods
    
    # Check if this is a ViewSet by name
    if view_name.endswith('ViewSet'):
        return default_methods
    
    # For other views, assume GET only
    return ['GET']


def generate_operation_id(method, path, view_name):
    """Generate a unique operationId for a path."""
    if not view_name:
        view_name = ""
        
    # Clean up the view name
    # Extract the class name if view is like ViewClass.as_view()
    view_match = re.search(r'(\w+)(?:\.as_view\(\)|$|\W)', view_name)
    if view_match:
        view_class = view_match.group(1)
    else:
        view_class = view_name
        
    # Remove common view-related suffixes
    for suffix in ['ViewSet', 'View', 'APIView']:
        if view_class.endswith(suffix):
            view_class = view_class[:-len(suffix)]
            break
    
    # Use snake_case for the view class name if it's in camelCase
    # Convert UserProfile to user_profile
    view_class = re.sub(r'([a-z0-9])([A-Z])', r'\1_\2', view_class).lower()
    
    # Clean up the path
    # Remove any path parameters
    clean_path = re.sub(r'\{[^}]+\}', '', path)
    
    # Convert to snake_case path segments
    # e.g., /api/userProfile/items/ becomes api_user_profile_items
    clean_path = clean_path.strip('/')
    path_parts = clean_path.split('/')
    clean_parts = []
    
    for part in path_parts:
        # Skip empty parts
        if not part:
            continue
            
        # Convert camelCase to snake_case 
        part = re.sub(r'([a-z0-9])([A-Z])', r'\1_\2', part).lower()
        
        # Replace special characters with underscores
        part = re.sub(r'[^a-z0-9_]', '_', part)
        
        # Remove duplicate underscores
        part = re.sub(r'_+', '_', part)
        
        # Remove leading and trailing underscores
        part = part.strip('_')
        
        if part:
            clean_parts.append(part)
    
    path_str = '_'.join(clean_parts)
    
    # Combine method, view_class, and path
    parts = []
    if method:
        parts.append(method.lower())
    if view_class:
        parts.append(view_class)
    if path_str:
        parts.append(path_str)
    
    operation_id = '_'.join(filter(None, parts))
    
    # Make sure the ID doesn't start with a digit
    if operation_id and operation_id[0].isdigit():
        operation_id = 'op_' + operation_id
    
    # Make sure the ID isn't too long (max 64 characters)
    if len(operation_id) > 64:
        # Hash the path part to make it shorter
        import hashlib
        path_hash = hashlib.md5(path_str.encode()).hexdigest()[:8]
        
        # Use the first segment of the path
        first_segment = clean_parts[0] if clean_parts else ""
        
        # Reconstruct with a shorter path component
        parts_without_path = [p for p in parts if p != path_str]
        short_id = '_'.join(filter(None, parts_without_path + [first_segment, path_hash]))
        
        if len(short_id) <= 64:
            operation_id = short_id
        else:
            # Last resort: truncate
            operation_id = operation_id[:64]
    
    return operation_id


if __name__ == "__main__":
    main() 