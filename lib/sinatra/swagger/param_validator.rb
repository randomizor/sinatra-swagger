require 'sinatra/swagger/swagger_linked'
require 'string_bool'
require 'active_schema'

module Sinatra
  module Swagger
    module ParamValidator
      def self.registered(app)
        app.register Swagger::SwaggerLinked
        app.helpers Helpers

        app.before do
          next if swagger_spec.nil?
          _, captures, spec = swagger_spec.values
          invalid_content_type(spec['consumes']) if spec['consumes'] && !spec['consumes'].include?(request.content_type)

          # NB. The Validity parser will update the application params with defaults and typing as it goes
          vp = ValidityParser.new(request, params, captures, spec, settings.swagger['definitions'])

          invalid_params(vp.invalidities) if vp.invalidities?
          nil
        end
      end

      module Helpers
        def invalid_params(invalidities)
          error_response(
            'invalid_params',
            'Some of the given parameters were invalid according to the Swagger spec.',
            details: { invalidities: invalidities },
            status: 400
          )
        end

        def invalid_content_type(acceptable)
          error_response(
            'invalid_content',
            'The ',
            details: {
              content_types: {
                acceptable: acceptable,
                given: request.content_type
              }
            },
            status: 400
          )
        end

        def error_response(code, dev_message, details: {}, status: 400)
          content_type :json
          halt(status,{
            error: code,
            developerMessage: dev_message,
            details: details
          }.to_json)
        end
      end

      class ValidityParser
        attr_reader :request, :params, :captures, :spec, :definitions

        def initialize(request, params, captures, spec, definitions)
          @request = request
          @params = params
          @captures = captures
          @spec = spec
          @definitions = definitions
        end

        def invalidities?
          invalidities.any?
        end

        def invalidities
          return @invalidities unless @invalidities.nil?
          @parameters = spec['parameters'] || []

          validate_query if query_params.any?
          validate_body if body_params.any?

          @invalidities || []
        end

        def query_params
          @query_params ||= @parameters.select { |p| p['in'] == 'query' }.map do |qp|
            {
              qp['name'] => qp
            }
          end
        end

        def query_schema
          @required = []

          query_params.each do |qp|
            name    = qp.keys[0]
            details = qp.values[0]
            param   = params[name]

            # Cast parameter to correct type
            params[name] = cast(param.to_s, details['type']) if param

            # Add to required list if this parameter is required
            @required << name if details['required'] == true
          end

          @query_schema ||= {
            'type' => 'object',
            'required' => @required,
            'properties' => query_params.reduce({}, :merge)
          }
        end

        def body_params
          @body_params ||= @parameters.select { |p| p['in'] == 'body' }
        end

        def body_schema
          @body_schema ||= body_params[0]['schema'].merge!(
            definitions: definitions
          )
        end

        def validate_query
          validate(query_schema, params)
        end

        def validate_body
          request.body.rewind
          params[:body] = request.body.read

          validate(body_schema, params[:body].to_json) if params[:body]
        end

        private

        def validate(schema, params)
          schema_errors = ::JSON::Validator.fully_validate(
              schema,
              params,
              errors_as_objects: true
          )
          return unless schema_errors.any?

          formatted_errors = ActiveSchema::ErrorsFormatter.new(
            schema_errors
          ).format

          @invalidities = formatted_errors.map do |e|
            {
              e.key => I18n.t(
                e.message,
                e.options.merge(scope: 'errors.messages')
              )
            }
          end

          @invalidities = @invalidities.reduce({}, :merge)
        end

        def cast(value, type = 'string')
          return value unless value.is_a?(String)
          new_value = value
          case type
          when 'integer'
            new_value = value.to_i if value =~ /^-?\d+$/
          when 'number'
            new_value = value.to_f if value =~ /^-?\d+(?:\.\d+)?$/
          when 'boolean'
            new_value = value.to_bool if value =~ /^(true|t|yes|y|1|false|f|no|n|0)$/i
          end

          new_value
        end
      end
    end
  end
end
