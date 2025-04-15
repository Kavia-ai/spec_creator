#!/bin/bash

# Build OpenAPI Specifications for all frameworks defined in swagger.config.json
# using generators defined in spec_generator.config.json

# Define paths
SPEC_GEN_CONFIG="spec_generator.config.json"
SWAGGER_CONFIG="swagger.config.json"
TEMP_OUTPUT_FILE="openapi_paths.txt"

# Check if spec generator config file exists
if [ ! -f "$SPEC_GEN_CONFIG" ]; then
  echo "Error: $SPEC_GEN_CONFIG not found."
  exit 1
fi

# Check if swagger config file exists, create if not
if [ ! -f "$SWAGGER_CONFIG" ]; then
  echo "Warning: $SWAGGER_CONFIG not found. Creating an empty file."
  touch "$SWAGGER_CONFIG"
fi

# Function to extract all frameworks from swagger.config.json
get_all_frameworks() {
  grep -o "\"framework\":\"[^\"]*\"" "$SWAGGER_CONFIG" | cut -d'"' -f4
}

# Function to extract framework path from swagger.config.json
get_framework_path() {
  local framework=$1
  grep -A 5 "\"framework\":\"$framework\"" "$SWAGGER_CONFIG" | grep "\"path\":" | head -1 | cut -d'"' -f4
}

# Function to extract main file from swagger.config.json
get_main_file() {
  local framework=$1
  grep -A 5 "\"framework\":\"$framework\"" "$SWAGGER_CONFIG" | grep "\"main_file\":" | head -1 | cut -d'"' -f4
}

# Function to extract spec generator from spec_generator.config.json
get_spec_generator() {
  local framework=$1
  # Look for the framework in the spec_creator object
  cat "$SPEC_GEN_CONFIG" | tr -d '\n' | grep -o "\"spec_creator\"[^}]*}" | grep -o "\"$framework\": *\"[^\"]*\"" | cut -d'"' -f4
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
    
    # Use framework-specific logic for handling main file paths
    case "$framework" in
      "spring")
        java -jar "$GENERATOR_NAME" "$path" "$OPENAPI_OUT_PATH"
        ;;
      "express.js")
        # For express.js, main file is "server.js"
        node "$GENERATOR_NAME" -e "$path/server.js" -o "$OPENAPI_OUT_PATH"
        ;;
      "flask")
        # For flask, main file is "main_.py"
        python3 "$GENERATOR_NAME" -e "$path/main_.py" -o "$OPENAPI_OUT_PATH"
        ;;
      "ruby-on-rails")
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
  echo "Updating swagger.config.json with OpenAPI paths..."
  
  # Create a temporary file to hold the updated JSON
  local temp_file="swagger.config.temp.json"
  cp "$SWAGGER_CONFIG" "$temp_file"
  
  # Process each openapi path
  while IFS=: read -r framework openapi_path; do
    # Skip empty lines
    if [ -z "$framework" ]; then
      continue
    fi
    
    # Escape forward slashes in the path for sed
    local escaped_path=$(echo "$openapi_path" | sed 's/\//\\\//g')
    
    # Check if openapi_path field already exists for this framework
    if grep -q "\"framework\":\"$framework\".*openapi_path" "$temp_file"; then
      # Update existing openapi_path
      sed -i.bak "s/\"openapi_path\":.*,/\"openapi_path\":\"$escaped_path\",/" "$temp_file"
    else
      # Add new openapi_path field - we add it after the port field
      sed -i.bak "s/\"framework\":\"$framework\".*\"port\":\"[0-9]*\"/&,\"openapi_path\":\"$escaped_path\"/" "$temp_file"
    fi
    
    # Remove the backup file created by sed
    rm -f "${temp_file}.bak"
  done < "$TEMP_OUTPUT_FILE"
  
  # Replace the original config with the updated one
  mv "$temp_file" "$SWAGGER_CONFIG"
  
  echo "✅ Updated $SWAGGER_CONFIG with OpenAPI specification paths"
}

# Clean up any previous run
rm -f "$TEMP_OUTPUT_FILE"

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

echo "OpenAPI specification generation complete!"
