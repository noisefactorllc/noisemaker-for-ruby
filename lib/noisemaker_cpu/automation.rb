# frozen_string_literal: true

# CPU port of upstream Noisemaker automation evaluation
# (shaders/src/runtime/pipeline.js): oscillator-driven parameter values written as
# `osc(...)` in the Polymorphic DSL. Upstream resolves these per frame inside
# Pipeline.resolveUniformValue with a normalized 0..1 loop time; the port resolves
# them per render in Renderer.render_effect / the iterated-effect param refresh
# with the render's normalized time, which is the same normalized time the
# canonical kernels receive as their `time` uniform.
#
# The upstream Midi/Audio automation nodes are not compiled by this port's DSL
# (value-position calls other than osc() are rejected at compile time), so only the
# Oscillator branch of upstream's evaluateAutomation is reachable here. The math
# below is a verbatim port of the upstream oscillator evaluation, including the
# noise2d two-stage periodic noise introduced upstream at eabb537e/5e68552a (speed
# applied once, after the first periodic wrap, matching the osc2d shader).
#
# Ruby-specific note: JavaScript's `%` is a truncating remainder (sign of the
# dividend) while Ruby's `%` floors (sign of the divisor); every `%` below goes
# through Float#remainder to stay value-identical with the JS reference, and the
# hash's own sign corrections are kept exactly as upstream wrote them.

