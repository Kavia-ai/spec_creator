// swagger-autogen.js
const swaggerAutogen = require('swagger-autogen')();
const fs = require('fs');
const path = require('path');

// Parse command line arguments
const args = process.argv.slice(2);
let outputFile = '';
const endpointsFiles = [];

for (let i = 0; i < args.length; i++) {
  if (args[i] === '-o' && i + 1 < args.length) {
    outputFile = args[i + 1];
    i++;
  } else if (args[i] === '-e' && i + 1 < args.length) {
    endpointsFiles.push(args[i + 1]);
    i++;
  }
}

if (!outputFile || endpointsFiles.length === 0) {
  console.log('Usage: node openapi_spec_creator.js -e <endpoint_file1> -e <endpoint_file2> -o <output_file>');
  process.exit(1);
}

const doc = {
  info: {
    title: 'My Express API',
    description: 'API Documentation',
    version: '1.0.0',
  },
  host: 'localhost:8081',
  basePath: '/',
  schemes: ['http'],
  consumes: ['application/json'],
  produces: ['application/json'],
  tags: [
    {
      name: 'API Endpoints',
      description: 'API Endpoints'
    },
  ],
  securityDefinitions: {
    // You can add security definitions here if needed
  },
  definitions: {
    // You can add model definitions here if needed
  }
};

// Ensure the output directory exists
const outputDir = path.dirname(outputFile);
if (!fs.existsSync(outputDir)) {
  fs.mkdirSync(outputDir, { recursive: true });
}

// Generate the OpenAPI specification
swaggerAutogen(outputFile, endpointsFiles, doc).then(() => {
  console.log('OpenAPI specification generated successfully');
});