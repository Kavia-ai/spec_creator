// Updated app.js file to handle paths without leading slash
const express = require('express');
const fs = require('fs');
const path = require('path');
const app = express();
const port = process.env.PORT || 9876;
const { exec } = require('child_process');
const { createProxyMiddleware } = require('http-proxy-middleware');
const http = require('http');
const url = require('url');

// Middleware to parse JSON request bodies
app.use(express.json());

// Serve the Swagger UI from swagger-ui-dist
app.use(express.static(path.join(__dirname, 'public')));

// Function to get config data
async function getFrameworkConfig(basePath) {
  try {
    const configPath = path.join(basePath, 'swagger.config.json');
    
    if (!fs.existsSync(configPath)) {
      throw new Error(`Config file not found: ${configPath}`);
    }
    
    const configContent = fs.readFileSync(configPath, 'utf8');
    return JSON.parse(configContent);
  } catch (error) {
    console.error('Error reading config file:', error);
    throw error;
  }
}

// Function to find a framework by name
function findFramework(config, frameworkName) {
  return config.find(item => 
    item.framework.toLowerCase() === frameworkName.toLowerCase() ||
    (item.folder_name && item.folder_name.toLowerCase() === frameworkName.toLowerCase())
  );
}

// Proxy endpoint
app.use('/proxy/:framework/*', async (req, res) => {
  try {
    // Extract the framework name and path
    const frameworkName = req.params.framework;
    // Extract the path after the framework name
    const pathAfterFramework = req.url.substring(req.url.indexOf(frameworkName) + frameworkName.length);
    
    console.log(`Proxy request for framework: ${frameworkName}, path: ${pathAfterFramework}`);
    
    // Get basePath from query parameter
    const basePath = req.query.basePath;
    
    // Ensure basePath is provided
    if (!basePath) {
      return res.status(400).json({ error: 'basePath parameter is required' });
    }
    
    // Get the configuration data
    const configData = await getFrameworkConfig(basePath);
    
    // Find the framework
    const framework = findFramework(configData, frameworkName);
    
    if (!framework) {
      return res.status(404).json({ error: `Framework '${frameworkName}' not found` });
    }
    
    // Check if port is specified
    if (!framework.port) {
      return res.status(400).json({ error: `No port specified for framework '${frameworkName}'` });
    }
    
    const port = framework.port;
    const targetHost = `localhost:${port}`;
    
    console.log(`Proxying request to ${targetHost}${pathAfterFramework}`);
    
    // Create the proxy request
    const options = {
      hostname: 'localhost',
      port: port,
      path: pathAfterFramework,
      method: req.method,
      headers: { ...req.headers, host: targetHost },
    };
    
    // Create the proxy request
    const proxyReq = http.request(options, (proxyRes) => {
      // Copy headers from proxied response
      Object.keys(proxyRes.headers).forEach(key => {
        res.setHeader(key, proxyRes.headers[key]);
      });
      
      // Set status code
      res.statusCode = proxyRes.statusCode;
      
      // Pipe the response from the proxied server back to the client
      proxyRes.pipe(res);
    });
    
    // Handle errors in the proxy request
    proxyReq.on('error', (error) => {
      console.error(`Proxy error for ${targetHost}${pathAfterFramework}:`, error.message);
      if (!res.headersSent) {
        res.status(502).json({ 
          error: 'Proxy error', 
          message: error.message,
          details: `Could not connect to ${targetHost}`
        });
      }
    });
    
    // If there's a request body, pipe it to the proxy request
    if (['POST', 'PUT', 'PATCH'].includes(req.method) && req.body) {
      proxyReq.write(JSON.stringify(req.body));
    }
    
    // End the proxy request
    proxyReq.end();
    
  } catch (error) {
    console.error('Error in proxy middleware:', error);
    if (!res.headersSent) {
      res.status(500).json({ error: error.message });
    }
  }
});

