# frozen_string_literal: true

# Port of noisemaker-for-cpu test/dsl-inline-chains.test.js (GAP-046), adapted
# to the Ruby API: the pinned authority grammar allows a chain as an argument
# value (`Expr ::= Chain | ...`). Upstream's validator compiles a chain in a
# surface argument into its own steps ahead of the consuming effect and binds
# the argument to that temporary surface. The port compiles the chain to a
# hidden surface that is written before the consuming effect runs.

require "minitest/autorun"
require "json"
require_relative "../lib/noisemaker_cpu/dsl"
require_relative "../lib/noisemaker_cpu/renderer"

D = NoisemakerCpu::DSL unless defined?(D)
EFFECTS = JSON.parse(
  File.binread(File.expand_path("../lib/noisemaker_cpu/bundle/metadata.json", __dir__))
)["effects"] unless defined?(EFFECTS)

# Each pair is [inline form, the same program with each chain written to an
# unused surface and read back].
INLINE_PAIRS = [
  # A one-call chain.
  [
    "search synth, mixer\nnoise(seed: 1).blendMode(tex: solid(color: #ff0000), mode: screen).write(o0)\nrender(o0)\n",
    "search synth, mixer\nsolid(color: #ff0000).write(o1)\nnoise(seed: 1).blendMode(tex: read(o1), mode: screen).write(o0)\nrender(o0)\n",
  ],
  # A multi-call chain.
  [
    "search synth, filter, mixer\nnoise(seed: 1).blendMode(tex: noise(seed: 2).invert(), mode: screen).write(o0)\nrender(o0)\n",
    "search synth, filter, mixer\nnoise(seed: 2).invert().write(o1)\nnoise(seed: 1).blendMode(tex: read(o1), mode: screen).write(o0)\nrender(o0)\n",
  ],
  # Two inline arguments in one call.
  [
    "search synth, mixer\nnoise(seed: 1).alphaMask(tex: solid(color: #ff0000), baseTex: solid(color: #0000ff, alpha: 0.25)).write(o0)\nrender(o0)\n",
    "search synth, mixer\nsolid(color: #ff0000).write(o1)\nsolid(color: #0000ff, alpha: 0.25).write(o2)\nnoise(seed: 1).alphaMask(tex: read(o1), baseTex: read(o2)).write(o0)\nrender(o0)\n",
  ],
  # Positional arguments.
  [
    "search synth, mixer\nnoise(seed: 1).blendMode(solid(color: #00ff00), screen).write(o0)\nrender(o0)\n",
    "search synth, mixer\nsolid(color: #00ff00).write(o1)\nnoise(seed: 1).blendMode(read(o1), screen).write(o0)\nrender(o0)\n",
  ],
  # A chain inside a chain argument.
  [
    "search synth, filter, mixer\nnoise(seed: 1).blendMode(tex: solid(color: #ff0000).blendMode(tex: noise(seed: 3), mode: multiply), mode: screen).write(o0)\nrender(o0)\n",
    "search synth, filter, mixer\nnoise(seed: 3).write(o2)\nsolid(color: #ff0000).blendMode(tex: read(o2), mode: multiply).write(o1)\nnoise(seed: 1).blendMode(tex: read(o1), mode: screen).write(o0)\nrender(o0)\n",
  ],
  # A partial binding called in a chain argument, and a partial that holds a
  # chain argument. A partial resolves its arguments where it is called.
  [
    "search synth, mixer\nlet red = solid(color: #ff0000)\nnoise(seed: 1).blendMode(tex: red(), mode: screen).write(o0)\nrender(o0)\n",
    "search synth, mixer\nsolid(color: #ff0000).write(o1)\nnoise(seed: 1).blendMode(tex: read(o1), mode: screen).write(o0)\nrender(o0)\n",
  ],
  [
    "search synth, mixer\nlet tint = blendMode(tex: solid(color: #ff0000), mode: screen)\nnoise(seed: 1).tint().write(o0)\nnoise(seed: 2).tint().write(o1)\nrender(o0)\n",
    "search synth, mixer\nsolid(color: #ff0000).write(o2)\nnoise(seed: 1).blendMode(tex: read(o2), mode: screen).write(o0)\nrender(o0)\n",
  ],
  # A partial that holds an automation value.
  [
    "search synth\nlet tuned = noise(seed: 1, scaleX: osc(type: oscKind.sine, min: 0.25, max: 0.75, speed: 0))\ntuned().write(o0)\nrender(o0)\n",
    "search synth\nnoise(seed: 1, scaleX: 25.75).write(o0)\nrender(o0)\n",
  ],
  # Chain arguments of a volume generator.
  [
    "search synth, filter, synth3d, render\nheightmap3d(heightTex: solid(color: #00ff00).invert(), tex: solid(color: #ff0000), volumeSize: x16).renderLandscape3d().write(o0)\nrender(o0)\n",
    "search synth, filter, synth3d, render\nsolid(color: #00ff00).invert().write(o1)\nsolid(color: #ff0000).write(o2)\nheightmap3d(heightTex: read(o1), tex: read(o2), volumeSize: x16).renderLandscape3d().write(o0)\nrender(o0)\n",
  ],
].freeze

