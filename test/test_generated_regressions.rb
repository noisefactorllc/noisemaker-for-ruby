# frozen_string_literal: true

require "digest"
require "minitest/autorun"
require_relative "../lib/noisemaker_cpu"

class TestGeneratedRegressions < Minitest::Test
  def test_error_diffusion_dither_matches_pinned_cpu_frame
    result = NoisemakerCpu::Renderer.render_dsl(
      "search synth, filter\n" \
      "noise(seed: 1, ridges: true).dither(type: errorDiffusion).write(o0)\n" \
      "render(o0)",
      width: 8, height: 8, time: 0.25
    )
    assert_equal "0665d7edb18d3e61a4e6731369c881b045145ca6d0a709ccf070319b0a6f8dc7",
                 Digest::SHA256.hexdigest(result.to_rgba8)
  end

  def test_median_radii_match_pinned_cpu_frames
    width = 6
    height = 5
    data = []
    height.times do |y|
      width.times do |x|
        data.concat([
          (((31 * x) + (17 * y) + 7) % 97 + 1).fdiv(101),
          (((13 * x) + (37 * y) + 11) % 89 + 2).fdiv(97),
          (((43 * x) + (5 * y) + 3) % 83 + 3).fdiv(91),
          1
        ])
      end
    end
    input = NoisemakerCpu::Surface.new(width, height, data)
    expected = {
      1 => "c977bad100bc84f0c6d14246860ab5084b4ce23208701cf88c51322c51335bda",
      2 => "a36571e1856f4e964b4f14f3957915dcee87a9381e944f6104df329e6914bcd7",
      3 => "73d5a67ab88331c89b89f6e95fbb4fa63101e340e92e94ecc2e15a12f9f57b69"
    }

    expected.each do |radius, digest|
      result = NoisemakerCpu::Renderer.render_dsl(
        "search filter\nread(o0).median(radius: #{radius}).write(o7)\nrender(o7)",
        width: width, height: height, seed_surfaces: { "o0" => input }
      )
      assert_equal digest, Digest::SHA256.hexdigest(result.to_rgba8), "radius #{radius}"
    end
  end

  def test_median_preserves_negative_packed_channels
    input = NoisemakerCpu::Surface.new(3, 3).clear([-0.5, 0.25, 0.5, 1])
    result = NoisemakerCpu::Renderer.render_effect(
      "filter/median", { "radius" => 3 }, { "inputTex" => input }, width: 3, height: 3
    )
    assert_equal [-0.5, 0.25, 0.5, 1.0], result.data[0, 4]
  end
end
