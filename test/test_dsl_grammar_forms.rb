# frozen_string_literal: true

# Port of noisemaker-for-cpu test/dsl-grammar-forms.test.js (GAP-047), adapted
# to the Ruby API. Five grammar forms that the pinned authority documents in
# docs/shaders/language.rst: Math.PI, triple-quoted strings, a `let` alias of
# an effect function, the built-in volume I/O calls write3d(vol, geo) and
# read3d(vol, geo), and the namespace helper from(namespace, call()).

require "minitest/autorun"
require "json"
require_relative "../lib/noisemaker_cpu/dsl"
require_relative "../lib/noisemaker_cpu/renderer"
require_relative "../lib/noisemaker_cpu/surface"

D = NoisemakerCpu::DSL unless defined?(D)
EFFECTS = JSON.parse(
  File.binread(File.expand_path("../lib/noisemaker_cpu/bundle/metadata.json", __dir__))
)["effects"] unless defined?(EFFECTS)

SIZE = 8

def text_texture
  surface = NoisemakerCpu::Surface.new(SIZE, SIZE)
  surface.data.length.times do |index|
    pixel = index / 4
    surface.data[index, 4] = [(pixel % SIZE).fdiv(SIZE), (pixel / SIZE).fdiv(SIZE), 0.5, 1.0]
  end
  surface
end

def render_bytes(source)
  NoisemakerCpu::Renderer.render_dsl(
    source, width: SIZE, height: SIZE, time: 0.25, seed: 1,
            external_textures: { "textTex" => text_texture }
  ).to_rgba8
end

def step_params(source, id)
  plan = D.compile_dsl(source, EFFECTS)
  plan["chains"].flat_map { |chain| chain["steps"] }
                .find { |step| step["effect_id"] == id }["params"]
end

def err_str
  yield
  ""
rescue StandardError => e
  e.message
end

# Each pair is [the authority form, its plain equivalent].
GRAMMAR_PAIRS = {
  "Math.PI" => [
    ["search synth\nnoise(seed: 1, scaleX: Math.PI * 4).write(o0)\nrender(o0)\n",
     "search synth\nnoise(seed: 1, scaleX: 12.566370614359172).write(o0)\nrender(o0)\n"],
    ["search synth\nlet tau = Math.PI * 2\nnoise(seed: 1, scaleX: tau).write(o0)\nrender(o0)\n",
     "search synth\nnoise(seed: 1, scaleX: 6.283185307179586).write(o0)\nrender(o0)\n"],
    ["search synth\nnoise(seed: 1, scaleX: (Math.PI + 1) / 2 - -Math.PI).write(o0)\nrender(o0)\n",
     "search synth\nnoise(seed: 1, scaleX: #{(Math::PI + 1) / 2 - -Math::PI}).write(o0)\nrender(o0)\n"],
  ],
  "triple-quoted strings" => [
    ["search synth, filter\nsolid(color: #000).text(text: \"\"\"hi\"\"\").write(o0)\nrender(o0)\n",
     "search synth, filter\nsolid(color: #000).text(text: \"hi\").write(o0)\nrender(o0)\n"],
    ["search synth, filter\nsolid(color: #000).text(text: \"\"\"Hello\nWorld\"\"\").write(o0)\nrender(o0)\n",
     "search synth, filter\nsolid(color: #000).text(text: \"Hello\\nWorld\").write(o0)\nrender(o0)\n"],
  ],
  "let alias" => [
    ["search synth\nlet pattern = noise\npattern(seed: 3).write(o0)\nrender(o0)\n",
     "search synth\nnoise(seed: 3).write(o0)\nrender(o0)\n"],
    ["search synth\nlet pattern = noise\npattern(10).write(o0)\nrender(o0)\n",
     "search synth\nnoise(10).write(o0)\nrender(o0)\n"],
    ["search synth\nlet tuned = noise(seed: 3)\nlet again = tuned\nagain(scaleX: 20).write(o0)\nrender(o0)\n",
     "search synth\nnoise(seed: 3, scaleX: 20).write(o0)\nrender(o0)\n"],
    ["search synth, filter\nlet fx = invert\nnoise(seed: 1).fx().write(o0)\nrender(o0)\n",
     "search synth, filter\nnoise(seed: 1).invert().write(o0)\nrender(o0)\n"],
  ],
  "write3d and read3d" => [
    ["search synth3d, render\nnoise3d(seed: 1, volumeSize: 8).write3d(vol0, geo0)\nread3d(vol0, geo0).render3d().write(o0)\nrender(o0)\n",
     "search synth3d, render\nnoise3d(seed: 1, volumeSize: 8).render3d().write(o0)\nrender(o0)\n"],
    ["search synth3d, render\nnoise3d(seed: 1, volumeSize: 8).write3d(vol1, geo1).render3d().write(o0)\nrender(o0)\n",
     "search synth3d, render\nnoise3d(seed: 1, volumeSize: 8).render3d().write(o0)\nrender(o0)\n"],
    ["search synth3d, render\nnoise3d(seed: 1, volumeSize: 8).write3d(vol0, geo0)\nread3d(tex3d: vol0, geo: geo0).render3d().write(o0)\nrender(o0)\n",
     "search synth3d, render\nnoise3d(seed: 1, volumeSize: 8).render3d().write(o0)\nrender(o0)\n"],
  ],
  "from" => [
    ["search synth, filter\nfrom(classicNoisedeck, noise(seed: 3)).write(o0)\nrender(o0)\n",
     "search classicNoisedeck\nnoise(seed: 3).write(o0)\nrender(o0)\n"],
    ["search synth\nnoise(seed: 1).from(filter, invert()).write(o0)\nrender(o0)\n",
     "search synth, filter\nnoise(seed: 1).invert().write(o0)\nrender(o0)\n"],
    ["search synth, mixer\nnoise(seed: 1).blendMode(tex: from(synth, solid(color: #ff0000)), mode: screen).write(o0)\nrender(o0)\n",
     "search synth, mixer\nsolid(color: #ff0000).write(o1)\nnoise(seed: 1).blendMode(tex: read(o1), mode: screen).write(o0)\nrender(o0)\n"],
    ["search synth, filter\nlet n = from(classicNoisedeck, noise(seed: 3))\nn().write(o0)\nrender(o0)\n",
     "search classicNoisedeck\nnoise(seed: 3).write(o0)\nrender(o0)\n"],
  ],
}.freeze

