// swagger-autogen.js
const swaggerAutogen = require('swagger-autogen')({ openapi: '3.0.0', disableSwaggerHostInformation: true });
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

/**
 * OpenAPI specification template
 * 
 * IMPORTANT NOTES FOR FUTURE MODIFICATIONS:
 * 1. The 'openapi' field defines the version of the OpenAPI spec (3.0.0)
 * 2. No 'host' or 'servers' fields should be added to allow the spec to work with 
 *    the current host where the Swagger UI is served
 * 3. If you need to add auth, update the 'securityDefinitions' or 'components.securitySchemes' section
 * 4. To add models/schemas, use the 'definitions' or 'components.schemas' section
 * 5. Base path is set to '/proxy' for all endpoints
 */
const doc = {
  openapi: '3.0.0',
  info: {
    title: 'My Express API',
    description: 'API Documentation',
    version: '1.0.0',
  },
  basePath: '/proxy/express.js',
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
swaggerAutogen(outputFile, endpointsFiles, doc)
  .then(() => {
    // Post-process the generated file to remove any host/server information
    // that might be added by the swagger-autogen library
    try {
      const openApiContent = fs.readFileSync(outputFile, 'utf8');
      const openApiSpec = JSON.parse(openApiContent);
      
      // Remove host and servers properties if they exist
      if (openApiSpec.host) {
        console.log(`Removing 'host' property from OpenAPI spec`);
        delete openApiSpec.host;
      }
      
      if (openApiSpec.servers) {
        console.log(`Removing 'servers' property from OpenAPI spec`);
        delete openApiSpec.servers;
      }
      
      // Add servers with basePath for OpenAPI 3.0
      console.log(`Adding base path '/proxy' to OpenAPI spec`);
      openApiSpec.servers = [
        {
          url: '/proxy/express.js'
        }
      ];
      
      // Write the modified spec back to the file
      fs.writeFileSync(outputFile, JSON.stringify(openApiSpec, null, 2), 'utf8');
      console.log(`OpenAPI specification generated successfully at ${outputFile}`);
      console.log(`Base path set to '/proxy'`);
    } catch (err) {
      console.error(`Error post-processing OpenAPI file: ${err.message}`);
    }
  })
  .catch(err => {
    console.error(`Error generating OpenAPI specification: ${err.message}`);
  });