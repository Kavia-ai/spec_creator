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

echo "Using swagger config file: $SWAGGER_CONFIG"

# Check if spec generator config file exists
if [ ! -f "$SPEC_GEN_CONFIG" ]; then
  echo "Error: $SPEC_GEN_CONFIG not found."
  exit 1
fi

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
  
  # Fallback to a more robust grep approach that handles multiline entries
  cat "$SWAGGER_CONFIG" | tr -d '\n' | grep -o '"framework":"[^"]*"' | cut -d'"' -f4
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
  
  # Fallback method with grep and sed
  # Convert file to single line and extract the entire object containing the framework
  local json_obj=$(cat "$SWAGGER_CONFIG" | tr -d '\n' | grep -o "{[^{]*\"framework\":\"$framework\"[^}]*}")
  # Then extract the path field
  local raw_path=$(echo "$json_obj" | grep -o '"path":"[^"]*"' | cut -d'"' -f4)
  normalize_path "$raw_path"
}

# Function to extract main file from swagger.config.json
get_main_file() {
  local framework=$1
  
  # First try using jq if available
  if command -v jq >/dev/null 2>&1; then
    jq -r ".[] | select(.framework == \"$framework\") | .main_file" "$SWAGGER_CONFIG" 2>/dev/null
    return
  fi
  
  # Fallback method with grep and sed
  # Convert file to single line and extract the entire object containing the framework
  local json_obj=$(cat "$SWAGGER_CONFIG" | tr -d '\n' | grep -o "{[^{]*\"framework\":\"$framework\"[^}]*}")
  # Then extract the main_file field
  echo "$json_obj" | grep -o '"main_file":"[^"]*"' | cut -d'"' -f4
}

# Function to extract default main file from spec_generator.config.json
get_default_main_file() {
  local framework=$1
  # Look for the framework in the default_main_files object
  if command -v jq >/dev/null 2>&1; then
    jq -r ".default_main_files.\"$framework\"" "$SPEC_GEN_CONFIG" 2>/dev/null
  else
    # Fallback to grep/sed for systems without jq
    cat "$SPEC_GEN_CONFIG" | tr -d '\n' | grep -o "\"default_main_files\"[^}]*}" | grep -o "\"$framework\": *\"[^\"]*\"" | cut -d'"' -f4
  fi
}

# Function to extract spec generator from spec_generator.config.json
get_spec_generator() {
  local framework=$1
  # Look for the framework in the spec_creator object
  if command -v jq >/dev/null 2>&1; then
    jq -r ".spec_creator.\"$framework\"" "$SPEC_GEN_CONFIG" 2>/dev/null
  else
    # Fallback to grep/sed
    cat "$SPEC_GEN_CONFIG" | tr -d '\n' | grep -o "\"spec_creator\"[^}]*}" | grep -o "\"$framework\": *\"[^\"]*\"" | cut -d'"' -f4
  fi
}

# Function to extract virtual environment path from spec_generator.config.json
get_venv_path() {
  local framework=$1
  # Look for the framework in the venv_paths object
  if command -v jq >/dev/null 2>&1; then
    jq -r ".venv_paths.\"$framework\"" "$SPEC_GEN_CONFIG" 2>/dev/null
  else
    # Fallback to grep/sed
    cat "$SPEC_GEN_CONFIG" | tr -d '\n' | grep -o "\"venv_paths\"[^}]*}" | grep -o "\"$framework\": *\"[^\"]*\"" | cut -d'"' -f4
  fi
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
  local default_main_file=$(get_default_main_file "$framework")
  
  if [ -z "$path" ]; then
    echo "❌ Path not found for $framework in $SWAGGER_CONFIG"
    return
  fi
  
  if [ ! -d "$path" ]; then
    echo "❌ Directory not found: $path"
    return
  fi
  
  # If main_file is empty, use the default main file from config
  if [ -z "$main_file" ]; then
    if [ -n "$default_main_file" ] && [ "$default_main_file" != "null" ]; then
      echo "Using default main file for $framework: $default_main_file"
      main_file="$default_main_file"
    else
      echo "❌ Main file not found for $framework in $SWAGGER_CONFIG and no default provided"
      return
    fi
  fi
  
  # Store original directory
  ORIGINAL_DIR=$(pwd)
  
  if [ -n "$generator" ] && [ "$generator" != "null" ]; then
    echo "Running $framework generator..."
    
    # Get the absolute paths
    GENERATOR_DIR=$(dirname "$generator")
    GENERATOR_NAME=$(basename "$generator")
    
    # Check if generator actually exists
    if [ ! -f "$GENERATOR_DIR/$GENERATOR_NAME" ]; then
      echo "❌ Generator file not found: $GENERATOR_DIR/$GENERATOR_NAME"
      return
    fi
    
    # Run the generator with appropriate command based on framework
    cd "$GENERATOR_DIR" || { echo "❌ Failed to change directory to $GENERATOR_DIR"; return; }
    
    # Define the openapi.json output path
    OPENAPI_OUT_PATH="$path/openapi.json"
    
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
          main_file=""
        fi
      fi
    else
      # It's a relative path, check if it exists
      if [ ! -f "$path/$main_file" ]; then
        echo "⚠️ Main file $path/$main_file not found"
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
  else
    echo "⚠️ No generator specified for $framework in $SPEC_GEN_CONFIG"
  fi
}

