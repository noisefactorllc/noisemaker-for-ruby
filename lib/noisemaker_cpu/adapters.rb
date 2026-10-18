# frozen_string_literal: true

# CPU adapter registry -- the reference engine renders a handful of effects
# through hand-written CPU adapters (canonicalAdapterFactories) instead of
# the transpiled GLSL kernel. For byte-parity we run the same adapters:
#
#   filter/crt:crt        -- handwritten Metal M2 float32 implementation.
#   filter/snow:snow      -- full reimplementation (TV static), bit-faithful
#                            to snow.js's exact f32-rounding points.
#   filter/palette:palette-- full reimplementation (cosine palette + HSV/OKLAB
#                            modes) over the vendored 55-entry table.
#
# An adapter factory is factory(rt, compiled) -> kernel callable(ctx, out); it
# may wrap the transpiled kernel or replace it entirely.

require_relative "sampler"
require_relative "palette_data"

module NoisemakerCpu
  module Adapters
    @adapters = {}

    def self.register(effect_id, program, adapter)
      @adapters["#{effect_id}:#{program}"] = adapter
    end

    def self.get_adapter(effect_id, program)
      @adapters["#{effect_id}:#{program}"]
    end

    def self._f32(x)
      [x].pack("e").unpack1("e")
    end

    TAU = 6.283185307179586
    TAU32 = _f32(6.283185307179586)
    INV_TAU = _f32(1.0.fdiv(6.283185307179586))

    # ---- filter/crt: handwritten Metal M2 float32 adapter ----

    module Crt
      def self.f(value)
        Adapters._f32(value)
      end

      def self.floor(value)
        value.finite? && value != 0 ? value.floor : value
      end

      def self.trunc(value)
        value.finite? && value != 0 ? value.truncate : value
      end

      def self.int32(value)
        return 0 unless value.finite? && value != 0

        bits = value.to_i & 0xFFFFFFFF
        bits >= 0x80000000 ? bits - 4294967296 : bits
      end

      def self.minimum(*values)
        return Float::NAN if values.any? { |v| v.respond_to?(:nan?) && v.nan? }

        result = values.min
        return -0.0 if result == 0 && values.any? { |v| v == 0 && 1.0.fdiv(v) < 0 }

        result
      end

      def self.maximum(*values)
        return Float::NAN if values.any? { |v| v.respond_to?(:nan?) && v.nan? }

        result = values.max
        return 0.0 if result == 0 && values.any? { |v| v == 0 && 1.0.fdiv(v) > 0 }

        result
      end

      # TwoSum preserves the exact addition error when a float64 sum lands on
      # a float32 midpoint, matching the source adapter's exported fma32.
      def self.fma32(a, b, c)
        product = a.to_f * b.to_f
        sum = product + c
        back = sum - product
        error = (product - (sum - back)) + (c - back)
        rounded = f(sum)
        return rounded if error == 0 || rounded == sum

        toward_sum = sum > rounded ? 1 : -1
        neighbor = if rounded == 0
          toward_sum * [1].pack("L<").unpack1("e")
        else
          bits = [rounded].pack("e").unpack1("L<")
          bits += (rounded > 0) == (toward_sum > 0) ? 1 : -1
          [bits].pack("L<").unpack1("e")
        end
        return rounded unless (rounded + neighbor).fdiv(2) == sum

        error > 0 ? maximum(rounded, neighbor) : minimum(rounded, neighbor)
      end

      def self.add(a, b) = f(a + b)
      def self.sub(a, b) = f(a - b)
      def self.mul(a, b) = f(a * b)
      # CRT deliberately uses the M2 rounded reciprocal, not the generic M4 division.
      def self.div(a, b) = f(a * f(1.0.fdiv(b)))
      def self.fract(value) = f(value - floor(value))
      def self.clamp(value, low, high) = minimum(maximum(value, low), high)
      def self.clamp01(value) = clamp(value, 0, 1)
      def self.sqrt(value) = f(Math.sqrt(value))
      def self.mix(a, b, t) = fma32(t, sub(b, a), a)
      def self.length2(x, y) = sqrt(fma32(y, y, mul(x, x)))
      def self.dot3(ax, ay, az, bx, by, bz) = fma32(az, bz, fma32(ay, by, mul(ax, bx)))

      INV_TAU = f(1.0.fdiv(2 * Math::PI))
      INV_THREE = f(1.0.fdiv(3))
      HASH = f(43758.5453123)
      HASH3 = f(43758.5453)

      def self.quadrant_sine(r)
        n = floor(r)
        fraction = r - n
        y = (int32(n) & 1) != 0 ? 1 - fraction : fraction
        return n >= 2 ? -0.0 : 0.0 if y == 0

        z = 2 * y * y - 1
        quotient = Math.sin(y * Math::PI / 2).fdiv(y)
        p = f(quotient - 2.0**-23 * (0.783734 + 0.010102 * z + 0.052674 * (2 * z * z - 1)))
        value = f(y * p)
        n >= 2 ? -value : value
      end

      def self.quadrant_of_turns(turns) = f(4 * (turns - floor(turns)))
      def self.sin(x) = quadrant_sine(quadrant_of_turns(f(x * INV_TAU)))
      def self.sin_turns(turns) = quadrant_sine(quadrant_of_turns(turns))
      def self.cos_turns(turns) = quadrant_sine(quadrant_of_turns(add(turns, 0.25)))
      def self.cos_half_turns(turns) = quadrant_sine(quadrant_of_turns(fma32(turns, 0.5, 0.25)))
      def self.periodic_value(time, value) = fma32(sin_turns(sub(time, value)), 0.5, 0.5)

      C289 = f(1.0.fdiv(289))
      TAYLOR_A = f(1.79284291400159)
      TAYLOR_B = f(0.85373472095314)
      C_X = f(1.0.fdiv(6))
      C_Y = f(1.0.fdiv(3))
      N = f(0.14285714285714285)
      NS_X = mul(N, 2)
      NS_Y = sub(mul(N, 0.5), 1)
      M0 = f(0.6)

      def self.mod289(x) = sub(x, mul(floor(mul(x, C289)), 289))
      def self.permute(x) = mod289(mul(fma32(x, 34, 1), x))

      def self.simplex_noise(vx, vy, vz)
        dv = dot3(vx, vy, vz, C_Y, C_Y, C_Y)
        i0x, i0y, i0z = [vx, vy, vz].map { |v| floor(add(v, dv)) }
        di = dot3(i0x, i0y, i0z, C_X, C_X, C_X)
        x0x, x0y, x0z = [[vx, i0x], [vy, i0y], [vz, i0z]].map { |v, i| add(sub(v, i), di) }
        s1x, s1y, s1z = x0x < x0y ? 0 : 1, x0y < x0z ? 0 : 1, x0z < x0x ? 0 : 1
        lx, ly, lz = 1 - s1z, 1 - s1x, 1 - s1y
        i1x, i1y, i1z = minimum(s1x, lx), minimum(s1y, ly), minimum(s1z, lz)
        i2x, i2y, i2z = maximum(s1x, lx), maximum(s1y, ly), maximum(s1z, lz)
        corners = [x0x, x0y, x0z,
                   add(sub(x0x, i1x), C_X), add(sub(x0y, i1y), C_X), add(sub(x0z, i1z), C_X),
                   add(sub(x0x, i2x), C_Y), add(sub(x0y, i2y), C_Y), add(sub(x0z, i2z), C_Y),
                   sub(x0x, 0.5), sub(x0y, 0.5), sub(x0z, 0.5)]
        ix, iy, iz = [i0x, i0y, i0z].map { |i| mod289(i) }
        offsets_x, offsets_y, offsets_z = [0, i1x, i2x, 1], [0, i1y, i2y, 1], [0, i1z, i2z, 1]
        p = Array.new(4) do |k|
          pz = permute(add(iz, offsets_z[k]))
          py = permute(add(add(pz, iy), offsets_y[k]))
          permute(add(add(py, ix), offsets_x[k]))
        end
        x, y, h = [], [], []
        4.times do |k|
          j = sub(p[k], mul(49, floor(mul(mul(p[k], N), N))))
          xi = floor(mul(j, N))
          yi = floor(sub(j, mul(7, xi)))
          x[k] = fma32(xi, NS_X, NS_Y)
          y[k] = fma32(yi, NS_X, NS_Y)
          h[k] = sub(sub(1, x[k].abs), y[k].abs)
        end
        b0, b1 = [x[0], x[1], y[0], y[1]], [x[2], x[3], y[2], y[3]]
        s0 = b0.map { |v| add(mul(floor(v), 2), 1) }
        s1 = b1.map { |v| add(mul(floor(v), 2), 1) }
        sh = h.map { |v| v > 0 ? 0 : -1 }
        gradient = [fma32(s0[0], sh[0], b0[0]), fma32(s0[2], sh[0], b0[2]), h[0],
                    fma32(s0[1], sh[1], b0[1]), fma32(s0[3], sh[1], b0[3]), h[1],
                    fma32(s1[0], sh[2], b1[0]), fma32(s1[2], sh[2], b1[2]), h[2],
                    fma32(s1[1], sh[3], b1[1]), fma32(s1[3], sh[3], b1[3]), h[3]]
        sum = 0
        4.times do |k|
          g = k * 3
          gx, gy, gz = gradient[g, 3]
          norm = fma32(-TAYLOR_B, dot3(gx, gy, gz, gx, gy, gz), TAYLOR_A)
          cx, cy, cz = corners[g, 3]
          m = maximum(sub(M0, dot3(cx, cy, cz, cx, cy, cz)), 0)
          msq = mul(m, m)
          term = dot3(mul(gx, norm), mul(gy, norm), mul(gz, norm), cx, cy, cz)
          sum = k == 0 ? mul(mul(msq, msq), term) : fma32(mul(msq, msq), term, sum)
        end
        mul(42, sum)
      end

      def self.wrap_float(value, limit)
        return 0 if limit <= 0

        result = fma32(-floor(div(value, limit)), limit, value)
        result < 0 ? add(result, limit) : result
      end

      def self.freq_for_shape(base_freq, width, height)
        freq, width, height = maximum(base_freq, 1), maximum(width, 1), maximum(height, 1)
        return [freq, freq] if sub(width, height).abs < f(1e-5)
        return [freq, maximum(floor(div(mul(freq, width), height)), 1)] if height < width

        [maximum(floor(div(mul(freq, height), width)), 1), freq]
      end

      def self.value_noise_hash(cx, cy, cz, seed)
        value = fma32(seed, f(0.001), dot3(cx, cy, cz, f(12.9898), f(78.233), f(37.719)))
        fract(mul(sin(value), HASH3))
      end

      def self.fade(value) = mul(mul(value, value), fma32(-2, value, 3))
      def self.lerp(a, b, t) = fma32(sub(b, a), t, a)

      def self.value_noise_3d(x, y, z, seed)
        cx, cy, cz = floor(x), floor(y), floor(z)
        tx, ty, tz = fade(sub(x, cx)), fade(sub(y, cy)), fade(sub(z, cz))
        h = ->(dx, dy, dz) { value_noise_hash(cx + dx, cy + dy, cz + dz, seed) }
        x00 = lerp(h.call(0, 0, 0), h.call(1, 0, 0), tx)
        x10 = lerp(h.call(0, 1, 0), h.call(1, 1, 0), tx)
        x01 = lerp(h.call(0, 0, 1), h.call(1, 0, 1), tx)
        x11 = lerp(h.call(0, 1, 1), h.call(1, 1, 1), tx)
        lerp(lerp(x00, x10, ty), lerp(x01, x11, ty), tz)
      end

      def self.wrap_unit(value)
        wrapped = sub(value, floor(value))
        wrapped < 0 ? add(wrapped, 1) : wrapped
      end

      def self.rgb_to_hsv(r, g, b)
        cmax, cmin = maximum(maximum(r, g), b), minimum(minimum(r, g), b)
        delta, hue = sub(cmax, cmin), 0
        if delta > 0
          if cmax == r
            hue = div(sub(g, b), delta)
            hue = add(hue, 6) if hue < 0
          elsif cmax == g
            hue = add(div(sub(b, r), delta), 2)
          else
            hue = add(div(sub(r, g), delta), 4)
          end
          hue = wrap_unit(div(hue, 6))
        end
        [hue, cmax != 0 ? div(delta, cmax) : 0, cmax]
      end

      def self.hsv_to_rgb(h, s, v)
        dh, one_minus_s = mul(h, 6), sub(1, s)
        [clamp01(mul(fma32(s, clamp01(sub(sub(dh, 3).abs, 1)), one_minus_s), v)),
         clamp01(mul(fma32(s, clamp01(add(-sub(dh, 2).abs, 2)), one_minus_s), v)),
         clamp01(mul(fma32(s, clamp01(add(-sub(dh, 4).abs, 2)), one_minus_s), v))]
      end

      def self.adjust_hue(r, g, b, amount)
        h, s, v = rgb_to_hsv(r, g, b)
        hsv_to_rgb(wrap_unit(add(h, amount)), clamp01(s), clamp01(v))
      end

      def self.adjust_saturation(r, g, b, amount)
        h, s, v = rgb_to_hsv(r, g, b)
        hsv_to_rgb(h, clamp01(mul(s, amount)), clamp01(v))
      end

      def self.kernel(rt)
        lambda do |ctx, out|
          rt.begin_pixel(ctx)
          u = ctx.uniforms
          resolution = u.fetch("resolution", ctx.resolution)
          tile_offset = u.fetch("tileOffset", [0, 0])
          render_scale = u.fetch("renderScale", 1).to_f
          alpha = clamp01(u.fetch("alpha", 0).to_f)
          rs = maximum(render_scale, 1)
          full_res = u.fetch("fullResolution", [0, 0])
          full_res = resolution unless full_res[0] > 0
          width = maximum(div(full_res[0].to_f, rs), 1)
          height = maximum(div(full_res[1].to_f, rs), 1)
          time, speed, seed = u.fetch("time", ctx.time).to_f, u.fetch("speed", 1).to_f, u.fetch("seed", ctx.seed).to_f
          gx, gy = int32(ctx.frag_coord[0]), int32(ctx.frag_coord[1])
          fetch = ->(x, y) { rt.texel_fetch(ctx.texture_binding("inputTex"), [int32(x), int32(y)]) }
          base_r, base_g, base_b, base_a = fetch.call(gx, gy)
          if alpha == 0
            out[0, 4] = [base_r, base_g, base_b, base_a]
            next
          end

          freq = freq_for_shape(2, width, height)
          freq_x, freq_y = maximum(freq[1], 1), maximum(freq[0], 1)
          z_base = mul(cos_turns(time), speed)
          s = mul(seed, 73)
          base_seed_x, base_seed_y, base_seed_z = add(17, s), fma32(s, f(1.1), 29), fma32(s, f(0.7), 47)
          time_seed_x, time_seed_y, time_seed_z = add(base_seed_x, 54), add(base_seed_y, 82), add(base_seed_z, 124)
          animated_simplex_value = lambda do |a, b|
            base_noise = simplex_noise(add(a, base_seed_x), add(b, base_seed_y), add(z_base, base_seed_z))
            value = clamp01(fma32(base_noise, 0.5, 0.5))
            if speed != 0 && time != 0
              time_noise = simplex_noise(add(a, time_seed_x), add(b, time_seed_y), time_seed_z)
              time_value = clamp01(fma32(time_noise, 0.5, 0.5))
              value = clamp01(periodic_value(mul(periodic_value(time, time_value), speed), value))
            end
            clamp01(value)
          end
          aspect = div(width, height)
          max_radius = length2(mul(aspect, 0.5), 0.5)
          lens_offsets = lambda do |sample_x, sample_y|
            wx, wy = wrap_float(sample_x, width), wrap_float(sample_y, height)
            noise = animated_simplex_value.call(mul(div(wx, width), freq_x), mul(div(wy, height), freq_y))
            dx = sub(div(add(wx, 0.5), width), 0.5).abs
            dy = sub(div(add(wy, 0.5), height), 0.5).abs
            mask = 0
            if max_radius > 0
              normalized = clamp01(div(length2(mul(dx, aspect), dy), max_radius))
              masked = sqrt(normalized)
              squared = mul(masked, masked)
              mask = mul(mul(squared, squared), masked)
            end
            distortion = mul(fma32(noise, 2, -1), mask)
            [mul(mul(cos_turns(distortion), 0.0625), width), mul(mul(sin_turns(distortion), 0.0625), height)]
          end
          time_scaled = mul(mul(time, speed), f(0.1))
          noise_seed = fma32(seed, 31, f(19.37))
          scan_base0 = value_noise_3d(0, 0, time_scaled, noise_seed)
          scan_base1 = value_noise_3d(1, 0, time_scaled, noise_seed)
          scan_row = ->(row) { trunc(floor(div(row, 2.5))) % 2 == 0 ? scan_base0 : scan_base1 }
          sample_scanline = lambda do |sample_x, sample_y|
            wx = fma32(-floor(div(sample_x, width)), width, sample_x)
            wy = fma32(-floor(div(sample_y, height)), height, sample_y)
            wx = add(wx, width) if wx < 0
            wy = add(wy, height) if wy < 0
            wx, wy = clamp(wx, 0, sub(width, 1)), clamp(wy, 0, sub(height, 1))
            y0 = floor(wy)
            y1 = minimum(add(y0, 1), sub(height, 1))
            xf, yf = clamp01(sub(wx, floor(wx))), clamp01(sub(wy, y0))
            top, bottom = scan_row.call(y0), scan_row.call(y1)
            mix(mix(top, top, xf), mix(bottom, bottom, xf), yf)
          end
          seed_hash = lambda do |offset|
            turns = fma32(seed, f(73 * INV_TAU), f(f(17 + f(offset)) * INV_TAU))
            fract(mul(quadrant_sine(quadrant_of_turns(turns)), HASH))
          end
          displacement_base = fma32(seed_hash.call(0.37), f(0.00625), f(0.0125))
          displacement_pixels = mul(mul(displacement_base, width), seed_hash.call(0.73))
          hue_shift = fma32(seed_hash.call(1.91), 0.25, -0.125)
          vignette_alpha = mul(seed_hash.call(3.17), f(0.175))
          blend_cosine = lambda do |a, b, value|
            c = cos_half_turns(clamp01(value))
            weight = mul(sub(1, c), 0.5)
            fma32(b, weight, mul(a, fma32(0.5, c, 0.5)))
          end
          blend_scan = ->(value, scan) { mix(value, mul(add(value, scan), scan), 0.5) }
          x, y = div(add(gx, tile_offset[0]), rs), div(add(gy, tile_offset[1]), rs)
          ox, oy = lens_offsets.call(x, y)
          scan_value = sample_scanline.call(add(x, ox), add(y, oy))
          green = [base_r, base_g, base_b].map { |v| clamp01(blend_scan.call(v, scan_value)) }
          dx, dy = div(sub(x, mul(width, 0.5)), width), div(sub(y, mul(height, 0.5)), height)
          singularity = length2(dx, dy)
          aber_mask = mul(mul(singularity, singularity), singularity)
          gradient_x = clamp01(div(x, sub(width, 1)))
          red_x = mix(minimum(add(x, displacement_pixels), sub(width, 1)), x, gradient_x)
          red_sample_x = blend_cosine.call(x, red_x, aber_mask)
          red_sample = fetch.call(trunc(sub(mul(red_sample_x, render_scale), tile_offset[0])), gy)
          ox, oy = lens_offsets.call(red_sample_x, y)
          red_scan = sample_scanline.call(add(red_sample_x, ox), add(y, oy))
          blue_x = mix(x, maximum(sub(x, displacement_pixels), 0), gradient_x)
          blue_sample_x = blend_cosine.call(x, blue_x, aber_mask)
          blue_sample = fetch.call(trunc(sub(mul(blue_sample_x, render_scale), tile_offset[0])), gy)
          ox, oy = lens_offsets.call(blue_sample_x, y)
          blue_scan = sample_scanline.call(add(blue_sample_x, ox), add(y, oy))
          red = adjust_hue(*red_sample[0, 3].map { |v| blend_scan.call(v, red_scan) }, hue_shift)
          green = adjust_hue(*green, hue_shift)
          blue = adjust_hue(*blue_sample[0, 3].map { |v| blend_scan.call(v, blue_scan) }, hue_shift)
          color = adjust_hue(red[0], green[1], blue[2], -hue_shift)
          color = adjust_saturation(*color, 1.125)
          color = color.map { |v| mix(v, mix(v, 0, singularity), clamp01(vignette_alpha)) }
          local_mean = mul(add(add(color[0], color[1]), color[2]), INV_THREE)
          [base_r, base_g, base_b].each_with_index do |base, channel|
            normalized = clamp01(fma32(sub(color[channel], local_mean), 1.25, local_mean))
            quantized = div(floor(fma32(clamp01(normalized), 255, 0.5)), 255)
            out[channel] = mix(base, quantized, alpha)
          end
          out[3] = base_a
        end
      end
    end

    register("filter/crt", "crt", ->(rt, _compiled) { Crt.kernel(rt) })

    # ---- filter/snow: TV static (full reimplementation) ----

    TIME_SEED_OFFSETS = [_f32(97.0), _f32(57.0), _f32(131.0)].freeze
    STATIC_SEED = [_f32(37.0), _f32(17.0), _f32(53.0)].freeze
    LIMITER_SEED = [_f32(113.0), _f32(71.0), _f32(193.0)].freeze

    def self._sadd(a, b)
      _f32(a + b)
    end

    def self._ssub(a, b)
      _f32(a - b)
    end

    def self._smul(a, b)
      _f32(a * b)
    end

    def self._sdiv(a, b)
      _f32(a.fdiv(b))
    end

    def self._sfract(x)
      _f32(x - Crt.floor(x))
    end

    def self._sclamp01(x)
      x <= 0 ? 0.0 : (x >= 1 ? 1.0 : x)
    end

    def self._ssine(x)
      turns = _f32(x * INV_TAU)
      phase = turns - Crt.floor(turns)
      _f32(Math.sin(phase * TAU32))
    end

    def self._speriodic(a, b)
      _smul(_sadd(_ssine(_smul(_ssub(a, b), TAU32)), 1.0), 0.5)
    end

    def self._snow_hash(x, y, z)
      sx = _sfract(_smul(x, _f32(0.1031)))
      sy = _sfract(_smul(y, _f32(0.1031)))
      sz = _sfract(_smul(z, _f32(0.1031)))
      dot = Crt.fma32(sz, _sadd(sx, _f32(33.33)),
                      Crt.fma32(sy, _sadd(sz, _f32(33.33)), _smul(sx, _sadd(sy, _f32(33.33)))))
      _sclamp01(_sfract(_smul(_sadd(_sadd(sx, sy), 2 * dot), _sadd(sz, dot))))
    end

    def self._snow_noise(x, y, time, speed, seed)
      angle = _smul(time, TAU32)
      cosine_value = _f32(angle.infinite? ? Float::NAN : Math.cos(angle))
      z_base = _smul(cosine_value, speed)
      base_value = _snow_hash(_sadd(x, seed[0]), _sadd(y, seed[1]), _sadd(z_base, seed[2]))
      return base_value if speed == 0 || time == 0

      tsx = _sadd(seed[0], TIME_SEED_OFFSETS[0])
      tsy = _sadd(seed[1], TIME_SEED_OFFSETS[1])
      tsz = _sadd(seed[2], TIME_SEED_OFFSETS[2])
      time_value = _snow_hash(_sadd(x, tsx), _sadd(y, tsy), _sadd(1.0, tsz))
      scaled_time = _smul(_speriodic(time, time_value), speed)
      _sclamp01(_speriodic(scaled_time, base_value))
    end

    register("filter/snow", "snow", lambda do |rt, _compiled|
      lambda do |ctx, out|
        rt.begin_pixel(ctx)
        x = 0.0 + ctx.frag_coord[0]
        y = 0.0 + ctx.frag_coord[1]
        source = rt.texel_fetch(ctx.texture_binding("inputTex"), [Crt.int32(x), Crt.int32(y)])
        alpha = _sclamp01(ctx.uniforms["alpha"].nil? ? 0.0 : ctx.uniforms["alpha"])
        if alpha == 0
          out[0, 4] = source
          return
        end
        pause = ctx.uniforms["pause"].nil? ? 0 : ctx.uniforms["pause"]
        time = pause > 0.5 ? 0.0 : (ctx.uniforms["time"].nil? ? ctx.time : ctx.uniforms["time"])
        speed = _f32(100.0)
        static_value = _snow_noise(x, y, time, speed, STATIC_SEED)
        limiter_value = _snow_noise(x, y, time, speed, LIMITER_SEED)
        density_u = ctx.uniforms["density"].nil? ? 0.0 : ctx.uniforms["density"]
        density = _smul(density_u, _f32(0.01))
        density = _f32(0.0001) if density < _f32(0.0001)
        exponent = _sdiv(_ssub(1.0, density), density)
        lim = Crt.minimum(limiter_value, _f32(0.99))
        limiter_mask = _smul(_f32(lim**exponent), alpha)
        inverse_mask = _ssub(1.0, limiter_mask)
        (0..2).each { |idx| out[idx] = _f32((source[idx] * inverse_mask) + (static_value * limiter_mask)) }
        out[3] = source[3]
      end
    end)

    # ---- filter/palette: cosine palette (full reimplementation) ----

    def self._to_int32(x)
      n = x.to_i & 0xFFFFFFFF
      n >= 0x80000000 ? n - 4294967296 : n
    end

    def self._pclamp01(x)
      x < 0 ? 0.0 : (x > 1 ? 1.0 : x)
    end

    def self._pmix(a, b, amount)
      (a * (1.0 - amount)) + (b * amount)
    end

    def self._hsv_to_rgb(h, s, v)
      c = v * s
      hp = h * 6.0
      x = c * (1.0 - (((hp - (2.0 * (hp.fdiv(2.0)).floor)) - 1.0).abs))
      m = v - c
      r, g, b =
        if hp < 1.0 then [c + m, x + m, m]
        elsif hp < 2.0 then [x + m, c + m, m]
        elsif hp < 3.0 then [m, c + m, x + m]
        elsif hp < 4.0 then [m, x + m, c + m]
        elsif hp < 5.0 then [x + m, m, c + m]
        else [c + m, m, x + m]
        end
      [_f32(r), _f32(g), _f32(b)]
    end

    def self._linear_to_srgb(value)
      return value * 12.92 if value <= 0.0031308

      (1.055 * (value**(1.0.fdiv(2.4)))) - 0.055
    end

    def self._oklab_to_rgb(lab_l, lab_a, lab_b)
      lightness = lab_l
      a = (lab_a * -0.509) + 0.276
      b = (lab_b * -0.509) + 0.198
      l1 = lightness + (0.3963377774 * a) + (0.2158037573 * b)
      m1 = lightness - (0.1055613458 * a) - (0.0638541728 * b)
      s1 = lightness - (0.0894841775 * a) - (1.291485548 * b)
      l = l1**3
      m = m1**3
      s = s1**3
      r = _pclamp01(_linear_to_srgb((4.0767416621 * l) - (3.3077115913 * m) + (0.2309699292 * s)))
      g = _pclamp01(_linear_to_srgb((-1.2684380046 * l) + (2.6097574011 * m) - (0.3413193965 * s)))
      bo = _pclamp01(_linear_to_srgb((-0.0041960863 * l) - (0.7034186147 * m) + (1.707614701 * s)))
      [_f32(r), _f32(g), _f32(bo)]
    end

    # Mirror GlslCpuRuntime#texture: uv against the input texture's own size,
    # bilinear with flipped v when 'linear', else nearest-bottom-left.
    def self._sample_input(surface, fx, fy)
      u = fx.fdiv(surface.width)
      v = fy.fdiv(surface.height)
      if (surface.filter || "nearest") == "linear"
        return NoisemakerCpu::Sampler.sample_bilinear(surface, u, 1.0 - v)
      end

      NoisemakerCpu::Sampler.sample_nearest_bottom_left(surface, u, v)
    end

    register("filter/palette", "palette", lambda do |_rt, _compiled|
      lambda do |ctx, out|
        surface = ctx.texture_binding("inputTex")
        inp = _sample_input(surface, 0.0 + ctx.frag_coord[0], 0.0 + ctx.frag_coord[1])
        table = NoisemakerCpu::PaletteData::PALETTE_DATA

        palette_index = _to_int32(ctx.uniforms["paletteIndex"].nil? ? 0 : ctx.uniforms["paletteIndex"])
        if palette_index <= 0 || palette_index > table.length
          (0..3).each { |idx| out[idx] = _f32(inp[idx]) }
          return
        end
        entry = table[palette_index - 1]
        lum = (inp[0] * 0.299) + (inp[1] * 0.587) + (inp[2] * 0.114)
        repeat = ctx.uniforms["repeat"].nil? ? 0 : ctx.uniforms["repeat"]
        offset = ctx.uniforms["offset"].nil? ? 0.0 : ctx.uniforms["offset"]
        rotation = ctx.uniforms["rotation"].nil? ? 0 : ctx.uniforms["rotation"]
        time = ctx.uniforms["time"].nil? ? ctx.time : ctx.uniforms["time"]
        t = (lum * repeat) + (offset * 0.01)
        if rotation == -1
          t += time
        elsif rotation == 1
          t -= time
        end

        color = [0.0, 0.0, 0.0]
        (0..2).each do |channel|
          raw = entry[8 + channel] +
            (entry[channel] * Math.cos(TAU * ((entry[4 + channel] * t) + entry[12 + channel])))
          color[channel] = _f32(_pclamp01(raw))
        end
        mode = _to_int32(entry[3])
        color = _hsv_to_rgb(*color) if mode == 1
        color = _oklab_to_rgb(*color) if mode == 2

        alpha = ctx.uniforms["alpha"].nil? ? 0.0 : ctx.uniforms["alpha"]
        (0..2).each { |idx| out[idx] = _f32(_pmix(inp[idx], color[idx], alpha)) }
        out[3] = _f32(inp[3])
      end
    end)

    # ---- filter/median: bit-faithful port of src/effects/adapters/median.js ----
    # The oracle renders median through the hand-written CPU adapter (the
    # transpiled CDN GLSL disagrees with it on the pivot index, the half
    # packing and the alpha source), so the adapter is the parity target.

    def self._f32_bits(value)
      [value].pack("e").unpack1("L<")
    end

    def self._median_float_to_half(value)
      return 0x7e00 if value.is_a?(Float) && value.nan?
      return 0x7c00 if value == Float::INFINITY
      return 0xfc00 if value == -Float::INFINITY

      bits = _f32_bits(value)
      sign = (bits >> 16) & 0x8000
      exponent = ((bits >> 23) & 0xff) - 127 + 15
      fraction = bits & 0x7fffff
      if exponent <= 0
        return sign if exponent < -10

        fraction = (fraction | 0x800000) >> (1 - exponent)
        return sign | ((fraction + 0x1000) >> 13)
      end
      return sign | 0x7c00 if exponent >= 31

      fraction += 0x1000
      if (fraction & 0x800000) != 0
        fraction = 0
        exponent += 1
        return sign | 0x7c00 if exponent >= 31
      end
      sign | (exponent << 10) | (fraction >> 13)
    end

    def self._median_half_to_float(value)
      sign = (value & 0x8000) != 0 ? -1 : 1
      exponent = (value >> 10) & 0x1f
      fraction = value & 0x3ff
      return sign * (2**-14) * fraction.fdiv(1024) if exponent.zero?
      # JS order: the NaN branch requires BOTH exponent 0x1f and a nonzero
      # fraction; a normal fraction with a smaller exponent is a normal half.
      return Float::NAN if exponent == 0x1f && fraction != 0
      return sign * Float::INFINITY if exponent == 0x1f

      sign * (2**(exponent - 15)) * (1 + fraction.fdiv(1024))
    end

    register("filter/median", "median", lambda do |_rt, _compiled|
      lambda do |ctx, out|
        surface = ctx.textures["inputTex"]
        radius = ctx.uniforms["RADIUS"].to_i
        center_x = ctx.frag_coord[0].to_i
        center_y = ctx.frag_coord[1].to_i
        center_row = surface.height - 1 - center_y
        center_offset = (center_row * surface.width + center_x) * 4
        original_red = surface.data[center_offset]
        original_green = surface.data[center_offset + 1]
        original_blue = surface.data[center_offset + 2]

        brightness = Array.new(49, 0)
        red_green = Array.new(49, 0)
        blue = Array.new(49, 0)
        index = 0
        (-radius..radius).each do |y|
          sample_y = [center_y + y, 0].max
          sample_y = [sample_y, surface.height - 1].min
          sample_row = surface.height - 1 - sample_y
          (-radius..radius).each do |x|
            sample_x = [center_x + x, 0].max
            sample_x = [sample_x, surface.width - 1].min
            offset = (sample_row * surface.width + sample_x) * 4
            red = surface.data[offset]
            green = surface.data[offset + 1]
            sample_blue = surface.data[offset + 2]
            luminance = _f32(_f32(_f32(red * 0.2126) + _f32(green * 0.7152)) + _f32(sample_blue * 0.0722))
            packed_red = _median_float_to_half(red)
            packed_green = _median_float_to_half(green)
            brightness[index] = _f32_bits(luminance)
            red_green[index] = NoisemakerCpu::UintMath.u32((packed_red << 16) | packed_green)
            blue[index] = _median_float_to_half(sample_blue)
            index += 1
          end
        end
        count = index
        median_index = (count - 1) >> 1
        left = 0
        right = count - 1
        less = lambda do |l, r|
          if brightness[l] != brightness[r]
            brightness[l] < brightness[r]
          elsif red_green[l] != red_green[r]
            red_green[l] < red_green[r]
          else
            blue[l] < blue[r]
          end
        end
        swap = lambda do |l, r|
          value = brightness[l]
          brightness[l] = brightness[r]
          brightness[r] = value
          value = red_green[l]
          red_green[l] = red_green[r]
          red_green[r] = value
          value = blue[l]
          blue[l] = blue[r]
          blue[r] = value
        end
        while left < right
          pivot_brightness = brightness[median_index]
          pivot_red_green = red_green[median_index]
          pivot_blue = blue[median_index]
          less_pivot = lambda do |record|
            if brightness[record] != pivot_brightness
              brightness[record] < pivot_brightness
            elsif red_green[record] != pivot_red_green
              red_green[record] < pivot_red_green
            else
              blue[record] < pivot_blue
            end
          end
          pivot_less = lambda do |record|
            if pivot_brightness != brightness[record]
              pivot_brightness < brightness[record]
            elsif pivot_red_green != red_green[record]
              pivot_red_green < red_green[record]
            else
              pivot_blue < blue[record]
            end
          end
          scan_left = left
          scan_right = right
          while scan_left <= scan_right
            scan_left += 1 while less_pivot.call(scan_left)
            scan_right -= 1 while pivot_less.call(scan_right)
            if scan_left <= scan_right
              swap.call(scan_left, scan_right)
              scan_left += 1
              scan_right -= 1
            end
          end
          left = scan_left if scan_right < median_index
          right = scan_right if median_index < scan_left
        end
        packed = red_green[median_index]
        median_red = _median_half_to_float(packed >> 16)
        median_green = _median_half_to_float(packed & 0xffff)
        median_blue = _median_half_to_float(blue[median_index])
        # JS Math.max propagates NaN (Math.max(NaN, x) = NaN), and `NaN >= t`
        # is false — the packed half can be a NaN pattern for out-of-domain
        # inputs. Ruby's Array#max and `>=` would instead raise or misorder.
        maximum_difference = [
          (original_red - median_red).abs,
          (original_green - median_green).abs,
          (original_blue - median_blue).abs
        ].reduce do |acc, value|
          next Float::NAN if acc.nan? || value.nan?

          value > acc ? value : acc
        end
        threshold = ctx.uniforms["threshold"]
        replace = threshold.to_f <= 0 || !(maximum_difference < threshold.to_f / 100)
        out[0] = replace ? median_red : original_red
        out[1] = replace ? median_green : original_green
        out[2] = replace ? median_blue : original_blue
        out[3] = surface.data[center_offset + 3]
      end
    end)

    # ---- classicNoisedeck/fractal: Julia/Newton/Mandelbrot (full
    # reimplementation) -- the oracle renders fractal through the hand-written
    # CPU adapter (src/effects/adapters/fractal.js), not the transpiled CDN
    # GLSL, so the adapter is the parity target. Julia and shared color mapping
    # follow its float32 rounding and fused-operation order; Newton and
    # Mandelbrot retain their existing float64 iteration paths.
    #
    # V8's 2-argument Math.hypot is exactly
    # sqrt((x/m)^2 + (y/m)^2) * m with m = max(|x|, |y|) -- verified 200k
    # random pairs across the adapter's value range; Ruby's Math.hypot
    # (C hypot) differs in the last bit on ~1 in 10k of those pairs.

    FRACTAL_PI = 3.14159265359
    FRACTAL_TAU = 6.28318530718
    FRACTAL_PALETTE_TAU = 6.28318

    def self._hypot2(x, y)
      m = x.abs > y.abs ? x.abs : y.abs
      return m if m.zero? || m == Float::INFINITY

      (x.fdiv(m)**2 + y.fdiv(m)**2)**0.5 * m
    end

    def self._fmap(value, in_min, in_max, out_min, out_max)
      out_min + ((out_max - out_min) * (value - in_min)) / (in_max - in_min)
    end

    def self._ffract(value)
      value - value.floor
    end

    def self._fmod(value, divisor)
      value - (divisor * (value.fdiv(divisor)).floor)
    end

    def self._frotate(x, y, rotation, aspect)
      angle = _fmap(rotation, 0.0, 360.0, 0.0, 2.0) * FRACTAL_PI
      px = x - (0.5 * aspect)
      py = y - 0.5
      cs = Math.cos(angle)
      sn = Math.sin(angle)
      [(cs * px) + (sn * py) + (0.5 * aspect), (-sn * px) + (cs * py) + 0.5]
    end

    def self._fmap32(value, in_min, in_max, out_min, out_max)
      _f32(out_min + _f32(out_max - out_min) * ((value - in_min) * _f32(1.0.fdiv(_f32(in_max - in_min)))))
    end

    def self._fmix32(a, b, amount)
      _f32(_f32(a * _f32(1.0 - amount)) + _f32(b * amount))
    end

    def self._frotate32(x, y, rotation, aspect)
      angle = _f32(_fmap32(rotation, 0.0, 360.0, 0.0, 2.0) * _f32(3.1415929794311523))
      px = _f32(x - _f32(0.5 * aspect))
      py = _f32(y - 0.5)
      cs = _f32(angle.infinite? ? Float::NAN : Math.cos(angle))
      sn = _f32(Math.sin(angle))
      [_f32(sn * py + _f32(cs * px)), _f32(cs * py + _f32(-sn * px))]
    end

    def self._ffract32(value)
      _f32(value - value.floor)
    end

    def self._fmod32(value, divisor)
      base = _f32(value)
      _f32(base - _f32(divisor * _f32(base.fdiv(divisor)).floor))
    end

    def self._fhsv_to_rgb32(h, s, v)
      h = _ffract32(h)
      c = _f32(v * s)
      x = _f32(c * _f32(1.0 - (_fmod32(_f32(h * 6.0), 2.0) - 1.0).abs))
      m = _f32(v - c)
      color = if h < 1.0.fdiv(6.0)
        [c + m, x + m, m]
      elsif h < 2.0.fdiv(6.0)
        [x + m, c + m, m]
      elsif h < 3.0.fdiv(6.0)
        [m, c + m, x + m]
      elsif h < 4.0.fdiv(6.0)
        [m, x + m, c + m]
      elsif h < 5.0.fdiv(6.0)
        [x + m, m, c + m]
      else
        [c + m, m, x + m]
      end
      color.map { |value| _f32(value) }
    end

    def self._fpalette32(t, u)
      return _fpalette(t, u) if u["paletteMode"] == 2

      color = (0..2).map do |channel|
        inner = _f32(u["paletteFreq"][channel] * t + u["palettePhase"][channel])
        cosine = _f32(Math.cos(_f32(inner * _f32(FRACTAL_PALETTE_TAU))))
        _f32(u["paletteAmp"][channel] * cosine + u["paletteOffset"][channel])
      end
      u["paletteMode"] == 1 ? _fhsv_to_rgb32(*color) : color
    end

    def self._linear_to_srgb_f(value)
      return value * 12.92 if value <= 0.0031308

      (1.055 * (value**(1.0.fdiv(2.4)))) - 0.055
    end

    def self._fpalette(t, u)
      color = [
        u["paletteOffset"][0] + (u["paletteAmp"][0] * Math.cos(FRACTAL_PALETTE_TAU * ((u["paletteFreq"][0] * t) + u["palettePhase"][0]))),
        u["paletteOffset"][1] + (u["paletteAmp"][1] * Math.cos(FRACTAL_PALETTE_TAU * ((u["paletteFreq"][1] * t) + u["palettePhase"][1]))),
        u["paletteOffset"][2] + (u["paletteAmp"][2] * Math.cos(FRACTAL_PALETTE_TAU * ((u["paletteFreq"][2] * t) + u["palettePhase"][2])))
      ]
      mode = u["paletteMode"]
      # The adapter's `color` target is a Float32Array: the palette values are
      # f32-truncated on store before paletteMode 1/2 read them.
      color = color.map { |value| _f32(value) }
      color = _fhsv_to_rgb(color[0], color[1], color[2]) if mode == 1
      if mode == 2
        l = color[0]
        a = (color[1] * -0.509) + 0.276
        b = (color[2] * -0.509) + 0.198
        l1 = l + (0.3963377774 * a) + (0.2158037573 * b)
        m1 = l - (0.1055613458 * a) - (0.0638541728 * b)
        s1 = l - (0.0894841775 * a) - (1.291485548 * b)
        l3 = l1 * l1 * l1
        m3 = m1 * m1 * m1
        s3 = s1 * s1 * s1
        color = [
          _linear_to_srgb_f((4.0767245293 * l3) - (3.3072168827 * m3) + (0.2307590544 * s3)),
          _linear_to_srgb_f((-1.2681437731 * l3) + (2.6093323231 * m3) - (0.341134429 * s3)),
          _linear_to_srgb_f((-0.0041119885 * l3) - (0.7034763098 * m3) + (1.7068625689 * s3))
        ]
      end
      color
    end

    # Mirrors the adapter's hsvToRgb (f64 chain, no per-step rounding).
    def self._fhsv_to_rgb(h, s, v)
      h = _ffract(h)
      c = v * s
      x = c * (1.0 - (_fmod(h * 6.0, 2.0) - 1.0).abs)
      m = v - c
      if h < 1.0.fdiv(6.0)
        [c + m, x + m, m]
      elsif h < 2.0.fdiv(6.0)
        [x + m, c + m, m]
      elsif h < 3.0.fdiv(6.0)
        [m, c + m, x + m]
      elsif h < 4.0.fdiv(6.0)
        [m, x + m, c + m]
      elsif h < 5.0.fdiv(6.0)
        [x + m, m, c + m]
      else
        [c + m, m, x + m]
      end
    end

    def self._fjulia(x, y, u, aspect)
      x, y, aspect = [_f32(x), _f32(y), _f32(aspect)]
      time = _f32(u["time"])
      zoom = _fmap32(u["zoomAmt"], 0.0, 100.0, 2.0, 0.5)
      speedy = _fmap32(u["speed"], 0.0, 100.0, 0.0, 1.0)
      speed = _fmix32(_f32(speedy * 0.05), _f32(speedy * 0.125), speedy)
      cx = _f32(Math.sin(_f32(time * _f32(FRACTAL_TAU))) * speed + _fmap32(u["offsetX"], -100.0, 100.0, -0.5, 0.5))
      cy = _f32(Math.cos(_f32(time * _f32(FRACTAL_TAU))) * speed + _fmap32(u["offsetY"], -100.0, 100.0, -1.0, 1.0))
      x, y = _frotate32(x, y, _f32(u["rotation"]), aspect)
      # The oracle rounds each zoom multiply plus center add only once.
      x = _f32(x * zoom + _fmap32(u["centerX"], -100.0, 100.0, 1.0, -1.0))
      y = _f32(y * zoom + _fmap32(u["centerY"], -100.0, 100.0, 1.0, -1.0))
      count = u["iterations"] * 2.0
      iteration = 0.0
      index = 0.0
      while index < count
        iteration = index
        next_x = _f32(_f32(x * x + cx) - y * y)
        next_y = _f32(y * x + x * y + cy)
        break if _f32(next_x * next_x + next_y * next_y) > 4.0

        x = next_x
        y = next_y
        index += 1.0
      end
      return 1.0 if (count - iteration) < u["cutoff"].to_i

      u["mode"] == 0 ? _f32(iteration.fdiv(count)) : _f32(Math.sqrt(_f32(x * x + y * y)))
    end

    def self._fnewton(x, y, u, aspect)
      x, y = _frotate(x, y, u["rotation"] + 90.0, aspect)
      zoom = _fmap(u["zoomAmt"], 0.0, 130.0, 1.0, 0.01)
      x = ((x - (0.5 * aspect)) * zoom) + (u["centerY"] * 0.01)
      y = ((y - 0.5) * zoom) + (u["centerX"] * 0.01)
      speed = _fmap(u["speed"], 0.0, 100.0, 0.0, 1.0)
      offset_x = _fmap(u["offsetX"], -100.0, 100.0, -0.25, 0.25)
      offset_y = _fmap(u["offsetY"], -100.0, 100.0, -0.25, 0.25)
      iteration = 0.0
      while iteration < u["iterations"]
        fx = (x * x * x) - (3.0 * x * y * y) - 1.0
        fy = (3.0 * x * x * y) - (y * y * y)
        fpx = (3.0 * x * x) - (3.0 * y * y)
        fpy = 6.0 * x * y
        denominator = (fpx * fpx) + (fpy * fpy)
        tx = ((fx * fpx) + (fy * fpy)).fdiv(denominator)
        ty = ((fy * fpx) - (fx * fpy)).fdiv(denominator)
        tx += (Math.sin(u["time"] * FRACTAL_TAU) * 0.1 * speed) + offset_x
        ty += (Math.cos(u["time"] * FRACTAL_TAU) * 0.1 * speed) + offset_y
        break if _hypot2(tx, ty) < 0.001

        x -= tx
        y -= ty
        iteration += 1.0
      end
      u["mode"] == 0 ? iteration.fdiv(u["iterations"]) : _hypot2(x, y)
    end

    def self._fmandelbrot(x, y, u, aspect)
      zoom = _fmap(u["zoomAmt"], 0.0, 100.0, 2.0, 0.5)
      speedy = _fmap(u["speed"], 0.0, 100.0, 0.0, 1.0)
      speed = (speedy * 0.05) * (1.0 - speedy) + (speedy * 0.125) * speedy
      x, y = _frotate(x, y, u["rotation"], aspect)
      y = (y * 2.0) - 1.0
      x = (x * 2.0) - aspect
      cx = (zoom * x) - ((u["centerX"] + 50.0) * 0.01)
      cy = (zoom * y) - (u["centerY"] * 0.01)
      x = Math.sin(u["time"] * FRACTAL_TAU) * speed
      y = Math.cos(u["time"] * FRACTAL_TAU) * speed
      iteration = 0.0
      while iteration < u["iterations"]
        next_x = (x * x) - (y * y) + cx
        next_y = (2.0 * x * y) + cy
        x = next_x
        y = next_y
        break if ((x * x) + (y * y)) > 16.0

        iteration += 1.0
      end
      return 1.0 if iteration == u["iterations"]

      u["mode"] == 0 ? iteration.fdiv(u["iterations"]) : _hypot2(x, y).fdiv(u["iterations"])
    end

    register("classicNoisedeck/fractal", "fractal", lambda do |_rt, _compiled|
      lambda do |ctx, out|
        u = ctx.uniforms
        full_resolution = u["fullResolution"]
        tile_offset = u["tileOffset"]
        aspect = full_resolution[0].fdiv(full_resolution[1])
        global_x = (0.0 + ctx.frag_coord[0]) + tile_offset[0]
        global_y = (0.0 + ctx.frag_coord[1]) + tile_offset[1]
        x = global_x.fdiv(full_resolution[1])
        y = global_y.fdiv(full_resolution[1])
        distance =
          case u["type"]
          when 1 then _fnewton(x, y, u, aspect)
          else u["type"].zero? ? _fjulia(x, y, u, aspect) : _fmandelbrot(x, y, u, aspect)
          end
        if distance == 1.0
          out[0] = u["bgColor"][0]
          out[1] = u["bgColor"][1]
          out[2] = u["bgColor"][2]
          out[3] = _f32(_f32(u["bgAlpha"]) * _f32(0.01))
          return
        end
        cycle = u["cyclePalette"]
        distance = _f32(distance - u["time"]) if cycle == -1
        distance = _f32(distance + u["time"]) if cycle == 1
        distance = _ffract32(_f32(distance * _f32(u["repeatPalette"]) + _f32(_f32(u["rotatePalette"]) * _f32(0.01))))
        levels = u["levels"]
        if levels > 0
          levels = _f32(_f32(levels) + 1.0)
          distance = _f32(_f32(distance * levels).floor.fdiv(levels))
        end
        color =
          case u["colorMode"]
          when 0 then [_ffract32(distance)] * 3
          when 4 then _fpalette32(distance, u)
          when 6 then _fhsv_to_rgb32(_f32(distance * _f32(_f32(u["hueRange"]) * _f32(0.01))), 1.0, 1.0)
          else [0.0, 0.0, 1.0]
          end
        out[0] = _f32(color[0])
        out[1] = _f32(color[1])
        out[2] = _f32(color[2])
        out[3] = 1.0
      end
    end)
  end
end
