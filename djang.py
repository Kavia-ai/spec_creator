#!/usr/bin/env python3
"""
Static (non‑executing) OpenAPI 3.0 generator for Django projects.

Features
--------
* Parses every *urls.py* with the Python AST – **no Django settings** and
  **no runtime imports** of your project code.
* Recursively follows `include()` chains **and** Django REST Framework
  `router.register()` patterns, even when the router is included via
  `path("api/", include(router.urls))`.
* Extracts all API endpoints including DRF ViewSet methods and function-based views
* Detects HTTP methods from ViewSets, class-based views, and @api_view decorators

Usage
-----
    python3 django_openapi_spec_creator.py \
        -e /path/to/project/project/urls.py \
        -o openapi.json \
        -r /path/to/project

CLI Flags
---------
-e / --endpoint      Root *file* (`urls.py`) **or** directory that contains it.
-o / --output        Destination JSON file.
-r / --project-root  (optional) Directory that holds **all** Django apps;
                     defaults to the current working directory.
"""

from __future__ import annotations

import argparse
import ast
import importlib.util
import json
import os
import re
import sys
from pathlib import Path
from typing import Dict, List, Set, Tuple, Optional, Any

from apispec import APISpec
from apispec.ext.marshmallow import MarshmallowPlugin


# ────────────────────────── helper utilities ──────────────────────────
def _ensure_on_syspath(folder: Path) -> None:
    """Add *folder* to sys.path once so importlib can resolve includes."""
    folder_str = str(folder)
    if folder_str not in sys.path:
        sys.path.insert(0, folder_str)


def _str(node: ast.AST) -> str | None:
    if isinstance(node, ast.Str):
        return node.s
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    return None


def _str_list(node: ast.AST) -> List[str]:
    if isinstance(node, (ast.List, ast.Tuple)):
        return [_str(el) for el in node.elts if _str(el)]
    return []


_slug = re.compile(r"<(?:int|str|slug|uuid|path):([^>]+)>")
_angle = re.compile(r"<([^>]+)>")


def _django_to_openapi(path: str) -> Tuple[str, List[Dict]]:
    """Convert Django path syntax to OpenAPI path and collect parameters."""
    openapi = _slug.sub(r"{\1}", path)
    openapi = _angle.sub(r"{\1}", openapi)
    params = [
        {
            "name": name,
            "in": "path",
            "required": True,
            "schema": {"type": "string"},
        }
        for name in re.findall(r"{([^}]+)}", openapi)
    ]
    return "/" + openapi.lstrip("/"), params


# DRF ViewSet standard actions mapping to HTTP methods
VIEWSET_ACTION_METHODS = {
    "list": ["get"],
    "create": ["post"],
    "retrieve": ["get"],
    "update": ["put"],
    "partial_update": ["patch"],
    "destroy": ["delete"],
}

# Default ViewSet actions based on base class - will be expanded in code
VIEWSET_BASE_ACTIONS = {
    "ModelViewSet": ["list", "create", "retrieve", "update", "partial_update", "destroy"],
    "ReadOnlyModelViewSet": ["list", "retrieve"],
    "ViewSet": [],  # Custom ViewSets need explicit action detection
}


