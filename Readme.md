mvn spring-boot:run

docker run -p 8085:8080 -e SWAGGER_JSON=/output/openapi.json -v /Volumes/Praveen/Skillrank/kavia/SwaggerOpenApi/OPENAPI/output/openapi.json:/output/openapi.json swagger-ui-no-header
