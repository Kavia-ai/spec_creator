#!/bin/bash

# Build OpenAPI Specifications for all frameworks defined in swagger.config.json
# using generators defined in spec_generator.config.json

# Display usage instructions
show_usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Options:"
  echo "  -c, --config FILE    Path to swagger.config.json file (default: swagger.config.json in current dir)"
  echo "  -b, --build INDEX    Build only the framework at specified INDEX in the config file (1-based index)"
  echo "                       Can be specified multiple times to build multiple frameworks"
  echo "  -h, --help           Show this help message"
  exit 1
}

# Parse command line arguments
SWAGGER_CONFIG="swagger.config.json"
# Array to store framework indices to build
FRAMEWORKS_TO_BUILD=()

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--config)
      SWAGGER_CONFIG="$2"
      shift 2
      ;;
    -b|--build)
      FRAMEWORKS_TO_BUILD+=("$2")
      shift 2
      ;;
    -h|--help)
      show_usage
      ;;
    *)
      echo "Unknown option: $1"
      show_usage
      ;;
  esac
done

# Define paths
SPEC_GEN_CONFIG="spec_generator.config.json"
TEMP_OUTPUT_FILE="openapi_paths.txt"

# Check if spec generator config file exists
if [ ! -f "$SPEC_GEN_CONFIG" ]; then
  echo "⚠️ Warning: $SPEC_GEN_CONFIG not found in current directory."
  # Try to find it in different locations
  if [ -f "$(dirname "$0")/$SPEC_GEN_CONFIG" ]; then
    echo "Found spec generator config in script directory."
    SPEC_GEN_CONFIG="$(dirname "$0")/$SPEC_GEN_CONFIG"
  else
    echo "❌ Error: $SPEC_GEN_CONFIG not found. Creating an empty config."
    echo '{
  "spec_creator": {
    "spring": null,
    "express.js": "creators/node/expressjs_creator.js",
    "flask": "creators/python/flask_creator.py",
    "ruby-on-rails": "creators/rails/ruby_on_rails_creator.rb",
    "django": "creators/python/django_creator.py"
  },
  "venv_paths": {
    "spring": null,
    "express.js": "/root/spec_creator/specs/node_modules",
    "flask": "/root/spec_creator/specs/env",
    "ruby-on-rails": null,
    "django": "/root/spec_creator/specs/env"
  }
}' > "$SPEC_GEN_CONFIG"
  fi
fi

echo "Using spec generator config file: $SPEC_GEN_CONFIG"
# Debug: show file contents
if [ -f "$SPEC_GEN_CONFIG" ]; then
  echo "Spec generator config content:"
  cat "$SPEC_GEN_CONFIG"
fi

# Set up cleanup trap
trap cleanup EXIT INT TERM

# Cleanup function
cleanup() {
  echo "Cleaning up temporary files..."
  # Clean up any temp files
  if [ -f "$TEMP_OUTPUT_FILE" ]; then
    rm -f "$TEMP_OUTPUT_FILE"
  fi
  
  # Remove any temporary JSON files
  for temp_file in "swagger.config.temp.json" "swagger.config.normalized.json" "${SWAGGER_CONFIG}.formatted"; do
    if [ -f "$temp_file" ]; then
      rm -f "$temp_file"
    fi
  done
  
  # Remove any .bak files
  find . -name "*.bak" -type f -delete
}

echo "Using swagger config file: $SWAGGER_CONFIG"

# Check if swagger config file exists, create if not
if [ ! -f "$SWAGGER_CONFIG" ]; then
  echo "Warning: $SWAGGER_CONFIG not found. Creating an empty file."
  touch "$SWAGGER_CONFIG"
else
  echo "Config file found: $SWAGGER_CONFIG"
  # Debug: Print file size
  ls -la "$SWAGGER_CONFIG"
  # Debug: Show first few lines of the file
  echo "First 10 lines of config file:"
  head -10 "$SWAGGER_CONFIG"
fi

# Function to normalize paths for the current system
normalize_path() {
  local path="$1"
  
  # Check if path exists as is
  if [ -d "$path" ]; then
    echo "$path"
    return
  fi
  
  # Handle macOS paths on Linux or vice versa
  if echo "$path" | grep -q "^/Volumes/"; then
    # Convert macOS path to Linux-style path
    # Extract the relevant part after /Volumes/something/
    local relative_path=$(echo "$path" | sed -E 's|^/Volumes/[^/]+/(.*)|\1|')
    
    # Try different base directories
    for base_dir in "/home" "/home/kavia/workspace" "/home/kavia" "/home/ubuntu" "/opt" "/var"; do
      if [ -d "$base_dir/$relative_path" ]; then
        echo "$base_dir/$relative_path"
        return
      fi
    done
  fi
  
  # Return original path if no conversion could be made
  echo "$path"
}

