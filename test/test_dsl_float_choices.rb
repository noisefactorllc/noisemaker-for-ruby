# frozen_string_literal: true

# Port of noisemaker-for-cpu test/dsl-float-choices.test.js (GAP-038), adapted
# to the Ruby API. A float parameter may declare inline choices: the
# `rotation` parameter of the palette filters declares
# { none: 0, fwd: 1, back: -1 }. Upstream's validator resolves a bare
# identifier against the choices, so the DSL forms that the authority accepts
# and unparser writes must reach the renderer as numbers.

require "minitest/autorun"
require "json"
require_relative "../lib/noisemaker_cpu/dsl"
require_relative "../lib/noisemaker_cpu/renderer"
require_relative "../lib/noisemaker_cpu/parameters"

D = NoisemakerCpu::DSL unless defined?(D)
EFFECTS = JSON.parse(
  File.binread(File.expand_path("../lib/noisemaker_cpu/bundle/metadata.json", __dir__))
)["effects"] unless defined?(EFFECTS)

# The effect ids that declare a float param with inline choices.
FLOAT_CHOICE_EFFECTS = EFFECTS.select do |_id, spec|
  (spec["params"] || {}).any? { |_name, param| param.is_a?(Hash) && param["type"] == "float" && param["choices"].is_a?(Hash) }
end.keys.freeze

# A 3D palette filter needs a volume chain; the image palettes run after noise().
def program_prefix(id)
  return "search synth3d, filter3d, render\nnoise3d(seed: 1, volumeSize: x16).#{id.split('/')[1]}" if id.start_with?("filter3d/")

  "search synth, #{id.split('/')[0]}\nnoise(seed: 1).#{id.split('/')[1]}"
end

def program_suffix(id)
  id.start_with?("filter3d/") ? ".render3d().write(o0)\nrender(o0)\n" : ".write(o0)\nrender(o0)\n"
end

def rotation_param(id)
  param = EFFECTS.fetch(id)["params"].find { |_name, spec| spec["type"] == "float" && spec["choices"].is_a?(Hash) }
  [param[0], param[1]]
end

def render_bytes(source)
  NoisemakerCpu::Renderer.render_dsl(source, width: 8, height: 8, time: 0.25, seed: 1).to_rgba8
end

def err_str
  yield
  ""
rescue StandardError => e
  e.message
end

class TestDslFloatChoices < Minitest::Test
  def test_the_catalog_declares_float_choice_params_exactly_as_the_authority
    choices = FLOAT_CHOICE_EFFECTS.map do |id|
      name, spec = rotation_param(id)
      [id, name, spec["choices"]]
    end
    assert_equal [
      ["filter/historicPalette", "rotation", { "none" => 0, "fwd" => 1, "back" => -1 }],
      ["filter/palette", "rotation", { "none" => 0, "fwd" => 1, "back" => -1 }],
      ["filter/tetraColorArray", "rotation", { "none" => 0, "fwd" => 1, "back" => -1 }],
      ["filter/tetraCosine", "rotation", { "none" => 0, "fwd" => 1, "back" => -1 }],
      ["filter3d/palette3d", "rotation", { "none" => 0, "fwd" => 1, "back" => -1 }],
    ], choices
  end

  def test_each_float_choice_name_resolves_to_its_numeric_choice_value
    FLOAT_CHOICE_EFFECTS.each do |id|
      name, spec = rotation_param(id)
      spec["choices"].each do |choice_name, number|
        assert_equal number, NoisemakerCpu::Parameters.coerce(spec, choice_name), "#{id} #{name}: #{choice_name}"
        assert_equal number, NoisemakerCpu::Parameters.coerce(spec, number), "#{id} #{name}: #{number}"
      end
    end
  end

  def test_each_float_choice_name_renders_the_same_rgba_bytes_as_its_number
    # Bounded wall time: this loop is the suite's slowest unit, so it can be
    # executed as concurrent file shards (NOISEMAKER_TEST_FILE_SHARD=i/n).
    # Every effect still runs exactly once across the shards; the default
    # (unset) covers all of them in one invocation.
    ids = FLOAT_CHOICE_EFFECTS
    pairs = ids.flat_map do |id|
      name, spec = rotation_param(id)
      spec["choices"].map { |choice_name, number| [id, name, choice_name, number] }
    end
    if (shard = ENV["NOISEMAKER_TEST_FILE_SHARD"])
      index, total = shard.split("/").map(&:to_i)
      # Round-robin over (effect, choice) pairs instead of slicing the effect
      # list: one 3D palette effect's three heavy choices would otherwise
      # all land in one contiguous shard and gate the whole suite phase.
      pairs = pairs.each_with_index.select { |_p, i| i % total == index }.map(&:first)
    end
    pairs.each do |id, name, choice_name, number|
      by_name = "#{program_prefix(id)}(#{name}: #{choice_name})#{program_suffix(id)}"
      by_number = "#{program_prefix(id)}(#{name}: #{number})#{program_suffix(id)}"
      assert_equal render_bytes(by_number), render_bytes(by_name), "#{id} #{name}: #{choice_name}"
    end
  end

  def test_an_unknown_float_choice_name_still_fails
    thrown = err_str do
      render_bytes("search synth, filter\nnoise(seed: 1).palette(rotation: loop).write(o0)\nrender(o0)\n")
    end
    assert_match(/expected a number or one of: none, fwd, back/, thrown)
  end
end