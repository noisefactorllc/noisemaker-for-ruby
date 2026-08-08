# frozen_string_literal: true

# Procedural worm/fiber/scratch overlay generator.
#
# Port of noisemaker-cpu src/effects/cpu/worm-overlay.js (via the Python
# port). filter/fibers, filter/scratches and filter/strayHair declare an
# overlayTex that no pass produces; the reference engine generates it once on
# the CPU and binds it.
#
# Fidelity notes:
# - SeededRng multiplies with plain JS `*` on products up to ~2^61, which is
#   LOSSY in float64 (NOT Math.imul). We replicate that by multiplying in NV
#   (float64) and truncating. Ruby Integers are arbitrary-precision (unlike
#   Perl's native IV, which is what actually makes the exact-integer trick
#   below work identically in both languages -- see _round53), so the same
#   exact-integer emulation ports verbatim.
# - Field/surface storage is float32; reads promote to float64, writes round.
# - Final surface is quantized to 8-bit like the reference.

# NOTE (parallel-build bootstrap): Surface is owned by Worker A. Only
# render_worm_overlay (via _trace/_draw_segment) needs it, and only when
# actually CALLED, so this file -- including SeededRng, which never touches
# Surface -- loads standalone even before surface.rb lands.
begin
  require_relative "surface"
rescue LoadError
  nil
end

