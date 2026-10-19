# frozen_string_literal: true

# Port of noisemaker-for-cpu test/dsl-subchain.test.js (GAP-045), adapted to
# the Ruby API: the pinned authority grammar has
#   SubchainCall ::= 'subchain' '(' ArgList? ')' '{' ( '.' Call )+ '}'
# as a chain element. A subchain groups effects and passes its output to the
# next chain element; upstream's validator emits pass-through begin and end
# markers around the body, so a subchain renders as its flattened chain.

require "minitest/autorun"
require "json"
require_relative "../lib/noisemaker_cpu/dsl"
require_relative "../lib/noisemaker_cpu/renderer"

D = NoisemakerCpu::DSL unless defined?(D)
EFFECTS = JSON.parse(
  File.binread(File.expand_path("../lib/noisemaker_cpu/bundle/metadata.json", __dir__))
)["effects"] unless defined?(EFFECTS)

FLAT = "search synth, filter\nnoise(seed: 1).invert().posterize(levels: 4).write(o0)\nrender(o0)\n"

# Each accepted program renders the same bytes as FLAT.
ACCEPTED = [
  "search synth, filter\nnoise(seed: 1).subchain(name: \"look\") { .invert() .posterize(levels: 4) }.write(o0)\nrender(o0)\n",
  "search synth, filter\nnoise(seed: 1).subchain(\"look\") { .invert() .posterize(levels: 4) }.write(o0)\nrender(o0)\n",
  "search synth, filter\nnoise(seed: 1).subchain(id: \"sc1\") { .invert() .posterize(levels: 4) }.write(o0)\nrender(o0)\n",
  "search synth, filter\nnoise(seed: 1).subchain(name: \"look\", id: \"sc1\") { .invert() .posterize(levels: 4) }.write(o0)\nrender(o0)\n",
  "search synth, filter\nnoise(seed: 1).subchain() { .invert() .posterize(levels: 4) }.write(o0)\nrender(o0)\n",
  # Two blocks in one chain, and a block between ordinary elements.
  "search synth, filter\nnoise(seed: 1).subchain(name: \"a\") { .invert() }.subchain(name: \"b\") { .posterize(levels: 4) }.write(o0)\nrender(o0)\n",
  "search synth, filter\nnoise(seed: 1).invert().subchain() { .posterize(levels: 4) }.write(o0)\nrender(o0)\n",
  # The text that the pinned authority unparser writes for the first program.
  "search synth, filter\n\nnoise()\n  .subchain(name: \"look\") {\n    .invert()\n    .posterize(levels: 4)\n  }\n  .write(o0)\n\nrender(o0)",
  # Comments between body elements.
  "search synth, filter\nnoise(seed: 1)\n  .subchain(name: \"look\") {\n    // grade\n    .invert()\n    /* steps */ .posterize(levels: 4)\n  }\n  .write(o0)\nrender(o0)\n",
  # Upstream reports these subchain arguments as warnings (P008, P009, P010) and
  # accepts the program: an unknown key, a duplicate key, a missing comma and a
  # trailing comma.
  "search synth, filter\nnoise(seed: 1).subchain(name: \"look\", color: \"red\") { .invert() .posterize(levels: 4) }.write(o0)\nrender(o0)\n",
  "search synth, filter\nnoise(seed: 1).subchain(name: \"a\", name: \"b\") { .invert() .posterize(levels: 4) }.write(o0)\nrender(o0)\n",
  "search synth, filter\nnoise(seed: 1).subchain(name: \"a\" id: \"b\") { .invert() .posterize(levels: 4) }.write(o0)\nrender(o0)\n",
  "search synth, filter\nnoise(seed: 1).subchain(name: \"a\",) { .invert() .posterize(levels: 4) }.write(o0)\nrender(o0)\n",
].freeze