# The grammar also lets a chain argument start from read() or hold a subchain
# block. The pinned validator cannot compile these two forms: its substitute()
# reads `args` of every chain element, and a Read or Subchain node has none, so
# compile() throws a TypeError. The port compiles them by the grammar.
INLINE_GRAMMAR_PAIRS = [
  # A chain that starts from read(), after a mid-chain write in the same statement.
  [
    "search synth, filter, mixer\nnoise(seed: 1).write(o1).blendMode(tex: read(o1).invert(), mode: screen).write(o0)\nrender(o0)\n",
    "search synth, filter, mixer\nnoise(seed: 1).write(o1)\nread(o1).invert().write(o2)\nread(o1).blendMode(tex: read(o2), mode: screen).write(o0)\nrender(o0)\n",
  ],
  # A subchain block inside a chain argument.
  [
    "search synth, filter, mixer\nnoise(seed: 1).blendMode(tex: noise(seed: 2).subchain(name: \"x\") { .invert() }, mode: screen).write(o0)\nrender(o0)\n",
    "search synth, filter, mixer\nnoise(seed: 2).invert().write(o1)\nnoise(seed: 1).blendMode(tex: read(o1), mode: screen).write(o0)\nrender(o0)\n",
  ],
].freeze

# Each rejected program also fails on the pinned authority; the port reports
# each one with an existing message template.
INLINE_REJECTED = [
  # write() is only allowed in statement context. The port reports it with the
  # existing message for a name that cannot be a chain element.
  ["search synth, mixer\nnoise(seed: 1).blendMode(tex: solid(color: #ff0000).write(o1), mode: screen).write(o0)\nrender(o0)\n", /Expected effect or IO function name/],
  # A chain argument must start with a generator or read().
  ["search filter, mixer, synth\nnoise(seed: 1).blendMode(tex: invert(), mode: screen).write(o0)\nrender(o0)\n", /filter\/invert requires an input/],
  # An effect that the search order does not resolve.
  ["search synth, mixer\nnoise(seed: 1).blendMode(tex: wobble(), mode: screen).write(o0)\nrender(o0)\n", /Unknown effect "wobble"/],
].freeze

def render_bytes(source)
  NoisemakerCpu::Renderer.render_dsl(source, width: 8, height: 8, time: 0.25, seed: 1).to_rgba8
end

def err_str
  yield
  ""
rescue StandardError => e
  e.message
end

class TestDslInlineChains < Minitest::Test
  def test_all_authority_style_chain_argument_programs_compile
    # The compile path of every pair and grammar pair, including the automation
    # partial, must succeed.
    (INLINE_PAIRS + INLINE_GRAMMAR_PAIRS).each do |inline, _flat|
      plan = D.compile_dsl(inline, EFFECTS)
      assert plan["chains"][0]["steps"].any? { |step| step["effect_id"] }, inline
    end
  end

  def test_a_chain_argument_renders_the_same_rgba_bytes_as_the_chain_written_to_an_unused_surface_and_read_back
    (INLINE_PAIRS + INLINE_GRAMMAR_PAIRS).each do |inline, flat|
      assert_equal render_bytes(flat), render_bytes(inline), inline
    end
  end

  def test_a_partial_holding_a_chain_argument_compiles_it_where_it_is_called
    plan = D.compile_dsl(INLINE_PAIRS[6][0], EFFECTS)
    inline = plan["chains"][0]["steps"].flat_map { |step| step["inline_chains"] || [] }
    assert_equal 1, inline.length
    assert_equal "inline:0", inline[0]["surface"]
    assert_equal ["synth/solid"], inline[0]["chain"]["steps"].map { |step| step["effect_id"] }
  end

  def test_a_chain_argument_that_the_authority_rejects_still_fails
    INLINE_REJECTED.each do |source, error|
      thrown = err_str { D.compile_dsl(source, EFFECTS) }
      refute_equal "", thrown, source
      assert_match error, thrown, source
    end
  end
end