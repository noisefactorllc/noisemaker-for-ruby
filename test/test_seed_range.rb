# frozen_string_literal: true

# The CLI's unseeded seed draw, and the parameter contract it must not break.
#
# README, Library section: metadata slider ranges are hints, not clamps --
# explicit values beyond a declared slider maximum render, seeds included.
# Only the AUTOMATIC draw is bounded: the bundled metadata declares seed
# maximums (255/100/1000), an out-of-range seed renders the degenerate
# all-white output for a large share of the old unbounded draw
# (1 to 2**32-1), and the automatic draw has no reason to leave the declared
# range. The draw falls back to the old range when the effect declares no
# seed maximum.

require "minitest/autorun"
require "tmpdir"
require "open3"
require "rbconfig"
require_relative "../lib/noisemaker_cpu"
require_relative "../lib/noisemaker_cpu/cli"

class TestSeedRange < Minitest::Test
  Renderer = NoisemakerCpu::Renderer
  # Subprocess CLI runner (same shape as test_cli.rb's helper, with its own
  # name so the two files never fight over one top-level method).
  def run_noisemaker_cli(args)
    stdout_str, stderr_str, status = Open3.capture3(
      RbConfig.ruby, File.expand_path("../exe/noisemaker-rb", __dir__), *args.map(&:to_s)
    )
    [status.exitstatus, stdout_str, stderr_str]
  end

  def render(effect, params, seed: 1)
    Renderer.render_effect(effect, params, nil, width: 3, height: 2, seed: seed).to_rgba8
  end

  def test_unseeded_draw_stays_inside_the_declared_range
    fallback = NoisemakerCpu::CLI::MAX_SEED_VALUE
    drawn = 0
    Renderer.meta["effects"].keys.sort.each do |effect_id|
      spec = Renderer.meta["effects"][effect_id]["params"]["seed"]
      low, high =
        if spec.is_a?(Hash) && !spec["max"].nil?
          [(spec["min"].nil? ? 1 : Integer(spec["min"])), Integer(spec["max"])]
        else
          [1, fallback]
        end
      8.times do
        seed = NoisemakerCpu::CLI._draw_seed(effect_id)
        assert_kind_of Integer, seed
        assert_includes low..high, seed, effect_id
        drawn += 1
      end
    end
    assert_operator drawn, :>, 100, "expected to draw for most of the catalog"
  end

  def test_slider_ranges_stay_hints_not_clamps
    # The published contract (README, Library section): explicit values
    # beyond a declared slider maximum render, seeds included.
    assert_equal 3 * 2 * 4, render("synth/curl", { scale: 25 }, seed: 1).bytesize
    filtered = Renderer.render_effect("filter/adjust", { contrast: 5 }, { "inputTex" => NoisemakerCpu::Surface.new(3, 2) },
                                      width: 3, height: 2)
    assert_equal 3 * 2 * 4, filtered.to_rgba8.bytesize
    assert_equal 3 * 2 * 4, render("synth/curl", {}, seed: 5000).bytesize
  end

  def test_unseeded_cli_generate_renders_with_the_bounded_draw
    Dir.mktmpdir("noisemaker-seed-") do |dir|
      out_png = File.join(dir, "out.png")
      rc, _out, err = run_noisemaker_cli([
        "generate", "synth/curl", "--width", "4", "--height", "4", "--filename", out_png
      ])
      assert_equal 0, rc, err
      assert File.exist?(out_png)
    end
  end
end
