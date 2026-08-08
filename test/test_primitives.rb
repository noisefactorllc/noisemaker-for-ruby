# frozen_string_literal: true

# Mirror of t/02-primitives.t (Perl), assertion-for-assertion. Goldens
# generated from the Python port (proven vs the JS oracle), copied verbatim
# from the Perl test. The PNG round-trip / error-path sections depend on
# Math::Fractal::Noisemaker::PNG (lib/noisemaker_cpu/png.rb, Worker D, not
# yet written) -- those are ported as explicit `skip`s per the port contract
# rather than silently dropped. Every other assertion in t/02-primitives.t
# is ported in full below.

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu/surface"
require_relative "../lib/noisemaker_cpu/texture_format"
require_relative "../lib/noisemaker_cpu/sampler"

class TestPrimitives < Minitest::Test
  Surface = NoisemakerCpu::Surface
  TF = NoisemakerCpu::TextureFormat
  Sampler = NoisemakerCpu::Sampler

  def feq(got, want, msg = nil)
    if want.is_a?(Float) && want.nan?
      assert got.nan?, msg
      return
    end
    assert_operator (got - want).abs, :<=, (want.abs * 1e-12) + 1e-12, msg
  end

  def test_float16_truncate
    [
      [0.0, 0.0], [1.0, 1.0], [-1.0, -1.0], [0.1, 0.0999755859375],
      [0.30000001192092896, 0.2998046875], [3.14159, 3.140625],
      [100000.0, 65504.0], [-70000.0, -65504.0],
      [1e-05, 9.953975677490234e-06], [6.1e-05, 6.097555160522461e-05],
      [5.96e-08, 0.0], [1e-10, 0.0], [-0.333333333, -0.333251953125],
    ].each do |input, expected|
      feq TF.float16_truncate(input), expected, "f16_truncate(#{input})"
    end
  end

  def test_surface_to_rgba8_edge_cases
    inf = Float::INFINITY
    nan = Float::NAN
    s = Surface.new(2, 2,
                     [0.0, 0.5, 1.0, 2.0, -1.0, nan, inf, 0.24901961,
                      0.25098039, 0.99803922, 0.001, 0.998, 0.5019608, 0.25, 0.75, 1.0])
    assert_equal [0, 128, 255, 255, 0, 0, 0, 64, 64, 255, 0, 254, 128, 64, 191, 255],
                 s.to_rgba8.unpack("C*"), "to_rgba8 edge cases match python"
  end

  def test_from_rgba8_f32_scaling
    s8 = Surface.from_rgba8(1, 1, [0, 127, 128, 255].pack("C4"))
    [
      [0, 0.0], [127, 0.49803921580314636], [128, 0.501960813999176], [255, 1.0],
    ].each_with_index do |(byte, expected), idx|
      feq s8.data[idx], expected, "from_rgba8 byte #{byte}"
    end
  end

  def test_samplers_on_4x4_arange_surface
    sf = Surface.new(4, 4, (0..63).map { |x| x + 0.0 })
    coords = [[0.3, 0.3], [0.55, 0.7], [0.1, 0.9], [0.42, 0.18], [0.77, 0.63],
              [0.0, 0.0], [1.0, 1.0], [-0.2, 0.5], [0.5, 1.3]]
    nearest = [[20, 21, 22, 23], [40, 41, 42, 43], [48, 49, 50, 51], [4, 5, 6, 7], [44, 45, 46, 47],
               [0, 1, 2, 3], [60, 61, 62, 63], [32, 33, 34, 35], [56, 57, 58, 59]]
    nearest_bl = [[36, 37, 38, 39], [24, 25, 26, 27], [0, 1, 2, 3], [52, 53, 54, 55], [28, 29, 30, 31],
                  [48, 49, 50, 51], [12, 13, 14, 15], [16, 17, 18, 19], [8, 9, 10, 11]]
    bilinear = [[39.599998474121094, 40.599998474121094, 41.599998474121094, 42.599998474121094],
                [18, 19, 20, 21], [0, 1, 2, 3],
                [49.20000076293945, 50.20000076293945, 51.20000076293945, 52.20000076293945],
                [26, 27, 28, 29], [48, 49, 50, 51], [12, 13, 14, 15], [24, 25, 26, 27], [6, 7, 8, 9]]
    coords.each_with_index do |(u, v), idx|
      assert_equal nearest[idx], Sampler.sample_nearest(sf, u, v), "nearest(#{u},#{v})"
      assert_equal nearest_bl[idx], Sampler.sample_nearest_bottom_left(sf, u, v), "nearest_bl(#{u},#{v})"
      b = Sampler.sample_bilinear(sf, u, v)
      (0..3).each { |c| feq b[c], bilinear[idx][c], "bilinear(#{u},#{v})[#{c}]" }
    end
  end

  def test_quantize_texture_rgba16f_in_place
    q = Surface.new(1, 1, [0.1, 0.30000001192092896, 3.14159, 1.0])
    TF.quantize_texture(q, "rgba16f")
    feq q.data[0], 0.0999755859375, "quantize rgba16f [0]"
    feq q.data[1], 0.2998046875, "quantize rgba16f [1]"
    feq q.data[2], 3.140625, "quantize rgba16f [2]"
  end

  def test_png_round_trip
    skip "needs Math::Fractal::Noisemaker::PNG (lib/noisemaker_cpu/png.rb, worker D)"
  end

  def test_png_error_paths
    skip "needs Math::Fractal::Noisemaker::PNG (lib/noisemaker_cpu/png.rb, worker D)"
  end

  def test_rgba8_quantize_nan_propagates_and_clamps
    nan = Float::NAN
    qn = Surface.new(1, 1, [nan, -0.5, 0.5, 2.0])
    TF.quantize_texture(qn, "rgba8unorm")
    assert qn.data[0].nan?, "rgba8 quantize keeps NaN"
    assert_equal 0.0, qn.data[1], "rgba8 quantize clamps negative to 0"
    feq qn.data[2], 0.501960813999176, "rgba8 quantize rounds 0.5 (f32 of 128/255)"
    assert_equal 1.0, qn.data[3], "rgba8 quantize clamps >1 to 1"
  end
end
