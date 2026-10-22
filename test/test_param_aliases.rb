# frozen_string_literal: true

# Mirror of the CPU port's param-alias and inherit-sized base-color coverage
# (noisemaker-for-cpu test/param-aliases.test.js and the inherit-sized tests in
# test/iterated-effects.test.js), adapted to Ruby / minitest. Deprecated
# parameter aliases resolve exactly as upstream's resolveParamAliases: an alias
# present without its canonical name migrates the value; with both present the
# canonical name wins; the alias is always consumed; every alias hit warns.
#
# The catalog checks run against the real committed bundle. The pinned CDN
# bundle (1.0.271) has not published the dla/flow/physarum paramAliases
# records yet, so the real-catalog alias assertions stay out until the bundle
# carries them; the alias machinery itself is covered with the same synthetic
# definitions the compile tests use.

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu/dsl"
require_relative "../lib/noisemaker_cpu/renderer"

D = NoisemakerCpu::DSL

def err_str
  yield
  ""
rescue StandardError => e
  e.message
end

def aliased_effect
  {
    "id" => "points/tracer", "namespace" => "points", "func" => "tracer",
    "kind" => "generator", "domain" => "image",
    "params" => {
      "heightTex" => { "type" => "float", "default" => 2 },
      "seed" => { "type" => "int", "default" => 1 },
    },
    "paramOrder" => ["heightTex", "seed"],
    "paramAliases" => { "fieldTex" => "heightTex" },
    "passes" => [{ "inputs" => {}, "outputs" => { "fragColor" => "outputTex" } }],
  }
end

class TestParamAliases < Minitest::Test
  def args(*pairs)
    pairs.map { |name, value| { "name" => name, "value" => value } }
  end

  def capture_warnings
    out = []
    original = $stderr
    require "stringio"
    $stderr = StringIO.new
    yield
    out.concat($stderr.string.lines.map(&:strip).reject(&:empty?))
    out
  ensure
    $stderr = original
  end

  def test_a_deprecated_alias_migrates_its_value_when_the_canonical_name_is_absent
    params, = D._normalize_effect("points/tracer", aliased_effect, args(["fieldTex", 3]))
    assert_equal 3, params["heightTex"]
    refute params.key?("fieldTex")
  end

  def test_the_canonical_name_wins_when_both_names_are_present
    params, = D._normalize_effect("points/tracer", aliased_effect, args(["fieldTex", 3], ["heightTex", 5]))
    assert_equal 5, params["heightTex"]
    refute params.key?("fieldTex")
  end

  def test_positional_arguments_keep_their_positional_names
    params, = D._normalize_effect("points/tracer", aliased_effect, args([nil, 3]))
    assert_equal 3, params["heightTex"]
  end

  def test_an_unknown_name_still_reports_the_supplied_name
    message = err_str { D._normalize_effect("points/tracer", aliased_effect, args(["bogus", 1])) }
    assert_includes message, 'Unknown parameter "bogus"'
  end

  def test_an_alias_hit_warns_with_the_upstream_deprecation_text
    expected = "param 'fieldTex' is deprecated, use 'heightTex' instead. Aliases will be removed on 2027-06-01."
    warnings = capture_warnings do
      D._normalize_effect("points/tracer", aliased_effect, args(["fieldTex", 3]))
      D._normalize_effect("points/tracer", aliased_effect, args(["fieldTex", 3], ["heightTex", 5]))
    end
    assert_equal [expected, expected], warnings
  end

  def test_a_canonical_argument_does_not_warn
    warnings = capture_warnings do
      D._normalize_effect("points/tracer", aliased_effect, args(["heightTex", 3]))
    end
    assert_empty warnings
  end

  def test_the_dsl_resolves_an_alias_argument
    effects = { "points/tracer" => aliased_effect }
    plan = D.compile_dsl("search points\ntracer(fieldTex: 3).write(o0)\nrender(o0)", effects)
    step = plan["chains"][0]["steps"][0]
    assert_equal 3, step["params"]["heightTex"]
    refute step["params"].key?("fieldTex")
  end

  def test_the_dsl_resolves_the_canonical_name_when_both_names_are_present
    effects = { "points/tracer" => aliased_effect }
    plan = D.compile_dsl("search points\ntracer(fieldTex: 3, heightTex: 5).write(o0)\nrender(o0)", effects)
    step = plan["chains"][0]["steps"][0]
    assert_equal 5, step["params"]["heightTex"]
    refute step["params"].key?("fieldTex")
  end
end

class TestInheritedStateSize < Minitest::Test
  def render
    NoisemakerCpu::Renderer
  end

  def inherit_effect(declare_state_size: false)
    textures = {
      "global_join_base_color" => {
        "width" => { "param" => "stateSize", "inherit" => true },
        "height" => { "param" => "stateSize", "inherit" => true },
        "format" => "rgba32f",
      },
    }
    params = { "iterationCount" => { "type" => "int", "default" => 60 } }
    params["stateSize"] = { "type" => "int", "default" => 4, "uniform" => "stateSize" } if declare_state_size
    {
      "id" => "points/testJoinBaseColor", "namespace" => "points", "func" => "testJoinBaseColor",
      "kind" => "filter", "domain" => "image", "iterated" => true,
      "params" => params,
      "paramOrder" => params.keys,
      "textures" => textures,
      "passes" => [{ "inputs" => {}, "outputs" => { "fragColor" => "outputTex" } }],
    }
  end

  def state_for(eff, owner_state_size)
    render._initialize_iteration_state(
      eff, {}, {}, 1, 2, 2, owner_state_size: owner_state_size
    )
  end

  def test_an_inherit_true_base_color_texture_in_a_joining_step_sizes_from_the_group_owner
    state = state_for(inherit_effect, 8)
    assert_equal 8, state["params"]["stateSize"]
    state = state_for(inherit_effect(declare_state_size: true), 8)
    assert_equal 8, state["params"]["stateSize"]
  end

  def test_an_inherit_true_base_color_texture_without_an_owner_uses_the_shared_fallback_size
    state = state_for(inherit_effect, nil)
    assert_equal 256, state["params"]["stateSize"]
  end

  def test_a_standalone_effect_that_declares_state_size_keeps_its_own_params
    eff = inherit_effect(declare_state_size: true)
    params, = render._normalize_iteration_params(eff, {}, {}, 1)
    assert_equal 4, params["stateSize"]
  end

  def test_a_step_without_inherit_textures_or_state_size_stays_unscoped
    eff = {
      "id" => "points/plain", "namespace" => "points", "func" => "plain",
      "kind" => "filter", "domain" => "image",
      "params" => { "iterationCount" => { "type" => "int", "default" => 60 } },
      "paramOrder" => ["iterationCount"],
      "textures" => { "global_plain_scratch" => { "width" => "100%", "height" => "100%", "format" => "rgba16f" } },
      "passes" => [{ "inputs" => {}, "outputs" => { "fragColor" => "outputTex" } }],
    }
    state = state_for(eff, 8)
    refute state["params"].key?("stateSize")
  end
end