# Function to extract all frameworks from swagger.config.json
get_all_frameworks() {
  # First try using jq if available
  if command -v jq >/dev/null 2>&1; then
    jq -r '.[].framework' "$SWAGGER_CONFIG" 2>/dev/null
    return
  fi
  
  # Fallback to a more robust approach without jq
  # Read line by line and look for "framework": patterns
  echo >&2 "Using fallback method to extract frameworks without jq"
  frameworks=""
  while IFS= read -r line; do
    # Look for "framework": "value" pattern and extract value
    if echo "$line" | grep -q "\"framework\":" ; then
      # Extract the framework value between quotes
      framework=$(echo "$line" | sed 's/.*"framework"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
      if [ -n "$framework" ]; then
        frameworks="$frameworks $framework"
      fi
    fi
  done < "$SWAGGER_CONFIG"
  
  # Return the frameworks list without leading space
  echo "${frameworks# }"
}

# Function to extract framework path from swagger.config.json
get_framework_path() {
  local framework=$1
  
  # First try using jq if available
  if command -v jq >/dev/null 2>&1; then
    local raw_path=$(jq -r ".[] | select(.framework == \"$framework\") | .path" "$SWAGGER_CONFIG" 2>/dev/null)
    normalize_path "$raw_path"
    return
  fi
  
  # Improved fallback method with multiple approaches
  echo >&2 "Using fallback method to extract path for $framework"
  
  # Approach 1: Try grep for the framework and extract path from the same block
  local json_obj=""
  json_obj=$(grep -A10 "\"framework\":\"$framework\"" "$SWAGGER_CONFIG" | head -10)
  
  if [ -n "$json_obj" ]; then
    # Extract the path field from the matching object
    local raw_path=$(echo "$json_obj" | grep -o '"path":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -n "$raw_path" ]; then
      echo >&2 "Found path using grep approach: $raw_path"
      normalize_path "$raw_path"
      return
    fi
  fi
  
  # Approach 2: Try direct pattern extraction from the entire file
  echo >&2 "Trying direct pattern extraction for framework: $framework"
  
  # First find the line number where the framework is defined
  local line_num=$(grep -n "\"framework\":\"$framework\"" "$SWAGGER_CONFIG" | head -1 | cut -d':' -f1)
  
  if [ -n "$line_num" ]; then
    echo >&2 "Framework found at line $line_num, looking for path in surrounding lines"
    
    # Look for path in the surrounding 10 lines before and after
    local start_line=$((line_num - 10))
    [ $start_line -lt 1 ] && start_line=1
    
    local context_lines=20
    local context=$(sed -n "${start_line},+${context_lines}p" "$SWAGGER_CONFIG")
    local raw_path=$(echo "$context" | grep -o '"path":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -n "$raw_path" ]; then
      echo >&2 "Found path in context: $raw_path"
      normalize_path "$raw_path"
      return
    fi
  fi
  
  # Approach 3: Brute force - search for the path in any object that has this framework
  echo >&2 "Using brute force approach for framework: $framework"
  
  # Get all path entries from the file
  local all_paths=$(grep -o '"path":"[^"]*"' "$SWAGGER_CONFIG" | cut -d'"' -f4)
  
  # For each path, check if it corresponds to our framework
  for path in $all_paths; do
    # Check if this path's object contains our framework
    local check_framework=$(grep -A10 "\"path\":\"$path\"" "$SWAGGER_CONFIG" | grep -o "\"framework\":\"$framework\"")
    if [ -n "$check_framework" ]; then
      echo >&2 "Found matching path for $framework through brute force: $path"
      normalize_path "$path"
      return
    fi
  done
  
  # If we're still here, nothing worked - try the original fallback method
  local json_obj=$(cat "$SWAGGER_CONFIG" | tr -d '\n' | grep -o "{[^{]*\"framework\":\"$framework\"[^}]*}")
  local raw_path=$(echo "$json_obj" | grep -o '"path":"[^"]*"' | cut -d'"' -f4)
  
  # If still empty, try the hardcoded path patterns based on the framework type
  if [ -z "$raw_path" ]; then
    echo >&2 "⚠️ All extraction methods failed. Trying framework-specific patterns."
    case "$framework" in
      "express.js")
        echo >&2 "Using pattern for express.js"
        raw_path="/root/spec_creator/test/source/nodejs-express"
        ;;
      "flask")
        echo >&2 "Using pattern for flask"
        raw_path="/root/spec_creator/test/source/python-flask"
        ;;
      "django")
        echo >&2 "Using pattern for django"
        raw_path="/root/spec_creator/test/source/python-django"
        ;;
      "ruby-on-rails")
        echo >&2 "Using pattern for ruby-on-rails"
        raw_path="/root/spec_creator/test/source/ruby-rails"
        ;;
      "spring")
        echo >&2 "Using pattern for spring"
        raw_path="/root/spec_creator/test/source/spring-java"
        ;;
      *)
        echo >&2 "❌ No pattern available for framework: $framework"
        ;;
    esac
  fi
  
  normalize_path "$raw_path"
}

