# frozen_string_literal: true

# Port of the upstream stateful-instance tests added with the cf95f49c pin
# (noisemaker shaders/tests/test_stateful_instances.js): each stateful effect
# instance in a chain keeps its own state and sizes from its own parameters,
# while deliberately shared state keeps its chain scope -- the loop
# accumulator and the mesh buffers. The upstream test asserts the render
# graph's texture IDs and sizes; this port asserts the same programs render
# byte-exact against the pinned authority, which exercises the same
# per-instance resource model end to end.

require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "../scripts/oracle"
require_relative "../lib/noisemaker_cpu/renderer"
require_relative "../lib/noisemaker_cpu/png"

class TestStatefulInstances < Minitest::Test
  include NoisemakerOracle::Tests

  # Each entry is [program, size]. Programs mirror the upstream test's
  # chains; sizes stay small so the suite keeps its bounded wall time.
  CASES = {
    # Two reactionDiffusion instances in one chain: independent state and
    # independent zoom sizes (upstream programs A and B).
    "reaction_diffusion_instances" => [
      "search synth, mixer, filter\nreactionDiffusion(zoom: x4).blendMode(tex: reactionDiffusion(zoom: x16)).write(o0)\nrender(o0)", 32,
    ],
    "reaction_diffusion_instances_after_perlin" => [
      "search synth, mixer, filter\nperlin().blendMode(tex: reactionDiffusion(zoom: x4)).blendMode(tex: reactionDiffusion(zoom: x16)).write(o0)\nrender(o0)", 32,
    ],
    # Two watercolor instances: independent ping-pong state (upstream
    # program C).
    "watercolor_instances" => [
      "search synth, filter\nperlin().watercolor().watercolor().write(o0)\nrender(o0)", 32,
    ],
    # Different stateful effects in one chain each size from their own zoom
    # (upstream's distinct-effects chains).
    "distinct_stateful_effects" => [
      "search synth, mixer, filter\nreactionDiffusion(zoom: x4).blendMode(tex: cellularAutomata(zoom: x16)).write(o0)\nrender(o0)", 32,
    ],
    "distinct_stateful_effects_after_perlin" => [
      "search synth, mixer, filter\nperlin().blendMode(tex: reactionDiffusion(zoom: x4)).blendMode(tex: cellularAutomata(zoom: x16)).write(o0)\nrender(o0)", 32,
    ],
    # Repeated instances keep each explicit or default zoom (upstream's
    # three-instance chain: x4, default, x16).
    "repeated_state_keeps_each_zoom" => [
      "search synth, mixer, filter\nreactionDiffusion(zoom: x4).blendMode(tex: reactionDiffusion()).blendMode(tex: reactionDiffusion(zoom: x16)).write(o0)\nrender(o0)", 32,
    ],
    # loopBegin and loopEnd retain their shared accumulator (upstream's
    # one-loop and two-loop chains).
    "loop_accumulator_shared" => [
      "search synth, filter, render\nperlin().loopBegin(iterationCount: 2).loopEnd().write(o0)\nrender(o0)", 32,
    ],
    "loop_accumulator_shared_twice" => [
      "search synth, filter, render\nperlin().loopBegin(iterationCount: 2).loopEnd().loopBegin(iterationCount: 2).loopEnd().write(o0)\nrender(o0)", 32,
    ],
    # meshLoader and meshRender retain their shared mesh buffers, in one
    # chain and across chains.
    "mesh_buffers_shared" => [
      "search synth, render\nmeshLoader().meshRender().meshRender().write(o0)\nrender(o0)", 32,
    ],
    "mesh_buffers_shared_across_chains" => [
      "search synth, render\nmeshLoader().write(o0)\nread(o0).meshRender().meshRender().write(o1)\nrender(o1)", 32,
    ],
    # Single instances keep their existing behavior: one reactionDiffusion
    # followed by one watercolor renders exactly as before the pin.
    "single_instances_unchanged" => [
      "search synth, filter\nperlin().write(o0)\nreactionDiffusion(zoom: x4).watercolor().write(o1)\nrender(o1)", 32,
    ],
  }.freeze

  CASES.each do |name, (program, size)|
    define_method("test_#{name}_byte_exact") do
      require_oracle
      Dir.mktmpdir("ruby-stateful-instances-") do |dir|
        output = File.join(dir, "cpu.png")
        _, err, status = Open3.capture3("node", NoisemakerOracle::CLI, "render", "-",
          "--width", size.to_s, "--height", size.to_s, "--seed", "1",
          "--time", "0.25", "--output", output, stdin_data: program)
        assert status.success?, err
        expected = NoisemakerCpu::PNG.decode_png(File.binread(output)).to_rgba8
        actual = NoisemakerCpu::Renderer.render_dsl(program, width: size, height: size, seed: 1, time: 0.25).to_rgba8
        different = expected.bytes.zip(actual.bytes).count { |a, b| a != b }
        assert expected == actual, "#{name}: #{different} differing bytes"
      end
    end
  end
end
