module Ai
  # Parses model output as JSON and validates it against a small subset of
  # JSON Schema — enough for our fixed output shapes without adding a gem.
  #
  # Supported keywords: type (object/array/string/integer/number/boolean,
  # or an array of types), properties, required, additionalProperties
  # (false only), items, enum, maxLength, maxItems, pattern.
  #
  #   result = Ai::StructuredOutput.parse(text, schema)
  #   result.ok?      # => true when JSON parsed and validated
  #   result.data     # => Hash (only when ok?)
  #   result.errors   # => ["summary: is required", ...]
  module StructuredOutput
    Result = Struct.new(:data, :errors, :parsed_json, keyword_init: true) do
      def ok?
        errors.empty?
      end
    end

    module_function

    def parse(text, schema)
      json = extract_json(text.to_s)
      return Result.new(data: nil, errors: [ "response is not valid JSON" ], parsed_json: false) if json.nil?

      errors = validate(json, schema)
      Result.new(data: errors.empty? ? json : nil, errors: errors, parsed_json: true)
    end

    # Accepts bare JSON, JSON in ```json fences, or JSON embedded in prose.
    def extract_json(text)
      candidate = text.strip
      if (fenced = candidate.match(/```(?:json)?\s*(\{[\s\S]*?\})\s*```/))
        candidate = fenced[1]
      end
      JSON.parse(candidate)
    rescue JSON::ParserError
      match = text.match(/\{[\s\S]*\}/)
      return nil unless match
      begin
        JSON.parse(match[0])
      rescue JSON::ParserError
        nil
      end
    end

    def validate(value, schema, path = "$")
      errors = []
      types  = Array(kw(schema, "type")).map(&:to_s)

      if types.any? && types.none? { |t| type_match?(value, t) }
        return [ "#{path}: expected #{types.join(' or ')}" ]
      end

      enum = kw(schema, "enum")
      errors << "#{path}: must be one of #{enum.join(', ')}" if enum && !enum.include?(value)

      case value
      when String
        max = kw(schema, "maxLength")
        errors << "#{path}: longer than #{max}" if max && value.length > max
        pattern = kw(schema, "pattern")
        errors << "#{path}: does not match #{pattern}" if pattern && !value.match?(Regexp.new(pattern))
      when Array
        max = kw(schema, "maxItems")
        errors << "#{path}: more than #{max} items" if max && value.length > max
        items = kw(schema, "items")
        value.each_with_index { |v, i| errors.concat(validate(v, items, "#{path}[#{i}]")) } if items
      when Hash
        props    = (kw(schema, "properties") || {}).transform_keys(&:to_s)
        required = Array(kw(schema, "required")).map(&:to_s)
        required.each { |k| errors << "#{path}.#{k}: is required" unless value.key?(k) }

        if (kw(schema, "additionalProperties")) == false
          (value.keys - props.keys).each { |k| errors << "#{path}.#{k}: is not allowed" }
        end

        props.each do |key, sub|
          errors.concat(validate(value[key], sub, "#{path}.#{key}")) if value.key?(key)
        end
      end

      errors
    end

    # Schema keyword lookup accepting string or symbol keys. Uses key? so
    # that `false` values (additionalProperties: false) are preserved.
    def kw(schema, name)
      return schema[name] if schema.key?(name)
      schema[name.to_sym]
    end

    def type_match?(value, type)
      case type
      when "object"  then value.is_a?(Hash)
      when "array"   then value.is_a?(Array)
      when "string"  then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "number"  then value.is_a?(Numeric)
      when "boolean" then value == true || value == false
      when "null"    then value.nil?
      else true
      end
    end

    # Strips keywords that constrained-decoding APIs may not accept, giving
    # a wire schema; the full schema is still enforced locally.
    def wire_schema(schema)
      case schema
      when Hash
        schema.each_with_object({}) do |(k, v), out|
          next if %w[maxLength maxItems pattern].include?(k.to_s)
          out[k] = wire_schema(v)
        end
      when Array then schema.map { |v| wire_schema(v) }
      else schema
      end
    end
  end
end
