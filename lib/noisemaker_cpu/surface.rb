# frozen_string_literal: true

# Surface -- an RGBA float32 pixel buffer, top-down row order.
#
# Faithful port of noisemaker-cpu src/runtime/surface.js (via the Python
# port's surface.py). Storage is a flat Array of width*height*4 numbers
# holding float32-representable values. Conversion to/from 8-bit RGBA is a
# naive /255 linear scale (no sRGB curve). to_rgba8 clamps to [0,1], maps
# non-finite values to zero, and rounds with floor(x*255 + 0.5) to match JS
# Math.round (ties toward +inf).

module NoisemakerCpu
  class Surface
    def self._f32(x)
      [x].pack("e").unpack1("e")
    end

    # Perl checks `$value =~ /^\d+$/ && $value > 0` -- a positive whole
    # number in any of Perl's loosely-typed numeric-ish forms. Accept both
    # Integer and a whole-valued Float the same way (not marked private:
    # called both from class methods with no receiver and from #initialize
    # via `self.class._assert_dim`, i.e. with an explicit receiver, which a
    # private class method would reject).
    def self._assert_dim(value, name)
      whole = value.is_a?(Integer) || (value.is_a?(Float) && value.finite? && value == value.to_i)
      raise "#{name} must be a positive integer" unless whole && value > 0
    end

    attr_reader :width, :height, :data
    attr_accessor :format

    def initialize(width, height, data = nil)
      self.class._assert_dim(width, "width")
      self.class._assert_dim(height, "height")
      length = width * height * 4
      if data
        raise "data must be an array of length #{length}" unless data.is_a?(Array) && data.length == length
      else
        data = Array.new(length, 0.0)
      end
      @width = width
      @height = height
      @data = data
      @format = "rgba16f"
      # "nearest" (canonical internal default) or "linear" (external images).
      @filter = "nearest"
    end

    # Combined getter/setter to mirror Perl's `sub filter { @_ > 1 ? (...) :
    # (...) }` dual-purpose accessor -- callers may use either
    # `surf.filter` (getter) or `surf.filter('linear')` (setter).
    def filter(*value)
      value.empty? ? @filter : (@filter = value[0])
    end

    def self.from_rgba8(width, height, bytes)
      _assert_dim(width, "width")
      _assert_dim(height, "height")
      length = width * height * 4
      b = bytes.unpack("C*")
      raise "bytes must have length #{length}" unless b.length == length

      # Match JS: data[i] = fround(bytes[i] * (1/255)) -- float64 product, then f32.
      data = b.map { |byte| _f32(byte * (1.0 / 255.0)) }
      new(width, height, data)
    end

    def clone
      s = self.class.new(@width, @height, @data.dup)
      s.filter(@filter)
      s.format = @format
      s
    end

    def clear(color = nil)
      color ||= [0.0, 0.0, 0.0, 0.0]
      raise "color must contain four components" unless color.length == 4

      d = @data
      rgba = color.map { |c| self.class._f32(c) }
      i = 0
      while i < d.length
        d[i, 4] = rgba
        i += 4
      end
      self
    end

    def to_rgba8
      out = @data.map do |v|
        x = (v == v && v != Float::INFINITY && v != -Float::INFINITY) ? v : 0.0
        x = 0.0 if x < 0.0
        x = 1.0 if x > 1.0
        (x * 255.0 + 0.5).truncate
      end
      out.pack("C*")
    end
  end
end
