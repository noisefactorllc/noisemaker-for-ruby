# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/noisemaker_cpu/dsl"

class TestDslArgumentBinding < Minitest::Test
  DSL = NoisemakerCpu::DSL
  EFFECTS = JSON.parse(File.binread(File.expand_path("../lib/noisemaker_cpu/bundle/metadata.json", __dir__))).fetch("effects")
  HEADER = "search synth, synth3d, filter, mixer, render"

  def chains(body, effects = EFFECTS, header = HEADER)
    DSL.compile_dsl("#{header}\n#{body}", effects).fetch("chains").map { |chain| chain.fetch("steps") }
  end

  def test_saved_element_ids_stay_on_effect_inline_subchain_and_io_steps
    steps = chains(<<~DSL)
      let n = noise(_id: "base_2", seed: 1)
      n().subchain(id: "block") { .invert(_id: 'flip') }.write(o1, _id: "w")
      read(o1, _id: "r",).blendMode(tex: n(_id: "over")).write(o0)
      read(_id: "again", surface: o1, _skip: true).write(o2)
      noise3d().write3d(vol0, geo0, _id: "w3")
      read3d(vol0, geo0, _id: "r3").render3d().write(o3)
      read3d(_skip: true, _id: "named3", tex3d: vol0, geo: geo0).render3d().write(o4)
      n().write(o5)
    DSL
    assert_equal [%w[base_2 flip w], ["r", nil, nil], ["again", nil], [nil, "w3"], ["r3", nil, nil],
                  ["named3", nil, nil], ["base_2", nil]], steps.map { |chain| chain.map { |step| step["_id"] } }
    assert steps[2][0].fetch("_skip")
    assert steps[5][0].fetch("_skip")
    inline = steps[1][1].fetch("inline_chains").first.fetch("chain").fetch("steps").first
    assert_equal "over", inline.fetch("_id")
    assert_equal({ "seed" => 1 }, inline.fetch("params"))
    assert_equal ["surface", "o1"], chains("noise().blendMode(tex: read(_id: 'r', tex: o1, _skip: true)).write(o0)")[0][1]["surfaces"]["tex"]
  end

  def test_invalid_id_overrides_are_discarded_before_resolving_values
    _, warnings = capture_io do
      ['5', '""', '"9a"', '"a-b"', '"_a"', 'alias', 'unknown()'].each do |value|
        steps = chains("let alias = 'valid'\nlet n = noise(_id: 'base')\nn(_id: #{value}).write(o0, _id: #{value})")
        refute steps.flatten.any? { |step| step.key?("_id") }, value
      end
    end
    assert_empty warnings
  end

  def test_only_literal_boolean_skip_is_metadata
    assert_empty chains("noise(_skip: (false)).write(o0)")[0][0]["params"]
    refute chains("read(_skip: 1, surface: o1).write(o0)")[0][0].key?("_skip")
    assert_raises(DSL::Error) { chains("noise(_skip: 0).write(o0)") }
  end

  def test_only_one_trailing_io_id_is_allowed_after_positional_targets
    ['noise(1, _id: "n").write(o0)', 'noise().write(o0,)', 'noise().write(o0, _id: "x",)',
     'noise().write(surface: o0, _id: "x")', 'noise().write(o0, other: "x")',
     'noise3d().write3d(vol0, geo0, other: "x")', 'read(o0, other: "x").write(o0)'].each do |body|
      assert_raises(DSL::Error, body) { chains(body) }
    end
  end

  def test_trailing_commas_keep_named_positional_array_and_vector_values
    [
      ["synth", "solid(color: [1, 0.25, 0.5, /*end*/],)", "color", [1, 0.25, 0.5]],
      ["synth", "solid([1, 0.25, 0.5,],)", "color", [1, 0.25, 0.5]],
      ["synth", "noise(3,)", "type", 3],
      ["synth", "media(imageSize: vec2(32,24,))", "imageSize", [32, 24]],
      ["classicNoisedeck", "noise(paletteOffset: vec3(0.1,0.2,0.3,))", "paletteOffset", [0.1, 0.2, 0.3]],
      ["synth", "remap(zone0_bounds: vec4(0,0.2,0.5,1,))", "zone0_bounds", [0, 0.2, 0.5, 1]],
    ].each do |namespace, call, name, expected|
      assert_equal expected, chains("#{call}.write(o0)", EFFECTS, "search #{namespace}")[0][0]["params"].fetch(name), call
    end
    ["solid([1,,0])", "solid([,1,0])", "solid([1,0,,])", "noise(,)", "noise(12,,)", "noise(scaleX: ,)"].each do |call|
      assert_match(/Expected DSL value/, assert_raises(DSL::Error) { chains("#{call}.write(o0)") }.message)
    end
  end

  def test_partial_arguments_keep_their_index_and_named_overrides_discard_unused_chains
    [
      ["let red = noise(seed: 7)\nlet alias = red", "alias(3, 4)", {"type" => 3, "octaves" => 4, "seed" => 7}],
      ["let n = noise(3, 4)", "n(seed: 7)", {"type" => 3, "octaves" => 4, "seed" => 7}],
      ["let n = noise(type: 11)", "n(unknown(), 4)", {"type" => 11, "octaves" => 4}],
      ["let n = noise(noise(), 4)", "n(type: 11)", {"type" => 11, "octaves" => 4}],
      ["let n = noise(seed: 7)\nlet tuned = n(3, 4)", "tuned(type: 11)", {"type" => 11, "octaves" => 4, "seed" => 7}],
    ].each do |binding, call, expected|
      step = chains("#{binding}\n#{call}.write(o0)")[0][0]
      assert_equal expected, step.fetch("params"), call
      refute step.key?("inline_chains"), call
    end
  end

  def test_excess_positional_values_warn_and_never_compile_an_inline_chain
    _, warnings = capture_io do
      ["solid(#f00, 1, unknown())", "let red = solid(#f00)\nred(1, noise())"].each do |call|
        step = chains("#{call}.write(o0)")[0][0]
        assert_equal({ "color" => [1, 0, 0], "alpha" => 1 }, step.fetch("params"))
        refute step.key?("inline_chains")
      end
    end
    assert_equal ["Too many positional arguments for solid(): 'solid' takes 2\n"] * 2, warnings.lines
  end

  def test_hex_colors_capture_at_declaration_and_expand_only_into_available_rgb_slots
    names = %w[r g b a x]
    probe = {"kind" => "filter", "paramOrder" => names, "params" => names.to_h { |n| [n, {"type" => "float", "default" => 1}] }}
    effects = EFFECTS.merge("filter/rgbprobe" => probe)
    error = assert_raises(DSL::Error) { chains("noise().rgbprobe([1, 0, 0]).write(o0)", effects) }
    assert_match(/Parameter "r" must be a finite number/, error.message)
    [
      ["let base = #f00\nlet color = base\nlet base = #0f0", "rgbprobe(color, 0.5, 0.6, 0.7)", {"r" => 1, "g" => 0, "b" => 0, "a" => 0.7}],
      ["let color = #f00\nlet t = rgbprobe(color)\nlet color = #0f0", "t(_skip: false)", {"r" => 1, "g" => 0, "b" => 0}],
      ["let t = rgbprobe(#f00)\nlet u = t(g: 0.25)", "u(_id: 'u')", {"r" => 1, "g" => 0.25, "b" => 0}],
      ["let t = rgbprobe(r: 0.25)\nlet u = t(#f00, 0.6)", "u(_id: 'u')", {"r" => 0.25, "g" => 0.6}],
      ["let t = rgbprobe(_id: 't')", "t(#f00)", {"r" => 1, "g" => 0, "b" => 0}],
    ].each do |binding, call, expected|
      assert_equal expected, chains("#{binding}\nnoise().#{call}.write(o0)", effects)[0][1].fetch("params"), call
    end
    [["noise().rgbprobe(base)", {"r" => 1, "g" => 0, "b" => 0}], ["solid(color: base)", {"color" => [1, 0, 0]}]].each do |expr, expected|
      mix = chains("let base = #f00\nlet t = blendMode(tex: #{expr})\nlet base = #0f0\nnoise().t().write(o0)", effects)[0][1]
      assert_equal expected, mix.fetch("inline_chains").first.fetch("chain").fetch("steps").last.fetch("params")
    end
  end
end
