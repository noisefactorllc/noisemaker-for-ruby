# frozen_string_literal: true

# Mirror of t/06-dsl.t (Perl), assertion-for-assertion, adapted to Ruby /
# minitest. Port of the pure tokenizer/parser/compiler tests in
# noisemaker-python tests/test_dsl.py (rendering-oracle tests excluded),
# plus a few render_dsl integration checks. Compile tests run against the
# real bundle metadata, exactly as the Perl/Python tests do.
#
# dsl.rb itself has zero cross-worker dependencies (DSL.pm doesn't require
# Renderer/bundle metadata at compile time -- effects/metadata are always
# handed in by the caller), so tokenizer/parser tests and the
# bundle-independent error paths always run. Tests that need the REAL
# effect catalog (compiler param/kind checks) or a full render (Worker C's
# renderer.rb + Worker E's generated bundle) are skip-guarded on the bundle
# actually being present on disk.

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu/dsl"

D = NoisemakerCpu::DSL

BUNDLE_METADATA_PATH = File.expand_path("../lib/noisemaker_cpu/bundle/metadata.json", __dir__)
BUNDLE_AVAILABLE = File.exist?(BUNDLE_METADATA_PATH)
RENDERER_PATH = File.expand_path("../lib/noisemaker_cpu/renderer.rb", __dir__)
RENDER_DSL_AVAILABLE = BUNDLE_AVAILABLE && File.exist?(RENDERER_PATH)

EFFECTS =
  if BUNDLE_AVAILABLE
    require "json"
    JSON.parse(File.read(BUNDLE_METADATA_PATH))["effects"]
  end

require_relative "../lib/noisemaker_cpu/renderer" if RENDER_DSL_AVAILABLE

# Run the block, returning '' on success or the raised error's message.
def err_str
  yield
  ""
rescue StandardError => e
  e.message
end

class TestDsl < Minitest::Test
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

  # --- compiler: resolution + surface split ----------------------------------

  def test_compile_effect_id_resolved_through_search
    skip "needs real bundle metadata (lib/noisemaker_cpu/bundle/metadata.json)" unless BUNDLE_AVAILABLE

    plan = D.compile_dsl("search synth, mixer\nnoise().cellSplit(tex: o1).write(o0)\nrender(o0)", EFFECTS)
    step = plan["chains"][0]["steps"][1]
    assert_equal "mixer/cellSplit", step["effect_id"]
    assert_equal ["surface", "o1"], step["surfaces"]["tex"]
  end

  def test_compile_render_surface_defaults_to_last_write
    skip "needs real bundle metadata (lib/noisemaker_cpu/bundle/metadata.json)" unless BUNDLE_AVAILABLE

    plan = D.compile_dsl("search synth\nsolid().write(o3)", EFFECTS)
    assert_equal "o3", plan["render_surface"]
  end

  # --- error paths -------------------------------------------------------------

  def test_error_missing_search_directive
    err = assert_raises(D::Error) { D.compile_dsl("solid().write(o0)\nrender(o0)", {}) }
    assert_match(/\A<dsl>:\d+:\d+: Missing required search directive\n\z/, err.message)
  end

  def test_error_unknown_effect
    skip "needs real bundle metadata (lib/noisemaker_cpu/bundle/metadata.json)" unless BUNDLE_AVAILABLE

    msg = err_str { D.compile_dsl("search synth\nwat().write(o0)\nrender(o0)", EFFECTS) }
    assert_match(/Unknown effect "wat" in search namespaces synth/, msg)
  end

  def test_error_unknown_parameter_lists_accepted_params_in_param_order
    skip "needs real bundle metadata (lib/noisemaker_cpu/bundle/metadata.json)" unless BUNDLE_AVAILABLE

    msg = err_str { D.compile_dsl("search synth\nnoise(bogus: 1).write(o0)\nrender(o0)", EFFECTS) }
    assert_match(
      /Unknown parameter "bogus" for synth\/noise; accepted: type, octaves, scaleX, scaleY, seed, wrap, ridges, loopOffset, loopScale, speed, colorMode/, # rubocop:disable Layout/LineLength
      msg
    )
  end

  def test_error_generator_chain_must_end_with_write
    skip "needs real bundle metadata (lib/noisemaker_cpu/bundle/metadata.json)" unless BUNDLE_AVAILABLE

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

  # --- render_dsl integration --------------------------------------------------

  def test_render_solid_exact_color_bytes
    skip "needs Renderer + a built bundle (worker C/E)" unless RENDER_DSL_AVAILABLE

    surface = NoisemakerCpu::Renderer.render_dsl(
      "search synth\nsolid(color: #336699).write(o0)\nrender(o0)", width: 4, height: 4
    )
    bytes = surface.to_rgba8.unpack("C*")
    assert_equal [0x33, 0x66, 0x99, 0xFF], bytes[0, 4]
  end

  def test_render_generator_filter_chain_dimensions
    skip "needs Renderer + a built bundle (worker C/E)" unless RENDER_DSL_AVAILABLE

    surface = NoisemakerCpu::Renderer.render_dsl(
      "search synth, filter\nnoise(seed: 3, scaleX: 8, scaleY: 8).vignette().write(o0)\nrender(o0)",
      width: 8, height: 8, seed: 3
    )
    assert_equal 8, surface.width
    assert_equal 8, surface.height
  end

  def test_render_read_of_unwritten_surface_dies
    skip "needs Renderer + a built bundle (worker C/E)" unless RENDER_DSL_AVAILABLE

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
    skip "needs real bundle metadata (lib/noisemaker_cpu/bundle/metadata.json)" unless BUNDLE_AVAILABLE

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

    skip "needs Renderer + a built bundle (worker C/E)" unless RENDER_DSL_AVAILABLE

    surface = NoisemakerCpu::Renderer.render_dsl(program, width: 8, height: 8, seed: 1)
    assert_equal 8, surface.width
  end

  # arithmetic + vector/array values (python: test_arithmetic_and_array_values_render)
  def test_arithmetic_and_array_values_render
    skip "needs real bundle metadata (lib/noisemaker_cpu/bundle/metadata.json)" unless BUNDLE_AVAILABLE

    plan = D.compile_dsl("search synth\nnoise(scaleX: 4 * 2, scaleY: 16 / 2, seed: 3).write(o0)\nrender(o0)", EFFECTS)
    step = plan["chains"][0]["steps"][0]
    assert_equal 8, step["params"]["scaleX"]
    assert_equal 8, step["params"]["scaleY"]

    skip "needs Renderer + a built bundle (worker C/E)" unless RENDER_DSL_AVAILABLE

    surface = NoisemakerCpu::Renderer.render_dsl(
      "search synth\nsolid(color: [0.2, 0.4, 0.6]).write(o0)\nrender(o0)", width: 2, height: 2
    )
    px = surface.to_rgba8.unpack("C4")
    assert_equal [51, 102, 153], px[0, 3]
  end
end
