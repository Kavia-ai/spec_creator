#!/bin/bash

# Initialize the JSON file with an opening bracket
echo "[" > swagger.config.json
first_entry=true

# Array to store gitignore patterns
declare -a GITIGNORE_PATTERNS

# Function to load gitignore patterns from a directory
load_gitignore_patterns() {
  local dir=$1
  local gitignore_file="$dir/.gitignore"
  
  if [ -f "$gitignore_file" ]; then
    # Read each non-empty, non-comment line
    while IFS= read -r line; do
      # Skip empty lines and comments
      if [[ -n "$line" && ! "$line" =~ ^# ]]; then
        # Trim leading/trailing whitespace
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        # Add pattern to array
        GITIGNORE_PATTERNS+=("$line")
      fi
    done < "$gitignore_file"
  fi
}

# Function to check if a path should be ignored
should_ignore() {
  local path=$1
  local base_dir=$2
  local relative_path=${path#$base_dir/}
  
  for pattern in "${GITIGNORE_PATTERNS[@]}"; do
    # Handle directory patterns (ending with /)
    if [[ "$pattern" == */ ]]; then
      pattern="${pattern%/}"
      if [[ "$relative_path" == "$pattern"/* || "$relative_path" == "$pattern" ]]; then
        return 0  # Should ignore
      fi
    # Handle file patterns
    elif [[ "$relative_path" == "$pattern" ]]; then
      return 0  # Should ignore
    # Handle wildcard patterns
    elif [[ "$pattern" == *"*"* ]]; then
      # Convert glob pattern to regex
      local regex_pattern=$(echo "$pattern" | sed 's/\./\\./g' | sed 's/\*/[^\/]*/g')
      if [[ "$relative_path" =~ ^$regex_pattern$ || "$relative_path" =~ ^$regex_pattern/ ]]; then
        return 0  # Should ignore
      fi
    fi
  done
  
  return 1  # Should not ignore
}

# Function to get relative path
get_relative_path() {
  local path=$1
  local base=$2
  # Remove base from path
  echo "${path#$base/}"
}

# Function to extract port from files
extract_port() {
  local DIR=$1
  local framework=$2
  local main_file=$3
  local port=""
  
  case "$framework" in
    "flask")
      # Look for port in Flask app files
      if [ -n "$main_file" ]; then
        port=$(grep -E "port[ ]*=[ ]*[0-9]+" "$DIR/$main_file" | grep -Eo '[0-9]+' | head -1)
        # If not found in main file, check all Python files
        if [ -z "$port" ]; then
          port=$(find "$DIR" -name "*.py" -not -path "*/\.*" -type f | while read file; do
            if ! should_ignore "$file" "$DIR"; then
              grep -l "app.run" "$file"
            fi
          done | xargs grep -E "port[ ]*=[ ]*[0-9]+" 2>/dev/null | grep -Eo '[0-9]+' | head -1)
        fi
      fi
      # Default Flask port if not found
      if [ -z "$port" ]; then port="5000"; fi
      ;;
    "fastapi")
      # Look for port in uvicorn.run calls
      if [ -n "$main_file" ]; then
        port=$(grep -E "uvicorn.run|port[ ]*=[ ]*[0-9]+" "$DIR/$main_file" | grep -Eo '[0-9]+' | head -1)
        # If not found in main file, check all Python files
        if [ -z "$port" ]; then
          port=$(find "$DIR" -name "*.py" -not -path "*/\.*" -type f | while read file; do
            if ! should_ignore "$file" "$DIR"; then
              grep -l "uvicorn.run" "$file"
            fi
          done | xargs grep -E "port[ ]*=[ ]*[0-9]+" 2>/dev/null | grep -Eo '[0-9]+' | head -1)
        fi
      fi
      # Default FastAPI port if not found
      if [ -z "$port" ]; then port="8000"; fi
      ;;
    "django")
      # Look for port in Django settings
      if [ -f "$DIR/manage.py" ] && ! should_ignore "$DIR/manage.py" "$DIR"; then
        port=$(grep -E "runserver.*[0-9]+(\.[0-9]+)*:[0-9]+" "$DIR/manage.py" | grep -Eo ':[0-9]+' | grep -Eo '[0-9]+' | head -1)
      fi
      # Check for port in settings.py
      if [ -z "$port" ]; then
        port=$(find "$DIR" -name "settings.py" -not -path "*/\.*" -type f | while read file; do
          if ! should_ignore "$file" "$DIR"; then
            grep -l "PORT" "$file"
          fi
        done | xargs grep -E "PORT[ ]*=[ ]*[0-9]+" 2>/dev/null | grep -Eo '[0-9]+' | head -1)
      fi
      # Default Django port if not found
      if [ -z "$port" ]; then port="8000"; fi
      ;;
    "ruby-on-rails")
      # Check config/puma.rb for port
      if [ -f "$DIR/config/puma.rb" ] && ! should_ignore "$DIR/config/puma.rb" "$DIR"; then
        port=$(grep -E "port[ ]*[0-9]+" "$DIR/config/puma.rb" | grep -Eo '[0-9]+' | head -1)
      fi
      # Default Rails port if not found
      if [ -z "$port" ]; then port="3000"; fi
      ;;
    "spring")
      # Check properties file for server.port
      if [ -f "$DIR/src/main/resources/application.properties" ] && ! should_ignore "$DIR/src/main/resources/application.properties" "$DIR"; then
        port=$(grep -E "server.port[ ]*=[ ]*[0-9]+" "$DIR/src/main/resources/application.properties" | grep -Eo '[0-9]+' | head -1)
      elif [ -f "$DIR/src/main/resources/application.yml" ] && ! should_ignore "$DIR/src/main/resources/application.yml" "$DIR"; then
        port=$(grep -E "port:[ ]*[0-9]+" "$DIR/src/main/resources/application.yml" | grep -Eo '[0-9]+' | head -1)
      fi
      # Default Spring port if not found
      if [ -z "$port" ]; then port="8080"; fi
      ;;
    "express.js")
      # Look for port in Express app files
      if [ -n "$main_file" ]; then
        port=$(grep -E "(port|PORT)[ ]*=[ ]*[0-9]+" "$DIR/$main_file" | grep -Eo '[0-9]+' | head -1)
      fi
      # Check all JS files if not found in main file
      if [ -z "$port" ]; then
        port=$(find "$DIR" -name "*.js" -not -path "*/\.*" -type f | while read file; do
          if ! should_ignore "$file" "$DIR"; then
            grep -l "listen" "$file"
          fi
        done | xargs grep -E "\.listen\([ ]*[0-9]+" 2>/dev/null | grep -Eo '[0-9]+' | head -1)
      fi
      # Default Express port if not found
      if [ -z "$port" ]; then port="3000"; fi
      ;;
    "next.js")
      # Check next.config.js or package.json scripts for port
      if [ -f "$DIR/next.config.js" ] && ! should_ignore "$DIR/next.config.js" "$DIR"; then
        port=$(grep -E "port:[ ]*[0-9]+" "$DIR/next.config.js" | grep -Eo '[0-9]+' | head -1)
      fi
      if [ -z "$port" ] && [ -f "$DIR/package.json" ] && ! should_ignore "$DIR/package.json" "$DIR"; then
        port=$(grep -E "\"dev\":.*-p[ ]*[0-9]+" "$DIR/package.json" | grep -Eo '-p[ ]*[0-9]+' | grep -Eo '[0-9]+' | head -1)
      fi
      # Default Next.js port if not found
      if [ -z "$port" ]; then port="3000"; fi
      ;;
    *)
      port=""
      ;;
  esac
  
  echo "$port"
}

