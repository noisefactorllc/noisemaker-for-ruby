# frozen_string_literal: true

# Texture samplers -- nearest, bottom-left-flipped nearest, and bilinear.
#
# Faithful port of noisemaker-cpu src/runtime/sampler.js. Every sampler
# clamps to the edge texel for out-of-range u/v (no wraparound).
#
# GLSL samplers address rows from the bottom, but Surface storage stays
# top-down (for fast PNG handoff). sample_nearest addresses storage rows
# directly (no flip). sample_nearest_bottom_left and sample_bilinear flip
# the INTEGER texel row (y = height - 1 - shader_y) rather than the
# normalized coordinate (1 - v) -- `1 - v` is wrong exactly on texel
# boundaries. The flip is only observable on a non-uniform texture (a solid
# input renders identically either way), which is why it must match the GL
# bottom-left convention that texelFetch uses.
#
# sample_bilinear mirrors the JS precision behavior: the four taps are read
# at full (float64) precision and blended, and only the final per-channel
# result is rounded to float32 (Math.fround), matching JS's implicit float64
# widening of Float32Array reads.

module NoisemakerCpu
  module Sampler
    def self._f32(x)
      [x].pack("e").unpack1("e")
    end

    def self._clamp(value, lo, hi)
      return lo if value < lo
      return hi if value > hi

      value
    end

    # Perl's `POSIX::floor` (like JS Math.floor) never raises; Ruby's native
    # Float#floor raises FloatDomainError on NaN/Infinity. u/v reaching a
    # sampler are expected finite (screen or texture coordinates), but a
    # pathological upstream divide-by-zero could in principle produce a
    # non-finite coordinate, so this guards the same way uint_math.rb and
    # texture_format.rb do rather than crashing the render.
    def self._safe_floor_to_i(value)
      return 0 unless value.finite?

      value.floor
    end

    # Nearest-neighbor sample, addressing storage rows top-down (no flip).
    def self.sample_nearest(surface, u, v)
      width = surface.width
      height = surface.height
      x = _clamp(_safe_floor_to_i(u * width), 0, width - 1)
      y = _clamp(_safe_floor_to_i(v * height), 0, height - 1)
      source = (y * width + x) * 4
      d = surface.data
      d[source, 4]
    end

    # Nearest-neighbor sample with GLSL bottom-left row addressing (flips the
    # integer texel row, not the normalized v).
    def self.sample_nearest_bottom_left(surface, u, v)
      width = surface.width
      height = surface.height
      x = _clamp(_safe_floor_to_i(u * width), 0, width - 1)
      shader_y = _clamp(_safe_floor_to_i(v * height), 0, height - 1)
      y = height - 1 - shader_y
      source = (y * width + x) * 4
      d = surface.data
      d[source, 4]
    end

    # Bilinear sample, half-texel-centered, clamped to edge, GL bottom-left
    # row addressing (flips the integer texel row, like
    # sample_nearest_bottom_left).
    def self.sample_bilinear(surface, u, v)
      width = surface.width
      height = surface.height
      d = surface.data

      px = _clamp(u * width - 0.5, 0, width - 1)
      py = _clamp(v * height - 0.5, 0, height - 1)
      x0 = _safe_floor_to_i(px)
      y0 = _safe_floor_to_i(py)
      x1 = x0 + 1 < width - 1 ? x0 + 1 : width - 1
      y1 = y0 + 1 < height - 1 ? y0 + 1 : height - 1
      tx = px - x0
      ty = py - y0

      row0 = (height - 1 - y0) * width * 4
      row1 = (height - 1 - y1) * width * 4
      p00 = row0 + x0 * 4
      p10 = row0 + x1 * 4
      p01 = row1 + x0 * 4
      p11 = row1 + x1 * 4

      out = []
      (0..3).each do |c|
        c00 = d[p00 + c]
        c10 = d[p10 + c]
        c01 = d[p01 + c]
        c11 = d[p11 + c]
        top = c00 + (c10 - c00) * tx
        bottom = c01 + (c11 - c01) * tx
        # Math.fround happens once, at the very end, in the JS source.
        out << _f32(top + (bottom - top) * ty)
      end
      out
    end
  end
end