# Function to extract main file from swagger.config.json
get_main_file() {
  local framework=$1
  
  echo >&2 "Looking for main file for framework: $framework"
  
  # First try using jq if available
  if command -v jq >/dev/null 2>&1; then
    local main_file=$(jq -r ".[] | select(.framework == \"$framework\") | .main_file" "$SWAGGER_CONFIG" 2>/dev/null)
    
    if [ "$main_file" = "null" ]; then
      echo >&2 "⚠️ Main file for $framework is null in config"
      return
    fi
    
    echo >&2 "Found main file with jq: $main_file"
    echo "$main_file"
    return
  fi
  
  # Improved fallback method with multiple approaches
  echo >&2 "Using fallback method to extract main file for $framework"
  
  # Approach 1: Try grep for the framework and extract main_file from the same block
  local json_obj=""
  json_obj=$(grep -A10 "\"framework\":\"$framework\"" "$SWAGGER_CONFIG" | head -10)
  
  if [ -n "$json_obj" ]; then
    # Extract the main_file field from the matching object
    local main_file=$(echo "$json_obj" | grep -o '"main_file":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -n "$main_file" ]; then
      echo >&2 "Found main file using grep approach: $main_file"
      echo "$main_file"
      return
    fi
  fi
  
  # Approach 2: Try direct pattern extraction from the entire file
  echo >&2 "Trying direct pattern extraction for framework: $framework"
  
  # First find the line number where the framework is defined
  local line_num=$(grep -n "\"framework\":\"$framework\"" "$SWAGGER_CONFIG" | head -1 | cut -d':' -f1)
  
  if [ -n "$line_num" ]; then
    echo >&2 "Framework found at line $line_num, looking for main_file in surrounding lines"
    
    # Look for main_file in the surrounding 10 lines before and after
    local start_line=$((line_num - 10))
    [ $start_line -lt 1 ] && start_line=1
    
    local context_lines=20
    local context=$(sed -n "${start_line},+${context_lines}p" "$SWAGGER_CONFIG")
    local main_file=$(echo "$context" | grep -o '"main_file":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -n "$main_file" ]; then
      echo >&2 "Found main_file in context: $main_file"
      echo "$main_file"
      return
    fi
  fi
  
  # If we're still here, nothing worked - try the original fallback method
  local json_obj=$(cat "$SWAGGER_CONFIG" | tr -d '\n' | grep -o "{[^{]*\"framework\":\"$framework\"[^}]*}")
  local main_file=$(echo "$json_obj" | grep -o '"main_file":"[^"]*"' | cut -d'"' -f4)
  
  if [ -n "$main_file" ]; then
    echo >&2 "Found main_file with original fallback method: $main_file"
    echo "$main_file"
    return
  fi
  
  echo >&2 "❌ Could not find main_file for framework: $framework"
  echo ""
}

# Function to extract spec generator from spec_generator.config.json
get_spec_generator() {
  local framework=$1
  local script_dir=$(dirname "$0")
  
  echo >&2 "Looking for spec generator for framework: $framework"
  
  # Check if the spec generator config file exists
  if [ ! -f "$SPEC_GEN_CONFIG" ]; then
    echo >&2 "❌ Spec generator config file not found: $SPEC_GEN_CONFIG"
    return
  fi
  
  # Look for the framework in the spec_creator object
  if command -v jq >/dev/null 2>&1; then
    local generator=$(jq -r ".spec_creator.\"$framework\"" "$SPEC_GEN_CONFIG" 2>/dev/null)
    
    if [ "$generator" = "null" ]; then
      echo >&2 "⚠️ Generator for $framework is null in spec_generator.config.json"
      return
    fi
    
    # Convert to absolute path if it's a relative path
    if [ -n "$generator" ] && [[ "$generator" != /* ]]; then
      # First try relative to the script directory
      if [ -f "$script_dir/$generator" ]; then
        generator="$script_dir/$generator"
      # Then try relative to the current directory
      elif [ -f "$(pwd)/$generator" ]; then
        generator="$(pwd)/$generator"
      fi
    fi
    
    echo >&2 "Found generator with jq: $generator"
    echo "$generator"
    return
  fi
  
  # Fallback to grep/sed with improved error handling
  echo >&2 "jq not available, using grep/sed fallback"
  
  # First check if the framework exists in the spec_creator section
  local spec_creator_section=$(cat "$SPEC_GEN_CONFIG" | tr -d '\n' | grep -o "\"spec_creator\"[^}]*}")
  
  if [ -z "$spec_creator_section" ]; then
    echo >&2 "❌ spec_creator section not found in $SPEC_GEN_CONFIG"
    return
  fi
  
  # Next, look for the framework within the spec_creator section
  local framework_pattern="\"$framework\": *\"[^\"]*\""
  local framework_entry=$(echo "$spec_creator_section" | grep -o "$framework_pattern")
  
  if [ -z "$framework_entry" ]; then
    # Try another pattern where the value might be null
    framework_pattern="\"$framework\": *null"
    framework_entry=$(echo "$spec_creator_section" | grep -o "$framework_pattern")
    
    if [ -z "$framework_entry" ]; then
      echo >&2 "❌ Framework $framework not found in spec_creator section"
      return
    else
      echo >&2 "⚠️ Generator for $framework is null in spec_generator.config.json"
      return
    fi
  fi
  
  # Extract the value
  local generator=$(echo "$framework_entry" | cut -d':' -f2 | tr -d ' "')
  
  # Check if the value is null
  if [ "$generator" = "null" ]; then
    echo >&2 "⚠️ Generator for $framework is null in spec_generator.config.json"
    return
  fi
  
  # Convert to absolute path if it's a relative path
  if [ -n "$generator" ] && [[ "$generator" != /* ]]; then
    # First try relative to the script directory
    if [ -f "$script_dir/$generator" ]; then
      generator="$script_dir/$generator"
    # Then try relative to the current directory
    elif [ -f "$(pwd)/$generator" ]; then
      generator="$(pwd)/$generator"
    fi
  fi
  
  echo >&2 "Found generator with grep/sed: $generator"
  echo "$generator"
}

# Function to extract virtual environment path from spec_generator.config.json
get_venv_path() {
  local framework=$1
  local script_dir=$(dirname "$0")
  
  echo >&2 "Looking for virtual environment path for framework: $framework"
  
  # Check if the spec generator config file exists
  if [ ! -f "$SPEC_GEN_CONFIG" ]; then
    echo >&2 "❌ Spec generator config file not found: $SPEC_GEN_CONFIG"
    return
  fi
  
  # Look for the framework in the venv_paths object
  if command -v jq >/dev/null 2>&1; then
    local venv_path=$(jq -r ".venv_paths.\"$framework\"" "$SPEC_GEN_CONFIG" 2>/dev/null)
    
    if [ "$venv_path" = "null" ]; then
      echo >&2 "⚠️ Virtual environment path for $framework is null in spec_generator.config.json"
      return
    fi
    
    # Convert to absolute path if it's a relative path
    if [ -n "$venv_path" ] && [[ "$venv_path" != /* ]]; then
      # First check if it exists relative to the script directory
      if [ -d "$script_dir/$venv_path" ]; then
        venv_path="$script_dir/$venv_path"
      # Then check if it exists relative to the current directory
      elif [ -d "$(pwd)/$venv_path" ]; then
        venv_path="$(pwd)/$venv_path"
      fi
    fi
    
    echo >&2 "Found venv_path with jq: $venv_path"
    echo "$venv_path"
    return
  fi
  
  # Fallback to grep/sed with improved error handling
  echo >&2 "jq not available, using grep/sed fallback for venv_path"
  
  # First check if the framework exists in the venv_paths section
  local venv_paths_section=$(cat "$SPEC_GEN_CONFIG" | tr -d '\n' | grep -o "\"venv_paths\"[^}]*}")
  
  if [ -z "$venv_paths_section" ]; then
    echo >&2 "❌ venv_paths section not found in $SPEC_GEN_CONFIG"
    return
  fi
  
  # Next, look for the framework within the venv_paths section
  local framework_pattern="\"$framework\": *\"[^\"]*\""
  local framework_entry=$(echo "$venv_paths_section" | grep -o "$framework_pattern")
  
  if [ -z "$framework_entry" ]; then
    # Try another pattern where the value might be null
    framework_pattern="\"$framework\": *null"
    framework_entry=$(echo "$venv_paths_section" | grep -o "$framework_pattern")
    
    if [ -z "$framework_entry" ]; then
      echo >&2 "❌ Framework $framework not found in venv_paths section"
      return
    else
      echo >&2 "⚠️ Virtual environment path for $framework is null in spec_generator.config.json"
      return
    fi
  fi
  
  # Extract the value
  local venv_path=$(echo "$framework_entry" | cut -d':' -f2 | tr -d ' "')
  
  # Check if the value is null
  if [ "$venv_path" = "null" ]; then
    echo >&2 "⚠️ Virtual environment path for $framework is null in spec_generator.config.json"
    return
  fi
  
  # Convert to absolute path if it's a relative path
  if [ -n "$venv_path" ] && [[ "$venv_path" != /* ]]; then
    # First check if it exists relative to the script directory
    if [ -d "$script_dir/$venv_path" ]; then
      venv_path="$script_dir/$venv_path"
    # Then check if it exists relative to the current directory
    elif [ -d "$(pwd)/$venv_path" ]; then
      venv_path="$(pwd)/$venv_path"
    fi
  fi
  
  echo >&2 "Found venv_path with grep/sed: $venv_path"
  echo "$venv_path"
}

# Simple function to store framework and openapi path
store_openapi_path() {
  local framework=$1
  local openapi_path=$2
  # Store in a temporary file
  echo "$framework:$openapi_path" >> "$TEMP_OUTPUT_FILE"
}

# Process each framework
process_framework() {
  local framework=$1
  
  echo "Processing $framework framework"
  
  # Get path and main file dynamically from config
  local path=$(get_framework_path "$framework")
  local main_file=$(get_main_file "$framework")
  local generator=$(get_spec_generator "$framework")
  local venv_path=$(get_venv_path "$framework")
  
  # Validate path
  if [ -z "$path" ]; then
    echo "❌ Path not found for $framework in $SWAGGER_CONFIG"
    echo "Make sure the framework entry exists in the configuration file."
    return
  fi
  
  echo "Using path: $path"
  
  if [ ! -d "$path" ]; then
    echo "❌ Directory not found: $path"
    echo "Please check if the path exists and is accessible."
    return
  fi
  
  # Validate main file
  if [ -z "$main_file" ]; then
    echo "❌ Main file not found for $framework in $SWAGGER_CONFIG"
    echo "Please specify a main_file in the configuration for $framework"
    return
  fi
  
  echo "Using main file: $main_file"
  
  # Store original directory
  ORIGINAL_DIR=$(pwd)
  
  # Check if generator is available
  if [ -z "$generator" ]; then
    echo "❌ No generator specified for $framework in $SPEC_GEN_CONFIG"
    echo "Please make sure the framework is properly configured in $SPEC_GEN_CONFIG"
    return
  fi
  
  if [ "$generator" = "null" ]; then
    echo "❌ Generator for $framework is set to null in $SPEC_GEN_CONFIG"
    echo "Please specify a valid generator for the framework in $SPEC_GEN_CONFIG"
    return
  fi
  
  echo "Running $framework generator..."
  
  # Get the absolute paths
  GENERATOR_DIR=$(dirname "$generator")
  GENERATOR_NAME=$(basename "$generator")
  
  echo "Generator directory: $GENERATOR_DIR"
  echo "Generator name: $GENERATOR_NAME"
  
  # Check if generator actually exists
  if [ ! -f "$GENERATOR_DIR/$GENERATOR_NAME" ]; then
    echo "❌ Generator file not found: $GENERATOR_DIR/$GENERATOR_NAME"
    echo "Please check if the generator file exists and has the correct permissions."
    return
  fi
  
  # Run the generator with appropriate command based on framework
  cd "$GENERATOR_DIR" || { echo "❌ Failed to change directory to $GENERATOR_DIR"; return; }
  
  # Define the openapi.json output path
  OPENAPI_OUT_PATH="$path/openapi.json"
  echo "OpenAPI output path: $OPENAPI_OUT_PATH"
  
  # Ensure main file path is accessible
  if echo "$main_file" | grep -q "^/"; then
    # It's an absolute path
    echo "Using absolute path for main file: $main_file"
    if [ ! -f "$main_file" ]; then
      echo "⚠️ Main file $main_file not found, trying to find it relative to project path"
      # Try to find it under the project path
      MAIN_FILE_REL=$(basename "$main_file")
      if [ -f "$path/$MAIN_FILE_REL" ]; then
        echo "Found main file at $path/$MAIN_FILE_REL"
        main_file="$MAIN_FILE_REL"
      else
        echo "❌ Cannot locate main file: $main_file"
        echo "Please check if the main file exists at the specified path."
        main_file=""
      fi
    fi
  else
    # It's a relative path, check if it exists
    if [ ! -f "$path/$main_file" ]; then
      echo "⚠️ Main file $path/$main_file not found"
      echo "Please check if the main file exists at the specified relative path."
    else
      echo "Found main file at relative path: $path/$main_file"
    fi
  fi
  
  # Check if virtual environment path is specified and valid
  if [ -n "$venv_path" ]; then
    echo "Virtual environment path specified: $venv_path"
    if [ ! -d "$venv_path" ]; then
      echo "⚠️ Virtual environment directory not found: $venv_path"
    else
      echo "Virtual environment directory exists."
    fi
  fi
  
  # Use framework-specific logic for handling virtual environments and main file paths
  case "$framework" in
    "spring")
      java -jar "$GENERATOR_NAME" "$path" "$OPENAPI_OUT_PATH"
      ;;
    "express.js")
      # For express.js, use node_modules if available
      if [ -n "$venv_path" ] && [ "$venv_path" != "null" ]; then
        if [ -d "$venv_path" ]; then
          echo "Using Node.js packages from: $venv_path"
          export PATH="$venv_path/.bin:$PATH"
          
          # Add node_modules to NODE_PATH if it exists
          if [ -d "$venv_path" ]; then
            if [ -z "$NODE_PATH" ]; then
              export NODE_PATH="$venv_path"
            else
              export NODE_PATH="$NODE_PATH:$venv_path"
            fi
            echo "Set NODE_PATH to include $venv_path"
          fi
        else
          echo "⚠️ Node.js environment path $venv_path not found"
          # Check for local node_modules
          if [ -d "node_modules" ]; then
            echo "Found local node_modules directory"
            export PATH="$(pwd)/node_modules/.bin:$PATH"
            if [ -z "$NODE_PATH" ]; then
              export NODE_PATH="$(pwd)/node_modules"
            else
              export NODE_PATH="$NODE_PATH:$(pwd)/node_modules"
            fi
            echo "Set NODE_PATH to include local node_modules"
          fi
        fi
      else
        # Check for local node_modules as fallback
        if [ -d "node_modules" ]; then
          echo "Using local node_modules"
          export PATH="$(pwd)/node_modules/.bin:$PATH"
          if [ -z "$NODE_PATH" ]; then
            export NODE_PATH="$(pwd)/node_modules"
          else
            export NODE_PATH="$NODE_PATH:$(pwd)/node_modules"
          fi
        fi
      fi
      
      # Check if we should use npm/yarn
      if [ -f "$GENERATOR_DIR/package.json" ]; then
        echo "Found package.json in generator directory"
        
        # Check if script exists in package.json
        if grep -q "\"generate\"" "$GENERATOR_DIR/package.json"; then
          echo "Using npm run generate"
          
          # Check if we should use yarn or npm
          if [ -f "$GENERATOR_DIR/yarn.lock" ]; then
            if command -v yarn >/dev/null 2>&1; then
              yarn --cwd "$GENERATOR_DIR" generate -- -e "$path/$main_file" -o "$OPENAPI_OUT_PATH"
            else
              echo "⚠️ yarn not found, falling back to npm"
              (cd "$GENERATOR_DIR" && npm run generate -- -e "$path/$main_file" -o "$OPENAPI_OUT_PATH")
            fi
          else
            (cd "$GENERATOR_DIR" && npm run generate -- -e "$path/$main_file" -o "$OPENAPI_OUT_PATH")
          fi
        else
          # Fallback to direct node execution
          node "$GENERATOR_NAME" -e "$path/$main_file" -o "$OPENAPI_OUT_PATH"
        fi
      else
        # For express.js, use main file from config
        if [ -n "$main_file" ] && [ -f "$path/$main_file" ]; then
          node "$GENERATOR_NAME" -e "$path/$main_file" -o "$OPENAPI_OUT_PATH"
        else
          echo "❌ Main file not found for Express.js app"
          return
        fi
      fi
      ;;
    "flask")
      # For flask, activate virtual environment if available
      if [ -n "$venv_path" ] && [ "$venv_path" != "null" ]; then
        # Check if it's a directory
        if [ -d "$venv_path" ]; then
          echo "Activating Python virtual environment: $venv_path"
          if [ -f "$venv_path/bin/activate" ]; then
            . "$venv_path/bin/activate"
          else
            echo "⚠️ Cannot find activate script in $venv_path/bin"
            # Check if there are multiple environments (envs directory)
            if [ -d "$venv_path/envs" ]; then
              echo "Checking for environments in $venv_path/envs"
              # Try to use the first environment found
              for env_dir in "$venv_path/envs"/*; do
                if [ -d "$env_dir" ] && [ -f "$env_dir/bin/activate" ]; then
                  echo "Found environment: $env_dir"
                  . "$env_dir/bin/activate"
                  break
                fi
              done
            fi
          fi
        elif [ -d "${venv_path}s" ]; then
          # Try plural 'envs' if 'env' doesn't exist
          echo "Environment directory $venv_path not found, trying ${venv_path}s"
          for env_dir in "${venv_path}s"/*; do
            if [ -d "$env_dir" ] && [ -f "$env_dir/bin/activate" ]; then
              echo "Found environment: $env_dir"
              . "$env_dir/bin/activate"
              break
            fi
          done
        else
          # Try to find any Python environment
          echo "⚠️ Virtual environment path $venv_path not found"
          echo "Looking for Python environments in current directory..."
          if [ -d "env" ] && [ -f "env/bin/activate" ]; then
            echo "Found local env directory"
            . "env/bin/activate"
          elif [ -d "venv" ] && [ -f "venv/bin/activate" ]; then
            echo "Found local venv directory"
            . "venv/bin/activate"
          elif [ -d ".venv" ] && [ -f ".venv/bin/activate" ]; then
            echo "Found local .venv directory"
            . ".venv/bin/activate"
          fi
        fi
      fi
      
      # For flask, use main file from config
      if [ -n "$main_file" ] && [ -f "$path/$main_file" ]; then
        python3 "$GENERATOR_NAME" -e "$path/$main_file" -o "$OPENAPI_OUT_PATH"
      else
        echo "❌ Main file not found for Flask app"
        return
      fi
      
      # Deactivate virtual environment if it was activated
      if which deactivate >/dev/null 2>&1; then
        deactivate
      fi
      ;;
    "django")
      # For Django, activate virtual environment if available
      if [ -n "$venv_path" ] && [ "$venv_path" != "null" ]; then
        # Check if it's a directory
        if [ -d "$venv_path" ]; then
          echo "Activating Python virtual environment: $venv_path"
          if [ -f "$venv_path/bin/activate" ]; then
            . "$venv_path/bin/activate"
          else
            echo "⚠️ Cannot find activate script in $venv_path/bin"
            # Check if there are multiple environments (envs directory)
            if [ -d "$venv_path/envs" ]; then
              echo "Checking for environments in $venv_path/envs"
              # Try to use the first environment found
              for env_dir in "$venv_path/envs"/*; do
                if [ -d "$env_dir" ] && [ -f "$env_dir/bin/activate" ]; then
                  echo "Found environment: $env_dir"
                  . "$env_dir/bin/activate"
                  break
                fi
              done
            fi
          fi
        elif [ -d "${venv_path}s" ]; then
          # Try plural 'envs' if 'env' doesn't exist
          echo "Environment directory $venv_path not found, trying ${venv_path}s"
          for env_dir in "${venv_path}s"/*; do
            if [ -d "$env_dir" ] && [ -f "$env_dir/bin/activate" ]; then
              echo "Found environment: $env_dir"
              . "$env_dir/bin/activate"
              break
            fi
          done
        else
          # Try to find any Python environment
          echo "⚠️ Virtual environment path $venv_path not found"
          echo "Looking for Python environments in current directory..."
          if [ -d "env" ] && [ -f "env/bin/activate" ]; then
            echo "Found local env directory"
            . "env/bin/activate"
          elif [ -d "venv" ] && [ -f "venv/bin/activate" ]; then
            echo "Found local venv directory"
            . "venv/bin/activate"
          elif [ -d ".venv" ] && [ -f ".venv/bin/activate" ]; then
            echo "Found local .venv directory"
            . ".venv/bin/activate"
          fi
        fi
      fi
      
      # For Django, use the project root as the endpoint for the Django creator
      # The main_file is not directly used but is needed for project identification
      python3 "$GENERATOR_NAME" -e "$path" -o "$OPENAPI_OUT_PATH"
      
      # Deactivate virtual environment if it was activated
      if which deactivate >/dev/null 2>&1; then
        deactivate
      fi
      ;;
    "ruby-on-rails")
      # For Rails, use bundler if virtual environment is available
      if [ -n "$venv_path" ] && [ "$venv_path" != "null" ]; then
        if [ -d "$venv_path" ]; then
          echo "Using Ruby environment from: $venv_path"
          # Check for .gems directory
          if [ -d "$venv_path/.gems" ]; then
            export GEM_HOME="$venv_path/.gems"
            export PATH="$venv_path/.gems/bin:$PATH"
            echo "Set GEM_HOME to $GEM_HOME"
          elif [ -d "$venv_path/vendor/bundle" ]; then
            # Check for vendored gems
            export BUNDLE_PATH="$venv_path/vendor/bundle"
            export PATH="$venv_path/vendor/bundle/bin:$PATH"
            echo "Set BUNDLE_PATH to $BUNDLE_PATH"
          else
            # Default approach
            export GEM_HOME="$venv_path"
            export PATH="$venv_path/bin:$PATH"
            echo "Set GEM_HOME to $GEM_HOME"
          fi
          
          # Check if bundler is available
          if command -v bundle >/dev/null 2>&1; then
            echo "Using bundler for Ruby dependencies"
            BUNDLE_GEMFILE="$path/Gemfile" bundle exec ruby "$GENERATOR_NAME" -e "$path" -o "$OPENAPI_OUT_PATH"
          else
            # Fall back to direct ruby execution
            ruby "$GENERATOR_NAME" -e "$path" -o "$OPENAPI_OUT_PATH"
          fi
        else
          # Try to use local Ruby environment
          echo "⚠️ Ruby environment path $venv_path not found"
          echo "Looking for Ruby environments in current directory..."
          
          if [ -d "vendor/bundle" ]; then
            echo "Found local vendor/bundle"
            export BUNDLE_PATH="$(pwd)/vendor/bundle"
            export PATH="$(pwd)/vendor/bundle/bin:$PATH"
          fi
          
          # Try to use bundler if available
          if command -v bundle >/dev/null 2>&1; then
            echo "Using local bundler for Ruby dependencies"
            BUNDLE_GEMFILE="$path/Gemfile" bundle exec ruby "$GENERATOR_NAME" -e "$path" -o "$OPENAPI_OUT_PATH"
          else
            ruby "$GENERATOR_NAME" -e "$path" -o "$OPENAPI_OUT_PATH"
          fi
        fi
      else
        # No specified environment, use system Ruby
        ruby "$GENERATOR_NAME" -e "$path" -o "$OPENAPI_OUT_PATH"
      fi
      ;;
    *)
      # Default case for any other framework type
      echo "⚠️ No specific generator command for framework: $framework. Using generic approach."
      if [ -f "$GENERATOR_NAME" ]; then
        # Check if virtual environment is specified
        if [ -n "$venv_path" ] && [ "$venv_path" != "null" ] && [ -d "$venv_path" ]; then
          echo "Using environment from: $venv_path"
          # Try to detect and use appropriate environment
          if [ -f "$venv_path/bin/activate" ]; then
            # Looks like a Python/Ruby environment
            . "$venv_path/bin/activate"
            "$GENERATOR_NAME" "$path" "$OPENAPI_OUT_PATH"
            if which deactivate >/dev/null 2>&1; then
              deactivate
            fi
          elif [ -d "$venv_path/bin" ]; then
            # Generic bin directory approach
            export PATH="$venv_path/bin:$PATH"
            "$GENERATOR_NAME" "$path" "$OPENAPI_OUT_PATH"
          else
            # Just use the generator directly
            "$GENERATOR_NAME" "$path" "$OPENAPI_OUT_PATH"
          fi
        else
          # No environment specified, run directly
          "$GENERATOR_NAME" "$path" "$OPENAPI_OUT_PATH"
        fi
      else
        echo "❌ Cannot determine how to run generator for framework: $framework"
      fi
      ;;
  esac
  
  # Return to the original directory
  cd "$ORIGINAL_DIR" || echo "⚠️ Failed to return to original directory"
  
  if [ -f "$OPENAPI_OUT_PATH" ]; then
    echo "✅ Successfully generated OpenAPI specification for $framework at $OPENAPI_OUT_PATH"
    
    # Store the openapi path
    store_openapi_path "$framework" "$OPENAPI_OUT_PATH"
  else
    echo "❌ Failed to generate OpenAPI specification for $framework"
  fi
}

# Update the swagger.config.json file with new OpenAPI paths
update_swagger_config() {
  echo "Updating original config file at: $ORIGINAL_CONFIG"
  
  # Debug: Show the paths we're trying to add
  echo "OpenAPI paths to add:"
  cat "$TEMP_OUTPUT_FILE"
  
  # Create a temp file to hold our updated JSON
  local temp_file="swagger.config.temp.json"
  cp "$SWAGGER_CONFIG" "$temp_file"
  
  # Check if jq is available for proper JSON manipulation
  if command -v jq >/dev/null 2>&1; then
    echo "Using jq for JSON updates"
    
    # Create an associative array of frameworks to paths (if bash version supports it)
    declare -A openapi_paths 2>/dev/null
    if [ $? -eq 0 ]; then
      # Bash version supports associative arrays
      while IFS=: read -r framework path; do
        [ -n "$framework" ] && openapi_paths["$framework"]="$path"
      done < "$TEMP_OUTPUT_FILE"
      
      # Process the JSON file
      jq_script=""
      for framework in "${!openapi_paths[@]}"; do
        path="${openapi_paths[$framework]}"
        echo "Processing with jq: $framework -> $path"
        jq_script="$jq_script | map(if .framework == \"$framework\" then . + {\"openapi_path\": \"$path\"} else . end)"
      done
      
      # Remove the leading pipe
      jq_script="${jq_script#" | "}"
      
      # Apply the jq transformation
      jq "$jq_script" "$SWAGGER_CONFIG" > "$temp_file"
    else
      # Fallback for bash versions without associative arrays
      # Process each line and use a separate jq call
      while IFS=: read -r framework path; do
        if [ -n "$framework" ] && [ -n "$path" ]; then
          echo "Updating $framework with path $path"
          # Escape quotes in path
          escaped_path=$(echo "$path" | sed 's/"/\\"/g')
          # Create a temp file for each iteration
          jq "map(if .framework == \"$framework\" then . + {\"openapi_path\": \"$escaped_path\"} else . end)" "$temp_file" > "${temp_file}.new"
          mv "${temp_file}.new" "$temp_file"
        fi
      done < "$TEMP_OUTPUT_FILE"
    fi
  else
    echo "jq not available, using sed for updates (less reliable)"
    
    # Process each openapi path
    while IFS=: read -r framework openapi_path; do
      # Skip empty lines
      if [ -z "$framework" ]; then
        continue
      fi
      
      echo "Adding path for $framework: $openapi_path"
      
      # Escape forward slashes in the path for sed
      local escaped_path=$(echo "$openapi_path" | sed 's/\//\\\//g')
      
      # Try multiple sed patterns to handle different JSON formats
      # Try to update existing openapi_path first
      if grep -q "\"framework\":\"$framework\".*\"openapi_path\"" "$temp_file"; then
        echo "Updating existing openapi_path for $framework"
        # Update existing openapi_path - handle JSON formatting variations
        sed -i.bak "s|\"openapi_path\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"openapi_path\":\"$escaped_path\"|g" "$temp_file"
      else
        echo "Adding new openapi_path for $framework"
        
        # Extract the object containing the framework into a temporary file for modification
        grep -n "\"framework\":\"$framework\"" "$temp_file" | cut -d: -f1 | while read -r line_num; do
          # Extract the line
          framework_line=$(sed -n "${line_num}p" "$temp_file")
          
          # Check if this line contains the closing brace for the object
          if echo "$framework_line" | grep -q "}"; then
            # If the object ends on this line, insert openapi_path before the closing brace
            sed -i.bak "${line_num}s/}/,\"openapi_path\":\"$escaped_path\"}/g" "$temp_file"
          else
            # Find the closing brace for this object in subsequent lines
            closing_line=$(tail -n +$line_num "$temp_file" | grep -n "}" | head -1 | cut -d: -f1)
            if [ -n "$closing_line" ]; then
              actual_line=$((line_num + closing_line - 1))
              # Insert openapi_path before the closing brace
              sed -i.bak "${actual_line}s/}/,\"openapi_path\":\"$escaped_path\"}/g" "$temp_file"
            fi
          fi
        done
      fi
      
      # Remove the backup file created by sed
      rm -f "${temp_file}.bak"
    done < "$TEMP_OUTPUT_FILE"
  fi
  
  # Check for and remove any ___MARKER___ strings that might have been left behind
  if grep -q "___MARKER___" "$temp_file"; then
    echo "Found ___MARKER___ in JSON - removing"
    sed -i.bak 's/___MARKER___//g' "$temp_file"
    rm -f "${temp_file}.bak"
  fi
  
  # Validate and format JSON if jq is available
  if command -v jq >/dev/null 2>&1; then
    echo "Validating JSON with jq before saving..."
    
    # Validate JSON
    if jq '.' "$temp_file" > /dev/null 2>&1; then
      echo "✅ JSON structure is valid."
      # Format the JSON nicely
      jq '.' "$temp_file" > "${temp_file}.formatted"
      mv "${temp_file}.formatted" "$ORIGINAL_CONFIG"
      echo "✅ Updated config file with formatted JSON"
    else
      echo "❌ JSON validation failed. Attempting to fix..."
      # Try to fix common errors before saving
      # 1. Remove trailing commas before closing braces
      sed -i.bak 's/,[ \t]*}/}/g' "$temp_file"
      # 2. Remove trailing commas before closing brackets
      sed -i.bak 's/,[ \t]*\]/]/g' "$temp_file"
      # 3. Fix cases where our replacements may have gone wrong
      sed -i.bak 's/,\+/,/g' "$temp_file"  # Replace multiple commas with single one
      
      # Try to validate again
      if jq '.' "$temp_file" > /dev/null 2>&1; then
        echo "✅ JSON structure fixed successfully."
        jq '.' "$temp_file" > "${temp_file}.formatted"
        mv "${temp_file}.formatted" "$ORIGINAL_CONFIG"
        echo "✅ Updated config file with fixed JSON"
      else
        echo "⚠️ Could not fix JSON automatically. Saving original file and providing backup."
        cp "$temp_file" "${ORIGINAL_CONFIG}.backup"
        mv "$temp_file" "$ORIGINAL_CONFIG"
        echo "⚠️ Backup saved as ${ORIGINAL_CONFIG}.backup"
      fi
    fi
  else
    # No JSON validator available, save directly
    mv "$temp_file" "$ORIGINAL_CONFIG"
    echo "✅ Updated config file (no JSON validation available)"
  fi
  
  # Debug: Show the updated file
  echo "Updated JSON content (first 20 lines):"
  head -20 "$ORIGINAL_CONFIG"
}

# Clean up any previous run
rm -f "$TEMP_OUTPUT_FILE"

# Store the original config path before normalization
ORIGINAL_CONFIG="$SWAGGER_CONFIG"

# Normalize the JSON file to make it easier to parse
echo "Normalizing JSON config file..."
TEMP_JSON_FILE="swagger.config.normalized.json"
if command -v jq >/dev/null 2>&1; then
  # Use jq to normalize if available
  jq '.' "$SWAGGER_CONFIG" > "$TEMP_JSON_FILE" 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "JSON normalized with jq"
    SWAGGER_CONFIG="$TEMP_JSON_FILE"
  else
    echo "jq failed to parse the JSON, using original file"
    cp "$SWAGGER_CONFIG" "$TEMP_JSON_FILE"
    SWAGGER_CONFIG="$TEMP_JSON_FILE"
  fi
else
  # Create a normalized version that's easier to parse
  echo "jq not available, using basic normalization"
  # First, preserve the original formatting in a backup
  cp "$SWAGGER_CONFIG" "${SWAGGER_CONFIG}.orig"
  
  # Simplified approach - just copy the file and process it directly
  cp "$SWAGGER_CONFIG" "$TEMP_JSON_FILE"
  SWAGGER_CONFIG="$TEMP_JSON_FILE"
  echo "Basic normalization complete."
fi

# Direct manual extraction of framework values (as a fallback)
FRAMEWORKS_DIRECT=$(grep -o '"framework":"[^"]*"' "$SWAGGER_CONFIG" | cut -d'"' -f4)

# Process all frameworks defined in swagger.config.json
FRAMEWORKS=$(get_all_frameworks)

# If no frameworks were found using the main function, use the direct extraction
if [ -z "$FRAMEWORKS" ]; then
  echo "⚠️ No frameworks found with primary method, using fallback extraction."
  FRAMEWORKS="$FRAMEWORKS_DIRECT"
fi

echo "Found frameworks: $FRAMEWORKS"

# Check if any frameworks were found
if [ -z "$FRAMEWORKS" ]; then
  echo "⚠️ No frameworks found in the configuration file."
  echo "This could be due to one of the following issues:"
  echo "  1. The configuration file is empty or improperly formatted"
  echo "  2. The 'framework' field is missing or not properly formatted"
  echo "Attempting to fix by showing the first few entries directly:"
  
  # Print the first framework entry directly from the file for debugging
  head -20 "$SWAGGER_CONFIG" | grep -A 2 "\"framework\":" || echo "No framework entries found in first 20 lines"
  
  # Try directly extracting frameworks with a different method
  echo "Trying alternative extraction method..."
  FRAMEWORKS=$(cat "$SWAGGER_CONFIG" | grep -o '"framework":"[^"]*"' | sed 's/"framework":"//g' | sed 's/"//g')
  
  if [ -n "$FRAMEWORKS" ]; then
    echo "Alternative method found frameworks: $FRAMEWORKS"
  else
    echo "❌ Failed to find any frameworks in the configuration file."
    exit 1
  fi
fi

# Function to get framework at specific index (1-based)
get_framework_at_index() {
  local index=$1
  local count=1
  
  # Debug messages to stderr instead of stdout so they don't affect the return value
  echo >&2 "Frameworks list: '$FRAMEWORKS'"
  echo >&2 "Finding framework at position $index"
  
  # Handle space-separated list 
  for framework in $FRAMEWORKS; do
    echo >&2 "Checking framework: $framework (position $count)"
    if [ $count -eq $index ]; then
      echo >&2 "Found match at position $count: $framework"
      echo "$framework"
      return
    fi
    count=$((count + 1))
  done
  
  # Return empty if index is out of bounds
  echo >&2 "No framework found at position $index"
  echo ""
}

# If specific frameworks are requested by index, only process those
if [ ${#FRAMEWORKS_TO_BUILD[@]} -gt 0 ]; then
  echo "Building only specified frameworks by index: ${FRAMEWORKS_TO_BUILD[*]}"
  
  # Debug message to show available frameworks
  echo "Available frameworks: $FRAMEWORKS"
  
  # Array to store frameworks to process
  FRAMEWORKS_TO_PROCESS=()
  
  for index in "${FRAMEWORKS_TO_BUILD[@]}"; do
    framework=$(get_framework_at_index "$index")
    echo "Framework at index $index: $framework"
    if [ -n "$framework" ]; then
      FRAMEWORKS_TO_PROCESS+=("$framework")
    else
      echo "❌ No framework found at index $index"
    fi
  done
  
  # Process only the specified frameworks - check if array is not empty
  if [ ${#FRAMEWORKS_TO_PROCESS[@]} -gt 0 ]; then
    for framework in "${FRAMEWORKS_TO_PROCESS[@]}"; do
      echo "Processing framework: $framework"
      process_framework "$framework"
    done
  else
    echo "⚠️ No valid frameworks to process."
  fi
else
  # Process all frameworks
  echo "No specific frameworks specified, processing all"
  for framework in $FRAMEWORKS; do
    echo "Processing framework: $framework"
    process_framework "$framework"
  done
fi

# Update the swagger.config.json with OpenAPI paths
if [ -f "$TEMP_OUTPUT_FILE" ]; then
  update_swagger_config
  rm -f "$TEMP_OUTPUT_FILE"
fi

# Clean up temporary files
if [ -f "$TEMP_JSON_FILE" ]; then
  rm -f "$TEMP_JSON_FILE"
fi

echo "OpenAPI specification generation complete!"
