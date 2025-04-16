#!/bin/bash

# Build OpenAPI Specifications for all frameworks defined in swagger.config.json
# using generators defined in spec_generator.config.json

# Display usage instructions
show_usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Options:"
  echo "  -c, --config FILE    Path to swagger.config.json file (default: swagger.config.json in current dir)"
  echo "  -h, --help           Show this help message"
  exit 1
}

# Parse command line arguments
SWAGGER_CONFIG="swagger.config.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)
      SWAGGER_CONFIG="$2"
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
    jq -r ".[] | select(.framework == \"$framework\") | .path" "$SWAGGER_CONFIG" 2>/dev/null
    return
  fi
  
  # Fallback method with grep and sed
  # Convert file to single line and extract the entire object containing the framework
  local json_obj=$(cat "$SWAGGER_CONFIG" | tr -d '\n' | grep -o "{[^{]*\"framework\":\"$framework\"[^}]*}")
  # Then extract the path field
  echo "$json_obj" | grep -o '"path":"[^"]*"' | cut -d'"' -f4
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

# Function to extract spec generator from spec_generator.config.json
get_spec_generator() {
  local framework=$1
  # Look for the framework in the spec_creator object
  cat "$SPEC_GEN_CONFIG" | tr -d '\n' | grep -o "\"spec_creator\"[^}]*}" | grep -o "\"$framework\": *\"[^\"]*\"" | cut -d'"' -f4
}

# Function to extract virtual environment path from spec_generator.config.json
get_venv_path() {
  local framework=$1
  # Look for the framework in the venv_paths object
  cat "$SPEC_GEN_CONFIG" | tr -d '\n' | grep -o "\"venv_paths\"[^}]*}" | grep -o "\"$framework\": *\"[^\"]*\"" | cut -d'"' -f4
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
  
  if [ -z "$path" ]; then
    echo "❌ Path not found for $framework in $SWAGGER_CONFIG"
    return
  fi
  
  if [ -z "$main_file" ]; then
    echo "❌ Main file not found for $framework in $SWAGGER_CONFIG"
    return
  fi
  
  # Store original directory
  ORIGINAL_DIR=$(pwd)
  
  if [ -n "$generator" ] && [ "$generator" != "null" ]; then
    echo "Running $framework generator..."
    
    # Get the absolute paths
    GENERATOR_DIR=$(dirname "$generator")
    GENERATOR_NAME=$(basename "$generator")
    
    # Run the generator with appropriate command based on framework
    cd "$GENERATOR_DIR"
    
    # Define the openapi.json output path
    OPENAPI_OUT_PATH="$path/openapi.json"
    
    # Use framework-specific logic for handling virtual environments and main file paths
    case "$framework" in
      "spring")
        java -jar "$GENERATOR_NAME" "$path" "$OPENAPI_OUT_PATH"
        ;;
      "express.js")
        # For express.js, use node_modules if available
        if [ -n "$venv_path" ] && [ "$venv_path" != "null" ] && [ -d "$venv_path" ]; then
          echo "Using Node.js packages from: $venv_path"
          export PATH="$venv_path/.bin:$PATH"
        fi
        # For express.js, main file is "server.js"
        node "$GENERATOR_NAME" -e "$path/server.js" -o "$OPENAPI_OUT_PATH"
        ;;
      "flask")
        # For flask, activate virtual environment if available
        if [ -n "$venv_path" ] && [ "$venv_path" != "null" ] && [ -d "$venv_path" ]; then
          echo "Activating Python virtual environment: $venv_path"
          source "$venv_path/bin/activate"
        fi
        # For flask, main file is "main_.py"
        python3 "$GENERATOR_NAME" -e "$path/main_.py" -o "$OPENAPI_OUT_PATH"
        # Deactivate virtual environment if it was activated
        if [ -n "$venv_path" ] && [ "$venv_path" != "null" ] && [ -d "$venv_path" ]; then
          deactivate 2>/dev/null || true
        fi
        ;;
      "ruby-on-rails")
        # For Rails, use bundler if virtual environment is available
        if [ -n "$venv_path" ] && [ "$venv_path" != "null" ] && [ -d "$venv_path" ]; then
          echo "Using Ruby environment from: $venv_path"
          export GEM_HOME="$venv_path"
          export PATH="$venv_path/bin:$PATH"
        fi
        # For Rails, use the path directly
        ruby "$GENERATOR_NAME" -e "$path" -o "$OPENAPI_OUT_PATH"
        ;;
      *)
        # Default case for any other framework type
        echo "⚠️ No specific generator command for framework: $framework. Using generic approach."
        if [[ -f "$GENERATOR_NAME" ]]; then
          "$GENERATOR_NAME" "$path" "$OPENAPI_OUT_PATH"
        else
          echo "❌ Cannot determine how to run generator for framework: $framework"
        fi
        ;;
    esac
    
    # Return to the original directory
    cd "$ORIGINAL_DIR"
    
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

for framework in $FRAMEWORKS; do
  process_framework "$framework"
done

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
