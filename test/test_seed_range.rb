# frozen_string_literal: true

# Parameter range enforcement, mirroring the pinned oracle's
# src/effects/definition.js: after coercion, every numeric parameter outside
# its declared min/max is rejected with `Parameter "<name>" must be at
# least/at most <bound>`. The bundled metadata declares seed maximums
# (255/100/1000), so the CLI's unseeded draw stays inside the selected
# effect's declared range, and an explicitly out-of-range seed fails with a
# clean diagnostic instead of rendering.
#
# The split the reference keeps (runtime/renderer.js): the DSL's implicit
# render-seed threading spreads the render seed into step params WITHOUT a
# range check, while explicit DSL assignments are validated -- so the tests
# pin both sides.

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

  def test_explicit_out_of_range_seed_is_rejected_with_the_reference_diagnostic
    [1001, 5000].each do |seed|
      error = assert_raises(NoisemakerCpu::ParameterRangeError, "seed #{seed}") do
        render("synth/curl", {}, seed: seed)
      end
      assert_equal 'Parameter "seed" must be at most 1000', error.message
    end
    error = assert_raises(NoisemakerCpu::ParameterRangeError) do
      render("synth/curl", {}, seed: -1)
    end
    assert_equal 'Parameter "seed" must be at least 0', error.message
  end

  def test_boundary_seed_still_renders_and_float_bounds_print_without_the_fraction
    assert_equal 3 * 2 * 4, render("synth/curl", {}, seed: 1000).bytesize
    error = assert_raises(NoisemakerCpu::ParameterRangeError) do
      render("synth/curl", { scale: 25 }, seed: 1)
    end
    assert_equal 'Parameter "scale" must be at most 20', error.message
  end

  def test_every_declared_seed_range_rejects_one_past_each_bound
    checked = 0
    Renderer.meta["effects"].each_value do |eff|
      spec = eff["params"]["seed"]
      next unless spec.is_a?(Hash)

      max = spec["max"]
      unless max.nil?
        error = assert_raises(NoisemakerCpu::ParameterRangeError,
                              "#{eff['namespace']}/#{eff['func']}") do
          NoisemakerCpu::Parameters.coerce(spec, Integer(max) + 1, "seed")
        end
        assert_equal %(Parameter "seed" must be at most #{NoisemakerCpu::Parameters._bound_text(max)}),
                     error.message
        assert_equal Integer(max), NoisemakerCpu::Parameters.coerce(spec, max, "seed")
        checked += 1
      end
      min = spec["min"]
      next if min.nil?

      error = assert_raises(NoisemakerCpu::ParameterRangeError,
                            "#{eff['namespace']}/#{eff['func']}") do
        NoisemakerCpu::Parameters.coerce(spec, Integer(min) - 1, "seed")
      end
      assert_equal %(Parameter "seed" must be at least #{NoisemakerCpu::Parameters._bound_text(min)}),
                   error.message
    end
    assert_operator checked, :>, 0, "expected at least one declared seed maximum in the bundle"
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

  def test_implicit_dsl_seed_threading_stays_unvalidated_but_explicit_assignments_do_not
    # Implicit threading (runtime/renderer.js spreads the render seed into
    # step params without a range check): seed 5000 renders.
    surface = Renderer.render_dsl(
      "search synth\ncurl().write(o0)\nrender(o0)", width: 4, height: 4, seed: 5000
    )
    assert_equal 4 * 4 * 4, surface.to_rgba8.bytesize
    # Explicit assignment: validated like every direct call argument.
    error = assert_raises(NoisemakerCpu::ParameterRangeError) do
      Renderer.render_dsl("search synth\ncurl(seed: 5000).write(o0)\nrender(o0)", width: 4, height: 4)
    end
    assert_equal 'Parameter "seed" must be at most 1000', error.message
  end

  def test_dsl_iteration_groups_thread_the_implicit_seed_unvalidated
    program = "search synth\ncellularAutomata(iterationCount: 1).write(o0)\nrender(o0)"
    surface = Renderer.render_dsl(program, width: 4, height: 4, seed: 5000)
    assert_equal 4 * 4 * 4, surface.to_rgba8.bytesize
  end

  def test_cli_generate_rejects_an_out_of_range_seed_and_accepts_the_bound
    Dir.mktmpdir("noisemaker-seed-") do |dir|
      out_png = File.join(dir, "out.png")
      rc, _out, err = run_noisemaker_cli([
        "generate", "synth/curl", "--width", "4", "--height", "4",
        "--seed", "5000", "--filename", out_png
      ])
      assert_equal 1, rc
      assert_includes err, 'Parameter "seed" must be at most 1000'
      refute File.exist?(out_png)

      rc, _out, err = run_noisemaker_cli([
        "generate", "synth/curl", "--width", "4", "--height", "4",
        "--seed", "1000", "--filename", out_png
      ])
      assert_equal 0, rc, err
      assert File.exist?(out_png)
    end
  end

  def test_cli_volume_generate_validates_the_threaded_seed_before_rendering
    Dir.mktmpdir("noisemaker-seed-") do |dir|
      out_png = File.join(dir, "out.png")
      rc, _out, err = run_noisemaker_cli([
        "generate", "synth3d/noise3d", "--width", "4", "--height", "4",
        "--seed", "5000", "--filename", out_png
      ])
      assert_equal 1, rc
      assert_includes err, 'Parameter "seed" must be at most 100'
      refute File.exist?(out_png)
    end
  end
end
