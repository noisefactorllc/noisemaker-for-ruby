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
    # Pinned oracle frames regenerated at the bfbe54764eee authority pin via
    # scripts/oracle.mjs-equivalent (CpuRenderer.render with the exact seed
    # surface); r3 is unchanged from the previous pin.
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

  def test_dither_palette_arrays_render_nearest_colors_without_crashing
    # Mirror of noisemaker-for-cpu 5de2bf8's renderer.test.js: the dither
    # kernel's builtin palette globals are vecN rows, so the pre-5de2bf8
    # rt.copy (a flat scalar-buffer copy) raised TypeError on every palette
    # > PALETTE_INPUT; the fixed copy retains the vecN rows and each solid
    # input maps to the nearest builtin palette color.
    endpoints = [
      [[1.0, 1.0, 1.0], [0.0, 0.0, 0.0]],                    # MONOCHROME
      [[0.61, 0.74, 0.06], [0.06, 0.22, 0.06]],              # DOT_MATRIX
      [[1.0, 0.6, 0.0], [0.0, 0.0, 0.0]],                    # AMBER
      [[1.0, 0.945, 0.91], [0.0, 0.0, 0.0]],                 # PICO8
    ] + Array.new(5) { [[1.0, 1.0, 1.0], [0.0, 0.0, 0.0]] }  # C64..EGA
    (1..9).each do |palette|
      [1, 0, 1, 0].each do |color|
        frame = NoisemakerCpu::Renderer.render_dsl(
          "search synth, filter\n" \
          "solid(color: [#{color}, #{color}, #{color}]).dither(palette: #{palette}, threshold: #{color.zero? ? -0.5 : 0.5}).write(o0)\n" \
          "render(o0)",
          width: 3, height: 2
        )
        endpoint = endpoints[palette - 1][color.zero? ? 1 : 0]
        expected = endpoint.map { |v| ([v.to_f].pack("e").unpack1("e") * 255).round } + [255]
        assert_equal Array.new(6, expected).flatten, frame.to_rgba8.bytes,
                     "palette #{palette}, color #{color}"
      end
    end
  end
end
