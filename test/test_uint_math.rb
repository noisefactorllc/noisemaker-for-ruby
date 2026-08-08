# frozen_string_literal: true

# Mirror of t/01-uintmath.t (Perl), assertion-for-assertion. Golden vectors
# generated from the Python port (itself proven bit-exact against the JS
# oracle across 167 effects) -- copied verbatim from the Perl test.

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu/uint_math"

UM = NoisemakerCpu::UintMath

class TestUintMath < Minitest::Test
  def test_umul
    [
      [4294967295, 374761393, 3920205903],
      [1664525, 1013904223, 182531539],
      [2654435761, 97, 4077198353],
      [123456789, 987654321, 4227814277],
      [2147483648, 3, 2147483648],
      [4294967295, 4294967295, 1],
    ].each do |a, b, expected|
      assert_equal expected, UM.umul(a, b), "umul(#{a},#{b})"
    end
  end

  def test_uadd
    [
      [4294967295, 1, 0],
      [2147483647, 2147483647, 4294967294],
      [7, 9, 16],
    ].each do |a, b, expected|
      assert_equal expected, UM.uadd(a, b), "uadd"
    end
  end

  def test_usub
    [
      [0, 1, 4294967295],
      [5, 10, 4294967291],
      [4294967295, 4294967294, 1],
    ].each do |a, b, expected|
      assert_equal expected, UM.usub(a, b), "usub"
    end
  end

  def test_ushl
    [
      [1, 31, 2147483648],
      [4294967295, 4, 4294967280],
      [3, 33, 6],
    ].each do |a, b, expected|
      assert_equal expected, UM.ushl(a, b), "ushl (shift count masked)"
    end
  end

  def test_ushr
    [
      [2147483648, 31, 1],
      [4294967295, 16, 65535],
      [7, 33, 3],
    ].each do |a, b, expected|
      assert_equal expected, UM.ushr(a, b), "ushr (shift count masked)"
    end
  end

  def test_pcg3d
    [
      [[0, 0, 0], [2611992518, 2833812075, 1058359340]],
      [[1, 2, 3], [4204755366, 1223881804, 1500469937]],
      [[4294967295, 12345, 67890], [4093664991, 2632112527, 615798276]],
      [[2147483648, 4000000000, 999999999], [1605979321, 1388827049, 3948892479]],
    ].each do |input, expected|
      assert_equal expected, UM.pcg3d(input), "pcg3d(#{input.join(' ')})"
    end
  end

  def test_hash_uint32
    [
      [0, 0],
      [1, 1753845952],
      [42, 388445122],
      [4294967295, 1734902346],
      [2654435761, 1834104592],
    ].each do |input, expected|
      assert_equal expected, UM.hash_uint32(input), "hash_uint32(#{input})"
    end
  end

  def test_float_bits_to_uint
    [
      [0.0, 0],
      [1.0, 1065353216],
      [-1.0, 3212836864],
      [0.5, 1056964608],
      [3.14159, 1078530000],
      [1e-40, 71362],
    ].each do |input, expected|
      assert_equal expected, UM.float_bits_to_uint(input), "float_bits_to_uint(#{input})"
    end
  end

  def test_bits_round_trip
    [0, 1065353216, 3212836864, 1078530000].each do |bits|
      assert_equal bits, UM.float_bits_to_uint(UM.uint_bits_to_float(bits)), "bits round trip #{bits}"
    end
  end

  def test_pack_half_2x16
    [
      [[0.0, 0.0], 0],
      [[1.0, -1.0], 3154131968],
      [[0.5, 65504.0], 2080323584],
      [[1e-08, -2.5], 3238002688],
      [[70000.0, 0.1], 778468352],
    ].each do |input, expected|
      assert_equal expected, UM.pack_half_2x16(input), "pack_half_2x16"
    end
  end

  def test_unpack_half_2x16_inverse
    # unpack inverse (on exactly-representable halves)
    pair = UM.unpack_half_2x16(UM.pack_half_2x16([1.0, -2.5]))
    assert_operator (pair[0] - 1.0).abs, :<, 1e-7, "unpack half lo"
    assert_operator (pair[1] + 2.5).abs, :<, 1e-7, "unpack half hi"
  end

  def test_u32_coercion
    # u32 coercion of floats / negatives / huge values (JS ToUint32 semantics)
    [
      [-1, 4294967295],
      [-2.7, 4294967294],
      [3.9, 3],
      [1e+20, 1661992960],
      [-1e+20, 2632974336],
    ].each do |input, expected|
      assert_equal expected, UM.u32(input), "u32(#{input})"
    end
    nan = UM.fdiv(0, 0)
    assert_equal 0, UM.u32(nan), "u32(NaN) == 0"
    assert_equal 0, UM.u32(Float::INFINITY), "u32(Inf) == 0"
  end

  def test_glsl_mod
    # glsl_mod: floored modulo + IEEE zero-divide propagation
    assert_equal 1.5, UM.glsl_mod(5.5, 2.0), "glsl_mod positive"
    assert_equal 2.0, UM.glsl_mod(-1.0, 3.0), "glsl_mod floored (not truncated)"
    gm = UM.glsl_mod(1.0, 0.0)
    assert gm.nan?, "glsl_mod(x, 0) is NaN"
  end

  def test_fdiv
    # fdiv IEEE semantics
    assert_equal Float::INFINITY, UM.fdiv(1, 0), "fdiv 1/0 = +Inf"
    assert_equal(-Float::INFINITY, UM.fdiv(-1, 0), "fdiv -1/0 = -Inf")
    assert UM.fdiv(0, 0).nan?, "fdiv 0/0 = NaN"
  end
end
