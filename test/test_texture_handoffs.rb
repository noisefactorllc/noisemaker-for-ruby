# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu/renderer"

class TestTextureHandoffs < Minitest::Test
  Renderer = NoisemakerCpu::Renderer
  TINY = { "width" => 1, "height" => 1, "format" => "rgba32f" }.freeze

  def setup
    @original_meta = Renderer.instance_variable_get(:@meta)
    @original_loader = Renderer.method(:_kernel_for)
    @effects = {}
    Renderer.instance_variable_set(:@meta, { "effects" => @effects })
    kernels = {
      "fill" => lambda { |ctx, out|
        value = ctx.uniforms.fetch("value")
        value.is_a?(Array) ? out.replace(value) : out.fill(value)
      },
      "read" => ->(ctx, out) { out.replace(ctx.textures.fetch("src").data.first(4)) },
      "measure" => lambda { |ctx, out|
        src = ctx.textures.fetch("src")
        out.replace([src.data[0], src.width, ctx.textures.fetch("image").data[0], 1])
      },
      "compareSamplers" => lambda { |ctx, out|
        uv = [0.375, 0.5]
        out.replace([ctx.rt.texture(ctx.textures.fetch("regular"), uv)[0],
          ctx.rt.texture(ctx.textures.fetch("external"), uv)[0], 0, 1])
      },
      "half" => ->(_ctx, out) { out.fill(0.5) },
      "optionalSample" => ->(ctx, out) { out.replace(ctx.texture_binding("sample").data.first(4)) },
      "optionalSlot" => ->(ctx, out) { out.replace(ctx.texture_binding("slot").data.first(4)) },
      "tick" => ->(ctx, out) { out.fill((ctx.uniforms.fetch("frame") + 1) * 0.25) },
      "sum" => ->(ctx, out) { out.fill(ctx.textures.values.sum { |src| src.data.first }) },
      "split" => ->(_ctx, out) { out.replace([0.5] * 8) },
    }
    Renderer.define_singleton_method(:_kernel_for) do |key|
      { kernel: kernels.fetch(key), output_names: (key == "split" ? %w[a b] : nil) }
    end
  end

  def teardown
    Renderer.instance_variable_set(:@meta, @original_meta)
    Renderer.define_singleton_method(:_kernel_for, @original_loader)
  end

  def effect(name, passes, kind: "filter", iterated: false, **fields)
    params = { "iterationCount" => { "type" => "int", "default" => 2 } }
    @effects["probe/#{name}"] = {
      "namespace" => "probe", "func" => name, "kind" => kind,
      "params" => params, "paramOrder" => params.keys, "iterated" => iterated,
      "passes" => passes, "textures" => {},
    }.merge(fields.transform_keys(&:to_s))
  end

  def shader_pass(key, output = "outputTex", inputs = {}, **fields)
    { "name" => key, "key" => key, "program" => key, "inputs" => inputs,
      "outputs" => { "color" => output } }.merge(fields.transform_keys(&:to_s))
  end

  def fill(target, value)
    shader_pass("fill", target, {}, uniforms: { "value" => value })
  end

  def render(chain)
    Renderer.render_dsl("search probe\n#{chain}.write(o0)\nrender(o0)", width: 2, height: 2)
  end

  def test_pass_conditions_and_repeat_use_the_effects_bound_uniforms
    flag = { "flag" => { "type" => "int", "uniform" => "flag", "default" => 0 } }
    second = fill("outputTex", 0.75)
    second["uniforms"]["flag"] = 1
    [false, true].each do |iterated|
      [[{ "conditions" => { "runIf" => [{ "uniform" => "flag", "equals" => 1 }] } }, 0.125],
       [{ "conditions" => { "skipIf" => [{ "uniform" => "flag", "equals" => "0" }] } }, 0.125],
       [{ "conditions" => { "runIf" => [{ "uniform" => "missing", "equals" => 0 }] } }, 0.125],
       [{ "conditions" => { "skipIf" => [{ "uniform" => "missing", "equals" => 0 }] } }, 0.75],
       [{ "repeat" => "flag" }, 0.125]].each do |control, expected|
        effect("controlled", [fill("outputTex", 0.125), second.merge(control)], kind: "generator",
               iterated: iterated, params: flag, paramOrder: flag.keys)
        assert_equal expected, render("controlled()").data.first, control.inspect
      end
    end
  end

  def test_pass_conditions_read_the_parameter_name_or_its_define
    [false, true].each do |iterated|
      [{ "default" => 1 }, { "default" => 1, "define" => "FLAG", "uniform" => "other" }].each do |binding|
        target = binding.fetch("define", "flag")
        params = { "flag" => { "type" => "int" }.merge(binding) }
        passes = [fill("outputTex", 0.125), fill("outputTex", 0.75).merge(
          "repeat" => target, "conditions" => { "runIf" => [{ "uniform" => target, "equals" => 1 }] }
        )]
        effect("controlled", passes, kind: "generator", iterated: iterated, params: params, paramOrder: params.keys)
        assert_equal 0.75, render("controlled()").data.first
        assert_equal 0.125, render("controlled(flag: 0)").data.first
      end
    end
  end

  def test_shared_storage_updates_published_image_and_agent_in_place
    [false, true].each do |iterated|
      storage = ->(value) { fill("unused", value).merge("outputs" => {}, "storageTextures" => { "dst" => "global_work" }) }
      effect("emit", [storage.call(0.25)], kind: "generator", iterated: iterated, textures: { "global_work" => TINY },
             outputTex: "global_work", outputXyz: "global_work")
      effect("edit", [storage.call(0.75), shader_pass("measure", "outputTex", { "image" => "inputTex", "src" => "inputXyz" })],
             iterated: iterated, textures: { "outputXyz" => TINY })
      assert_equal [0.75, 1, 0.75, 1], render("emit().edit()").data.first(4)

      effect("reader", [shader_pass("read", "outputTex", { "src" => "global_work" })])
      error = assert_raises(RuntimeError) { render("emit().write(o1)\nread(o1).reader()") }
      assert_match(/requires texture "global_work"/, error.message)
    end
  end

  def test_image_and_agent_aliases_follow_transitive_writes
    [false, true].each do |iterated|
      effect("emit", [fill("work", 0.25)], kind: "generator", iterated: iterated,
             textures: { "work" => TINY, "outputTex" => {} }, outputTex: "work", outputVel: "work")
      effect("forward", [shader_pass("read", "private", { "src" => "inputTex" })], outputTex: "inputTex", outputXyz: "inputVel")
      effect("edit", [fill("inputXyz", 0.75), shader_pass("measure", "outputTex", { "image" => "inputTex", "src" => "inputVel" })])
      assert_equal [0.75, 1, 0.75, 1], render("emit().forward().edit()").data.first(4)
    end
  end

  def test_particle_readers_run_on_each_tick_and_new_emitters_clear_channels
    effect("emit", [shader_pass("tick", "global_xyz"), fill("outputTex", 0)], kind: "generator", iterated: true,
           textures: { "global_xyz" => TINY }, outputVel: "global_xyz")
    effect("sum", [shader_pass("sum", "outputTex", { "particle" => "inputVel", "prior" => "selfTex" })])
    assert_equal 0.75, render("emit().sum()").data.first
    effect("nextEmit", [fill("outputTex", 0)], iterated: true, textures: { "global_xyz" => TINY })
    error = assert_raises(RuntimeError) { render("emit().nextEmit().sum()") }
    assert_match(/requires texture "inputVel"/, error.message)
  end

  def test_particle_group_shares_the_numeric_value_of_an_emitter_size_preset
    params = { "stateSize" => { "type" => "int", "uniform" => "stateSize", "default" => 1, "choices" => { "x2" => 2 } },
               "iterationCount" => { "type" => "int", "default" => 1 } }
    effect("emit", [fill("outputTex", 0.5)], kind: "generator", iterated: true, params: params,
      paramOrder: params.keys, textures: { "global_xyz" => TINY })
    dimension = { "param" => "stateSize", "inherit" => true }
    effect("inspectSize", [shader_pass("measure", "outputTex", { "src" => "global_test_base_color", "image" => "inputTex" })],
      textures: { "global_test_base_color" => { "width" => dimension, "height" => dimension } })
    assert_equal [0, 2, 0.5, 1], render("emit(stateSize: x2).inspectSize()").data.first(4)
  end

  def test_pixel_blend_uses_each_mrt_attachments_previous_color
    [false, true].each do |iterated|
      effect("colors", [fill("_left", 0.25), fill("_right", 0.75),
        shader_pass("split", nil, {}, drawBuffers: 2, outputs: { "a" => "_left", "b" => "_right" },
             blend: ["DST_COLOR", 0]),
        shader_pass("measure", "outputTex", { "src" => "_left", "image" => "_right" }),
        fill("outputTex", 0.5).merge("blend" => [0, 1])], kind: "generator", iterated: iterated)
      assert_equal [0.125, 2, 0.375, 1], render("colors()").data.first(4)
    end
  end

  def test_blend_factors_use_source_and_backdrop_alpha_for_all_four_channels
    src = [0.5, 0.25, 0.75, 0.5]
    dst = [0.25, 0.5, 1, 0.75]
    {
      ["src-alpha", "ONE_MINUS_SRC_ALPHA"] => [0.375, 0.375, 0.875, 0.625],
      [0x0305, "zero"] => [0.125, 0.0625, 0.1875, 0.125],
      true => [0.75, 0.75, 1.75, 1.25],
    }.each do |blend, expected|
      effect("colors", [fill("outputTex", dst), fill("outputTex", src).merge("blend" => blend)], kind: "generator")
      assert_equal expected, render("colors()").data.first(4)
    end
  end

  def test_standalone_feedback_can_be_supplied_through_a_declared_surface_parameter
    passes = [shader_pass("read", "saved", { "src" => "_feedback" }), shader_pass("half", "_feedback"),
              shader_pass("read", "outputTex", { "src" => "saved" })]
    params = { "feedbackMap" => { "type" => "surface", "texture" => "_feedback", "default" => "none" } }
    effect("filter", passes, textures: { "_feedback" => TINY }, params: params, paramOrder: params.keys)
    supplied = NoisemakerCpu::Surface.new(1, 1).clear([0.75] * 4)
    result = Renderer.render_effect("probe/filter", {}, { "_feedback" => supplied }, width: 1, height: 1)
    assert_equal [0.75] * 4, result.data
  end

  def test_standalone_unwritten_declaration_reads_previous_pass_unless_an_input_is_supplied
    measure = shader_pass("measure", "outputTex", { "src" => "aux", "image" => "prior" })
    effect("filter", [shader_pass("half", "prior"), measure], textures: { "aux" => TINY })
    render = ->(inputs) { Renderer.render_effect("probe/filter", {}, inputs, width: 5, height: 4).data.first(4) }
    assert_equal [0.5, 5, 0.5, 1], render.call({})
    supplied = NoisemakerCpu::Surface.new(2, 3).clear([0.75] * 4)
    assert_equal [0.75, 2, 0.5, 1], render.call(aux: supplied)
  end

  def test_standalone_declared_samplers_and_raw_pass_sources_resolve_independently
    params = { "map" => { "type" => "surface", "texture" => "slot", "default" => "none" } }
    mapped = NoisemakerCpu::Surface.new(1, 1).clear([0.125] * 4)
    sample = NoisemakerCpu::Surface.new(1, 1).clear([0.375] * 4)
    render = ->(inputs) { Renderer.render_effect("probe/filter", {}, inputs, width: 1, height: 1).data[0] }
    effect("filter", [shader_pass("optionalSample", "outputTex", { "sample" => "slot" })],
      params: params, paramOrder: params.keys)
    assert_equal 0, render.call(map: mapped)
    assert_equal 0.375, render.call(sample: sample)
    assert_equal 0.125, render.call(slot: mapped, sample: sample)

    read_slot = shader_pass("optionalSlot", "outputTex", { "slot" => "missing" })
    effect("filter", [read_slot], params: params, paramOrder: params.keys)
    assert_equal 0.125, render.call(map: mapped)
    effect("filter", [shader_pass("half", "prior"), read_slot], params: params, paramOrder: params.keys)
    assert_equal 0.5, render.call(map: mapped)
  end

  def test_standalone_image_returns_the_last_executed_pass
    first = NoisemakerCpu::Surface.new(1, 1).clear([0.25] * 4)
    last = NoisemakerCpu::Surface.new(1, 1).clear([0.75] * 4)
    effect("filter", [shader_pass("read", "outputTex", { "src" => "first" }),
                      shader_pass("read", "work", { "src" => "last" })], outputTex: "outputTex")
    result = Renderer.render_effect("probe/filter", {}, { first: first, last: last, outputTex: first }, width: 1, height: 1)
    assert_equal [0.75] * 4, result.data
  end

  def test_standalone_sampler_modes_are_independent_when_they_share_caller_pixels
    effect("filter", [shader_pass("compareSamplers", "outputTex", { "regular" => "inputTex", "external" => "external" })],
      externalTexture: "external")
    gradient = NoisemakerCpu::Surface.new(2, 1, [0, 0, 0, 1, 1, 0, 0, 1])
    %w[nearest linear].each do |mode|
      gradient.filter(mode)
      result = Renderer.render_effect("probe/filter", {}, { inputTex: gradient, external: gradient }, width: 1, height: 1)
      assert_equal [0, 0.25, 0, 1], result.data
      assert_equal mode, gradient.filter
    end
  end

  def test_scratch_dimensions_use_resources_available_before_the_first_pass
    [false, true].each do |iterated|
      textures = { "anchor" => { "width" => 3, "height" => 1 },
                   "aux" => { "width" => { "inputOverride" => "anchor", "param" => "n" }, "height" => 1 } }
      params = { "n" => { "type" => "int", "default" => 1 }, "iterationCount" => { "type" => "int", "default" => 1 } }
      measure = shader_pass("measure", "outputTex", { "src" => "aux", "image" => "anchor" })
      options = { kind: "generator", textures: textures, params: params, paramOrder: params.keys, iterated: iterated }
      effect("inspectSize", [fill("anchor", 0.25), measure], **options)
      assert_equal 1, render("inspectSize()").data[1]
      effect("inspectSize", [measure], **options)
      assert_equal(iterated ? 1 : 3, render("inspectSize()").data[1])
    end
  end

  def test_declared_sampler_uses_its_resource_name_in_the_dsl
    effect("emit", [fill("outputTex", 0.25)], kind: "generator")
    params = { "map" => { "type" => "surface", "texture" => "src", "default" => "inputTex" } }
    effect("sample", [shader_pass("read", "outputTex", { "src" => "map" })], params: params, paramOrder: ["map"])
    assert_match(/requires texture "map"/, assert_raises(RuntimeError) { render("emit().sample()") }.message)

    effect("sample", [shader_pass("read")], params: params, paramOrder: ["map"])
    texture = NoisemakerCpu::Surface.new(1, 1).clear([0.5] * 4)
    assert_equal 0.5, Renderer.render_effect("probe/sample", {}, { map: texture }, width: 1, height: 1).data.first
  end

  def test_authored_outputs_take_precedence_over_configured_fallbacks
    [false, true].each do |iterated|
      effect("emit", [fill("work", 0.125), fill("outputTex", 0.25), fill("outputRgba", 0.75)],
        kind: "generator", iterated: iterated, outputTex: "work", outputRgba: "work")
      effect("measure", [shader_pass("measure", "outputTex", { "image" => "inputTex", "src" => "inputRgba" })])
      assert_equal [0.75, 2, 0.25, 1], render("emit().measure()").data.first(4)
    end
  end

  def test_first_and_next_particle_ticks_rebind_the_current_image_surface_parameter
    effect("emit", [shader_pass("tick", "global_xyz")], kind: "generator", iterated: true,
      textures: { "global_xyz" => TINY }, outputTex: "global_xyz", outputRgba: "global_xyz")
    params = { "map" => { "type" => "surface", "texture" => "src", "default" => "inputTex" } }
    effect("accumulate", [shader_pass("sum", "outputTex", { "held" => "selfTex", "map" => "src", "agent" => "inputRgba" })],
      params: params, paramOrder: ["map"])
    assert_equal 1.5, render("emit().accumulate()").data.first
  end

  def test_standalone_accepts_sampler_and_source_keys_and_keeps_explicit_input
    first = NoisemakerCpu::Surface.new(2, 2).clear([0.25] * 4)
    override = NoisemakerCpu::Surface.new(2, 2).clear([0.75] * 4)
    effect("filter", [fill("intermediate", 0.5), shader_pass("read", "outputTex", { "src" => "inputTex" })])
    render_effect = ->(inputs) { Renderer.render_effect("probe/filter", {}, inputs, width: 2, height: 2).data.first }
    assert_equal 0.25, render_effect.call(inputTex: first, src: override)
    assert_equal 0.75, render_effect.call(src: override)
    effect("filter", [fill("intermediate", 0.5), shader_pass("read", "outputTex", { "src" => "prev" })], kind: "generator")
    assert_equal 0.5, render_effect.call(inputTex: first)
    assert_equal 0.75, render_effect.call(inputTex: first, prev: override)
    assert_match(/requires texture "prev"/, assert_raises(RuntimeError) { render("filter()") }.message)
  end
end
