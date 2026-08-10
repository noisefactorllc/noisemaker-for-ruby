# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"

require_relative "../lib/noisemaker_cpu/png"
require_relative "../lib/noisemaker_cpu/renderer"

class TestSimulationEffects < Minitest::Test
  CPU_DIR = ENV["NOISEMAKER_CPU_DIR"] || File.expand_path("../../noisemaker-for-cpu", __dir__)
  CPU_CLI = File.join(CPU_DIR, "bin", "noisemaker-cpu.js")

  def capture_render
    [yield, ""]
  rescue StandardError => e
    [nil, "#{e.class}: #{e.message}"]
  end

  def js_effect(effect_id, params = {})
    Dir.mktmpdir do |tmp|
      output = File.join(tmp, "effect.png")
      command = [
        "node", CPU_CLI, "effect", effect_id,
        "--width", "8", "--height", "8", "--seed", "1", "--time", "0.25",
        "--output", output,
      ]
      params.each { |name, value| command.concat(["--param", "#{name}=#{value}"]) }
      ok = system(*command, chdir: CPU_DIR, out: File::NULL, err: File::NULL)
      raise "JavaScript oracle failed for #{effect_id}" unless ok

      return NoisemakerCpu::PNG.decode_png(File.binread(output))
    end
  end

  def js_dsl(program, width: 8, height: 8)
    Dir.mktmpdir do |tmp|
      output = File.join(tmp, "dsl.png")
      command = [
        "node", CPU_CLI, "render", "-", "--width", width.to_s, "--height", height.to_s,
        "--seed", "1", "--time", "0.25", "--output", output,
      ]
      _stdout, stderr, status = Open3.capture3(*command, stdin_data: program, chdir: CPU_DIR)
      raise "JavaScript DSL oracle failed: #{stderr}" unless status.success?

      return NoisemakerCpu::PNG.decode_png(File.binread(output))
    end
  end

  def test_zero_iterations_bypass_generator_and_filter
    blank, blank_error = capture_render do
      NoisemakerCpu::Renderer.render_effect(
        "synth/cellularAutomata", { "iterationCount" => 0 }, nil,
        width: 8, height: 8, seed: 1, time: 0.25
      )
    end
    assert_equal "", blank_error
    assert_equal Array.new(8 * 8 * 4, 0.0), blank.data

    input = NoisemakerCpu::Renderer.render_effect(
      "synth/solid", { "color" => "#58c" }, nil,
      width: 8, height: 8, seed: 1, time: 0.25
    )
    filtered, filtered_error = capture_render do
      NoisemakerCpu::Renderer.render_effect(
        "filter/motionBlur", { "iterationCount" => 0 }, { "inputTex" => input },
        width: 8, height: 8, seed: 1, time: 0.25
      )
    end
    assert_equal "", filtered_error
    assert_equal input.data, filtered.data
    refute_same input, filtered
  end

  def test_cellular_automata_one_iteration_matches_javascript
    expected = js_effect("synth/cellularAutomata", "iterationCount" => 1)
    actual, message = capture_render do
      NoisemakerCpu::Renderer.render_effect(
        "synth/cellularAutomata", { "iterationCount" => 1 }, nil,
        width: 8, height: 8, seed: 1, time: 0.25
      )
    end
    assert_equal "", message
    assert_equal expected.to_rgba8, actual.to_rgba8
  end

  def test_non_particle_iterated_effects_match_javascript_across_frames
    solid = NoisemakerCpu::Renderer.render_effect(
      "synth/solid", {}, nil, width: 8, height: 8, seed: 1, time: 0.25
    )
    ids = %w[
      filter/convolutionFeedback filter/feedback filter/motionBlur filter/temporalAberration
      synth/mnca synth/navierStokes synth/reactionDiffusion
    ]
    ids.each do |effect_id|
      expected = js_effect(effect_id, "iterationCount" => 4)
      inputs = effect_id.start_with?("filter/") ? { "inputTex" => solid } : nil
      actual, message = capture_render do
        NoisemakerCpu::Renderer.render_effect(
          effect_id, { "iterationCount" => 4 }, inputs,
          width: 8, height: 8, seed: 1, time: 0.25
        )
      end
      assert_equal "", message, effect_id
      assert_equal expected.to_rgba8, actual.to_rgba8, effect_id
    end
  end

  def test_particle_group_matches_javascript_across_frames
    program = <<~DSL
      search synth, points, render
      perlin().pointsEmit(stateSize: 64, iterationCount: 4).dla().pointsRender().write(o0)
      render(o0)
    DSL
    expected = js_dsl(program)
    actual, message = capture_render do
      NoisemakerCpu::Renderer.render_dsl(program, width: 8, height: 8, seed: 1, time: 0.25)
    end
    assert_equal "", message
    assert_equal expected.to_rgba8, actual.to_rgba8
  end

  def test_particle_group_matches_javascript_at_one_iteration
    program = <<~DSL
      search synth, points, render
      perlin().pointsEmit(stateSize: 64, iterationCount: 1).physical().pointsRender().write(o0)
      render(o0)
    DSL
    expected = js_dsl(program)
    actual, message = capture_render do
      NoisemakerCpu::Renderer.render_dsl(program, width: 8, height: 8, seed: 1, time: 0.25)
    end
    assert_equal "", message
    assert_equal expected.to_rgba8, actual.to_rgba8
  end

  def test_each_particle_simulation_group_matches_javascript
    %w[attractor buddhabrot dla flock flow hydraulic lenia life physarum physical].each do |effect|
      program = <<~DSL
        search synth, points, render
        perlin().pointsEmit(stateSize: 64, iterationCount: 1).#{effect}().pointsRender().write(o0)
        render(o0)
      DSL
      expected = js_dsl(program)
      actual, message = capture_render do
        NoisemakerCpu::Renderer.render_dsl(program, width: 8, height: 8, seed: 1, time: 0.25)
      end
      assert_equal "", message, effect
      assert_equal expected.to_rgba8, actual.to_rgba8, effect
    end
  end

  def test_particle_billboard_group_matches_javascript
    program = <<~DSL
      search synth, points, render
      perlin().pointsEmit(stateSize: 64, iterationCount: 1).physical().pointsBillboardRender(shapeMode: 1, pointSize: 4).write(o0)
      render(o0)
    DSL
    expected = js_dsl(program)
    actual, message = capture_render do
      NoisemakerCpu::Renderer.render_dsl(program, width: 8, height: 8, seed: 1, time: 0.25)
    end
    assert_equal "", message
    assert_equal expected.to_rgba8, actual.to_rgba8
  end
end
