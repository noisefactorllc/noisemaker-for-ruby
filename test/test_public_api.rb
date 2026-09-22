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