# Each rejected program fails on the pinned authority and on the port. The port
# reports each one with an existing message template.
SUBCHAIN_REJECTED = [
  # An empty block.
  ["search synth, filter\nnoise(seed: 1).subchain(name: \"x\") { }.write(o0)\nrender(o0)\n", /Expected "\."/],
  # A block at the start of a chain.
  ["search synth, filter\nsubchain(name: \"x\") { .invert() }.write(o0)\nrender(o0)\n", /Expected effect or IO function name/],
  # A generator inside a block.
  ["search synth, filter\nnoise(seed: 1).subchain() { .noise() }.write(o0)\nrender(o0)\n", /Generator synth\/noise must begin a chain/],
  # A read() inside a block.
  ["search synth, filter\nnoise(seed: 1).write(o1)\nread(o1).subchain() { .read(o1) }.write(o0)\nrender(o0)\n", /read\(surface\) must begin a chain/],
  # A write() inside a block, and a nested block.
  ["search synth, filter\nnoise(seed: 1).subchain() { .invert().write(o1) }.write(o0)\nrender(o0)\n", /Expected effect or IO function name/],
  ["search synth, filter\nnoise(seed: 1).subchain() { .write(o1) }.write(o0)\nrender(o0)\n", /Expected effect or IO function name/],
  ["search synth, filter\nnoise(seed: 1).subchain() { .subchain() { .invert() } }.write(o0)\nrender(o0)\n", /Expected effect or IO function name/],
  # A body element without its leading dot.
  ["search synth, filter\nnoise(seed: 1).subchain() { invert() }.write(o0)\nrender(o0)\n", /Expected "\."/],
  # Argument forms that upstream's parseSubchainCall rejects.
  ["search synth, filter\nnoise(seed: 1).subchain(name: 5) { .invert() }.write(o0)\nrender(o0)\n", /Expected "\)"/],
  ["search synth, filter\nnoise(seed: 1).subchain(\"look\", id: \"sc1\") { .invert() }.write(o0)\nrender(o0)\n", /Expected "\)"/],
  ["search synth, filter\nnoise(seed: 1).subchain(look) { .invert() }.write(o0)\nrender(o0)\n", /Expected "\)"/],
  ["search synth, filter\nnoise(seed: 1).subchain() .invert().write(o0)\nrender(o0)\n", /Expected "\{"/],
  ["search synth, filter\nnoise(seed: 1).subchain() { .invert()\n", /Expected "\."/],
].freeze

def compile_steps(source)
  D.compile_dsl(source, EFFECTS)["chains"][0]["steps"].map { |step| step["effect_id"] || step["kind"] }
end

def render_bytes(source)
  NoisemakerCpu::Renderer.render_dsl(source, width: 8, height: 8, time: 0.25, seed: 1).to_rgba8
end

class TestDslSubchain < Minitest::Test
  def test_a_subchain_block_compiles_to_the_steps_of_its_flattened_chain
    flat = compile_steps(FLAT)
    assert_equal ["synth/noise", "filter/invert", "filter/posterize", "write"], flat
    ACCEPTED.each do |source|
      assert_equal flat, compile_steps(source), source
    end
  end

  def test_a_program_with_a_subchain_block_renders_the_same_rgba_bytes_as_the_flattened_chain
    expected = render_bytes(FLAT)
    ACCEPTED.each { |source| assert_equal expected, render_bytes(source), source }
  end

  def test_a_loop_begin_end_pair_inside_a_subchain_renders_as_the_flattened_loop
    blocked = "search synth, filter, render\n" \
              "noise(seed: 1).subchain(name: \"feedback loop\", id: \"fb1\") " \
              "{ .loopBegin(iterationCount: 2) .blur() .loopEnd() }.write(o0)\nrender(o0)\n"
    flat = "search synth, filter, render\n" \
           "noise(seed: 1).loopBegin(iterationCount: 2).blur().loopEnd().write(o0)\nrender(o0)\n"
    assert_equal render_bytes(flat), render_bytes(blocked)
  end

  def test_a_subchain_that_the_authority_rejects_still_fails
    SUBCHAIN_REJECTED.each do |source, error|
      thrown = err_str { compile_steps(source) }
      refute_equal "", thrown, source
      assert_match error, thrown, source
    end
  end

  def err_str
    yield
    ""
  rescue StandardError => e
    e.message
  end
end