# frozen_string_literal: true

# Mirror of t/06-dsl.t (Perl), assertion-for-assertion, adapted to Ruby /
# minitest. Port of the pure tokenizer/parser/compiler tests in
# noisemaker-python tests/test_dsl.py (rendering-oracle tests excluded),
# plus a few render_dsl integration checks. Compile tests run against the
# real bundle metadata, exactly as the Perl/Python tests do.
#
# dsl.rb itself has zero engine dependencies (DSL.pm doesn't require
# Renderer/bundle metadata at compile time -- effects/metadata are always
# handed in by the caller). Compile and render tests run against the real
# committed bundle via Renderer, exactly as the Perl/Python tests do.

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu/dsl"

D = NoisemakerCpu::DSL

require "json"
require_relative "../lib/noisemaker_cpu/renderer"

EFFECTS = JSON.parse(
  File.read(File.expand_path("../lib/noisemaker_cpu/bundle/metadata.json", __dir__))
)["effects"]

# Run the block, returning '' on success or the raised error's message.
def err_str
  yield
  ""
rescue StandardError => e
  e.message
end

class TestDsl < Minitest::Test
  def typed_effects
    {
      "synth3d/volumeSeed" => {
        "id" => "synth3d/volumeSeed", "kind" => "generator", "domain" => "volume-generator",
        "params" => {}, "paramOrder" => [], "passes" => [{ "inputs" => {} }],
      },
      "synth3d/volumeState" => {
        "id" => "synth3d/volumeState", "kind" => "generator", "domain" => "volume-generator",
        "iterated" => true,
        "params" => { "iterationCount" => { "type" => "int", "default" => 1 } },
        "paramOrder" => ["iterationCount"], "passes" => [{ "inputs" => { "seedTex" => "source" } }],
      },
      "synth3d/otherSeed" => {
        "id" => "synth3d/otherSeed", "kind" => "generator", "domain" => "volume-generator",
        "params" => {}, "paramOrder" => [], "passes" => [{ "inputs" => {} }],
      },
      "filter3d/volumeFilter" => {
        "id" => "filter3d/volumeFilter", "kind" => "filter", "domain" => "volume-filter",
        "params" => {}, "paramOrder" => [], "passes" => [{ "inputs" => { "volume" => "inputTex3d" } }],
      },
      "render/volumeRender" => {
        "id" => "render/volumeRender", "kind" => "filter", "domain" => "volume-renderer",
        "params" => {}, "paramOrder" => [], "passes" => [{ "inputs" => { "volume" => "inputTex3d" } }],
      },
      "render/loopBegin" => {
        "id" => "render/loopBegin", "kind" => "filter", "domain" => "loop-begin", "loopRole" => "begin",
        "params" => {}, "paramOrder" => [], "passes" => [{ "inputs" => { "input" => "inputTex" } }],
      },
      "render/loopEnd" => {
        "id" => "render/loopEnd", "kind" => "filter", "domain" => "loop-end", "loopRole" => "end",
        "params" => {}, "paramOrder" => [], "passes" => [{ "inputs" => { "input" => "inputTex" } }],
      },
      "synth/solid" => {
        "id" => "synth/solid", "kind" => "generator", "domain" => "image",
        "params" => {}, "paramOrder" => [], "passes" => [{ "inputs" => {} }],
      },
      "filter/blur" => {
        "id" => "filter/blur", "kind" => "filter", "domain" => "image",
        "params" => {}, "paramOrder" => [], "passes" => [{ "inputs" => { "input" => "inputTex" } }],
      },
    }
  end

  # --- tokenizer: lexeme classification -------------------------------------

  def test_tokenize_keyword_and_surface_classification
    tokens = D.tokenize_dsl("search synth\nnoise(scaleX: 8).write(o0)")
    types = tokens.map { |t| t["type"] }
    assert_includes types, "keyword"
    assert_includes types, "surface"
    assert_equal "eof", tokens[-1]["type"]
  end

  def test_tokenize_color_token
    color = D.tokenize_dsl("#3af")[0]
    assert_equal "color", color["type"]
    assert_equal "#3af", color["lexeme"]
  end

  # --- parser: program shape -------------------------------------------------

  def test_parse_program_shape
    ast = D.parse_dsl("search synth, filter\nsolid(color: #336699).invert().write(o0)\nrender(o0)")
    assert_equal %w[synth filter], ast["search"]
    assert_equal 1, ast["chains"].length
    assert_equal %w[solid invert write], ast["chains"][0]["calls"].map { |c| c["name"] }
    assert_equal "o0", ast["render"]["name"]
  end

  def test_search_accepts_render_keyword_as_namespace
    ast = nil
    message = err_str do
      ast = D.parse_dsl(
        "search synth, points, render\nperlin().pointsEmit().write(o0)\nrender(o0)"
      )
    end
    assert_equal "", message
    assert_equal %w[synth points render], ast["search"]
    assert_equal %w[perlin pointsEmit write], ast["chains"][0]["calls"].map { |call| call["name"] }
    assert_equal "o0", ast["render"]["name"]
  end

  # --- compiler: resolution + surface split ----------------------------------

  def test_compile_effect_id_resolved_through_search

    plan = D.compile_dsl("search synth, mixer\nnoise().cellSplit(tex: o1).write(o0)\nrender(o0)", EFFECTS)
    step = plan["chains"][0]["steps"][1]
    assert_equal "mixer/cellSplit", step["effect_id"]
    assert_equal ["surface", "o1"], step["surfaces"]["tex"]
  end

  def test_compile_render_surface_defaults_to_last_write

    plan = D.compile_dsl("search synth\nsolid().write(o3)", EFFECTS)
    assert_equal "o3", plan["render_surface"]
  end

  # --- error paths -------------------------------------------------------------

  def test_error_missing_search_directive
    err = assert_raises(D::Error) { D.compile_dsl("solid().write(o0)\nrender(o0)", {}) }
    assert_match(/\A<dsl>:\d+:\d+: Missing required search directive\n\z/, err.message)
  end

  def test_error_unknown_effect

    msg = err_str { D.compile_dsl("search synth\nwat().write(o0)\nrender(o0)", EFFECTS) }
    assert_match(/Unknown effect "wat" in search namespaces synth/, msg)
  end

  def test_error_unknown_parameter_lists_accepted_params_in_param_order

    msg = err_str { D.compile_dsl("search synth\nnoise(bogus: 1).write(o0)\nrender(o0)", EFFECTS) }
    assert_match(
      /Unknown parameter "bogus" for synth\/noise; accepted: type, octaves, scaleX, scaleY, seed, wrap, ridges, loopOffset, loopScale, speed, colorMode/, # rubocop:disable Layout/LineLength
      msg
    )
  end

  def test_error_generator_chain_must_end_with_write

    msg = err_str { D.compile_dsl("search synth\nnoise()\nrender(o0)", EFFECTS) }
    assert_match(/Generator chain must end with write/, msg)
  end

  def test_error_cannot_mix_positional_and_named_arguments
    msg = err_str { D.parse_dsl("search synth\nnoise(4, seed: 2).write(o0)") }
    assert_match(/Cannot mix positional and named arguments/, msg)
  end

  def test_error_surface_reference_out_of_range
    msg = err_str { D.parse_dsl("search synth\nnoise().write(o9)") }
    assert_match(/Surface reference must be o0 through o7/, msg)
  end

  def test_error_malformed_numeric_literal_is_a_dsl_error
    msg = err_str { D.tokenize_dsl("noise(scaleX: 1e)") }
    assert_match(/Invalid numeric literal "1e"/, msg)
  end

  def test_compile_typed_volume_chain
    plan = D.compile_dsl(
      "search synth3d, filter3d, render\n" \
      "volumeSeed().volumeState(iterationCount: 1).volumeFilter().volumeRender().write(o0)\n" \
      "render(o0)",
      typed_effects
    )

    assert_equal %w[
      synth3d/volumeSeed synth3d/volumeState filter3d/volumeFilter render/volumeRender
    ], plan["chains"][0]["steps"].select { |step| step["kind"] == "effect" }.map { |step| step["effect_id"] }
  end

  def test_compile_rejects_invalid_typed_volume_chains
    cases = {
      "search synth, filter3d\nsolid().volumeFilter().write(o0)" =>
        /volume filter filter3d\/volumeFilter requires a volume input/,
      "search synth, render\nsolid().volumeRender().write(o0)" =>
        /volume renderer render\/volumeRender requires a volume input/,
      "search synth3d\nvolumeSeed().write(o0)" => /write\(surface\) requires a current image/,
      "search synth3d\nvolumeSeed().otherSeed().write(o0)" =>
        /Generator synth3d\/otherSeed must begin a chain/,
    }
    cases.each do |source, pattern|
      assert_match pattern, err_str { D.compile_dsl(source, typed_effects) }
    end
  end

  def test_compile_balanced_loop_and_rejects_malformed_markers
    plan = D.compile_dsl(
      "search synth, filter, render\nsolid().loopBegin().blur().loopEnd().write(o0)\nrender(o0)",
      typed_effects
    )
    assert_equal %w[synth/solid render/loopBegin filter/blur render/loopEnd],
                 plan["chains"][0]["steps"].select { |step| step["kind"] == "effect" }.map { |step| step["effect_id"] }

    cases = {
      "search synth, render\nsolid().loopEnd().write(o0)" => /loopEnd has no matching loopBegin/,
      "search synth, render\nsolid().loopBegin().write(o0)" => /loopBegin must be closed by loopEnd before write/,
      "search synth, render\nsolid().loopBegin().loopBegin().loopEnd().loopEnd().write(o0)" =>
        /nested loopBegin regions are not supported/,
    }
    cases.each do |source, pattern|
      assert_match pattern, err_str { D.compile_dsl(source, typed_effects) }
    end
  end

  # --- render_dsl integration --------------------------------------------------

  def test_render_solid_exact_color_bytes

    surface = NoisemakerCpu::Renderer.render_dsl(
      "search synth\nsolid(color: #336699).write(o0)\nrender(o0)", width: 4, height: 4
    )
    bytes = surface.to_rgba8.unpack("C*")
    assert_equal [0x33, 0x66, 0x99, 0xFF], bytes[0, 4]
  end

  def test_render_generator_filter_chain_dimensions

    surface = NoisemakerCpu::Renderer.render_dsl(
      "search synth, filter\nnoise(seed: 3, scaleX: 8, scaleY: 8).vignette().write(o0)\nrender(o0)",
      width: 8, height: 8, seed: 3
    )
    assert_equal 8, surface.width
    assert_equal 8, surface.height
  end

  def test_render_read_of_unwritten_surface_dies

    msg = err_str do
      NoisemakerCpu::Renderer.render_dsl(
        "search synth, filter\nread(o5).invert().write(o0)\nrender(o0)", width: 4, height: 4
      )
    end
    assert_match(/Surface o5 has not been written/, msg)
  end

  # let value + partial bindings merge into a chain call
  # (python: test_render_let_value_and_partial_bindings)
  def test_let_value_and_partial_bindings_merge_into_a_chain_call

    program = "search synth, filter\n" \
              "let amt = 3\n" \
              "let base = noise(scaleX: 7, scaleY: 7)\n" \
              "base(seed: 11).posterize(levels: amt).write(o0)\n" \
              "render(o0)\n"
    plan = D.compile_dsl(program, EFFECTS)
    step = plan["chains"][0]["steps"][0]
    assert_equal "synth/noise", step["effect_id"]
    assert_equal 11, step["params"]["seed"]
    assert_equal 7, step["params"]["scaleX"]
    post = plan["chains"][0]["steps"][1]
    assert_equal 3, post["params"]["levels"]


    surface = NoisemakerCpu::Renderer.render_dsl(program, width: 8, height: 8, seed: 1)
    assert_equal 8, surface.width
  end

  # arithmetic + vector/array values (python: test_arithmetic_and_array_values_render)
  def test_arithmetic_and_array_values_render

    plan = D.compile_dsl("search synth\nnoise(scaleX: 4 * 2, scaleY: 16 / 2, seed: 3).write(o0)\nrender(o0)", EFFECTS)
    step = plan["chains"][0]["steps"][0]
    assert_equal 8, step["params"]["scaleX"]
    assert_equal 8, step["params"]["scaleY"]


    surface = NoisemakerCpu::Renderer.render_dsl(
      "search synth\nsolid(color: [0.2, 0.4, 0.6]).write(o0)\nrender(o0)", width: 2, height: 2
    )
    px = surface.to_rgba8.unpack("C4")
    assert_equal [51, 102, 153], px[0, 3]
  end
end