# ───────────────────────── AST visitor ─────────────────────────
class URLVisitor(ast.NodeVisitor):
    """Walk one urls.py AST tree and collect routes, includes, and router prefixes."""

    def __init__(self, prefix: str = "") -> None:
        self.prefix = prefix
        self.routes: List[Dict] = []
        self.includes: List[Tuple[str, str]] = []  # (module, new_prefix)
        self.routers: Set[str] = set()             # variable names of routers
        self.router_base: dict[str, List[str]] = {}  # router var -> list[prefix]
        self.viewset_info: dict[str, Dict] = {}    # var name -> viewset info
        self.route_patterns: Set[str] = set()      # Keep track of found patterns to avoid duplicates

    # ─── handle assignments ───────────────────────────────────
    def visit_Assign(self, node: ast.Assign):  # type: ignore[override]
        # Detect "router = DefaultRouter()" etc.
        if isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Name):
            if node.value.func.id.endswith("Router"):
                for target in node.targets:
                    if isinstance(target, ast.Name):
                        self.routers.add(target.id)
                        self.router_base.setdefault(target.id, [""])

        # Detect "urlpatterns = [...]"
        if any(isinstance(t, ast.Name) and t.id == "urlpatterns" for t in node.targets):
            self._consume_iterable(node.value)
        self.generic_visit(node)

    # ─── handle augmented assignments (+=) ────────────────────
    def visit_AugAssign(self, node: ast.AugAssign):  # type: ignore[override]
        if isinstance(node.target, ast.Name) and node.target.id == "urlpatterns":
            self._consume_iterable(node.value)
        self.generic_visit(node)

    # ─── handle calls: extend, router.register, etc. ──────────
    def visit_Call(self, node: ast.Call):  # type: ignore[override]
        # urlpatterns.extend([...])
        if (
            isinstance(node.func, ast.Attribute)
            and node.func.attr == "extend"
            and isinstance(node.func.value, ast.Name)
            and node.func.value.id == "urlpatterns"
            and node.args
        ):
            self._consume_iterable(node.args[0])

        # router.register("users", UserViewSet, ...)
        if (
            isinstance(node.func, ast.Attribute)
            and node.func.attr == "register"
            and isinstance(node.func.value, ast.Name)
            and node.func.value.id in self.routers
        ):
            router_var = node.func.value.id
            if len(node.args) >= 2:
                prefix = _str(node.args[0]) if node.args else None
                viewset_var = None
                viewset_class = None
                
                # Get the ViewSet class name if possible
                if isinstance(node.args[1], ast.Name):
                    viewset_var = node.args[1].id
                    viewset_class = viewset_var
                elif isinstance(node.args[1], ast.Attribute):
                    viewset_class = node.args[1].attr
                
                # Look for basename kwarg
                basename = None
                for kw in node.keywords:
                    if kw.arg == "basename" and _str(kw.value):
                        basename = _str(kw.value)
                
                if prefix is not None:
                    # Determine the base actions this ViewSet might have
                    actions = []
                    if viewset_class:
                        for base, base_actions in VIEWSET_BASE_ACTIONS.items():
                            if base in viewset_class or viewset_class.endswith("ViewSet"):
                                actions.extend(base_actions)
                    
                    # If no actions detected from class name, assume it's a custom ViewSet
                    # with at least list and retrieve actions
                    if not actions:
                        actions = ["list", "retrieve"]
                    
                    for base in self.router_base.get(router_var, [""]):
                        # Add list/collection endpoints
                        list_path = self.prefix + base + prefix.rstrip("/") + "/"
                        for action in [a for a in actions if a in ["list", "create"]]:
                            op_id = f"{viewset_class or basename or 'viewset'}_{action}"
                            methods = VIEWSET_ACTION_METHODS.get(action, ["get"])
                            self._add_route(list_path, methods, op_id, f"{action} {prefix}")
                        
                        # Add detail endpoints with ID parameter
                        detail_path = list_path + "{id}/"
                        for action in [a for a in actions if a in ["retrieve", "update", "partial_update", "destroy"]]:
                            op_id = f"{viewset_class or basename or 'viewset'}_{action}"
                            methods = VIEWSET_ACTION_METHODS.get(action, ["get"])
                            self._add_route(detail_path, methods, op_id, f"{action} {prefix}")
        
        # Check for @api_view decorator
        if isinstance(node.func, ast.Name) and node.func.id == "api_view":
            if node.args:
                methods = _str_list(node.args[0])
                # Store these methods to be used when the decorated function is used in urlpatterns
                if hasattr(node, "parent_func") and isinstance(node.parent_func, ast.Name):
                    func_name = node.parent_func.id
                    self._store_api_view_methods(func_name, methods)
        
        self.generic_visit(node)

    # ─── helper to walk list/tuple urlpattern collections ────
    def _consume_iterable(self, node: ast.AST) -> None:
        if not isinstance(node, (ast.List, ast.Tuple)):
            return
        for elt in node.elts:
            self._handle_pattern_call(elt)

    # Track methods from @api_view decorator
    def _store_api_view_methods(self, func_name: str, methods: List[str]) -> None:
        self.viewset_info[func_name] = {"methods": [m.lower() for m in methods]}

    # Analyse single path()/re_path() call
    def _handle_pattern_call(self, node: ast.AST) -> None:
        if not isinstance(node, ast.Call):
            return
        func_name = ""
        if isinstance(node.func, ast.Name):
            func_name = node.func.id
        elif isinstance(node.func, ast.Attribute):
            func_name = node.func.attr
        if func_name not in {"path", "re_path"}:
            return

        # First positional arg – raw Django path pattern
        if not node.args:
            return
        raw_path = _str(node.args[0])
        if raw_path is None:
            return
        full_raw = self.prefix + raw_path

        # include(...) ?
        if (
            len(node.args) > 1
            and isinstance(node.args[1], ast.Call)
            and isinstance(node.args[1].func, ast.Name)
            and node.args[1].func.id == "include"
        ):
            include_arg = node.args[1].args[0] if node.args[1].args else None
            # Case A: include("app.urls") – string literal
            mod = _str(include_arg)
            if mod:
                self.includes.append((mod, full_raw))
                return
            # Case B: include(router.urls)
            if (
                isinstance(include_arg, ast.Attribute)
                and include_arg.attr == "urls"
                and isinstance(include_arg.value, ast.Name)
                and include_arg.value.id in self.routers
            ):
                self.router_base.setdefault(include_arg.value.id, [""]).append(raw_path)
                return
            return

        # Normal endpoint - check view function/class
        view_arg = node.args[1] if len(node.args) > 1 else None
        view_name = None
        if isinstance(view_arg, ast.Name):
            view_name = view_arg.id
        elif isinstance(view_arg, ast.Attribute):
            view_name = view_arg.attr
        
        name_kw = next((kw for kw in node.keywords if kw.arg == "name"), None)
        op_id = _str(name_kw.value) if name_kw else f"op_{len(self.routes)}"
        if view_name:
            op_id = view_name

        # Check for methods from @api_view decorator
        methods = []
        if view_name and view_name in self.viewset_info:
            methods = self.viewset_info[view_name].get("methods", [])
        
        # Check for methods kwarg in as_view() for CBVs
        if (
            isinstance(view_arg, ast.Call) 
            and isinstance(view_arg.func, ast.Attribute) 
            and view_arg.func.attr == "as_view"
        ):
            http_method_kw = next((kw for kw in view_arg.keywords if kw.arg == "http_method_names"), None)
            if http_method_kw:
                methods = _str_list(http_method_kw.value)
            
            # Check for methods in the as_view({}) method mapping
            methods_dict = next((arg for arg in view_arg.args if isinstance(arg, (ast.Dict))), None)
            if methods_dict and hasattr(methods_dict, 'keys') and methods_dict.keys:
                # Extract HTTP methods from the dictionary keys
                methods.extend([_str(k).lower() for k in methods_dict.keys if _str(k)])

        # If no methods detected, fall back to 'methods' kwarg or default to GET
        if not methods:
            methods_kw = next((kw for kw in node.keywords if kw.arg == "methods"), None)
            methods = [m.lower() for m in _str_list(methods_kw.value)] if methods_kw else ["get"]

        # Add the route
        self._add_route(full_raw, methods, op_id, f"{methods} {raw_path}")

    # ─── store a route record ────────────────────────────────
    def _add_route(self, raw_path: str, methods: List[str], op_id: str, description: Optional[str] = None) -> None:
        openapi_path, params = _django_to_openapi(raw_path)
        
        # Skip if we've already registered this exact route (to avoid duplicates from inference)
        path_method_key = f"{openapi_path}:{','.join(sorted(methods))}"
        if path_method_key in self.route_patterns:
            return
        self.route_patterns.add(path_method_key)
        
        for m in methods:
            self.routes.append(
                {
                    "path": openapi_path,
                    "method": m,
                    "operation_id": f"{op_id}_{m}" if m != "get" else op_id,
                    "description": description or f"{m.upper()} {raw_path}",
                    "parameters": params,
                }
            )


