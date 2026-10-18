# frozen_string_literal: true

require_relative "metal_reciprocal_data"

module NoisemakerCpu
  # CPU src/csl/metal-division.js: the measured M4 reciprocal and raw product.
  module MetalDivision
    MIN_NORMAL = 1.1754943508222875e-38
    MANTISSAS = 1 << 23

    def self.f32(value)
      [value].pack("e").unpack1("e")
    end

    def self.decode_deviations
      return @deviations if @deviations

      stream = DATA.fetch("bits").gsub(/\s/, "").unpack1("m0")
      deviations = "\0".b * (MANTISSAS >> 3)
      bit = 0
      count = 0
      (1...MANTISSAS).each do |mantissa|
        scaled = 140_737_488_355_328.0 / (8_388_608 + mantissa)
        position = scaled - scaled.floor
        next unless position >= DATA.fetch("bandLow") && position <= DATA.fetch("bandHigh")

        if ((stream.getbyte(bit >> 3) >> (bit & 7)) & 1) != 0
          index = mantissa >> 3
          deviations.setbyte(index, deviations.getbyte(index) | (1 << (mantissa & 7)))
          count += 1
        end
        bit += 1
      end
      unless bit == DATA.fetch("bandBits") && count == DATA.fetch("positiveDeviations") + DATA.fetch("negativeDeviations")
        raise "Metal reciprocal data is corrupt: #{bit} band bits and #{count} deviations"
      end
      @deviations = deviations.freeze
    end

    def self.reciprocal(value)
      word = [value].pack("e").unpack1("V")
      exponent = (word >> 23) & 0xff
      return word >> 31 == 1 ? -Float::INFINITY : Float::INFINITY if exponent.zero?
      return f32(1.0.fdiv(value)) if exponent == 0xff

      magnitude = [word & 0x7fffffff].pack("V").unpack1("e")
      exact = 1.0 / magnitude
      rounded = f32(exact)
      mantissa = word & 0x7fffff
      if mantissa != 0 && ((decode_deviations.getbyte(mantissa >> 3) >> (mantissa & 7)) & 1) != 0
        bits = [rounded].pack("e").unpack1("V") + (rounded < exact ? 1 : -1)
        rounded = [bits].pack("V").unpack1("e")
      end
      rounded = 0.0 if rounded < MIN_NORMAL
      word >> 31 == 1 ? -rounded : rounded
    end

    def self.divide(dividend, divisor)
      rounded = f32(dividend)
      rounded = rounded < 0 ? -0.0 : 0.0 if rounded != 0 && rounded.abs < MIN_NORMAL
      product = rounded * reciprocal(divisor)
      product != 0 && product.abs < MIN_NORMAL ? (product < 0 ? -0.0 : 0.0) : product
    end
  end
end
