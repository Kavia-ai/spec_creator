FROM swaggerapi/swagger-ui

# Copy the custom CSS that hides the header
RUN echo ".swagger-ui .topbar { display: none !important; }" > /usr/share/nginx/html/custom.css

# Modify the index.html to include our custom CSS
RUN sed -i 's/<\/head>/<link rel="stylesheet" type="text\/css" href="custom.css" \/><\/head>/' /usr/share/nginx/html/index.html