# ─── Decorator visitor to detect @api_view ───────────────────
class DecoratorVisitor(ast.NodeVisitor):
    """Walk AST tree to find function decorators, especially @api_view."""
    
    def __init__(self) -> None:
        self.api_views: Dict[str, List[str]] = {}  # function name -> methods
    
    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:  # type: ignore[override]
        for decorator in node.decorator_list:
            if isinstance(decorator, ast.Call) and isinstance(decorator.func, ast.Name):
                if decorator.func.id == "api_view" and decorator.args:
                    methods = _str_list(decorator.args[0])
                    if methods:
                        self.api_views[node.name] = [m.lower() for m in methods]
                # Add parent function reference to help in the main visitor
                decorator.parent_func = ast.Name(id=node.name)
        self.generic_visit(node)


# ─── ViewSet analysis visitor ───────────────────────────────
class ViewSetVisitor(ast.NodeVisitor):
    """Walk AST tree to find ViewSet classes and their actions."""
    
    def __init__(self) -> None:
        self.viewsets: Dict[str, Dict[str, Any]] = {}  # class name -> info
    
    def visit_ClassDef(self, node: ast.ClassDef) -> None:  # type: ignore[override]
        # Check if this is potentially a ViewSet
        is_viewset = False
        for base in node.bases:
            if isinstance(base, ast.Name) and "ViewSet" in base.id:
                is_viewset = True
            elif isinstance(base, ast.Attribute) and "ViewSet" in base.attr:
                is_viewset = True
        
        if is_viewset:
            viewset_info = {
                "actions": [],
                "detail_actions": [],
                "custom_methods": {}
            }
            
            # Look for action decorators
            for item in node.body:
                if isinstance(item, ast.FunctionDef):
                    action_detail = None
                    action_methods = []
                    
                    for decorator in item.decorator_list:
                        if (isinstance(decorator, ast.Call) and 
                            isinstance(decorator.func, ast.Name) and 
                            decorator.func.id == "action"):
                            
                            # Check detail kwarg
                            for kw in decorator.keywords:
                                if kw.arg == "detail" and hasattr(kw.value, "value"):
                                    action_detail = kw.value.value
                                if kw.arg == "methods":
                                    action_methods = _str_list(kw.value)
                            
                            # Store the action info
                            if action_detail is not None:
                                if action_detail:
                                    viewset_info["detail_actions"].append(item.name)
                                else:
                                    viewset_info["actions"].append(item.name)
                                
                                if action_methods:
                                    viewset_info["custom_methods"][item.name] = [m.lower() for m in action_methods]
            
            self.viewsets[node.name] = viewset_info
        
        self.generic_visit(node)


