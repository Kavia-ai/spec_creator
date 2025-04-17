# OpenAPI Specification Generator

This tool automatically generates OpenAPI specifications from various web frameworks and displays them using Swagger UI.

## Supported Frameworks

- Spring Boot (Java)
- Express.js (Node.js)
- Flask (Python)
- Ruby on Rails (Ruby)

## Prerequisites

Depending on the framework of your project, ensure you have the following installed:

- **Java/Spring Boot**: JDK and Maven
- **Node.js/Express.js**: Node.js and npm
- **Python/Flask**: Python 3 and pip
- **Ruby/Rails**: Ruby and Bundler

## Installation

1. Clone this repository
2. Setup dependencies for your framework:

   **For Spring Boot projects:**
   ```
   # Spring dependencies are managed through Maven
   ```

   **For Express.js projects:**
   ```
   cd specs
   npm install
   ```

   **For Flask projects:**
   ```
   cd specs
   python -m venv env
   source env/bin/activate  # On Windows: env\Scripts\activate
   pip install -r requirements.txt
   ```

   **For Ruby on Rails projects:**
   ```
   # Rails-specific setup
   ```

## Usage

### Generating OpenAPI Specifications

The tool will detect your framework and generate the appropriate OpenAPI specification.

1. Run the framework detection and OpenAPI builder:
   ```
   ./specs/openapi-builder.sh <path-to-your-project>
   ```

2. For Spring Boot applications, you can run the application to generate specs:
   ```
   mvn spring-boot:run
   ```

### Viewing API Documentation

Start the built-in web server to view the generated OpenAPI specification:

```
cd specs
node app.js
```

Then open your browser and navigate to `http://localhost:3000` (or the configured port) to view the API documentation.

## Configuration

The generator can be configured using the `specs/spec_generator.config.json` file, which defines:

- Framework-specific creators for generating OpenAPI specs
- Virtual environment paths for different frameworks

## Development

To run the spec generator in development mode:

```
cd specs
node app.js
```

## Project Structure

- `specs/` - Main directory for the specification generator
  - `creators/` - Framework-specific spec creator implementations
  - `env/` - Python virtual environment
  - `app.js` - Main application for serving Swagger UI
  - `openapi-builder.sh` - Main script for building OpenAPI specs
  - `framework-detector.sh` - Script to detect the framework of a project

