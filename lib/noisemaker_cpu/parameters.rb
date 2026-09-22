# frozen_string_literal: true

require_relative "transpiler/shared_enums"

module NoisemakerCpu
  # The API, CLI and DSL all use the same value conversions. Metadata min/max
  # values describe UI sliders, so they are not treated as hard render limits.
  module Parameters
    def self.choices(spec)
      return spec["choices"].compact if spec["choices"].is_a?(Hash)

      enum = spec["type"] == "palette" ? "palette" : spec["enum"]
      Transpiler::SharedEnums::SHARED_ENUMS[enum] || {}
    end

    def self.normalize(effect, params)
      raise ArgumentError, "parameters must be a Hash" unless params.is_a?(Hash)

      id = "#{effect['namespace']}/#{effect['func']}"
      params.each_with_object({}) do |(name, value), result|
        name = name.to_s
        raise ArgumentError, "#{id}: duplicate parameter #{name.inspect}" if result.key?(name)
        spec = effect.fetch("params")[name]
        raise ArgumentError, "#{id}: unknown parameter #{name.inspect}" unless spec
        begin
          raise ArgumentError, "bind surfaces in the inputs Hash" if spec["type"] == "surface"
          result[name] = coerce(spec, value)
        rescue ArgumentError, TypeError => error
          raise ArgumentError, "#{id} parameter #{name.inspect}: #{error.message}"
        end
      end
    end

    def self.number(value)
      number = Float(value)
      rounded = [number].pack("e").unpack1("e")
      raise ArgumentError, "expected a finite float32 number" unless rounded.finite?
      rounded
    end

    def self.coerce(spec, value)
      value = spec["default"] if value.nil?
      type = spec["type"]
      case type
      when "float"
        number(value.nil? ? 0 : value)
      when "int", "enum", "member", "palette"
        options = choices(spec)
        if value.is_a?(String) || value.is_a?(Symbol)
          key = value.to_s.split(".").last
          return options[key] if options.key?(key)
          value = Integer(value.to_s, 10)
        end
        unless value.is_a?(Integer) || (value.is_a?(Float) && value.finite? && value == value.to_i)
          raise ArgumentError, "expected an integer or one of: #{options.keys.join(', ')}"
        end
        value = value.to_i
        # Size dropdowns are presets; renderers also support smaller test atlases.
        custom_size = type == "int" && %w[volumeSize stateSize].include?(spec["uniform"])
        raise ArgumentError, "expected a positive size" if custom_size && value <= 0
        if !custom_size && !options.empty? && !options.value?(value)
          raise ArgumentError, "expected one of: #{options.keys.join(', ')} (or its numeric value)"
        end
        value
      when "bool", "boolean"
        return 1 if value == true || value == 1 || value.to_s.strip.match?(/\A(?:1|true|yes|on)\z/i)
        return 0 if value == false || value == 0 || value.to_s.strip.match?(/\A(?:0|false|no|off)\z/i)
        raise ArgumentError, "expected true/false, 1/0, yes/no or on/off"
      when "color", "vec2", "vec3", "vec4", "mat3"
        if type == "color" && value.is_a?(String)
          hex = value.delete_prefix("#")
          unless hex.match?(/\A(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})\z/)
            raise ArgumentError, "expected an RGB(A) hex color or an array of components"
          end
          hex = hex.chars.map { |digit| digit * 2 }.join if hex.length <= 4
          value = hex.scan(/../).map { |pair| pair.to_i(16).fdiv(255) }
        elsif value.is_a?(String)
          value = value.split(",", -1)
        end
        lengths = type == "color" ? [3, 4] : [type == "mat3" ? 9 : type[-1].to_i]
        unless value.is_a?(Array) && lengths.include?(value.length)
          raise ArgumentError, "expected #{lengths.join(' or ')} numeric components"
        end
        value.map { |component| number(component) }
      else
        value
      end
    end
  end
end