module NoisemakerCpu
  module OverlayGen
    TAU = 2.0 * 3.141592653589793
    M = 0xFFFFFFFF

    OVERLAY_EFFECTS = ["filter/fibers", "filter/scratches", "filter/strayHair"].freeze

    def self.is_overlay_effect(effect_id)
      OVERLAY_EFFECTS.include?(effect_id)
    end

    def self._f32(x)
      [x].pack("e").unpack1("e")
    end

    # Floored float modulo (Python/JS `((x % n) + n) % n` building block): result
    # sign follows the divisor, unlike POSIX::fmod's truncated semantics.
    def self._pymod(x, n)
      r = x.remainder(n)
      r += n if r != 0 && ((r < 0) != (n < 0))
      r
    end

    # JS advances state with a plain `*` whose ~2^61 product is LOSSY in
    # float64 -- that loss is part of the reference stream. We EMULATE the
    # float64 arithmetic in exact integer space: products of (u32 x 30-bit
    # constant) are exact Ruby Integers, and _round53 applies IEEE
    # round-to-nearest-even to 53 bits of mantissa -- bit-identical to the JS
    # double result -- before the exact mod-2^32.
    class SeededRng
      # Round a non-negative exact integer (< 2^62) to float64 precision: keep
      # the top 53 significant bits, round half to even.
      def self._round53(n)
        return n if n < 9_007_199_254_740_992 # < 2^53: already exact

        h = 0
        t = n
        h += 1 while (t >>= 1) != 0 # Ruby: 0 is truthy, so the zero-test must be explicit
        shift = h - 52
        keep = n >> shift
        rem = n & ((1 << shift) - 1)
        half = 1 << (shift - 1)
        keep += 1 if rem > half || (rem == half && (keep & 1) != 0)
        keep << shift
      end

      # float64( state*747796405 + 2891336453 ) mod 2^32, exactly.
      def self._advance(state)
        sum = _round53(_round53(state * 747796405) + 2891336453)
        sum % 4294967296
      end

      def initialize(seed)
        state = seed.to_i & M
        # constructor already advances once (matches JS)
        @state = self.class._advance(state)
      end

      def next_word
        s = @state = self.class._advance(@state)
        word = self.class._round53(((s >> ((s >> 28) + 4)) ^ s) * 277803737) % 4294967296
        ((word >> 22) ^ word) & M
      end

      def float
        next_word.fdiv(4294967295.0)
      end

      def normal(mean, deviation)
        u1 = float
        u1 = 1e-10 if u1 < 1e-10
        u2 = float
        mean + deviation * Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(TAU * u2)
      end
    end

    def self._value_noise_field(width, height, frequency, rng)
      grid_w = frequency.ceil + 2
      grid_h = frequency.ceil + 2
      grid = (1..(grid_w * grid_h)).map { _f32(rng.float) }
      field = []
      (0..height - 1).each do |y|
        (0..width - 1).each do |x|
          fx = x.fdiv(width) * frequency
          fy = y.fdiv(height) * frequency
          ix = fx.floor
          iy = fy.floor
          dx = fx - ix
          dy = fy - iy
          sx = dx * dx * (3 - 2 * dx)
          sy = dy * dy * (3 - 2 * dy)
          tl = grid[iy * grid_w + ix]
          tr = grid[iy * grid_w + ix + 1]
          bl = grid[(iy + 1) * grid_w + ix]
          br = grid[(iy + 1) * grid_w + ix + 1]
          field << _f32(((tl * (1 - sx) + tr * sx) * (1 - sy)) + ((bl * (1 - sx) + br * sx) * sy))
        end
      end
      field
    end

    def self._draw_segment(surface, x0, y0, x1, y1, line_width, color, alpha)
      return if alpha <= 0

      radius = line_width * 0.5
      w = surface.width
      h = surface.height
      min_x = ((x0 < x1 ? x0 : x1) - radius - 1).floor
      min_x = 0 if min_x < 0
      max_x = ((x0 > x1 ? x0 : x1) + radius + 1).ceil
      max_x = w - 1 if max_x > w - 1
      min_y = ((y0 < y1 ? y0 : y1) - radius - 1).floor
      min_y = 0 if min_y < 0
      max_y = ((y0 > y1 ? y0 : y1) + radius + 1).ceil
      max_y = h - 1 if max_y > h - 1
      dx = x1 - x0
      dy = y1 - y0
      len_sq = (dx * dx) + (dy * dy)
      data = surface.data
      (min_y..max_y).each do |y|
        (min_x..max_x).each do |x|
          px = x + 0.5
          py = y + 0.5
          amount = 0
          if len_sq > 0
            amount = (((px - x0) * dx) + ((py - y0) * dy)).fdiv(len_sq)
            amount = 0 if amount < 0
            amount = 1 if amount > 1
          end
          near_x = x0 + (dx * amount)
          near_y = y0 + (dy * amount)
          distance = Math.sqrt(((px - near_x)**2) + ((py - near_y)**2))
          coverage = radius + 0.5 - distance
          coverage = 0 if coverage < 0
          coverage = 1 if coverage > 1
          src_a = alpha * coverage
          next if src_a <= 0

          off = ((y * w) + x) * 4
          dst_a = data[off + 3]
          out_a = src_a + (dst_a * (1 - src_a))
          (0..2).each do |c|
            data[off + c] =
              out_a > 0 ? _f32(((color[c] * src_a) + (data[off + c] * dst_a * (1 - src_a))).fdiv(out_a)) : 0
          end
          data[off + 3] = _f32(out_a)
        end
      end
    end

    def self._trace(surface, opts)
      rng = SeededRng.new(opts["seed"])
      min_dim = surface.width < surface.height ? surface.width : surface.height
      max_dim = surface.width > surface.height ? surface.width : surface.height
      stride_scale = max_dim.fdiv(1024)
      flow = _value_noise_field(
        surface.width, surface.height, opts["flowFrequency"],
        SeededRng.new(opts["seed"] * 31337)
      )
      count = (max_dim * opts["density"]).floor
      count = 1 if count < 1
      shared_rotation = rng.float * TAU
      worms = []
      (0..count - 1).each do |index|
        worms << {
          "x" => rng.float * surface.width,
          "y" => rng.float * surface.height,
          "stride" => rng.normal(opts["stride"], opts["strideDeviation"]) * stride_scale,
          "rotation" => opts["behavior"] == "obedient" ? shared_rotation : rng.float * TAU,
          "color" => opts["color"].call(rng, index)
        }
      end
      iterations = (Math.sqrt(min_dim) * opts["duration"]).floor
      iterations = 1 if iterations < 1
      worms.each do |worm|
        x = worm["x"]
        y = worm["y"]
        (0..iterations - 1).each do |iteration|
          lifetime = iterations > 1 ? iteration.fdiv(iterations - 1) : 1
          exposure = 1 - (1 - (lifetime * 2)).abs
          flow_x = _pymod(_pymod(x, surface.width) + surface.width, surface.width).floor
          flow_y = _pymod(_pymod(y, surface.height) + surface.height, surface.height).floor
          angle = flow[(flow_y * surface.width) + flow_x] * TAU * opts["kink"]
          angle += opts["behavior"] == "obedient" ? shared_rotation : worm["rotation"]
          next_x = x + (Math.sin(angle) * worm["stride"])
          next_y = y + (Math.cos(angle) * worm["stride"])
          _draw_segment(surface, x, y, next_x, next_y, opts["lineWidth"], worm["color"],
            opts["alpha"] * exposure)
          x = next_x
          y = next_y
        end
      end
    end

    def self.render_worm_overlay(effect_id, width, height, params)
      surface = NoisemakerCpu::Surface.new(width, height)
      seed = params["seed"]
      seed = 1 if seed.nil? || seed == 0
      density = params["density"]
      case effect_id
      when "filter/fibers"
        base_density = 0.5 + (density * 2)
        (0..3).each do |layer|
          layer_seed = (seed * 1000) + (layer * 137)
          _trace(surface, {
            "seed" => layer_seed,
            "density" => base_density,
            "kink" => 5 + (layer_seed % 5),
            "stride" => 0.75,
            "strideDeviation" => 0.125,
            "duration" => 1,
            "behavior" => "chaotic",
            "flowFrequency" => 4,
            "lineWidth" => (width.fdiv(384) > 1.5 ? width.fdiv(384) : 1.5),
            "color" => lambda do |rng, _index|
              [
                (rng.float * 200 + 55).floor.fdiv(255),
                (rng.float * 200 + 55).floor.fdiv(255),
                (rng.float * 200 + 55).floor.fdiv(255)
              ]
            end,
            "alpha" => 0.5
          })
        end
      when "filter/scratches"
        (0..3).each do |layer|
          layer_seed = (seed * 1000) + (layer * 251)
          _trace(surface, {
            "seed" => layer_seed,
            "density" => 0.1 + (density * 0.4),
            "kink" => 0.125 + (layer_seed % 50).fdiv(400),
            "stride" => 0.75,
            "strideDeviation" => 0.5,
            "duration" => 2 + (layer_seed % 3),
            "behavior" => (layer_seed % 2 == 0 ? "obedient" : "unruly"),
            "flowFrequency" => 2 + (layer_seed % 3),
            "lineWidth" => (width.fdiv(1024) > 0.5 ? width.fdiv(1024) : 0.5),
            "color" => lambda { |_rng, _index| [1.0, 1.0, 1.0] },
            "alpha" => 1
          })
        end
      when "filter/strayHair"
        layer_seed = (seed * 1000) + 42
        _trace(surface, {
          "seed" => layer_seed,
          "density" => 0.001 + (density * 0.004),
          "kink" => 5 + (layer_seed % 45),
          "stride" => 0.5,
          "strideDeviation" => 0.25,
          "duration" => 8 + (layer_seed % 8),
          "behavior" => "unruly",
          "flowFrequency" => 4,
          "lineWidth" => (width.fdiv(400) > 1 ? width.fdiv(400) : 1),
          "color" => lambda do |rng, _index|
            [
              (rng.float * 30).floor.fdiv(255),
              (rng.float * 30).floor.fdiv(255),
              (rng.float * 30).floor.fdiv(255)
            ]
          end,
          "alpha" => 0.666
        })
      else
        raise "Unsupported canonical CPU overlay #{effect_id}"
      end
      surface.data.map! do |v|
        x = v < 0 ? 0 : (v > 1 ? 1 : v)
        # Snap to f32 -- Surface data holds float32-representable values.
        _f32(((x * 255.0) + 0.5).floor.fdiv(255.0))
      end
      surface
    end
  end
end
