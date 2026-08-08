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

# NOTE (parallel-build bootstrap): Sampler and PaletteData are owned by
# Worker A. Only the snow/palette adapter BODIES (invoked per-pixel, long
# after registration) need them, so the registry + pure helpers in this file
# load standalone even before sampler.rb/palette_data.rb land.
begin
  require_relative "sampler"
rescue LoadError
  nil
end
begin
  require_relative "palette_data"
rescue LoadError
  nil
end

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
      phase = turns - turns.floor
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
  end
end
