// Updated app.js file to handle paths without leading slash
const express = require('express');
const fs = require('fs');
const path = require('path');
const app = express();
const port = process.env.PORT || 9876;

// Serve the Swagger UI from swagger-ui-dist
app.use(express.static(path.join(__dirname, 'public')));

// Endpoint to get the swagger configuration
app.get('/config', (req, res) => {
  try {
    // Use the absolute path specified by the user
    const configPath = '/Volumes/Praveen/Skillrank/kavia/SwaggerOpenApi/OPENAPI/swagger.config.json';
    
    if (!fs.existsSync(configPath)) {
      console.error(`Config file not found: ${configPath}`);
      return res.status(404).json({ error: 'Configuration file not found' });
    }
    
    const configContent = fs.readFileSync(configPath, 'utf8');
    res.setHeader('Content-Type', 'application/json');
    res.send(configContent);
  } catch (error) {
    console.error('Error reading config file:', error);
    res.status(500).json({ error: error.message });
  }
});

// Endpoint to get the OpenAPI specification
app.get('/spec', (req, res) => {
  try {
    let filePath = req.query.path;
    
    console.log('Received request for spec with path:', filePath);
    
    if (!filePath) {
      console.error('No file path provided in request');
      return res.status(400).json({ error: 'No file path provided' });
    }
    
    // Handle file paths with or without leading slash based on platform
    if (process.platform !== 'win32') {
      // On Unix-like systems, ensure we have an absolute path
      filePath = path.isAbsolute(filePath) ? filePath : '/' + filePath;
    } else {
      // On Windows, don't add a leading slash
      // Windows absolute paths typically start with drive letter (C:\)
      // No changes needed for Windows paths
    }
    
    console.log(`Attempting to read file from normalized path: ${filePath}`);
    
    // Check if file exists
    if (!fs.existsSync(filePath)) {
      console.error(`File not found: ${filePath}`);
      return res.status(404).json({ error: `File not found: ${filePath}` });
    }
    
    // Read and send the file
    const content = fs.readFileSync(filePath, 'utf8');
    console.log(`Successfully read file, size: ${content.length} bytes`);
    
    // Determine content type based on extension
    const ext = path.extname(filePath).toLowerCase();
    const contentType = (ext === '.yaml' || ext === '.yml') ? 'application/yaml' : 'application/json';
    
    // Set headers
    res.setHeader('Content-Type', contentType);
    res.setHeader('Access-Control-Allow-Origin', '*');
    
    res.send(content);
  } catch (error) {
    console.error('Error reading file:', error);
    res.status(500).json({ error: error.message });
  }
});

// Add a route to directly view a spec in standalone mode
app.get('/view', (req, res) => {
  const filePath = req.query.path;
  
  if (!filePath) {
    return res.status(400).send('No file path provided');
  }

  // Simple HTML page that loads the spec directly
  const html = `
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>OpenAPI Viewer</title>
    <link rel="stylesheet" type="text/css" href="https://cdnjs.cloudflare.com/ajax/libs/swagger-ui/4.18.3/swagger-ui.css" />
    <style>
      body { margin: 0; padding: 0; }
      #swagger-ui { max-width: 1200px; margin: 0 auto; }
    </style>
  </head>
  <body>
    <div id="swagger-ui"></div>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/swagger-ui/4.18.3/swagger-ui-bundle.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/swagger-ui/4.18.3/swagger-ui-standalone-preset.js"></script>
    <script>
      window.onload = function() {
        const ui = SwaggerUIBundle({
          url: "/spec?path=${encodeURIComponent(filePath)}",
          dom_id: '#swagger-ui',
          deepLinking: true,
          presets: [
            SwaggerUIBundle.presets.apis,
            SwaggerUIStandalonePreset
          ],
          plugins: [
            SwaggerUIBundle.plugins.DownloadUrl
          ],
          layout: "StandaloneLayout"
        });
      }
    </script>
  </body>
  </html>
  `;
  
  res.send(html);
});

// Home route
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// Start the server
app.listen(port, () => {
  console.log(`Server running at http://localhost:${port}`);
});