# ───────────────────────── include() recursion ─────────────────────────
def _find_urls_in_app_dir(app_name: str, project_root: Path) -> Path | None:
    """Try to find the urls.py file in various common Django app structures."""
    # Check these common patterns:
    # 1. app/urls.py
    # 2. app/app/urls.py
    # 3. apps/app/urls.py
    # 4. project_root/app/urls.py
    
    patterns = [
        Path(app_name.replace('.', os.sep)) / "urls.py",
        Path(app_name.split('.')[0]) / app_name.split('.')[-1] / "urls.py",
        Path("apps") / app_name.replace('.', os.sep) / "urls.py",
        project_root / app_name.replace('.', os.sep) / "urls.py",
        project_root / "apps" / app_name.replace('.', os.sep) / "urls.py",
    ]
    
    for pattern in patterns:
        if pattern.exists():
            return pattern
    
    # If the app is directly in sys.path, try to find it
    for path in sys.path:
        app_path = Path(path) / app_name.replace('.', os.sep) / "urls.py"
        if app_path.exists():
            return app_path
    
    return None


def _file_from_module(mod: str, project_root: Path) -> Path | None:
    """Translate dotted module path to an absolute file path."""
    # First try the direct path
    candidate = project_root.joinpath(*mod.split(".")).with_suffix(".py")
    if candidate.exists():
        return candidate
    
    # Then try to find it in common app structures
    app_urls = _find_urls_in_app_dir(mod, project_root) 
    if app_urls:
        return app_urls
    
    # Finally, try importlib as a last resort
    try:
        spec = importlib.util.find_spec(mod)
        if spec and spec.origin and spec.origin.endswith(".py"):
            return Path(spec.origin)
    except ModuleNotFoundError:
        pass
    
    return None


