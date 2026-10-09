# frozen_string_literal: true

# CPU adapter registry -- the reference engine renders a handful of effects
# through hand-written CPU adapters (canonicalAdapterFactories) instead of
# the transpiled GLSL kernel. For byte-parity we run the same adapters:
#
#   filter/crt:crt        -- same kernel, `sin` replaced by range-reduced
#                            metalSine (large-argument precision).
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

    # ---- filter/crt: range-reduced sine ----

    def self._metal_sine(value)
      turns = _f32(value * INV_TAU)
      phase = turns - (turns.nan? ? turns : turns.floor)
      _f32(Math.sin(phase * TAU32))
    end

    def self._crt_sin(v)
      return _metal_sine(v) unless v.is_a?(Array)

      v.map { |x| _metal_sine(x) }
    end

    register("filter/crt", "crt", lambda do |rt, compiled|
      base = compiled[:kernel]
      lambda do |ctx, out|
        override = rt.stdlib_override
        # Runtime exposes stdlib_override as a reader over a mutable Hash
        # (no writer -- see runtime.rb's header note), so save/restore the
        # single "sin" entry in place rather than swapping the whole Hash the
        # way Perl's `$rt->{stdlib_override} = { %$prev, sin => ... }` does.
        had_prev = override.key?("sin")
        prev_sin = override["sin"]
        override["sin"] = method(:_crt_sin)
        begin
          base.call(ctx, out)
        ensure
          if had_prev
            override["sin"] = prev_sin
          else
            override.delete("sin")
          end
        end
      end
    end)

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
      _f32(x - x.floor)
    end

    def self._sclamp01(x)
      x <= 0 ? 0.0 : (x >= 1 ? 1.0 : x)
    end

    def self._ssine(x)
      turns = _f32(x * INV_TAU)
      phase = turns - turns.floor
      _f32(Math.sin(phase * TAU32))
    end

    def self._speriodic(a, b)
      _smul(_sadd(_ssine(_smul(_ssub(a, b), TAU32)), 1.0), 0.5)
    end

    def self._snow_hash(x, y, z)
      sx = _sfract(_smul(x, _f32(0.1031)))
      sy = _sfract(_smul(y, _f32(0.1031)))
      sz = _sfract(_smul(z, _f32(0.1031)))
      # `sx * add(...)` and `sz * add(...)` are RAW float64 products in the
      # JS source; only mul(...) and the two outer F32(...) wraps round.
      # Preserve that grouping exactly.
      inner = _f32((sx * _sadd(sy, _f32(33.33))) + _smul(sy, _sadd(sz, _f32(33.33))))
      dot = _f32(inner + (sz * _sadd(sx, _f32(33.33))))
      shifted_xy = _f32(sx + sy + _f32(2.0 * dot))
      _sclamp01(_sfract(_f32(shifted_xy * _sadd(sz, dot))))
    end

    def self._snow_noise(x, y, time, speed, seed)
      angle = _smul(time, TAU32)
      cosine_value = _f32(Math.cos(angle))
      z_base = cosine_value.abs < _f32(0.0000001) ? 0.0 : _smul(cosine_value, speed)
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
        x = 0.0 + ctx.frag_coord[0]
        y = 0.0 + ctx.frag_coord[1]
        source = rt.texel_fetch(ctx.texture_binding("inputTex"), [x, y])
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
        lim = limiter_value < _f32(0.99) ? limiter_value : _f32(0.99)
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
    # GLSL, so the adapter is the parity target. The f64 chain matters at
    # mode 1/2 (the Math.hypot distance feeds the palette directly); the
    # transpiled kernel's f32 vector stores diverge over 100 iterations.
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
      zoom = _fmap(u["zoomAmt"], 0.0, 100.0, 2.0, 0.5)
      speedy = _fmap(u["speed"], 0.0, 100.0, 0.0, 1.0)
      speed = (speedy * 0.05) * (1.0 - speedy) + (speedy * 0.125) * speedy
      cx = (Math.sin(u["time"] * FRACTAL_TAU) * speed) + _fmap(u["offsetX"], -100.0, 100.0, -0.5, 0.5)
      cy = (Math.cos(u["time"] * FRACTAL_TAU) * speed) + _fmap(u["offsetY"], -100.0, 100.0, -1.0, 1.0)
      x, y = _frotate(x, y, u["rotation"], aspect)
      x = ((x - (0.5 * aspect)) * zoom) + _fmap(u["centerX"], -100.0, 100.0, 1.0, -1.0)
      y = ((y - 0.5) * zoom) + _fmap(u["centerY"], -100.0, 100.0, 1.0, -1.0)
      count = u["iterations"] * 2.0
      iteration = 0.0
      index = 0.0
      while index < count
        iteration = index
        next_x = (x * x) - (y * y) + cx
        next_y = (y * x) + (x * y) + cy
        break if ((next_x * next_x) + (next_y * next_y)) > 4.0

        x = next_x
        y = next_y
        index += 1.0
      end
      return 1.0 if (count - iteration) < u["cutoff"].to_i

      u["mode"] == 0 ? iteration.fdiv(count) : _hypot2(x, y)
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
          out[3] = _f32(u["bgAlpha"] * 0.01)
          return
        end
        cycle = u["cyclePalette"]
        distance -= u["time"] if cycle == -1
        distance += u["time"] if cycle == 1
        distance = _ffract((distance * u["repeatPalette"]) + (u["rotatePalette"] * 0.01))
        levels = u["levels"]
        if levels > 0
          levels += 1
          distance = (distance * levels).floor.fdiv(levels)
        end
        color =
          case u["colorMode"]
          when 0 then [_ffract(distance)] * 3
          when 4 then _fpalette(distance, u)
          when 6 then _fhsv_to_rgb((distance * u["hueRange"]) * 0.01, 1.0, 1.0)
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
