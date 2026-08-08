# frozen_string_literal: true

# Per-pass texture-format quantization.
#
# Faithful port of noisemaker-cpu src/runtime/texture-format.js. After each
# render pass the reference engine quantizes the destination surface to that
# attachment's declared format (rgba16f by default, rgba8unorm for some
# intermediates). Skipping this leaves the port at full float32 and diverges
# from the GPU pipeline wherever an intermediate is stored at reduced
# precision.
#
# - rgba16f / rgba16float: round-TOWARD-ZERO truncation to IEEE 754 half
#   (truncate the low mantissa bits, do NOT round to nearest).
# - rgba8 / rgba8unorm: clamp to [0,1], round to 8-bit (JS Math.round =
#   floor(x + 0.5)), and scale back.

require_relative "uint_math"

module NoisemakerCpu
  module TextureFormat
    NAN = Float::NAN

    # Truncate one float to rgba16f storage and decode back to float32.
    # Bit reinterpretation uses the explicit-little-endian pack/unpack pair
    # (contract trap #4), not Ruby's native pack('f')/pack('L').
    def self.float16_truncate(value)
      bits = [value].pack('e').unpack1('V')
      sign = (bits >> 16) & 0x8000
      src_exp = (bits >> 23) & 0xFF
      frac = bits & 0x7FFFFF
      half =
        if src_exp == 0xFF # inf preserves sign; nan -> canonical nan bits
          frac == 0 ? (sign | 0x7C00) : 0x7E00
        else
          exp = src_exp - 127 + 15
          if exp >= 0x1F # overflow -> largest finite half (NOT inf)
            sign | 0x7BFF
          elsif exp <= 0 # subnormal / underflow
            if exp < -10
              sign # flush to signed zero
            else
              mant = frac | 0x800000
              sign | ((mant >> (1 - exp)) >> 13)
            end
          else
            sign | (exp << 10) | (frac >> 13)
          end
        end
      NoisemakerCpu::UintMath._half_to_float(half)
    end

    # Quantize surface data in place to fmt; returns the surface.
    def self.quantize_texture(surface, fmt = "rgba16f")
      d = surface.data
      if fmt == "rgba16f" || fmt == "rgba16float"
        d.map! { |v| float16_truncate(v) }
      elsif fmt == "rgba8" || fmt == "rgba8unorm"
        # Mirror the reference exactly: value <= 0 ? 0 : value >= 1 ? 1 :
        # round(value*255)/255. NaN fails both comparisons and PROPAGATES
        # (floor(NaN) is NaN, no die in Perl/JS) -- the oracle and Python
        # keep NaN too. Ruby's native Float#floor raises FloatDomainError on
        # NaN, so the floor here is inlined with an explicit NaN guard
        # instead of calling a raising floor.
        d.map! do |x|
          if x <= 0.0
            0.0
          elsif x >= 1.0
            1.0
          elsif x.nan?
            NAN
          else
            [(x * 255.0 + 0.5).floor / 255.0].pack("e").unpack1("e")
          end
        end
      end
      surface
    end
  end
end