// Alternate implementation using http-proxy-middleware
app.use('/proxy-alt/:framework', async (req, res, next) => {
  try {
    const frameworkName = req.params.framework;
    const basePath = req.query.basePath;
    
    // Ensure basePath is provided
    if (!basePath) {
      return res.status(400).json({ error: 'basePath parameter is required' });
    }
    
    // Get the configuration data
    const configData = await getFrameworkConfig(basePath);
    
    // Find the framework
    const framework = findFramework(configData, frameworkName);
    
    if (!framework) {
      return res.status(404).json({ error: `Framework '${frameworkName}' not found` });
    }
    
    // Check if port is specified
    if (!framework.port) {
      return res.status(400).json({ error: `No port specified for framework '${frameworkName}'` });
    }
    
    const port = framework.port;
    
    // Create a one-time proxy for this request
    const proxy = createProxyMiddleware({
      target: `http://localhost:${port}`,
      changeOrigin: true,
      pathRewrite: function (path) {
        // Remove the /proxy/{framework} part
        return path.substring(path.indexOf(frameworkName) + frameworkName.length) || '/';
      },
      onProxyReq: (proxyReq, req) => {
        // If there's a body and it's a JSON body, restream it
        if (req.body && Object.keys(req.body).length > 0) {
          const bodyData = JSON.stringify(req.body);
          proxyReq.setHeader('Content-Type', 'application/json');
          proxyReq.setHeader('Content-Length', Buffer.byteLength(bodyData));
          proxyReq.write(bodyData);
        }
      },
      logLevel: 'debug'
    });
    
    // Apply the proxy to this request
    proxy(req, res, next);
    
  } catch (error) {
    console.error('Error in proxy middleware:', error);
    if (!res.headersSent) {
      res.status(500).json({ error: error.message });
    }
  }
});