def _walk(urls_file: Path, project_root: Path,
          prefix: str = "", seen: Set[Path] | None = None,
          collect_viewsets: bool = True) -> List[Dict]:
    if seen is None:
        seen = set()
    urls_file = urls_file.resolve()
    if urls_file in seen or not urls_file.exists():
        return []
    seen.add(urls_file)

    try:
        content = urls_file.read_text(encoding="utf-8")
        tree = ast.parse(content)
    except Exception as exc:  # pragma: no cover
        print(f"⚠️  Could not parse {urls_file}: {exc}", file=sys.stderr)
        return []

    # First scan for @api_view decorators
    decorator_visitor = DecoratorVisitor()
    decorator_visitor.visit(tree)
    
    # If requested, look for ViewSet classes to extract more info
    viewset_info = {}
    if collect_viewsets:
        viewset_visitor = ViewSetVisitor()
        viewset_visitor.visit(tree)
        viewset_info = viewset_visitor.viewsets
    
    visitor = URLVisitor(prefix)
    # Add info from decorators
    for func_name, methods in decorator_visitor.api_views.items():
        visitor._store_api_view_methods(func_name, methods)
    
    visitor.visit(tree)

    routes = list(visitor.routes)
    for mod, new_pref in visitor.includes:
        sub = _file_from_module(mod, project_root)
        if sub:
            routes.extend(_walk(sub, project_root, new_pref, seen, collect_viewsets))
        else:
            print(f"⚠️  Could not resolve module '{mod}' - skipping")
    return routes


# ───────────────────────── spec assembly ─────────────────────
def _build_spec(routes: List[Dict]) -> Dict:
    spec = APISpec(
        title="DjangoApp",
        version="1.0.0",
        openapi_version="3.0.2",
        plugins=[MarshmallowPlugin()],
    )
    
    # Sort routes for better organization
    routes.sort(key=lambda r: (r["path"], r["method"]))
    
    # Remove any duplicate routes (same path/method combo)
    seen_routes = set()
    unique_routes = []
    for r in routes:
        key = f"{r['path']}:{r['method']}"
        if key not in seen_routes:
            seen_routes.add(key)
            unique_routes.append(r)
    
    for r in unique_routes:
        operation = {
            "operationId": r["operation_id"],
            "description": r["description"],
            "responses": {"200": {"description": "Successful response"}},
        }
        if r["parameters"]:
            operation["parameters"] = r["parameters"]
        spec.path(path=r["path"], operations={r["method"]: operation})

    spec_dict = spec.to_dict()
    spec_dict["servers"] = [
        {"url": "/proxy/django", "description": "API with base path"}
    ]
    return spec_dict


# ───────────────────────── CLI entry ─────────────────────────
def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate an OpenAPI 3.0 spec from Django URL‑confs (static analysis)"
    )
    parser.add_argument(
        "-e", "--endpoint", required=True,
        help="Path to root urls.py file **or** directory that contains it"
    )
    parser.add_argument(
        "-o", "--output", required=True,
        help="Output JSON file path"
    )
    parser.add_argument(
        "-r", "--project-root", default=".",
        help="Project root that holds all apps (default: cwd)"
    )
    parser.add_argument(
        "--debug", action="store_true",
        help="Enable debug output"
    )
    args = parser.parse_args()

    entry_path = Path(args.endpoint).resolve()
    if entry_path.is_dir():         # Allow pointing at a folder
        candidate = entry_path / "urls.py"
        if not candidate.exists():
            sys.exit("❌  Directory given but no urls.py found inside")
        entry_path = candidate

    if not entry_path.exists():
        sys.exit(f"❌  '{entry_path}' not found")

    project_root = Path(args.project_root).resolve()
    _ensure_on_syspath(project_root)
    
    # Add common Django app directories to sys.path
    for possible_path in [project_root, project_root.parent, project_root / "apps"]:
        _ensure_on_syspath(possible_path)

    print("🔍  Statically scanning Django URL‑confs …")
    
    # Debug: print all sys.path entries if debug is enabled
    if args.debug:
        print("Debug - sys.path entries:")
        for p in sys.path:
            print(f"  - {p}")
    
    routes = _walk(entry_path, project_root)
    print(f"✅  Found {len(routes)} routes")

    spec = _build_spec(routes)

    output_path = Path(args.output).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(spec, indent=2), encoding="utf-8")
    print(f"📄  OpenAPI spec written to {output_path}")


if __name__ == "__main__":  # pragma: no cover
    main()
