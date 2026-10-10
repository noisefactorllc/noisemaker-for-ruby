# frozen_string_literal: true

require_relative "transpiler/shared_enums"
require_relative "automation"

module NoisemakerCpu
  # A numeric parameter value outside its declared min/max range. Mirrors the
  # pinned oracle's src/effects/definition.js, which raises
  # `RangeError('Parameter "<name>" must be at most <max>')` after coercing
  # every numeric parameter value; this port enforces the bound for the
  # `seed` parameter only (README: metadata slider ranges are hints, not
  # clamps). A plain StandardError (not an ArgumentError): a range violation
  # is a render-time value error, so the CLI reports it as a named cause with
  # exit 1, not as a usage error.
  class ParameterRangeError < StandardError; end

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
          result[name] = coerce(spec, value, name)
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

    # Render a declared range bound the way JS Number -> String does: the
    # metadata declares some maxima as integral floats (1000.0), but the
    # reference diagnostic prints `1000`.
    def self._bound_text(bound)
      bound.is_a?(Float) && bound.finite? && bound == bound.to_i ? bound.to_i.to_s : bound.to_s
    end

    # Enforce a numeric parameter's declared min/max range -- SEED ONLY.
    #
    # The reference oracle (src/effects/definition.js) range-checks every
    # numeric parameter, but this port's published contract (README, Library
    # section) deliberately keeps metadata slider ranges as hints, not
    # clamps, for everything else. The one enforced case is the `seed`
    # parameter: the CLI's unseeded draw selects from it, and out-of-range
    # seeds render degenerate output rather than a clean diagnostic. `name
    # == nil` also skips the check: the DSL renderer's IMPLICIT render-seed
    # threading stays unvalidated, which the pinned oracle also leaves
    # unvalidated (runtime/renderer.js spreads the render seed into step
    # params without a range check; explicit DSL assignments are validated).
    # Automation (`osc(...)`) values return from #coerce before reaching the
    # numeric branches and stay unvalidated, like the reference.
    def self._check_range(spec, name, number)
      return if name.nil? || name != "seed"
      return unless number.is_a?(Numeric)

      declared_min = spec["min"]
      declared_max = spec["max"]
      if !declared_min.nil? && number < declared_min
        raise ParameterRangeError, "Parameter \"#{name}\" must be at least #{_bound_text(declared_min)}"
      end
      if !declared_max.nil? && number > declared_max
        raise ParameterRangeError, "Parameter \"#{name}\" must be at most #{_bound_text(declared_max)}"
      end
    end

    def self.coerce(spec, value, name = nil)
      value = spec["default"] if value.nil?
      type = spec["type"]
      # An `osc(...)` automation value (numeric params only, matching the
      # upstream uniformSpecs contract) is kept as-is here and resolved to a
      # concrete number per render in Renderer (see Automation). Other types
      # keep rejecting it below.
      return value if Automation.automation_value?(value) && (type == "float" || type == "int")

      case type
      when "float"
        # The finite-float32 check runs before the range check (an overflow
        # like 1e100 is a finiteness problem here, matching this port's
        # established diagnostic), so the range test sees a finite f32 value.
        number(value.nil? ? 0 : value).tap { |rounded| _check_range(spec, name, rounded) }
      when "int", "enum", "member", "palette"
        options = choices(spec)
        if value.is_a?(String) || value.is_a?(Symbol)
          key = value.to_s.split(".").last
          return options[key].tap { |v| _check_range(spec, name, v) } if options.key?(key)
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
        _check_range(spec, name, value)
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
