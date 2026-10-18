# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "../scripts/oracle"
require_relative "../lib/noisemaker_cpu/renderer"
require_relative "../lib/noisemaker_cpu/png"

class TestCpuSyncParity < Minitest::Test
  include NoisemakerOracle::Tests

  CASES = {
    "perlin_3d_seed13" => ["search synth\nperlin(seed: 13, dimensions: 3).write(o0)\nrender(o0)", 41, 23, 13, 0.25],
    "reaction_seed13" => ["search synth3d, render\nreactionDiffusion3d(seed: 13, volumeSize: x16, iterationCount: 1).render3d().write(o0)\nrender(o0)", 8, 8, 13, 0.75],
    "automata_seed7" => ["search synth3d, render\ncellularAutomata3d(seed: 7, volumeSize: x16, iterationCount: 1).render3d().write(o0)\nrender(o0)", 8, 8, 7, 0.75],
    "noise_volume_seed13" => ["search synth3d, render\nnoise3d(seed: 13, volumeSize: x16).render3d().write(o0)\nrender(o0)", 7, 5, 13, 0.75],
    "cell_volume_seed4" => ["search synth3d, render\ncell3d(seed: 4, volumeSize: x16).render3d().write(o0)\nrender(o0)", 7, 5, 4, 0.75],
    "scatter_odd_size" => ["search synth, filter\nperlin(seed: 7).scatter().write(o0)\nrender(o0)", 41, 23, 7, 0.75],
    "extrude_odd_size" => ["search synth, filter\nperlin(seed: 7).extrude().write(o0)\nrender(o0)", 41, 23, 7, 0.75],
    "spooky_odd_size" => ["search synth, filter\nperlin(seed: 7).spookyTicker().write(o0)\nrender(o0)", 41, 23, 7, 0.75],
  }.freeze

  CASES.each do |name, (program, width, height, seed, time)|
    define_method("test_#{name}_byte_exact") do
      require_oracle
      Dir.mktmpdir("ruby-cpu-sync-") do |dir|
        output = File.join(dir, "cpu.png")
        _, err, status = Open3.capture3("node", NoisemakerOracle::CLI, "render", "-",
          "--width", width.to_s, "--height", height.to_s, "--seed", seed.to_s,
          "--time", time.to_s, "--output", output, stdin_data: program)
        assert status.success?, err
        expected = NoisemakerCpu::PNG.decode_png(File.binread(output)).to_rgba8
        actual = NoisemakerCpu::Renderer.render_dsl(program, width: width, height: height, seed: seed, time: time)
        actual_bytes = actual.to_rgba8
        different = expected.bytes.zip(actual_bytes.bytes).count { |a, b| a != b }
        assert expected == actual_bytes, "#{name}: #{different} differing bytes"
      end
    end
  end
end
