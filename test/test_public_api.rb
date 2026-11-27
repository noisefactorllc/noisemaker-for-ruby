# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu"

class TestPublicApi < Minitest::Test
  Renderer = NoisemakerCpu::Renderer

  def render(effect, params)
    Renderer.render_effect(effect, params, nil, width: 3, height: 2).to_rgba8
  end

  def test_symbol_keys_and_enum_names_match_strings
    expected = render("synth/noise", "type" => "sine", "seed" => 7)
    assert_equal expected, render("synth/noise", type: :sine, seed: 7)
    refute_equal expected, render("synth/noise", {})
    assert_equal render("synth/osc2d", "oscType" => 4), render("synth/osc2d", oscType: "oscType.square")
  end

  def test_false_boolean_spellings_match_false
    expected = render("synth/curl", ridges: false)
    [0, "0", "false", "off", "no"].each do |value|
      assert_equal expected, render("synth/curl", "ridges" => value), value.inspect
    end
    refute_equal expected, render("synth/curl", ridges: true)
  end

  def test_invalid_parameters_identify_the_effect_and_parameter
    [{ typo: 1 }, { octaves: "two" }, { octaves: 1.5 }, { scale: "big" },
     { scale: false }, { scale: Float::INFINITY }, { scale: "1e100" }, { ridges: "maybe" },
     { outputMode: "typo" }, { outputMode: 99 }].each do |params|
      error = assert_raises(ArgumentError, params.inspect) { render("synth/curl", params) }
      assert_includes error.message, "synth/curl"
      assert_includes error.message, params.keys.first.to_s
    end
    [{ color: "#xyz" }, { color: [1, 2] }, { color: [1, Float::NAN, 0] }].each do |params|
      assert_raises(ArgumentError) { render("synth/solid", params) }
    end
  end

  def test_validation_applies_to_dsl_and_iterated_effects
    assert_raises(ArgumentError) do
      Renderer.render_dsl('search synth; curl(ridges: "maybe").write(o0)', width: 2, height: 2)
    end
    assert_raises(ArgumentError) { render("render/pointsEmit", typo: 1) }
  end

  def test_roll_starts_with_its_own_cleared_feedback
    options = { width: 16, height: 8, seed: 1, time: 0.25 }
    reference = Renderer.render_effect("synth/roll", {}, {}, **options)
    supplied = NoisemakerCpu::Surface.new(16, 8).clear([0.875, 0.5, 0.25, 1])
    result = Renderer.render_effect("synth/roll", {}, { "_rollFb" => supplied }, **options)
    assert_equal reference.to_rgba8, result.to_rgba8
    assert_equal [0.875, 0.5, 0.25, 1], supplied.data.first(4)
  end

  def test_generated_overlays_keep_their_own_textures
    base = NoisemakerCpu::Surface.new(9, 5).clear([0.125, 0.25, 0.5, 1])
    supplied = NoisemakerCpu::Surface.new(9, 5).clear([1, 1, 1, 1])
    %w[filter/fibers filter/scratches filter/strayHair].each do |id|
      render = ->(inputs) { Renderer.render_effect(id, {}, inputs, width: 9, height: 5).to_rgba8 }
      assert_equal render.call(inputTex: base), render.call(inputTex: base, overlayTex: supplied), id
    end
  end

  def test_standalone_filters_sample_regular_inputs_with_nearest_filtering
    gradient = 6.times.flat_map { |i| [i / 5.0, (5 - i) / 5.0, 0, 1] }
    input = NoisemakerCpu::Surface.new(3, 2, gradient)
    input.filter("linear")
    height_grid = Renderer.render_effect("points/heightGrid", {}, { inputTex: input }, width: 5, height: 3)
    assert_equal [0, 1, 0, 1], height_grid.data[4, 4]
    warp = Renderer.render_effect("filter/warp", {}, { inputTex: input }, width: 5, height: 3)
    assert_equal 0, warp.data[0]
    assert_equal "linear", input.filter
  end

  def test_standalone_iterated_effects_keep_the_input_surfaces_sampler_mode
    gradient = 6.times.flat_map { |i| [i / 5.0, (5 - i) / 5.0, 0, 1] }
    input = NoisemakerCpu::Surface.new(3, 2, gradient)
    input.filter("linear")
    result = Renderer.render_effect("filter/motionBlur", { iterationCount: 1 }, { inputTex: input }, width: 5, height: 3)
    assert_equal [0.0479736328125, 0.5517578125, 0, 0.599609375], result.data[4, 4]
    assert_equal "linear", input.filter
  end

  def test_volume_size_accepts_either_key_spelling_before_inheriting_the_atlas_dimensions
    atlas = NoisemakerCpu::Surface.new(2, 4)
    render_volume = ->(params) {
      Renderer.render_effect("filter3d/palette3d", params, { inputTex3d: atlas }, width: 2, height: 2).fetch("volume")
    }
    expected = render_volume.call("volumeSize" => 2)
    actual = render_volume.call(volumeSize: 2)
    assert_equal [2, 4], [actual.width, actual.height]
    assert_equal expected.data, actual.data
    error = assert_raises(ArgumentError) { render_volume.call("volumeSize" => 2, volumeSize: 2) }
    assert_match(/duplicate parameter "volumeSize"/, error.message)
  end

  def test_surface_defaults_and_explicit_unbinding
    bytes = (0...12).flat_map { |i| [i * 21, 255 - i * 21, i * 13, 255] }.pack("C*")
    input = NoisemakerCpu::Surface.from_rgba8(4, 3, bytes)
    render = ->(inputs) { Renderer.render_effect("filter/lighting", {}, inputs, width: 4, height: 3).to_rgba8 }
    expected = render.call("inputTex" => input, "heightMap" => input)
    assert_equal expected, render.call("inputTex" => input)
    unbound = render.call("inputTex" => input, "heightMap" => nil)
    refute_equal expected, unbound
    ["", "heightMap: none"].each do |argument|
      program = "search filter\nread(o0).lighting(#{argument}).write(o1)\nrender(o1)"
      actual = Renderer.render_dsl(program, width: 4, height: 3, seed_surfaces: { "o0" => input })
      assert_equal argument.empty? ? expected : unbound, actual.to_rgba8
    end
  end
end