module NoisemakerCpu
  module Automation
    TAU = Math::PI * 2.0

    # Consumer ranges for nested-osc field resolution (upstream automationRanges).
    AUTOMATION_FIELD_RANGES = {
      "unit" => { "min" => 0.0, "max" => 1.0 },
      "oscillatorSpeed" => { "min" => -20.0, "max" => 20.0 },
      "oscillatorOffset" => { "min" => -1.0, "max" => 1.0 },
      "oscillatorSeed" => { "min" => 1.0, "max" => 9999.0 },
    }.freeze

    MAX_AUTOMATION_DEPTH = 8

    # JS Number.isFinite: numerics only, finite (strings never pass).
    def self.finite_number?(value)
      value.is_a?(Numeric) && value.to_f.finite?
    end

    # JS Math.round semantics: half rounds toward +Infinity (floor(x + 0.5),
    # computed without the x + 0.5 rounding error on the exact double).
    def self.js_round(value)
      whole = value.floor
      (value - whole) >= 0.5 ? whole + 1 : whole
    end

    def self.automation_value?(value)
      value.is_a?(Hash) && value["type"] == "Oscillator"
    end

    def self.scale_automation_value(value, range)
      return value unless range.is_a?(Hash) && finite_number?(range["min"]) && finite_number?(range["max"])

      range["min"] + value * (range["max"] - range["min"])
    end

    def self.resolve_automation_field(value, normalized_time, range, depth, stack, fallback)
      return evaluate_automation(value, normalized_time, range, depth + 1, stack) if automation_value?(value)

      finite_number?(value) ? value : fallback
    end

    # ---- oscillator primitives ----------------------------------------------

    # Smooth continuous sine: 0->1->0 over t=0..1, no discontinuity at wrap
    def self.osc_sine(t)
      (1.0 - Math.cos(t * TAU)) * 0.5
    end

    # Triangle wave: 0->1->0 over t=0..1
    def self.osc_tri(t)
      tf = t - t.floor
      1.0 - (tf * 2.0 - 1.0).abs
    end

    # Sawtooth: 0->1 over t=0..1
    def self.osc_saw(t)
      t - t.floor
    end

    # Inverted sawtooth: 1->0 over t=0..1
    def self.osc_saw_inv(t)
      1.0 - (t - t.floor)
    end

    # Square wave: 0 or 1
    def self.osc_square(t)
      (t - t.floor) >= 0.5 ? 1.0 : 0.0
    end

    # Simple hash for noise (truncating remainders, as in JS)
    def self.hash21(px, py, s)
      x = (px * 234.34 + s).remainder(1)
      y = (py * 435.345 + s).remainder(1)
      x += 1 if x < 0
      y += 1 if y < 0
      p = x + y + (x + y) * 34.23
      (x * y * p).remainder(1)
    end

    # Value noise 2D
    def self.noise2_d(px, py, s)
      ix = px.floor
      iy = py.floor
      fx = px - ix
      fy = py - iy
      fx = fx * fx * (3 - 2 * fx)
      fy = fy * fy * (3 - 2 * fy)

      a = hash21(ix, iy, s)
      b = hash21(ix + 1, iy, s)
      c = hash21(ix, iy + 1, s)
      d = hash21(ix + 1, iy + 1, s)

      (a * (1 - fx) * (1 - fy)) + (b * fx * (1 - fy)) + (c * (1 - fx) * fy) + (d * fx * fy)
    end

    # Looping noise - samples on a circle for seamless temporal loops
    def self.osc_noise(t, seed)
      temporal = t.remainder(1)
      angle = temporal * TAU
      radius = 2
      loop_x = Math.cos(angle) * radius
      loop_y = Math.sin(angle) * radius
      n1 = noise2_d(loop_x + seed, loop_y + seed, seed)
      n2 = noise2_d(loop_x + seed * 2, loop_y + seed * 2, seed)
      (n1 + n2) / 2
    end

    # Two-stage periodic noise (noise2d, kind 6) - mirrors the osc2d effect:
    #   scaledTime = periodicValue(time, timeNoise) * speed
    #   value      = periodicValue(scaledTime, valueNoise)
    # `time` is the normalized loop time plus the phase offset; speed is applied
    # once, after the first periodic wrap, exactly as in the osc2d shader.
    # osc() has no spatial position, so both noise stages are sampled at a fixed
    # position derived from the seed (the osc2d shader salts the second stage with
    # +12345). periodicValue() has period 1 in time, so whole-number speeds loop
    # seamlessly.
    def self.osc_noise2d(time, speed, seed)
      periodic_value = ->(x, v) { (Math.sin((x - v) * TAU) + 1) * 0.5 }
      px = (seed.remainder(16).abs + 0.5) / 16
      py = (seed.fdiv(16).floor.remainder(16).abs + 0.5) / 16
      time_noise = noise2_d(px, py, seed + 12345)
      value_noise = noise2_d(px, py, seed)
      scaled_time = periodic_value.call(time, time_noise) * speed
      periodic_value.call(scaled_time, value_noise)
    end

    # ---- integration ----------------------------------------------------------

    # 16-point Gauss-Legendre nodes and weights on [-1, 1]. Fixed quadrature keeps
    # noise and deeply nested rate modulation deterministic and seekable.
    INTEGRATION_NODES = [
      -0.9894009349916499, -0.9445750230732326, -0.8656312023878318, -0.755404408355003,
      -0.6178762444026438, -0.4580167776572274, -0.2816035507792589, -0.0950125098376374,
      0.0950125098376374, 0.2816035507792589, 0.4580167776572274, 0.6178762444026438,
      0.755404408355003, 0.8656312023878318, 0.9445750230732326, 0.9894009349916499,
    ].freeze
    INTEGRATION_WEIGHTS = [
      0.0271524594117541, 0.0622535239386479, 0.0951585116824928, 0.1246289712555339,
      0.1495959888165767, 0.1691565193950025, 0.1826034150449236, 0.1894506104550685,
      0.1894506104550685, 0.1826034150449236, 0.1691565193950025, 0.1495959888165767,
      0.1246289712555339, 0.0951585116824928, 0.0622535239386479, 0.0271524594117541,
    ].freeze
    INTEGRATION_RULES = [
      { "nodes" => INTEGRATION_NODES, "weights" => INTEGRATION_WEIGHTS },
      {
        "nodes" => [
          -0.9602898564975363, -0.7966664774136267, -0.525532409916329,
          -0.1834346424956498, 0.1834346424956498, 0.525532409916329,
          0.7966664774136267, 0.9602898564975363,
        ],
        "weights" => [
          0.1012285362903763, 0.2223810344533745, 0.3137066458778873,
          0.362683783378362, 0.362683783378362, 0.3137066458778873,
          0.2223810344533745, 0.1012285362903763,
        ],
      },
      {
        "nodes" => [-0.8611363115940526, -0.3399810435848563, 0.3399810435848563, 0.8611363115940526],
        "weights" => [0.3478548451374538, 0.6521451548625461, 0.6521451548625461, 0.3478548451374538],
      },
      {
        "nodes" => [-0.5773502691896257, 0.5773502691896257],
        "weights" => [1, 1],
      },
    ].freeze

    def self.can_integrate_oscillator_exactly?(config)
      config["oscType"].is_a?(Integer) && config["oscType"] >= 0 && config["oscType"] <= 4 &&
        %w[min max speed offset seed].all? { |field| finite_number?(config[field]) }
    end

    def self.osc_primitive(type, x)
      whole = x.floor
      fraction = x - whole
      case type
      when 0
        x * 0.5 - Math.sin(x * TAU) / (2 * TAU)
      when 1
        partial = fraction < 0.5 ? fraction * fraction : 2 * fraction - fraction * fraction - 0.5
        whole * 0.5 + partial
      when 2
        whole * 0.5 + fraction * fraction * 0.5
      when 3
        x - (whole * 0.5 + fraction * fraction * 0.5)
      when 4
        whole * 0.5 + [0, fraction - 0.5].max
      end
    end

    def self.integrate_simple_oscillator(config, normalized_time)
      min = config["min"]
      max = config["max"]
      speed = config["speed"]
      offset = config["offset"]
      if speed == 0
        return evaluate_oscillator(config, 0, 0, []) * normalized_time
      end

      start = osc_primitive(config["oscType"], offset)
      fin = osc_primitive(config["oscType"], offset + speed * normalized_time)
      raw_integral = (fin - start) / speed
      min * normalized_time + (max - min) * raw_integral
    end

    def self.integrate_automation(config, normalized_time, range, depth, stack)
      integral =
        if can_integrate_oscillator_exactly?(config)
          integrate_simple_oscillator(config, normalized_time)
        else
          # Decrease the quadrature order as rate modulators nest. This bounds an
          # eight-level graph to thousands, rather than millions, of evaluations
          # while retaining the highest precision at the user-visible output.
          rule = INTEGRATION_RULES[[depth, INTEGRATION_RULES.length - 1].min]
          midpoint = normalized_time * 0.5
          half_width = normalized_time * 0.5
          sum = 0.0
          rule["nodes"].each_index do |i|
            sample_time = midpoint + half_width * rule["nodes"][i]
            sum += rule["weights"][i] * evaluate_automation(config, sample_time, nil, depth + 1, stack)
          end
          half_width * sum
        end

      return integral unless range.is_a?(Hash) && finite_number?(range["min"]) && finite_number?(range["max"])

      range["min"] * normalized_time + integral * (range["max"] - range["min"])
    end

    def self.evaluate_oscillator(osc, normalized_time, depth, stack)
      osc_type = osc["oscType"]
      min = resolve_automation_field(osc["min"], normalized_time, AUTOMATION_FIELD_RANGES["unit"], depth, stack, 0)
      max = resolve_automation_field(osc["max"], normalized_time, AUTOMATION_FIELD_RANGES["unit"], depth, stack, 1)
      offset = resolve_automation_field(osc["offset"], normalized_time, AUTOMATION_FIELD_RANGES["oscillatorOffset"],
                                        depth, stack, 0)
      seed = resolve_automation_field(osc["seed"], normalized_time, AUTOMATION_FIELD_RANGES["oscillatorSeed"],
                                      depth, stack, 1)

      # A modulated rate is frequency modulation, so phase is the integral of
      # rate. Literal rates keep the existing closed form exactly.
      phase = if automation_value?(osc["speed"])
                integrate_automation(osc["speed"], normalized_time, AUTOMATION_FIELD_RANGES["oscillatorSpeed"],
                                     depth, stack)
              else
                normalized_time * (finite_number?(osc["speed"]) ? osc["speed"] : 1)
              end
      t = phase + offset

      # Get raw oscillator value (0..1)
      value =
        case osc_type
        when 0 then osc_sine(t)
        when 1 then osc_tri(t)
        when 2 then osc_saw(t)
        when 3 then osc_saw_inv(t)
        when 4 then osc_square(t)
        when 5 then osc_noise(t, seed)
        when 6
          speed = resolve_automation_field(osc["speed"], normalized_time, AUTOMATION_FIELD_RANGES["oscillatorSpeed"],
                                           depth, stack, 1)
          osc_noise2d(normalized_time + offset, finite_number?(speed) ? speed : 1, seed)
        else
          0
        end

      # Map to min..max range
      min + value * (max - min)
    end

    # The evaluation stack holds oscillator configs by object identity (JS uses a
    # reference Set; Ruby Hash equality is structural, so identity must be explicit
    # to keep distinct-but-equal nested oscillators unconfused with a cycle).
    def self.stack_includes?(stack, config)
      stack.any? { |entry| entry.equal?(config) }
    end

    def self.evaluate_automation(config, normalized_time, range = nil, depth = 0, stack = [])
      if !automation_value?(config) || depth > MAX_AUTOMATION_DEPTH || stack_includes?(stack, config)
        return scale_automation_value(0, range)
      end

      stack.push(config)
      begin
        value = evaluate_oscillator(config, normalized_time, depth, stack)
      ensure
        index = stack.rindex { |entry| entry.equal?(config) }
        stack.delete_at(index) unless index.nil?
      end
      scale_automation_value(value, range)
    end

    # Port of upstream Pipeline.resolveUniformValue: resolve an automation value for
    # the current frame, scaled into the consumer parameter's declared range, with
    # the upstream integer rounding for `type: 'int'` consumers. Non-automation
    # values pass through unchanged.
    def self.resolve_automation_uniform(value, normalized_time, spec = nil)
      return value unless automation_value?(value)

      resolved = evaluate_automation(value, normalized_time, spec)
      spec.is_a?(Hash) && spec["type"] == "int" ? js_round(resolved) : resolved
    end
  end
end
