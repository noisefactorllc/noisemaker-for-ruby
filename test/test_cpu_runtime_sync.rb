# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "digest"
require_relative "../lib/noisemaker_cpu/runtime"
require_relative "../lib/noisemaker_cpu/surface"

class TestCpuRuntimeSync < Minitest::Test
  def from_bits(value)
    [value].pack("V").unpack1("e")
  end

  def bits(value)
    [value].pack("e").unpack1("V")
  end

  def fixture(name)
    JSON.parse(File.binread(File.join(__dir__, "fixtures", "cpu-sync", name)))
  end

  def test_captured_m4_division_pairs
    rt = NoisemakerCpu::Runtime.new
    data = fixture("metal-division-m4.json")
    (data.fetch("runtime") + data.fetch("special")).each do |a, b, expected|
      actual = rt.fdiv(from_bits(a), from_bits(b))
      if from_bits(expected).nan?
        assert actual.nan?
      else
        assert_equal expected, bits(actual), "#{a} / #{b}"
      end
    end
  end

  def test_division_keeps_product_unrounded_for_following_add
    rt = NoisemakerCpu::Runtime.new
    reciprocal = from_bits(bits(1.0 / 41) + 1)
    exact_product = from_bits(1_058_126_561) * reciprocal
    assert_equal exact_product, rt.fdiv(from_bits(1_058_126_561), 41)
    assert_equal [rt.fdiv(1, 41), rt.fdiv(2, 23)], rt.fdiv([1, 2], [41, 23])
    assert_equal [rt.fdiv(1, 41), rt.fdiv(2, 41)], rt.fdiv([1, 2], 41)
  end

  def test_nearest_texel_captured_boundaries
    rt = NoisemakerCpu::Runtime.new
    data = fixture("nearest-texel-m4.json")
    data.fetch("boundaries").each do |width, u, column|
      surface = NoisemakerCpu::Surface.new(width, 1, (0...width).flat_map { |x| [x.to_f, 0.0, 0.0, 1.0] })
      assert_equal column, rt.texture(surface, [from_bits(u), 0.5])[0]
    end
    surface = NoisemakerCpu::Surface.new(41, 3, (0...3).flat_map do |row|
      (0...41).flat_map { |x| [x.to_f, (2 - row).to_f, 0.0, 1.0] }
    end)
    data.fetch("special41x3").each do |u, v, x, y|
      assert_equal [x, y], rt.texture(surface, [from_bits(u), from_bits(v)]).first(2)
    end
  end

  def test_reciprocal_capture_table_hash
    model = NoisemakerCpu::MetalDivision
    deviations = model.decode_deviations
    table = "\0".b * ((1 << 23) >> 2)
    positive = 0
    negative = 0
    (1...(1 << 23)).each do |mantissa|
      next if ((deviations.getbyte(mantissa >> 3) >> (mantissa & 7)) & 1).zero?
      scaled = 140_737_488_355_328.0 / (8_388_608 + mantissa)
      up = scaled - scaled.floor < 0.5
      up ? positive += 1 : negative += 1
      index = mantissa >> 2
      table.setbyte(index, table.getbyte(index) | ((up ? 1 : 2) << ((mantissa & 3) * 2)))
    end
    assert_equal [859_417, 8_757], [positive, negative]
    assert_equal "9e62e57b1413fcfbcf95d9809e463498a30a917fc6c8b351015bffd3e6855a79", Digest::SHA256.hexdigest(table)
  end
end
