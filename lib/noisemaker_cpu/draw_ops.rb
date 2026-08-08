# frozen_string_literal: true

# CPU-only draw operations for drawMode passes (no GLSL kernel).
#
# wormhole deposit: port of noisemaker-cpu src/effects/cpu/wormhole.js
# (runWormholeDeposit) via the Python port -- scatter each source pixel into a
# lightness-driven offset destination, accumulating weighted color with
# float16 truncation (matching the GPU rgba16f attachment).

# NOTE (parallel-build bootstrap): TextureFormat is owned by Worker A.
# wormhole_deposit only resolves NoisemakerCpu::TextureFormat when actually
# CALLED, so the registry + pure helpers in this file load standalone even
# before texture_format.rb lands.
begin
  require_relative "texture_format"
rescue LoadError
  nil
end

module NoisemakerCpu
  module DrawOps
    @draw_ops = {} # "effect_id:program" -> callable(src, dest, uniforms)

    def self.register(effect_id, program, op)
      @draw_ops["#{effect_id}:#{program}"] = op
    end

    def self.get_draw_op(effect_id, program)
      @draw_ops["#{effect_id}:#{program}"]
    end

    TAU = 6.28318530717959
    PI = 3.141592653589793

    def self._f32(x)
      [x].pack("e").unpack1("e")
    end

    def self._add(a, b)
      _f32(a + b)
    end

    def self._mul(a, b)
      _f32(a * b)
    end

    def self._div(a, b)
      _f32(a.fdiv(b))
    end

    def self._oklab_lightness(red, green, blue)
      r = red < 0 ? 0 : (red > 1 ? 1 : red)
      g = green < 0 ? 0 : (green > 1 ? 1 : green)
      b = blue < 0 ? 0 : (blue > 1 ? 1 : blue)
      l = _add(_add(_mul(_f32(0.4122214708), r), _mul(_f32(0.5363325363), g)), _mul(_f32(0.0514459929), b))
      m = _add(_add(_mul(_f32(0.2119034982), r), _mul(_f32(0.6806995451), g)), _mul(_f32(0.1073969566), b))
      s = _add(_add(_mul(_f32(0.0883024619), r), _mul(_f32(0.2817188376), g)), _mul(_f32(0.6299787005), b))
      exponent = _div(1, 3)
      lr = _f32((l > 0 ? l : 0)**exponent)
      mr = _f32((m > 0 ? m : 0)**exponent)
      sr = _f32((s > 0 ? s : 0)**exponent)
      _add(_add(_mul(_f32(0.2104542553), lr), _mul(_f32(0.793617785), mr)), _mul(_f32(-0.0040720468), sr))
    end

    def self._wrap_repeat(value, size)
      ((value % size) + size) % size
    end

    def self._wrap_mirror(value, size)
      mirrored = _wrap_repeat(value, size * 2)
      size - 1 - (mirrored - size + 1).abs
    end

    def self.wormhole_deposit(input, dest, uniforms)
      width = input.width
      height = input.height
      if width != dest.width || height != dest.height
        raise "wormhole deposit requires matching source/destination dimensions"
      end

      idata = input.data
      odata = dest.data
      kink = 0.0 + (uniforms["kink"].nil? ? 0 : uniforms["kink"])
      pixel_stride = 1024 * (uniforms["stride"].nil? ? 0 : uniforms["stride"])
      rotation = _div(_mul(_f32(uniforms["rotation"].nil? ? 0 : uniforms["rotation"]), _f32(PI)), 180)
      wrap = (uniforms["wrap"].nil? ? 0 : uniforms["wrap"]).to_i
      # Vertex IDs enumerate GL texels bottom-up. Surface storage is top-down.
      (0..height - 1).each do |source_y|
        (0..width - 1).each do |source_x|
          source_row = height - 1 - source_y
          so = (source_row * width + source_x) * 4
          lightness = _oklab_lightness(idata[so], idata[so + 1], idata[so + 2])
          angle = _add(_mul(_mul(lightness, _f32(TAU)), _f32(kink)), rotation)
          offset_x = _mul(_add(_f32(Math.cos(angle)), 1), _f32(pixel_stride))
          offset_y = _mul(_add(_f32(Math.sin(angle)), 1), _f32(pixel_stride))
          dest_x = _add(source_x, offset_x).floor
          dest_y = _add(source_y, offset_y).floor
          if wrap == 0
            dest_x = _wrap_mirror(dest_x, width)
            dest_y = _wrap_mirror(dest_y, height)
          elsif wrap == 2
            dest_x = dest_x < 0 ? 0 : (dest_x > width - 1 ? width - 1 : dest_x)
            dest_y = dest_y < 0 ? 0 : (dest_y > height - 1 ? height - 1 : dest_y)
          else
            dest_x = _wrap_repeat(dest_x, width)
            dest_y = _wrap_repeat(dest_y, height)
          end
          dest_row = height - 1 - dest_y
          do_ = (dest_row * width + dest_x) * 4
          weight = _mul(lightness, lightness)
          odata[do_] = NoisemakerCpu::TextureFormat.float16_truncate(_add(odata[do_], _mul(idata[so], weight)))
          odata[do_ + 1] =
            NoisemakerCpu::TextureFormat.float16_truncate(_add(odata[do_ + 1], _mul(idata[so + 1], weight)))
          odata[do_ + 2] =
            NoisemakerCpu::TextureFormat.float16_truncate(_add(odata[do_ + 2], _mul(idata[so + 2], weight)))
        end
      end
    end

    register("filter/wormhole", "deposit", method(:wormhole_deposit))
  end
end