# Update the swagger.config.json file with new OpenAPI paths
update_swagger_config() {
  echo "Updating original config file at: $ORIGINAL_CONFIG"
  
  # Debug: Show the paths we're trying to add
  echo "OpenAPI paths to add:"
  cat "$TEMP_OUTPUT_FILE"
  
  # Check if jq is available for proper JSON manipulation
  if command -v jq >/dev/null 2>&1; then
    echo "Using jq for JSON updates"
    
    # Create a temp file to hold our updated JSON
    local temp_file="swagger.config.temp.json"
    cp "$SWAGGER_CONFIG" "$temp_file"
    
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
    
    # Move the result back to the original file
    mv "$temp_file" "$ORIGINAL_CONFIG"
    echo "✅ Updated config file using jq"
  else
    echo "jq not available, using sed for updates (less reliable)"
    
    # Create a temporary file to hold the updated JSON
    local temp_file="swagger.config.temp.json"
    cp "$SWAGGER_CONFIG" "$temp_file"
    
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
        # Try different sed patterns
        # Pattern 1: Look for port field at end of line
        sed -i.bak "s|\"port\"[[:space:]]*:[[:space:]]*\"[0-9]*\"[[:space:]]*$|&,\"openapi_path\":\"$escaped_path\"|g" "$temp_file"
        # Pattern 2: Look for port field followed by comma
        sed -i.bak "s|\"port\"[[:space:]]*:[[:space:]]*\"[0-9]*\"[[:space:]]*,|\"port\":\"[0-9]*\",\"openapi_path\":\"$escaped_path\",|g" "$temp_file"
        # Pattern 3: Look for framework and add after its closing brace
        sed -i.bak "s|\"framework\":\"$framework\".*}|&,\"openapi_path\":\"$escaped_path\"|g" "$temp_file"
      fi
      
      # Remove the backup file created by sed
      rm -f "${temp_file}.bak"
    done < "$TEMP_OUTPUT_FILE"
    
    # Always write back to the original config path
    mv "$temp_file" "$ORIGINAL_CONFIG"
    echo "✅ Updated config file using sed"
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
    # Create a normalized version by removing whitespace between lines
    cat "$SWAGGER_CONFIG" | tr -d '\n' | sed 's/},{/},\n{/g' > "$TEMP_JSON_FILE"
    SWAGGER_CONFIG="$TEMP_JSON_FILE"
  fi
else
  # Create a normalized version by removing whitespace between lines
  echo "jq not available, using basic normalization"
  cat "$SWAGGER_CONFIG" | tr -d '\n' | sed 's/},{/},\n{/g' > "$TEMP_JSON_FILE"
  SWAGGER_CONFIG="$TEMP_JSON_FILE"
fi

# Process all frameworks defined in swagger.config.json
FRAMEWORKS=$(get_all_frameworks)

echo "Found frameworks: $FRAMEWORKS"

# Function to get framework at specific index (1-based)
get_framework_at_index() {
  local index=$1
  local count=1
  
  for framework in $FRAMEWORKS; do
    if [ $count -eq $index ]; then
      echo "$framework"
      return
    fi
    count=$((count + 1))
  done
  
  # Return empty if index is out of bounds
  echo ""
}

# If specific frameworks are requested by index, only process those
if [ ${#FRAMEWORKS_TO_BUILD[@]} -gt 0 ]; then
  echo "Building only specified frameworks by index: ${FRAMEWORKS_TO_BUILD[*]}"
  FRAMEWORKS_TO_PROCESS=""
  
  for index in "${FRAMEWORKS_TO_BUILD[@]}"; do
    framework=$(get_framework_at_index "$index")
    if [ -n "$framework" ]; then
      echo "Framework at index $index: $framework"
      FRAMEWORKS_TO_PROCESS="$FRAMEWORKS_TO_PROCESS $framework"
    else
      echo "❌ No framework found at index $index"
    fi
  done
  
  # Process only the specified frameworks
  for framework in $FRAMEWORKS_TO_PROCESS; do
    process_framework "$framework"
  done
else
  # Process all frameworks
  echo "No specific frameworks specified, processing all"
  for framework in $FRAMEWORKS; do
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
