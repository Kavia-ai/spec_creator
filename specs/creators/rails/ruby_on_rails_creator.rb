#!/usr/bin/env ruby
# openapi_spec_creator.rb
# Non-invasive OpenAPI specification generator for Rails applications
# Usage: ruby openapi_spec_creator.rb -e /path/to/rails/app -o /path/to/output.json
#
# Note: This generator sets the base path to '/proxy' for all endpoints

require 'yaml'
require 'json'
require 'pathname'
require 'set'
require 'optparse'
require 'fileutils'

class FixedRailsOpenAPIGenerator
  attr_reader :rails_root, :output_path

  def initialize(rails_root, output_path)
    @rails_root = Pathname.new(rails_root)
    @output_path = Pathname.new(output_path)
    @routes = []
    @controllers = {}
    @models = {}
    @used_operation_ids = Set.new
  end

  # Simple pluralize method without requiring Rails
  def pluralize(word)
    return word if word.empty?
    
    # Very basic pluralization rules
    if word.end_with?('s', 'x', 'z', 'ch', 'sh')
      "#{word}es"
    elsif word.end_with?('y') && !%w(a e i o u).include?(word[-2])
      "#{word[0..-2]}ies"
    else
      "#{word}s"
    end
  end

  def generate
    load_rails_environment
    extract_routes
    extract_controllers
    extract_models
    generate_openapi_spec
  end

  private

  def load_rails_environment
    # We're only analyzing the files, not loading the Rails environment
    puts "Analyzing Rails application in #{rails_root}"
  end

  def extract_routes
    routes_file = rails_root.join('config', 'routes.rb')
    
    puts "Extracting routes from #{routes_file}"
    
    if File.exist?(routes_file)
      content = File.read(routes_file)
      
      # Extract RESTful resource declarations
      content.scan(/resources?\s+:(\w+)/) do |match|
        resource = match[0]
        add_resource_routes(resource)
      end
      
      # Extract custom routes
      content.scan(/(\w+)\s+['"]([^'"]+)['"]\s*,\s*to:\s*['"](\w+)#(\w+)['"]/) do |match|
        method, path, controller, action = match
        add_custom_route(method, path, controller, action)
      end
      
      # Extract routes with common HTTP verbs
      %w(get post put patch delete).each do |verb|
        content.scan(/#{verb}\s+['"]([^'"]+)['"]\s*,\s*to:\s*['"](\w+)#(\w+)['"]/) do |match|
          path, controller, action = match
          add_custom_route(verb, path, controller, action)
        end
      end
    else
      puts "Warning: routes.rb not found"
    end
  end

  def add_resource_routes(resource)
    # Add standard RESTful routes
    # Use our custom pluralize method
    controller = pluralize(resource)
    
    # Create conventional RESTful routes
    @routes << { method: 'get', path: "/#{resource}", controller: controller, action: 'index' }
    @routes << { method: 'get', path: "/#{resource}/{id}", controller: controller, action: 'show' }
    @routes << { method: 'post', path: "/#{resource}", controller: controller, action: 'create' }
    @routes << { method: 'put', path: "/#{resource}/{id}", controller: controller, action: 'update' }
    @routes << { method: 'delete', path: "/#{resource}/{id}", controller: controller, action: 'destroy' }
  end

  def add_custom_route(method, path, controller, action)
    # Convert Rails route to OpenAPI path format
    # Transform :param to {param}
    openapi_path = path.gsub(/:(\w+)/, '{\1}')
    @routes << { method: method.downcase, path: openapi_path, controller: controller, action: action }
  end

  def extract_controllers
    controllers_dir = rails_root.join('app', 'controllers')
    
    puts "Extracting controllers from #{controllers_dir}"
    
    if Dir.exist?(controllers_dir)
      Dir.glob(controllers_dir.join('**', '*.rb')).each do |file|
        controller_name = File.basename(file, '.rb').sub(/_controller$/, '')
        @controllers[controller_name] = parse_controller_file(file)
      end
    else
      puts "Warning: controllers directory not found"
    end
  end

  def parse_controller_file(file)
    content = File.read(file)
    actions = {}
    
    # Extract action methods
    content.scan(/def\s+(\w+)(.*?)end/m) do |match|
      action_name, action_body = match
      description = extract_comment_before(content, "def #{action_name}")
      actions[action_name] = {
        description: description || "#{action_name.capitalize} action",
        parameters: extract_parameters(action_body)
      }
    end
    
    actions
  end

  def extract_comment_before(content, target)
    index = content.index(target)
    return nil unless index
    
    # Look for comments before the target
    line_start = content.rindex("\n", index) || 0
    comment_section = content[0...line_start]
    comment_lines = []
    
    # Walk backwards through lines until we hit a non-comment line
    line_end = line_start
    while line_end > 0
      line_start = content.rindex("\n", line_end-1) || 0
      line = content[line_start...line_end].strip
      
      if line.start_with?('#')
        comment_lines.unshift(line.sub(/^\s*#\s*/, ''))
      else
        break unless line.empty? # Allow blank lines in comments
      end
      
      line_end = line_start
    end
    
    return nil if comment_lines.empty?
    comment_lines.join("\n")
  end

  def extract_parameters(action_body)
    params = []
    param_names = Set.new
    
    # Extract parameters from params[:x] patterns
    action_body.scan(/params\[:(\w+)\]/) do |match|
      param_name = match[0]
      next if param_names.include?(param_name) # Skip duplicates
      
      param_names.add(param_name)
      params << {
        name: param_name,
        in: 'query',
        required: false,
        schema: { type: 'string' }
      }
    end
    
    params
  end

  def extract_models
    models_dir = rails_root.join('app', 'models')
    
    puts "Extracting models from #{models_dir}"
    
    if Dir.exist?(models_dir)
      Dir.glob(models_dir.join('*.rb')).each do |file|
        model_name = File.basename(file, '.rb')
        @models[model_name] = parse_model_file(file)
      end
    else
      puts "Warning: models directory not found"
    end
  end

  def parse_model_file(file)
    content = File.read(file)
    attributes = {}
    
    # Look for database columns through schema information
    content.scan(/\#\s+(\w+)\s+:(\w+)/) do |match|
      column_name, column_type = match
      attributes[column_name] = map_rails_type_to_openapi(column_type)
    end
    
    # Try to extract attributes from model definition
    content.scan(/attribute\s+:(\w+),\s+[:'"](\w+)['"]/) do |match|
      attr_name, attr_type = match
      attributes[attr_name] = map_rails_type_to_openapi(attr_type)
    end
    
    # Look for validations which might indicate required attributes
    validations = {}
    content.scan(/validates\s+:(\w+),\s+presence:\s+true/) do |match|
      validations[match[0]] = { required: true }
    end
    
    { attributes: attributes, validations: validations }
  end

  def map_rails_type_to_openapi(rails_type)
    case rails_type
    when 'string', 'text', 'char'
      'string'
    when 'integer', 'bigint'
      'integer'
    when 'float', 'decimal', 'double'
      'number'
    when 'boolean'
      'boolean'
    when 'date', 'time'
      'string'
    when 'datetime', 'timestamp'
      'string'
    when 'json', 'jsonb'
      'object'
    else
      'string'
    end
  end

  def generate_unique_operation_id(base_id)
    operation_id = base_id
    suffix = 1
    
    while @used_operation_ids.include?(operation_id)
      operation_id = "#{base_id}_#{suffix}"
      suffix += 1
    end
    
    @used_operation_ids.add(operation_id)
    operation_id
  end

  def generate_openapi_spec
    puts "Generating OpenAPI specification..."
    
    spec = {
      openapi: '3.0.0',
      info: {
        title: "#{File.basename(rails_root)} API",
        description: "API Documentation for #{File.basename(rails_root)}",
        version: '1.0.0'
      },
      servers: [
        {
          url: '/proxy/ruby-on-rails',
          description: 'API with base path'
        }
      ],
      paths: generate_paths,
      components: {
        schemas: generate_schemas
      }
    }
    
    # Ensure output directory exists
    FileUtils.mkdir_p(File.dirname(output_path))
    
    # Write to output file
    File.write(output_path, JSON.pretty_generate(spec))
    
    puts "✅ Successfully generated OpenAPI specification at #{output_path}"
    puts "   Base path set to '/proxy/ruby-on-rails'"
    puts "   Note: You may want to validate this specification using a tool like swagger-cli"
  end

  def generate_paths
    paths = {}
    
    @routes.each do |route|
      path = route[:path]
      method = route[:method]
      controller = route[:controller]
      action = route[:action]
      
      paths[path] ||= {}
      
      # Generate a unique operationId for each operation
      operation_id = generate_unique_operation_id("#{controller}_#{action}")
      
      operation = {
        summary: "#{action.capitalize} #{controller}",
        operationId: operation_id,
        responses: {
          '200': {
            description: 'Successful operation'
          }
        }
      }
      
      # Add description from controller if available
      if @controllers[controller] && @controllers[controller][action]
        operation[:description] = @controllers[controller][action][:description]
      end
      
      # Process parameters, ensuring no duplicates
      parameters = []
      param_keys = Set.new  # To track unique param name+in combinations
      
      # Add path parameters first
      path_params = path.scan(/\{([^}]+)\}/).flatten
      path_params.each do |param|
        param_key = "#{param}:path"
        next if param_keys.include?(param_key)
        
        param_keys.add(param_key)
        parameters << {
          name: param,
          in: 'path',
          required: true,
          schema: { type: 'string' }
        }
      end
      
      # Add controller parameters
      if @controllers[controller] && @controllers[controller][action] && @controllers[controller][action][:parameters]
        @controllers[controller][action][:parameters].each do |param|
          param_key = "#{param[:name]}:#{param[:in]}"
          next if param_keys.include?(param_key)
          
          param_keys.add(param_key)
          parameters << param
        end
      end
      
      # Only add parameters if we have any
      operation[:parameters] = parameters if parameters.any?
      
      paths[path][method] = operation
    end
    
    paths
  end

  def generate_schemas
    schemas = {}
    
    @models.each do |model_name, model_info|
      properties = {}
      required = []
      
      model_info[:attributes].each do |attr_name, attr_type|
        properties[attr_name] = { type: attr_type }
        
        # Check if attribute is required
        if model_info[:validations][attr_name] && model_info[:validations][attr_name][:required]
          required << attr_name
        end
      end
      
      # If no properties were found but we can find a schema.rb file, try to extract from there
      if properties.empty? && File.exist?(rails_root.join('db', 'schema.rb'))
        schema_content = File.read(rails_root.join('db', 'schema.rb'))
        table_name = pluralize(model_name.downcase)
        
        if schema_content =~ /create_table\s+"#{table_name}".*?do\s+\|t\|(.*?)end/m
          table_block = $1
          table_block.scan(/t\.(\w+)\s+"(\w+)"/) do |type, name|
            properties[name] = { type: map_rails_type_to_openapi(type) }
          end
        end
      end
      
      # Only add if we found properties
      if properties.any?
        schemas[model_name] = {
          type: 'object',
          properties: properties
        }
        
        if required.any?
          schemas[model_name][:required] = required
        end
      end
    end
    
    schemas
  end
end

# Parse command line arguments
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: ruby openapi_spec_creator.rb -e RAILS_APP_PATH -o OUTPUT_FILE"

  opts.on("-e", "--endpoint PATH", "Path to Rails application") do |e|
    options[:rails_path] = e
  end

  opts.on("-o", "--output FILE", "Output file path for OpenAPI specification") do |o|
    options[:output_path] = o
  end

  opts.on("-h", "--help", "Display this help message") do
    puts opts
    exit
  end
end.parse!

# Validate required arguments
if options[:rails_path].nil? || options[:output_path].nil?
  puts "Error: Both -e (Rails app path) and -o (output file) are required"
  puts "Usage: ruby openapi_spec_creator.rb -e RAILS_APP_PATH -o OUTPUT_FILE"
  exit 1
end

# Execute the generator
generator = FixedRailsOpenAPIGenerator.new(options[:rails_path], options[:output_path])
generator.generate