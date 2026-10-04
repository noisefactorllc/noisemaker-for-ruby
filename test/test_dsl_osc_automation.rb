# frozen_string_literal: true

# Mirror of test/dsl-osc-automation.test.js (noisemaker-cpu), assertion-for-
# assertion, adapted to Ruby/minitest: the `osc(...)` automation evaluator is
# asserted against the upstream oracle captured at the pinned revision
# (test/fixtures/osc-automation-golden.json), re-proven live against the
# pinned upstream tree when NM_REFERENCE_ROOT is available, plus DSL-level
# byte-parity, error, depth, and binding tests.

require "minitest/autorun"
require "json"
require "open3"
require "set"
require_relative "../lib/noisemaker_cpu/automation"
require_relative "../lib/noisemaker_cpu/dsl"
require_relative "../lib/noisemaker_cpu/renderer"

# The fixture's expected values were captured from the pinned upstream tree's
# own automation evaluator (Pipeline.prototype.resolveUniformValue) at the
# recorded sourceRevision; the env-gated test below re-proves them against a
# live tree.
FIXTURE = JSON.parse(
  File.binread(File.expand_path("fixtures/osc-automation-golden.json", __dir__))
).freeze

SPECS = [nil, { "min" => 0, "max" => 1 }, { "min" => -2, "max" => 3 },
         { "type" => "int" }, { "type" => "int", "min" => 1, "max" => 5 }].freeze

BUNDLE_EFFECTS = JSON.parse(
  File.binread(File.expand_path("../lib/noisemaker_cpu/bundle/metadata.json", __dir__))
)["effects"].freeze

def err_str
  yield
  ""
rescue StandardError => e
  e.message
end

