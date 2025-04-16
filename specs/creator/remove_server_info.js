// Simple script to remove server information from OpenAPI files
const fs = require('fs');
const path = require('path');

// Parse command line arguments
if (process.argv.length < 3) {
  console.log('Usage: node remove_server_info.js <openapi_file>');
  process.exit(1);
}

const openApiFile = process.argv[2];

// Check if file exists
if (!fs.existsSync(openApiFile)) {
  console.error(`Error: File ${openApiFile} not found`);
  process.exit(1);
}

console.log(`Processing ${openApiFile}...`);

try {
  // Read the file
  const data = fs.readFileSync(openApiFile, 'utf8');
  
  // Parse JSON
  const openApi = JSON.parse(data);
  
  // Remove host, servers, etc.
  if (openApi.host) {
    delete openApi.host;
    console.log('Removed "host" property');
  }
  
  if (openApi.servers) {
    delete openApi.servers;
    console.log('Removed "servers" property');
  }
  
  // Write the file back
  fs.writeFileSync(openApiFile, JSON.stringify(openApi, null, 2), 'utf8');
  console.log(`✅ Successfully removed server information from ${openApiFile}`);
} catch (err) {
  console.error(`Error processing file: ${err.message}`);
  process.exit(1);
} 