# A one-argument read3d(vol) names a volume (or geometry) for a parameter.
READ3D_VALUE_FORM = [
  "search synth3d, render\ncellularAutomata3d(source: read3d(vol1), geoSource: read3d(geo1), volumeSize: x16).render3d().write(o0)\nrender(o0)\n",
  "search synth3d, render\ncellularAutomata3d(source: vol1, geoSource: geo1, volumeSize: x16).render3d().write(o0)\nrender(o0)\n",
].freeze

# Each rejected program also fails on the pinned authority. A from() call that
# the authority rejects stays a call named `from`, an unknown effect.
GRAMMAR_REJECTED = [
  # Math.E is not a constant of the grammar; the port's float coercion rejects
  # it at render time, as it rejects any non-numeric value.
  ["search synth\nnoise(seed: 1, scaleX: Math.E).write(o0)\nrender(o0)\n", /parameter "scaleX"/],
  ["search synth\nnoise(seed: 1, scaleX: Math.PI()).write(o0)\nrender(o0)\n", /Expected "\)"/],
  ["search synth, filter\nsolid(color: #000).text(text: \"\"\"open\n", /Unterminated string/],
  # Upstream's validator reports S003 for a bare identifier value that names
  # nothing resolvable at declaration (no earlier binding, no effect).
  ["search synth\nlet pattern = wobble\npattern().write(o0)\nrender(o0)\n", /Variable used before assignment: 'wobble'/],
  # An alias used as a value stays the effect's bare name, which is not a
  # number; the port's float coercion rejects it at render time.
  ["search synth\nlet pattern = noise\nnoise(seed: 1, scaleX: pattern).write(o0)\nrender(o0)\n", /parameter "scaleX"/],
  ["search synth3d, render\nnoise3d(seed: 1, volumeSize: x16).write3d(vol0)\nrender(o0)\n", /Expected ","/],
  ["search synth3d, render\nnoise3d(seed: 1, volumeSize: x16).write3d(tex3d: vol0, geo: geo0)\nrender(o0)\n", /Expected ","/],
  ["search synth3d, render\nnoise3d(seed: 1, volumeSize: x16).write3d(5, geo0)\nrender(o0)\n", /Expected surface reference/],
  ["search synth3d, render\nnoise3d(seed: 1, volumeSize: x16).write3d(vol0, geo0)\nnoise3d(seed: 2).read3d(vol0, geo0).render3d().write(o0)\nrender(o0)\n", /Unknown effect "read3d" in search namespaces synth3d, render/],
  ["search synth3d, render\nwrite3d(vol0, geo0)\nrender(o0)\n", /Expected effect or IO function name/],
  ["search synth3d, render\nnoise3d(seed: 1, volumeSize: x16).write3d(vol0, geo0)\nread3d(vol0).render3d().write(o0)\nrender(o0)\n", /Unknown effect "read3d"/],
  ["search synth, filter\nfrom(ns: classicNoisedeck, call: noise(seed: 3)).write(o0)\nrender(o0)\n", /Unknown effect "from" in search namespaces synth, filter/],
  ["search synth, filter\nfrom(classicNoisedeck).write(o0)\nrender(o0)\n", /Unknown effect "from" in search namespaces synth, filter/],
  ["search synth, filter\nfrom(\"classicNoisedeck\", noise(seed: 3)).write(o0)\nrender(o0)\n", /Unknown effect "from" in search namespaces synth, filter/],
  ["search synth, filter\nfrom(classicNoisedeck, noise).write(o0)\nrender(o0)\n", /Unknown effect "from" in search namespaces synth, filter/],
  ["search synth, filter\nfrom(classicNoisedeck, noise(seed: 3).invert()).write(o0)\nrender(o0)\n", /Unknown effect "from" in search namespaces synth, filter/],
  ["search synth, filter\nfrom(filter, noise(seed: 3)).write(o0)\nrender(o0)\n", /Unknown effect "noise" in search namespaces filter/],
].freeze