class TestDslOscAutomation < Minitest::Test
  def resolve(config, time, spec_index)
    NoisemakerCpu::Automation.resolve_automation_uniform(config, time, SPECS[spec_index])
  end

  def render(source, time: 0.0, width: 8, height: 8)
    NoisemakerCpu::Renderer.render_dsl(source, width: width, height: height, seed: 1, time: time)
  end

  # f32 rounding of the double value (what the renderer applies when a
  # resolved value becomes a kernel uniform).
  def f32(x)
    [x].pack("e").unpack1("e")
  end

  def test_osc_automation_evaluation_matches_the_upstream_oracle_captured_at_the_pinned_revision
    refute_empty FIXTURE["cases"]
    FIXTURE["cases"].each do |entry|
      label = "#{entry['label']} t=#{entry['time']} spec=#{entry['specIndex']}"
      spec = SPECS[entry["specIndex"]]
      actual = resolve(entry["config"], entry["time"], entry["specIndex"])
      expected = entry["expected"]
      next if expected == actual

      # The fixture was captured with V8's fdlibm trigonometry; this port
      # evaluates with the platform libm -- the same native-libm choice every
      # f32 kernel in this port makes (where f32 rounding absorbs it). The
      # renderer consumes a resolved value as an f32 uniform, so the binding
      # contract is f32-identical results with the double drift confined to
      # the last bits (measured: <= 4 ulp across all 1960 captured cases).
      # Integer selectors round the resolved value and are held to exact
      # equality: a last-bit drift may never cross a rounding boundary.
      refute spec && spec["type"] == "int", "#{label}: integer selector must match exactly"
      assert_equal f32(expected), f32(actual), "#{label}: resolved value must be f32-identical"
      tolerance = [expected.abs, actual.abs].max * 2**-50
      assert_operator (actual - expected).abs, :<=, tolerance,
                     "#{label}: drift beyond the platform-libm last-bits allowance"
    end
  end

  def test_every_noise2d_case_from_the_upstream_range_is_covered
    labels = FIXTURE["cases"].select { |entry| entry["config"]["oscType"] == 6 }
                            .map { |entry| entry["label"] }.to_set
    %w[defaults range speed2.5 offset0.3 seed42 fm-speed nested-min negative-speed].each do |suffix|
      assert_includes labels, "kind6-#{suffix}", "missing kind6-#{suffix}"
    end
  end

  # The live check runs the pinned upstream tree's own evaluator over the
  # fixture through node (Pipeline is an ESM module there), then requires this
  # port's evaluator to agree on every case.
  def test_osc_automation_reproves_against_the_live_pinned_upstream_tree_when_available
    reference_root = ENV["NM_REFERENCE_ROOT"]
    skip "NM_REFERENCE_ROOT is not set" unless reference_root
    skip "node is unavailable" unless system("node", "--version", out: File::NULL, err: File::NULL)

    pipeline = File.join(reference_root, "shaders", "src", "runtime", "pipeline.js")
    fixture_path = File.expand_path("fixtures/osc-automation-golden.json", __dir__)
    script = <<~JS
      import { readFile } from 'node:fs/promises'
      import { pathToFileURL } from 'node:url'
      const upstream = await import(pathToFileURL(process.argv[1]).href)
      const resolveUniformValue = upstream.Pipeline.prototype.resolveUniformValue
      const fixture = JSON.parse(await readFile(process.argv[2], 'utf8'))
      const specs = [undefined, { min: 0, max: 1 }, { min: -2, max: 3 },
                     { type: 'int' }, { type: 'int', min: 1, max: 5 }]
      const actuals = fixture.cases.map(({ config, time, specIndex }) =>
        resolveUniformValue.call({ externalState: null },
                                 JSON.parse(JSON.stringify(config)), time,
                                 specs[specIndex] === undefined ? undefined : JSON.parse(JSON.stringify(specs[specIndex]))))
      console.log(JSON.stringify(actuals))
    JS
    out, err, status = Open3.capture3("node", "--input-type=module", "-e", script, pipeline, fixture_path)
    assert status.success?, err
    actuals = JSON.parse(out)
    assert_equal FIXTURE["cases"].length, actuals.length
    FIXTURE["cases"].zip(actuals).each do |entry, actual|
      assert_equal entry["expected"], actual,
                   "live oracle mismatch #{entry['label']} t=#{entry['time']} spec=#{entry['specIndex']}"
    end
  end

  def test_evaluate_automation_keeps_the_0_to_1_oscillator_contract_and_depth_guard
    automation = NoisemakerCpu::Automation
    sine = { "type" => "Oscillator", "oscType" => 0, "min" => 0, "max" => 1, "speed" => 1, "offset" => 0, "seed" => 1 }
    assert_in_delta 0.5, automation.evaluate_automation(sine, 0.25), 1e-12
    assert_equal 0, automation.evaluate_automation(sine, 0)
    assert_in_delta 0.0, automation.evaluate_automation(sine, 1), 1e-12
    assert_equal true, automation.automation_value?(sine)
    assert_equal false, automation.automation_value?({ "type" => "Midi" })
    # Depth > 8 collapses nested fields to the range-scaled zero, as upstream's
    # evaluator does; the top-level oscillator still evaluates deterministically.
    deep = sine
    10.times { deep = { "type" => "Oscillator", "oscType" => 0, "min" => deep, "max" => 1, "speed" => 1, "offset" => 0, "seed" => 1 } }
    deep_value = automation.evaluate_automation(deep, 0.5)
    assert deep_value.is_a?(Numeric) && deep_value.finite? && deep_value >= 0 && deep_value <= 1
  end

  def test_an_osc_parameter_renders_byte_identically_to_its_resolved_numeric_value
    automation = NoisemakerCpu::Automation
    time = 0.25
    animated = render(
      "search synth, filter\nsolid().vignette(brightness: osc(type: sine, min: 0.1, max: 0.4)).write(o0)\nrender(o0)",
      time: time
    )
    spec = NoisemakerCpu::Renderer._automation_param_spec(BUNDLE_EFFECTS.fetch("filter/vignette")["params"].fetch("brightness"))
    expected_value = automation.evaluate_automation(
      { "type" => "Oscillator", "oscType" => 0, "min" => 0.1, "max" => 0.4, "speed" => 1, "offset" => 0, "seed" => 1 },
      time, spec
    )
    numeric = render(
      "search synth, filter\nsolid().vignette(brightness: #{expected_value}).write(o0)\nrender(o0)",
      time: time
    )
    assert_equal numeric.to_rgba8, animated.to_rgba8
  end

  def test_an_osc_value_survives_compile_unchanged_and_animates_across_time
    source = "search synth, filter\nsolid().vignette(brightness: osc(tri)).write(o0)\nrender(o0)"
    early = render(source, time: 0.1)
    mid = render(source, time: 0.5)
    refute_equal early.to_rgba8, mid.to_rgba8
  end

  def test_int_choices_params_round_the_resolved_automation_value
    automation = NoisemakerCpu::Automation
    time = 0.25
    # The conditional int selector receives the upstream resolveUniformValue
    # rounding contract: the resolved automation value is scaled into its
    # declared range when it declares one, otherwise unscaled, then rounded.
    # classicNoisedeck/cellNoise's `shape` selector declares no range, so the
    # resolved value is the rounded 0..1 output directly.
    shape_spec = BUNDLE_EFFECTS.fetch("classicNoisedeck/cellNoise")["params"].fetch("shape")
    assert_equal({ "type" => "int" }, NoisemakerCpu::Renderer._automation_param_spec(shape_spec))
    result = render(
      "search classicNoisedeck\ncellNoise(shape: osc(sine)).write(o0)\nrender(o0)", time: time
    )
    raw = automation.evaluate_automation(
      { "type" => "Oscillator", "oscType" => 0, "min" => 0, "max" => 1, "speed" => 1, "offset" => 0, "seed" => 1 }, time
    )
    numeric = render(
      "search classicNoisedeck\ncellNoise(shape: #{automation.js_round(raw)}).write(o0)\nrender(o0)", time: time
    )
    assert_equal numeric.to_rgba8, result.to_rgba8
    # And the rounded selection is observable: shape 0 and shape 1 differ.
    refute_equal(
      render("search classicNoisedeck\ncellNoise(shape: 0).write(o0)\nrender(o0)", time: time).to_rgba8,
      render("search classicNoisedeck\ncellNoise(shape: 1).write(o0)\nrender(o0)", time: time).to_rgba8
    )
  end

  def test_osc_compile_errors_mirror_the_upstream_contract
    assert_match(/oscKind/, err_str {
      render("search synth, filter\nsolid().vignette(brightness: osc(wobble)).write(o0)\nrender(o0)")
    })
    assert_match(/oscKind/, err_str {
      render("search synth, filter\nsolid().vignette(brightness: osc(7)).write(o0)\nrender(o0)")
    })
    assert_match(/unknown parameter 'phase'/, err_str {
      render("search synth, filter\nsolid().vignette(brightness: osc(type: sine, phase: 1)).write(o0)\nrender(o0)")
    })
    assert_match(/min must be a number/, err_str {
      render("search synth, filter\nsolid().vignette(brightness: osc(type: sine, min: [1, 2])).write(o0)\nrender(o0)")
    })
    # A color parameter keeps rejecting automation values (upstream
    # normalizeValue's non-float/int branches).
    assert_match(/color/, err_str {
      render("search synth\nsolid(color: osc(sine)).write(o0)\nrender(o0)")
    })
  end

  def test_osc_nesting_beyond_the_upstream_depth_limit_is_rejected_at_compile_time
    nested = "osc(type: sine)"
    9.times { nested = "osc(type: sine, min: #{nested})" }
    assert_match(
      /Automation nesting exceeds the maximum depth of 8/,
      err_str {
        render("search synth, filter\nsolid().vignette(brightness: #{nested}).write(o0)\nrender(o0)")
      }
    )
  end

  def test_a_binding_can_hold_an_osc_value_for_reuse_across_steps
    automation = NoisemakerCpu::Automation
    time = 0.25
    bound = render(
      "search synth, filter\nlet wobble = osc(type: sine, min: 0.1, max: 0.4)\n" \
      "solid().vignette(brightness: wobble).write(o0)\nrender(o0)",
      time: time
    )
    spec = NoisemakerCpu::Renderer._automation_param_spec(BUNDLE_EFFECTS.fetch("filter/vignette")["params"].fetch("brightness"))
    expected_value = automation.evaluate_automation(
      { "type" => "Oscillator", "oscType" => 0, "min" => 0.1, "max" => 0.4, "speed" => 1, "offset" => 0, "seed" => 1 },
      time, spec
    )
    numeric = render(
      "search synth, filter\nsolid().vignette(brightness: #{expected_value}).write(o0)\nrender(o0)",
      time: time
    )
    assert_equal numeric.to_rgba8, bound.to_rgba8
  end

  # Iterated effects re-resolve automation per iteration against the
  # iteration's own rewound time (refreshIterationParams). A time-invariant
  # osc value (speed 0) must render byte-identically to the equivalent
  # numeric parameter across the whole iteration loop; a time-varying one
  # must animate the iterated output.
  def test_an_osc_parameter_renders_byte_identically_across_an_iterated_effect
    time = 0.25
    animated = render(
      "search filter, synth\nsolid().motionBlur(amount: osc(type: sine, min: 0.5, max: 0.5, speed: 0))" \
      ".write(o0)\nrender(o0)", time: time
    )
    numeric = render(
      "search filter, synth\nsolid().motionBlur(amount: 50).write(o0)\nrender(o0)", time: time
    )
    assert_equal numeric.to_rgba8, animated.to_rgba8
  end

  def test_an_osc_parameter_animates_an_iterated_effect
    source = "search filter, synth\n" \
             "solid().motionBlur(amount: osc(type: saw, min: 0, max: 1), iterationCount: 3).write(o0)\nrender(o0)"
    early = render(source, time: 0.1)
    mid = render(source, time: 0.5)
    refute_equal early.to_rgba8, mid.to_rgba8
  end
end