check_frameworks() {
  local DIR=$1
  local language=""
  local framework=""
  local main_file=""
  local port=""
  # Get absolute path
  local ABSOLUTE_PATH=$(cd "$DIR" && pwd)
  # Get relative path
  local RELATIVE_PATH="${DIR}"

  # Skip if directory is gitignored
  if should_ignore "$DIR" "$(dirname "$DIR")"; then
    echo "Skipping gitignored directory: $DIR"
    return
  fi

  echo "Analyzing directory: $DIR"

  echo "Checking for Python frameworks..."
  # Only check files in the current directory, not recursive
  if find "$DIR" -maxdepth 1 -name "*.py" -not -path "*/\.*" -type f | while read file; do
      if ! should_ignore "$file" "$DIR"; then
        grep -l "from flask import\|app = Flask" "$file"
      fi
    done | grep -q .; then
    language="python"
    framework="flask"
    # Find file where Flask app is actually initialized
    FLASK_FILE=$(find "$DIR" -maxdepth 2 -name "*.py" -not -path "*/\.*" -type f | while read file; do
      if ! should_ignore "$file" "$DIR"; then
        grep -l "app = Flask" "$file"
      fi
    done | head -1)
    if [ -n "$FLASK_FILE" ]; then
      # Get the filename without the path
      main_file=$(basename "$FLASK_FILE")
    else
      # Fall back to conventional filenames
      if [ -f "$DIR/app.py" ] && ! should_ignore "$DIR/app.py" "$DIR"; then
        main_file="app.py"
      elif [ -f "$DIR/main.py" ] && ! should_ignore "$DIR/main.py" "$DIR"; then
        main_file="main.py"
      elif [ -f "$DIR/wsgi.py" ] && ! should_ignore "$DIR/wsgi.py" "$DIR"; then
        main_file="wsgi.py"
      fi
    fi
  elif find "$DIR" -maxdepth 1 -name "*.py" -not -path "*/\.*" -type f | while read file; do
      if ! should_ignore "$file" "$DIR"; then
        grep -l "from fastapi import\|app = FastAPI" "$file"
      fi
    done | grep -q .; then
    language="python"
    framework="fastapi"
    # Find file where FastAPI app is actually initialized
    FASTAPI_FILE=$(find "$DIR" -maxdepth 2 -name "*.py" -not -path "*/\.*" -type f | while read file; do
      if ! should_ignore "$file" "$DIR"; then
        grep -l "app = FastAPI" "$file"
      fi
    done | head -1)
    if [ -n "$FASTAPI_FILE" ]; then
      # Get the filename without the path
      main_file=$(basename "$FASTAPI_FILE")
    else
      # Fall back to conventional filenames
      if [ -f "$DIR/app.py" ] && ! should_ignore "$DIR/app.py" "$DIR"; then
        main_file="app.py"
      elif [ -f "$DIR/main.py" ] && ! should_ignore "$DIR/main.py" "$DIR"; then
        main_file="main.py"
      elif [ -f "$DIR/asgi.py" ] && ! should_ignore "$DIR/asgi.py" "$DIR"; then
        main_file="asgi.py"
      fi
    fi
  elif [ -f "$DIR/manage.py" ] && ! should_ignore "$DIR/manage.py" "$DIR" && find "$DIR" -maxdepth 1 -name "*.py" -not -path "*/\.*" -type f | while read file; do
      if ! should_ignore "$file" "$DIR"; then
        grep -l "django" "$file"
      fi
    done | grep -q .; then
    language="python"
    framework="django"
    # For Django, check if there's a settings file with INSTALLED_APPS
    DJANGO_SETTINGS=$(find "$DIR" -name "settings.py" -not -path "*/\.*" -type f | while read file; do
      if ! should_ignore "$file" "$DIR"; then
        grep -l "INSTALLED_APPS" "$file"
      fi
    done | head -1)
    if [ -n "$DJANGO_SETTINGS" ]; then
      main_file=$(basename "$(dirname "$DJANGO_SETTINGS")")/settings.py
    else
      # Django main file is usually manage.py
      if [ -f "$DIR/manage.py" ]; then
        main_file="manage.py"
      fi
    fi
  fi

  echo "Checking for Ruby frameworks..."
  if [ -f "$DIR/Gemfile" ] && ! should_ignore "$DIR/Gemfile" "$DIR" && grep "rails" "$DIR/Gemfile" > /dev/null; then
    language="ruby"
    framework="ruby-on-rails"
    # Find the actual Rails application class
    RAILS_APP=$(find "$DIR" -name "application.rb" -not -path "*/\.*" -type f | while read file; do
      if ! should_ignore "$file" "$DIR"; then
        grep -l "class Application < Rails::Application" "$file"
      fi
    done | head -1)
    if [ -n "$RAILS_APP" ]; then
      main_file="config/application.rb"
    elif [ -f "$DIR/config.ru" ] && ! should_ignore "$DIR/config.ru" "$DIR"; then
      main_file="config.ru"
    fi
  fi

  echo "Checking for Java frameworks..."
  if [ -f "$DIR/pom.xml" ] && ! should_ignore "$DIR/pom.xml" "$DIR" && grep -i "spring" "$DIR/pom.xml" > /dev/null; then
    language="java"
    framework="spring"
    # Find Spring Boot main application class with @SpringBootApplication annotation
    SPRING_FILE=$(find "$DIR" -path "*/src/main/java/*" -name "*.java" -not -path "*/\.*" -type f | while read file; do
      if ! should_ignore "$file" "$DIR"; then
        grep -l "SpringApplication.run\|@SpringBootApplication" "$file"
      fi
    done | head -1)
    if [ -n "$SPRING_FILE" ]; then
      # Get the relative path from the project root
      main_file=${SPRING_FILE#$ABSOLUTE_PATH/}
    fi
  fi

  echo "Checking for Node.js frameworks..."
  if [ -f "$DIR/package.json" ] && ! should_ignore "$DIR/package.json" "$DIR" && grep -i "express" "$DIR/package.json" > /dev/null; then
    language="javascript"
    framework="express.js"
    # Find file where Express app is initialized
    EXPRESS_APP=$(find "$DIR" -name "*.js" -not -path "*/\.*" -type f | while read file; do
      if ! should_ignore "$file" "$DIR"; then
        grep -l "express()\|require('express')" "$file"
      fi
    done | head -1)
    if [ -n "$EXPRESS_APP" ]; then
      main_file=$(basename "$EXPRESS_APP")
    else
      # Fall back to conventional filenames
      if [ -f "$DIR/app.js" ] && ! should_ignore "$DIR/app.js" "$DIR"; then
        main_file="app.js"
      elif [ -f "$DIR/server.js" ] && ! should_ignore "$DIR/server.js" "$DIR"; then
        main_file="server.js"
      elif [ -f "$DIR/index.js" ] && ! should_ignore "$DIR/index.js" "$DIR"; then
        main_file="index.js"
      fi
    fi
  elif [ -f "$DIR/package.json" ] && ! should_ignore "$DIR/package.json" "$DIR" && grep -i "next" "$DIR/package.json" > /dev/null; then
    language="javascript"
    framework="next.js"
    # For Next.js, check for actual configuration or entry points
    if [ -f "$DIR/next.config.js" ] && ! should_ignore "$DIR/next.config.js" "$DIR"; then
      main_file="next.config.js"
    elif [ -f "$DIR/pages/_app.js" ] && ! should_ignore "$DIR/pages/_app.js" "$DIR"; then
      main_file="pages/_app.js"
    elif [ -f "$DIR/app/layout.js" ] && ! should_ignore "$DIR/app/layout.js" "$DIR"; then
      main_file="app/layout.js"
    fi
  fi

  if [ -n "$framework" ]; then
    # Extract port based on the detected framework
    port=$(extract_port "$DIR" "$framework" "$main_file")
    
    if [ "$first_entry" = true ]; then
      first_entry=false
    else
      echo "," >> swagger.config.json
    fi
    echo "  {\"path\":\"$ABSOLUTE_PATH\",\"relative_path\":\"$RELATIVE_PATH\",\"language\":\"$language\",\"framework\":\"$framework\",\"main_file\":\"$main_file\",\"port\":\"$port\"}" >> swagger.config.json
  fi
}

# Main script logic
DIR=${1:-.}

# Load gitignore patterns
load_gitignore_patterns "$DIR"

check_frameworks "$DIR"

# If no framework is found in the main directory, check subdirectories
if [ -z "$framework" ]; then
  for subdir in "$DIR"/*/; do
    # Skip if directory is gitignored
    if ! should_ignore "$subdir" "$DIR"; then
      check_frameworks "$subdir"
    else
      echo "Skipping gitignored directory: $subdir"
    fi
  done
fi

# Close the JSON array
echo "]" >> swagger.config.json