class TestDslGrammarForms < Minitest::Test
  def test_each_authority_form_renders_the_same_rgba_bytes_as_its_plain_equivalent
    GRAMMAR_PAIRS.each_value do |pairs|
      pairs.each do |authority, plain|
        assert_equal render_bytes(plain), render_bytes(authority), authority
      end
    end
  end

  def test_math_pi_evaluates_to_the_same_number_the_authority_parser_folds
    assert_equal Math::PI * 4, step_params(GRAMMAR_PAIRS["Math.PI"][0][0], "synth/noise")["scaleX"]
    assert_equal((Math::PI + 1) / 2 - -Math::PI, step_params(GRAMMAR_PAIRS["Math.PI"][2][0], "synth/noise")["scaleX"])
  end

  def test_write3d_and_read3d_store_and_restore_the_volume_and_geometry_surfaces
    plan = D.compile_dsl(GRAMMAR_PAIRS["write3d and read3d"][0][0], EFFECTS)
    assert_equal [["synth3d/noise3d", "write3d"], ["read3d", "render/render3d", "write"]],
                 plan["chains"].map { |chain| chain["steps"].map { |step| step["effect_id"] || step["kind"] } }
    assert_equal %w[vol0 geo0],
                 [plan["chains"][0]["steps"][1]["volume"], plan["chains"][0]["steps"][1]["geometry"]]
    value_form = step_params(READ3D_VALUE_FORM[0], "synth3d/cellularAutomata3d")
    plain = step_params(READ3D_VALUE_FORM[1], "synth3d/cellularAutomata3d")
    assert_equal %w[vol1 geo1], [value_form["source"], value_form["geoSource"]]
    assert_equal plain, value_form
  end

  def test_a_triple_quoted_string_keeps_its_raw_content_newlines_and_quotes_included
    text = lambda do |literal|
      step_params(
        "search synth, filter\nsolid(color: #000).text(text: #{literal}).write(o0)\nrender(o0)\n", "filter/text"
      )["text"]
    end
    assert_equal "hi", text.call('"""hi"""')
    assert_equal "Hello\nWorld", text.call("\"\"\"Hello\nWorld\"\"\"")
    assert_equal 'say "hi" now', text.call("\"\"\"say \"hi\" now\"\"\"")
    assert_equal "", text.call('""""""')
    # Upstream's lexer keeps a triple-quoted string's content raw.
    assert_equal "a\\tb", text.call('"""a\\tb"""')
    # A string whose content is punctuation is a string, in the first position too.
    assert_equal ")", step_params(
      "search synth, filter\nsolid(color: #000).text(\")\").write(o0)\nrender(o0)\n", "filter/text"
    )["text"]
    assert_equal ")", step_params(
      "search synth, filter\nsolid(color: #000).text(\"\"\")\"\"\").write(o0)\nrender(o0)\n", "filter/text"
    )["text"]
  end

  def test_forms_that_the_authority_rejects_still_fail
    GRAMMAR_REJECTED.each do |source, error|
      # The port's parser and compiler reject most forms at compile time; the
      # two value-form rejections surface through the renderer's float
      # coercion, so every one is exercised through render_dsl.
      thrown = err_str { render_bytes(source) }
      refute_equal "", thrown, source
      assert_match error, thrown, source
    end
  end
end