// Endpoint to get the swagger configuration
app.get('/config', (req, res) => {
  try {
    // Get basePath from query parameter
    const basePath = req.query.basePath;
    
    if (!basePath) {
      return res.status(400).json({ error: 'basePath parameter is required' });
    }
    
    // Use the basePath from parameter
    const configPath = path.join(basePath, 'swagger.config.json');
    
    if (!fs.existsSync(configPath)) {
      console.error(`Config file not found: ${configPath}`);
      return res.status(404).json({ error: 'Configuration file not found' });
    }
    
    const configContent = fs.readFileSync(configPath, 'utf8');
    let configData = JSON.parse(configContent);
    
    // Add folder_name property to each item
    configData = configData.map(item => {
      if (item.openapi_path) {
        // Extract folder name from the path
        const pathParts = item.openapi_path.split('/');
        let folderName = '';
        
        // Find the last non-empty folder name
        for (let i = pathParts.length - 1; i >= 0; i--) {
          if (pathParts[i] && pathParts[i] !== '' && 
              !pathParts[i].includes('.json') && 
              !pathParts[i].includes('.yaml') && 
              !pathParts[i].includes('.yml')) {
            folderName = pathParts[i];
            break;
          }
        }
        
        // Add the folder_name property
        item.folder_name = folderName;
      }
      
      // Add basePath to the item so clients know which path to use when making further requests
      item.basePath = basePath;
      
      return item;
    });
    
    res.setHeader('Content-Type', 'application/json');
    res.send(JSON.stringify(configData));
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
  const basePath = req.query.basePath;
  
  if (!filePath) {
    return res.status(400).send('No file path provided');
  }

  // Pass basePath parameter when calling spec endpoint
  const specUrl = basePath ? 
    `/spec?path=${encodeURIComponent(filePath)}&basePath=${encodeURIComponent(basePath)}` : 
    `/spec?path=${encodeURIComponent(filePath)}`;

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
          url: "${specUrl}",
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

// Endpoint to get the base path
app.get('/base-path', (req, res) => {
  // This endpoint is no longer needed as we're using URL parameters
  res.status(400).json({ error: 'This endpoint is deprecated. Pass basePath as a URL parameter to other endpoints.' });
});

// Endpoint to get available base paths
app.get('/base-paths', (req, res) => {
  // Define common locations to look for config files
  const commonLocations = [
    // Current working directory
    process.cwd(),
    // Home directory
    require('os').homedir(),
    // Temp directory
    require('os').tmpdir()
  ];
  
  // Only return paths that actually exist and contain swagger.config.json
  const availablePaths = commonLocations.filter(p => {
    try {
      return fs.existsSync(path.join(p, 'swagger.config.json'));
    } catch (error) {
      return false;
    }
  });
  
  res.json({ paths: availablePaths });
});

// Start the server
app.listen(port, () => {
  console.log(`Server running at http://localhost:${port}`);
});

// Add endpoints to run shell scripts

// Endpoint to run framework-detector.sh
app.post('/run-framework-detector', (req, res) => {
  // Get basePath from query parameter
  const basePath = req.query.basePath;
  
  if (!basePath) {
    return res.status(400).json({ error: 'basePath parameter is required' });
  }
  
  const scriptPath = path.join(__dirname, 'framework-detector.sh');
  const command = `sh "${scriptPath}" --source "${basePath}" --output "${basePath}"`;
  
  console.log(`Running command: ${command}`);
  
  exec(command, (error, stdout, stderr) => {
    if (error) {
      console.error(`Error running framework-detector: ${error.message}`);
      console.error(`stderr: ${stderr}`);
      return res.status(500).json({ error: error.message, stderr });
    }
    
    if (stderr) {
      console.log(`Framework detector stderr: ${stderr}`);
    }
    
    console.log(`Framework detector output: ${stdout}`);
    res.json({ success: true, message: 'Framework detection completed', output: stdout });
  });
});

// Endpoint to run openapi-builder.sh
app.post('/run-openapi-builder', (req, res) => {
  // Get basePath from query parameter
  const basePath = req.query.basePath;
  
  if (!basePath) {
    return res.status(400).json({ error: 'basePath parameter is required' });
  }
  
  const scriptPath = path.join(__dirname, 'openapi-builder.sh');
  const configPath = path.join(basePath, 'swagger.config.json');
  const command = `sh "${scriptPath}" --config "${configPath}"`;
  
  console.log(`Running command: ${command}`);
  
  exec(command, (error, stdout, stderr) => {
    if (error) {
      console.error(`Error running openapi-builder: ${error.message}`);
      console.error(`stderr: ${stderr}`);
      return res.status(500).json({ error: error.message, stderr });
    }
    
    if (stderr) {
      console.log(`OpenAPI builder stderr: ${stderr}`);
    }
    
    console.log(`OpenAPI builder output: ${stdout}`);
    res.json({ success: true, message: 'OpenAPI builder completed', output: stdout });
  });
});

// Endpoint to update the swagger.config.json file
app.post('/update-config', (req, res) => {
  try {
    // Get basePath from query parameter
    const basePath = req.query.basePath;
    
    if (!basePath) {
      return res.status(400).json({ error: 'basePath parameter is required' });
    }
    
    // Use the basePath from parameter
    const configPath = path.join(basePath, 'swagger.config.json');
    
    if (!fs.existsSync(configPath)) {
      console.error(`Config file not found: ${configPath}`);
      return res.status(404).json({ error: 'Configuration file not found' });
    }
    
    // Get the request body
    const { index, config } = req.body;
    
    if (index === undefined || !config) {
      return res.status(400).json({ error: 'Both index and config are required in the request body' });
    }
    
    // Read the current config file
    const configContent = fs.readFileSync(configPath, 'utf8');
    let configData = JSON.parse(configContent);
    
    // Check if the index is valid
    if (index < 0 || index >= configData.length) {
      return res.status(400).json({ error: 'Invalid index provided' });
    }
    
    // Update the config at the specified index
    configData[index] = config;
    
    // Write the updated config back to the file
    fs.writeFileSync(configPath, JSON.stringify(configData, null, 2), 'utf8');
    
    console.log(`Updated config file at ${configPath}`);
    res.json({ success: true, message: 'Configuration updated successfully' });
  } catch (error) {
    console.error('Error updating config file:', error);
    res.status(500).json({ error: error.message });
  }
});